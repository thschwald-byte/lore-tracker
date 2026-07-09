defmodule HubWeb.MicLiveTest do
  @moduledoc """
  Issue #405: State-Maschine der sticky MicLive (Capture-Owner). Getrieben
  über handle_info/handle_event auf einem Bare-Socket — der Hub hat kein
  LiveViewTest/ConnCase-Harness, das Verhalten im Browser deckt der PR-Test ab.
  Hier: die kritischen Übergänge (start, stop, Multi-Kampagne-Switch,
  SessionEnded matcht nur die laufende Session).
  """

  use ExUnit.Case, async: true

  alias HubWeb.MicLive

  defp socket(assigns \\ %{}) do
    base = %{
      current_user: %{discord_id: "did-me"},
      recording_campaign_id: nil,
      recording_session_id: nil,
      capture_source: nil,
      mic_on?: false,
      show_silence_modal?: false,
      superseded?: false
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, assigns) |> Map.put(:__changed__, %{})
    }
  end

  # Issue #468: ein audio_chunk-Event durch den Handler schicken (kein Worker
  # registriert → forward_audio_chunk == 0 → Verlust). Cut 3: Handler returnt
  # jetzt {:reply, %{delivered: ...}, socket} damit der Browser-Hook den Status
  # kennt + ggf. den Chunk puffert.
  defp push_chunk(s) do
    {:reply, %{delivered: false}, s2} =
      MicLive.handle_event("audio_chunk", %{"session_id" => "sess-1", "chunk" => "QUJD"}, s)

    s2
  end

  # Issue #772: einen audio_nack durch den Handler schicken (default: für die
  # gerade laufende Session).
  defp nack(s, sid \\ nil) do
    sid = sid || s.assigns.recording_session_id
    {:noreply, s2} = MicLive.handle_info({:audio_nack, sid}, s)
    s2
  end

  describe "topic helpers" do
    test "command + state topics sind per-User getrennt" do
      assert MicLive.mic_topic("123") == "user_mic:123"
      assert MicLive.mic_state_topic("123") == "user_mic_state:123"
      refute MicLive.mic_topic("123") == MicLive.mic_state_topic("123")
    end
  end

  describe "start/stop capture" do
    test ":start_capture setzt das Recording-Tupel + mic_on?" do
      {:noreply, s} =
        MicLive.handle_info({:start_capture, "camp-a", "sess-1", "dev-x", "mic"}, socket())

      assert s.assigns.recording_campaign_id == "camp-a"
      assert s.assigns.recording_session_id == "sess-1"
      assert s.assigns.capture_source == "mic"
      assert s.assigns.mic_on? == true
    end

    test ":stop_capture leert das Tupel" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      {:noreply, s} = MicLive.handle_info({:stop_capture}, s0)

      assert s.assigns.recording_campaign_id == nil
      assert s.assigns.recording_session_id == nil
      assert s.assigns.mic_on? == false
    end
  end

  describe "Multi-Kampagne-Switch" do
    test ":start_capture für B überschreibt das laufende A (ein Mikro pro User)" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-a",
          capture_source: "mic",
          mic_on?: true
        })

      {:noreply, s} =
        MicLive.handle_info({:start_capture, "camp-b", "sess-b", "dev-y", "mic"}, s0)

      assert s.assigns.recording_campaign_id == "camp-b"
      assert s.assigns.recording_session_id == "sess-b"
      assert s.assigns.mic_on? == true
    end
  end

  describe "SessionEnded-Auto-Stop" do
    test "stoppt wenn die beendete Session die laufende ist" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      ev = {:event_appended, %{payload: %{"kind" => "SessionEnded", "id" => "sess-1"}}}
      {:noreply, s} = MicLive.handle_info(ev, s0)

      assert s.assigns.mic_on? == false
      assert s.assigns.recording_session_id == nil
    end

    test "ignoriert SessionEnded einer FREMDEN Session" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      ev = {:event_appended, %{payload: %{"kind" => "SessionEnded", "id" => "sess-OTHER"}}}
      {:noreply, s} = MicLive.handle_info(ev, s0)

      # läuft unverändert weiter
      assert s.assigns.mic_on? == true
      assert s.assigns.recording_session_id == "sess-1"
    end
  end

  describe "Silence-Modal" do
    test "mic_silence_warning öffnet das Modal, dismiss schließt" do
      {:noreply, s1} = MicLive.handle_event("mic_silence_warning", %{}, socket())
      assert s1.assigns.show_silence_modal? == true

      {:noreply, s2} = MicLive.handle_event("mic_silence_dismiss", %{}, s1)
      assert s2.assigns.show_silence_modal? == false
    end
  end

  describe "audio_chunk guard" do
    test "leerer/fehlender chunk crasht nicht (no-op, returnt delivered:false)" do
      s = socket(%{recording_campaign_id: "camp-a", capture_source: "mic"})

      assert {:reply, %{delivered: false}, ^s} =
               MicLive.handle_event("audio_chunk", %{"foo" => "bar"}, s)
    end
  end

  # Issue #468 (Fall a): kein Member-Worker erreichbar → forward_audio_chunk gibt
  # 0, der Chunk ist verloren. Ab 6 verworfenen Chunks in Folge wird der User
  # einmalig via mic_state_topic gewarnt (CampaignLive zeigt Flash). Im Test ist
  # KEIN Worker registriert → jede Zustellung schlägt fehl (streak wächst).
  describe "Chunk-Drop-Warnung (#468)" do
    setup do
      Phoenix.PubSub.subscribe(Hub.PubSub, MicLive.mic_state_topic("did-me"))
      :ok
    end

    test "warnt erst beim 6. verworfenen Chunk, nicht früher" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-drop-test",
          recording_session_id: "sess-1",
          capture_source: "mic",
          chunk_drop_streak: 0
        })

      s5 = Enum.reduce(1..5, s0, fn _, acc -> push_chunk(acc) end)
      assert s5.assigns.chunk_drop_streak == 5
      refute_received {:mic_audio_dropping, _}

      s6 = push_chunk(s5)
      assert s6.assigns.chunk_drop_streak == 6
      assert_received {:mic_audio_dropping, "sess-1"}
    end

    test "warnt nur EINMAL pro Strähne (kein Spam ab Chunk 7)" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-drop-test",
          recording_session_id: "sess-1",
          capture_source: "mic",
          chunk_drop_streak: 6
        })

      _s = push_chunk(s0) |> push_chunk()
      refute_received {:mic_audio_dropping, _}
    end
  end

  # Issue #396: Multi-Tab/Geräte-Übernahme. Supersede (#415) stoppt den älteren
  # Tab schon automatisch — hier wird zusätzlich der Übernahme-Hinweis gesetzt,
  # damit der User nicht ratlos vor einer „verschwundenen" Aufnahme steht.
  describe "Übernahme-Hinweis (#396)" do
    test "Supersede von fremdem PID bei laufender Aufnahme stoppt + setzt superseded?" do
      other = spawn(fn -> :ok end)
      s = socket(%{mic_on?: true, recording_campaign_id: "camp-a", recording_session_id: "s1"})

      {:noreply, s2} = MicLive.handle_info({:supersede_capture, other}, s)

      assert s2.assigns.mic_on? == false
      assert s2.assigns.recording_campaign_id == nil
      assert s2.assigns.superseded? == true
    end

    test "Supersede vom eigenen PID (self) lässt die laufende Aufnahme unberührt" do
      s = socket(%{mic_on?: true, recording_campaign_id: "camp-a"})

      {:noreply, s2} = MicLive.handle_info({:supersede_capture, self()}, s)

      assert s2.assigns.mic_on? == true
      assert s2.assigns.superseded? == false
    end

    test "Supersede ohne laufende Aufnahme (mic_on? false) → kein Hinweis" do
      other = spawn(fn -> :ok end)
      {:noreply, s2} = MicLive.handle_info({:supersede_capture, other}, socket(%{mic_on?: false}))
      assert s2.assigns.superseded? == false
    end

    test "dismiss_superseded blendet den Hinweis aus" do
      {:noreply, s2} =
        MicLive.handle_event("dismiss_superseded", %{}, socket(%{superseded?: true}))

      assert s2.assigns.superseded? == false
    end

    test "eigener Capture-Start räumt einen alten Hinweis weg" do
      s = socket(%{superseded?: true})

      {:noreply, s2} =
        MicLive.handle_info({:start_capture, "camp-a", "s1", "dev-x", "mic"}, s)

      assert s2.assigns.superseded? == false
    end
  end

  # Issue #772 (Fall b): Wrong-Worker-Drop. Der Session-Halter ging offline,
  # pick_leader fiel auf einen Worker OHNE Sink zurück → forward_audio_chunk gab
  # trotzdem 1 (delivered), der Sync-Streak (#468) greift nicht. Der verwerfende
  # Worker meldet den Drop per audio_nack; MicLive warnt ab @nack_warn_count (4)
  # NACKs derselben laufenden Session — über EINEN eigenen Zähler, den der
  # synchrone delivered=true-Reset nicht überstimmen kann.
  describe "Wrong-Worker-NACK-Warnung (#772)" do
    setup do
      Phoenix.PubSub.subscribe(Hub.PubSub, MicLive.mic_state_topic("did-me"))
      :ok
    end

    test "warnt erst beim 4. NACK, nicht früher" do
      s0 = socket(%{recording_campaign_id: "camp-a", recording_session_id: "sess-1"})

      s3 = Enum.reduce(1..3, s0, fn _, acc -> nack(acc) end)
      assert s3.assigns.nack_count == 3
      refute_received {:mic_audio_dropping, _}

      s4 = nack(s3)
      assert s4.assigns.nack_warned? == true
      assert_received {:mic_audio_dropping, "sess-1"}
    end

    test "warnt nur EINMAL (kein Spam ab NACK 5)" do
      s0 = socket(%{recording_campaign_id: "camp-a", recording_session_id: "sess-1"})
      s4 = Enum.reduce(1..4, s0, fn _, acc -> nack(acc) end)
      assert_received {:mic_audio_dropping, "sess-1"}

      _ = s4 |> nack() |> nack()
      refute_received {:mic_audio_dropping, _}
    end

    test "NACK einer FREMDEN Session wird ignoriert (kein Zähler, keine Warnung)" do
      s0 = socket(%{recording_campaign_id: "camp-a", recording_session_id: "sess-1"})
      s = Enum.reduce(1..10, s0, fn _, acc -> nack(acc, "sess-OTHER") end)

      assert (s.assigns[:nack_count] || 0) == 0
      refute_received {:mic_audio_dropping, _}
    end

    test "Sync-Streak und NACK-Zähler sind getrennt (Kern des #772-Fixes)" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic"
        })

      s = s0 |> nack() |> nack()
      # push_chunk → kein Worker → delivered=false → chunk_drop_streak++ ,
      # nack_count bleibt unberührt (sonst würde der Sync-Pfad den NACK-Zähler
      # zurücksetzen und die Warnung nie auslösen).
      s = push_chunk(s)

      assert s.assigns.nack_count == 2
      assert s.assigns.chunk_drop_streak == 1
    end

    test "start_capture resettet den NACK-Zähler (per-Recording, kein Leak)" do
      s0 = socket(%{recording_campaign_id: "camp-a", recording_session_id: "sess-1"})
      s3 = Enum.reduce(1..3, s0, fn _, acc -> nack(acc) end)
      assert s3.assigns.nack_count == 3

      {:noreply, s} =
        MicLive.handle_info({:start_capture, "camp-a", "sess-2", "dev-x", "mic"}, s3)

      assert s.assigns.nack_count == 0
      assert s.assigns.nack_warned? == false
    end
  end
end
