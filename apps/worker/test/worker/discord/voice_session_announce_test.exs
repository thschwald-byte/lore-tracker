defmodule Worker.Discord.VoiceSessionAnnounceTest do
  @moduledoc """
  Issue #1013: die VERDRAHTUNG der Beitritts-Ansagen in der VoiceSession.

  Die Session ist ohne echten Nostrum-Bot nicht STARTBAR — aber ihre Callbacks
  sind gewöhnliche Funktionen und mit einem `initial_state/3`-State direkt
  aufrufbar (dieselbe Erkenntnis wie `voice_session_test.exs` für terminate/2).
  Nostrum-Aufrufe im Pfad (`Cache.Me`, `Voice.play`) sind best-effort gekapselt
  und degradieren im Test zu `nil`/`{:error, …}` — genau die Pfade, die hier
  mit-geprüft werden (nichts crasht, Fehler sind laut statt still).

  NICHT hier testbar (braucht den echten Bot, → Live-Verifikation #1019):
  dass eine Ansage hörbar abgespielt wird und die busy-Ablehnung von
  `Voice.play/4` im Feld wirklich als busy klassifiziert wird.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Discord.AnnounceQueue
  alias Worker.Discord.VoiceSession

  @cfg %{
    campaign_id: "camp-1013",
    session_id: "sess-1013",
    guild_id: 999,
    voice_channel_id: 777
  }

  setup do
    clear_all_tables!()

    # Der Consent-Pfad läuft über den echten Materializer (Muster
    # audio_consent_status_convergence_test), der TTS-Task über den echten
    # Task-Supervisor — die Worker-App-Struktur läuft in der Test-Suite nicht.
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    unless Process.whereis(Worker.TaskSupervisor) do
      start_supervised!({Task.Supervisor, name: Worker.TaskSupervisor})
    end

    :ok
  end

  defp state(overrides \\ %{}) do
    # session_start_ms MUSS eine echte Monotonic-Zeit sein (wie in init/1):
    # mit 0 wäre `elapsed_ms` die ROHE Monotonic-Uhr — auf Linux negativ —,
    # und jede Consent-Prüfung läge „vor" jedem Grant-Intervall.
    @cfg
    |> VoiceSession.initial_state(nil, System.monotonic_time(:millisecond))
    |> Map.put(:listening?, true)
    |> Map.merge(overrides)
  end

  defp cast(state, msg) do
    {:noreply, state} = VoiceSession.handle_cast(msg, state)
    state
  end

  defp info(state, msg) do
    {:noreply, state} = VoiceSession.handle_info(msg, state)
    state
  end

  describe "Beitritt (voice_state-Cast)" do
    test "erster Beitritt: Begrüßung gereiht, Name gemerkt, Pending vorgemerkt, Queue gekickt" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})

      assert "111" in s.participants
      assert AnnounceQueue.name_for(s.announce_queue, "111") == "Grognak"
      {item, _} = AnnounceQueue.pop(s.announce_queue)
      assert item == {:join, "Grognak"}
      # Kein Consent bekannt → im Debounce-Fenster für die Sammel-Erinnerung.
      assert MapSet.member?(s.pending_dids, "111")
      assert is_reference(s.pending_timer)
      # Drain wurde angestoßen (0-ms-Timer an self()).
      assert_receive :queue_next
    end

    test "Reconnect (Leave dann Join): KEINE zweite Begrüßung" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      {_, q} = AnnounceQueue.pop(s.announce_queue)
      s = %{s | announce_queue: q}

      s = cast(s, {:voice_state, 111, nil, nil})
      s = cast(s, {:voice_state, 111, 777, nil})

      assert AnnounceQueue.empty?(s.announce_queue),
             "Reconnect erzeugte eine zweite Begrüßung — die Reconnect-Schleife aus dem Issue"
    end

    test "Mute/Video (gleicher Kanal, kein Übergang): keine Begrüßung" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      {_, q} = AnnounceQueue.pop(s.announce_queue)
      s = %{s | announce_queue: q}

      # Discord feuert VOICE_STATE_UPDATE auch bei Mute — channel bleibt 777,
      # die Person ist schon Teilnehmer → joined? == false.
      s = cast(s, {:voice_state, 111, 777, "Grognak"})

      assert AnnounceQueue.empty?(s.announce_queue)
    end

    test "Wechsel in fremden Kanal: raus aus Teilnehmern UND aus dem Pending-Fenster" do
      s = cast(state(), {:voice_state, 111, 777, nil})
      assert MapSet.member?(s.pending_dids, "111")

      s = cast(s, {:voice_state, 111, 555, nil})

      refute "111" in s.participants

      refute MapSet.member?(s.pending_dids, "111"),
             "Wer weg ist, darf in der Sammel-Ansage nicht mehr erwähnt werden"
    end

    test "Beitritt einer Person MIT persistiertem Consent: Begrüßung ja, Pending nein" do
      # Persistierter Consent (aktuelle Wortlaut-Version) über den echten
      # Materializer-Pfad — dieselbe Quelle, die auch der Flush konsultiert.
      "AudioConsentRecorded"
      |> event(
        %{
          "discord_id" => "222",
          "version" => Worker.Recording.ConsentPhrase.version(),
          "accepted_at" => "2026-08-13T10:00:00Z"
        },
        1,
        # Ohne event_id verwirft der #1005-LWW-Guard den Status-Write still —
        # die Convergence-Tests setzen sie aus demselben Grund explizit.
        event_id: "e-consent-222"
      )
      |> Worker.Materializer.apply_event()

      s = cast(state(), {:voice_state, 222, 777, "Vex"})

      {item, _} = AnnounceQueue.pop(s.announce_queue)
      assert item == {:join, "Vex"}

      refute MapSet.member?(s.pending_dids, "222"),
             "Wer schon zugestimmt hat, braucht keine Erinnerung (nur-bei-Bedarf-Regel)"
    end
  end

  describe "Pending-Fenster (:pending_fire)" do
    test "Sammelform: zwei Beitritte im Fenster → EIN pending-Item mit beiden Namen" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      s = cast(s, {:voice_state, 112, 777, "Vex"})

      # Begrüßungen aus der Queue nehmen, damit nur das pending-Item übrig ist.
      {_, q} = AnnounceQueue.pop(s.announce_queue)
      {_, q} = AnnounceQueue.pop(q)
      s = %{s | announce_queue: q}

      s = info(s, :pending_fire)

      {item, _} = AnnounceQueue.pop(s.announce_queue)
      assert {:pending, names} = item
      assert Enum.sort(names) == ["Grognak", "Vex"]
      assert s.pending_dids == MapSet.new()
      assert s.pending_timer == nil
    end

    test "wer bis zum Feuern zugestimmt hat, fällt aus der Erinnerung" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      s = cast(s, {:consent_click, :grant, "111", System.monotonic_time(:millisecond)})

      # Der Klick nimmt die Person sofort aus dem Fenster …
      refute MapSet.member?(s.pending_dids, "111")

      # … und selbst wenn sie noch drin stünde, prüft das Feuern den Consent
      # erneut (allowed_now?).
      s = %{s | pending_dids: MapSet.new(["111"])}
      s = info(%{s | announce_queue: AnnounceQueue.new()}, :pending_fire)

      assert AnnounceQueue.empty?(s.announce_queue),
             "Erinnerung an jemanden, der längst zugestimmt hat (der gemeldete Ärger)"
    end

    test "wer den Kanal verlassen hat, wird nicht erinnert" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      s = cast(s, {:voice_state, 111, nil, nil})
      s = info(%{s | announce_queue: AnnounceQueue.new()}, :pending_fire)

      assert AnnounceQueue.empty?(s.announce_queue)
    end
  end

  describe "Consent-Klick" do
    test "Zustimmung reiht die hörbare Bestätigung" do
      s = cast(state(), {:voice_state, 111, 777, "Grognak"})
      s = %{s | announce_queue: AnnounceQueue.note_name(AnnounceQueue.new(), "111", "Grognak")}

      s = cast(s, {:consent_click, :grant, "111", System.monotonic_time(:millisecond)})

      {item, _} = AnnounceQueue.pop(s.announce_queue)
      assert item == {:granted, "Grognak"}
    end

    test "Widerruf reiht KEINE Ansage" do
      s = cast(state(), {:voice_state, 111, 777, nil})
      s = %{s | announce_queue: AnnounceQueue.new()}

      s = cast(s, {:consent_click, :revoke, "111", System.monotonic_time(:millisecond)})

      assert AnnounceQueue.empty?(s.announce_queue)
    end
  end

  describe "Queue-Drain (:queue_next)" do
    test "vor dem Zuhören wartet die Queue (die #989-Erst-Ansage hat Vorrang)" do
      s = state(%{listening?: false})
      s = %{s | announce_queue: AnnounceQueue.push(AnnounceQueue.new(), {:join, "A"})}

      s = info(s, :queue_next)

      refute AnnounceQueue.empty?(s.announce_queue)
      assert s.queue_timer == nil
    end

    test "leeres pending-Item (niemand übrig) wird übersprungen statt gesprochen" do
      s = state()
      s = %{s | announce_queue: AnnounceQueue.push(AnnounceQueue.new(), {:pending, []})}

      s = info(s, :queue_next)

      # text_for_pending([]) == nil → Item verworfen, Drain weitergereicht.
      assert AnnounceQueue.empty?(s.announce_queue)
      refute s.tts_busy?
      assert_receive :queue_next
    end

    test "Item mit Text startet den TTS-Task (busy-Flag gesetzt)" do
      s = state()
      s = %{s | announce_queue: AnnounceQueue.push(AnnounceQueue.new(), {:join, "Grognak"})}

      s = info(s, :queue_next)

      assert s.tts_busy?
      # piper ist im Test nicht konfiguriert → der Task meldet den benannten
      # Fehlzustand zurück (kein Crash, kein Stillstand).
      assert_receive {:announce_tts, {:join, "Grognak"}, {:error, :piper_not_configured}}, 2_000
    end

    test "laufender TTS-Task: Drain wartet auf dessen Ergebnis" do
      s = state(%{tts_busy?: true})
      s = %{s | announce_queue: AnnounceQueue.push(AnnounceQueue.new(), {:join, "A"})}

      s = info(s, :queue_next)

      refute AnnounceQueue.empty?(s.announce_queue), "Item darf nicht parallel gezogen werden"
    end
  end

  describe "TTS-Ergebnis ({:announce_tts, …})" do
    test "TTS-Fehler: Item verworfen, Queue läuft weiter, kein Crash" do
      s = state()
      s = %{s | tts_busy?: true}

      s = info(s, {:announce_tts, {:join, "A"}, {:error, :piper_not_configured}})

      refute s.tts_busy?
      assert_receive :queue_next
    end

    test "Play-Fehler (kein echter Bot): Item verworfen, laut geloggt, kein Crash" do
      # Voice.play ohne Nostrum-Bot → rescue → {:error, announce_play_failed}.
      # Der Drain muss weiterlaufen — ein kaputtes Item darf die Queue nie
      # dauerhaft verstopfen.
      s = state(%{tts_busy?: true})

      s = info(s, {:announce_tts, {:join, "A"}, {:ok, "/nonexistent/wav"}})

      refute s.tts_busy?
      assert_receive :queue_next
    end
  end
end
