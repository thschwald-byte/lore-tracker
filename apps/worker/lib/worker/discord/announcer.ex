defmodule Worker.Discord.Announcer do
  @moduledoc """
  Issue #1013: die ORCHESTRIERUNG der Beitritts-Ansagen — herausgelöst aus der
  `VoiceSession`, die damit (erneut) über der God-Module-Grenze lag. Der
  Schnitt ist inhaltlich: alles hier ist EINE Verantwortlichkeit („wann wird
  was angesagt, und wie kommt es fehlertolerant durch den einen Lautsprecher"),
  ohne eigenen Prozess — jede Funktion nimmt den Session-State und gibt ihn
  zurück, die Timer-Nachrichten (`:queue_next`, `:pending_fire`,
  `{:announce_tts, …}`) landen weiter bei der VoiceSession, deren Klauseln
  hierher delegieren.

  Arbeitsteilung:
  - **`AnnounceQueue`** (pure): WAS gesagt werden darf — Begrüßungs-Dedup,
    Erinnerungs-Deckel, Reihenfolge.
  - **`Announcer`** (dieses Modul): WANN und WIE — Debounce-Fenster, TTS im
    supervisten Task, `Voice.play`-Rückgabe-Auswertung, Drain-Disziplin.
  - **`Announcement`** (pure): die TEXTE + piper.

  Drain-Disziplin: EIN Item zur Zeit. `Voice.play/4` lehnt bei laufender
  Wiedergabe ab — der Vorgänger-Code behandelte das als Erfolg (der in #1005
  benannte Silent-Failure-Generator). Hier wird der Rückgabewert ausgewertet:
  busy → Item zurück an den Kopf der Queue, später erneut. TTS läuft im
  supervisten Task (piper braucht Sekunden; synchron im GenServer würde er die
  50 Audio-Casts/s/Sprecher aufstauen).
  """

  require Logger

  alias Nostrum.Voice
  alias Worker.Discord.AnnounceQueue
  alias Worker.Discord.Announcement
  alias Worker.Discord.VoiceSession

  # Poll-Takt des Drains (gleicher Wert wie die #989-Erst-Ansage-Kette).
  @poll_ms 500

  # Issue #1032: Takt der Erinnerung. Vorher 10 s als reines Sammel-Fenster, das
  # GENAU EINMAL feuerte; jetzt 60 s und wiederholend, gedeckelt durch
  # `AnnounceQueue.max_pending_reminders/0`. Jeder Beitritt startet Uhr UND
  # Zähler neu (`schedule_pending/1` + `reset_pending_told/1`).
  #
  # 60 s statt 10 s ist der eigentliche Ruhe-Gewinn: im gut laufenden Fall hat
  # längst jeder geklickt, bevor die erste Erinnerung überhaupt fällig wird —
  # sie fällt dann ersatzlos aus, statt in jede Gesprächspause zu platzen.
  @pending_delay_ms 60_000

  # ─── Ereignis-Eingänge (von der VoiceSession delegiert) ─────────────

  @doc """
  Ein Voice-State-Ereignis (nach Teilnehmer-Pflege + Bot-Selbst-Filter der
  Session): Namen mitschreiben, echte Beitritte begrüßen + ggf. ins
  Pending-Fenster legen, Verlassende aus dem Fenster nehmen.
  """
  @spec on_voice_state(map(), String.t(), String.t() | nil, boolean(), term()) :: map()
  def on_voice_state(state, did, display_name, joined?, channel_id) do
    state
    |> note_name(did, display_name)
    |> handle_join_transition(did, joined?)
    |> drop_pending_if_left(did, channel_id)
  end

  @doc """
  Ein Zustimmungs-Klick: hörbare Bestätigung reihen (ohne sie weiß niemand, ob
  der Klick ankam) + raus aus dem laufenden Pending-Fenster.
  """
  @spec on_granted(map(), String.t()) :: map()
  def on_granted(state, did) do
    %{
      state
      | announce_queue:
          AnnounceQueue.push(state.announce_queue, {:granted, speaker_name(state, did)}),
        pending_dids: MapSet.delete(state.pending_dids, did)
    }
    |> kick()
  end

  @doc """
  Issue #1032: die Namen der Anwesenden OHNE gültige Zustimmung — die
  Eröffnungs-Ansage nennt sie, statt allen eine Anleitung vorzulesen.

  Wohnt hier und nicht in der `VoiceSession`, weil beide Bausteine hier liegen:
  die Namens-Kette (`speaker_name/2`) und die Consent-Sicht (`allowed_now?/2`).
  Damit sagen Eröffnung und Erinnerung nie unterschiedliche Namen für dieselbe
  Person — und die Session bleibt unter der God-Module-Grenze (#544).
  """
  @spec missing_names(map()) :: [String.t() | nil]
  def missing_names(state) do
    state.participants
    |> Enum.reject(&allowed_now?(state, &1))
    |> Enum.map(&speaker_name(state, &1))
  end

  @doc "Queue-Drain anstoßen (idempotent): ein evtl. laufender Timer wird ersetzt."
  @spec kick(map()) :: map()
  def kick(state) do
    if is_reference(state.queue_timer), do: Process.cancel_timer(state.queue_timer)
    %{state | queue_timer: Process.send_after(self(), :queue_next, 0)}
  end

  # ─── Timer-/Task-Eingänge ───────────────────────────────────────────

  @doc """
  `:queue_next`: das nächste Item sprechen — wenn gerade nichts anderes läuft.
  """
  @spec drain(map()) :: map()
  def drain(state) do
    cond do
      # Vor dem Zuhören spricht nur die #989-Erst-Ansage; die Queue wartet
      # (`begin_listening` kickt sie).
      not state.listening? ->
        %{state | queue_timer: nil}

      # Ein TTS-Task läuft — sein Ergebnis kickt die Queue selbst weiter.
      state.tts_busy? ->
        %{state | queue_timer: nil}

      # Es wird noch gesprochen (Erst-Ansage oder voriges Item) → später wieder.
      playing?(state.guild_id) ->
        %{state | queue_timer: Process.send_after(self(), :queue_next, @poll_ms)}

      true ->
        case AnnounceQueue.pop(state.announce_queue) do
          {nil, _q} ->
            %{state | queue_timer: nil}

          {item, q} ->
            state = %{state | announce_queue: q}

            case item_text(item) do
              # z.B. eine Pending-Gruppe, die leer wurde — nichts zu sagen,
              # direkt das nächste Item.
              nil -> kick(%{state | queue_timer: nil})
              text -> start_tts(state, item, text)
            end
        end
    end
  end

  @doc """
  `{:announce_tts, item, result}`: TTS fertig → abspielen. Busy-Ablehnung legt
  das Item zurück an den KOPF (es ist noch nicht gesprochen und darf seinen
  Platz nicht verlieren); der WAV-Cache (Hash über den Text) macht den zweiten
  TTS-Anlauf kostenlos.
  """
  @spec tts_result(map(), AnnounceQueue.item(), {:ok, Path.t()} | {:error, term()}) :: map()
  def tts_result(state, item, result) do
    state = %{state | tts_busy?: false}

    case result do
      {:ok, wav} ->
        case play(state.guild_id, wav) do
          :ok ->
            %{state | queue_timer: Process.send_after(self(), :queue_next, @poll_ms)}

          :busy ->
            %{
              state
              | announce_queue: AnnounceQueue.push_front(state.announce_queue, item),
                queue_timer: Process.send_after(self(), :queue_next, @poll_ms)
            }

          {:error, reason} ->
            # Ein Item ist verzichtbar (die Button-Nachricht existiert weiter) —
            # Fehler laut ins Log, Item verwerfen, weiter mit dem Rest.
            Logger.warning(
              "Worker.Discord.Announcer: Ansage nicht abspielbar campaign=#{state.campaign_id} " <>
                "item=#{inspect(elem(item, 0))}: #{inspect(reason)}"
            )

            kick(state)
        end

      {:error, reason} ->
        Logger.warning(
          "Worker.Discord.Announcer: Ansage-TTS fehlgeschlagen campaign=#{state.campaign_id} " <>
            "item=#{inspect(elem(item, 0))}: #{inspect(reason)} — Item verworfen"
        )

        kick(state)
    end
  end

  @doc """
  `:pending_fire` — der Erinnerungs-Timer ist abgelaufen.

  Issue #1032: gezählt werden ALLE gerade Anwesenden ohne gültige Zustimmung,
  nicht mehr nur die aus einem Sammelfenster. Der gesprochene Satz nennt genau
  sie („Keine Zustimmung von A, B und C"), also muss die Liste auch der aktuelle
  Kanal-Zustand sein und nicht eine Momentaufnahme von vor 60 Sekunden.

  Ist niemand mehr offen — oder ist der Deckel erreicht —, wird nichts gesagt
  UND kein neuer Timer gesetzt: der Bot ist dann still, bis der nächste Beitritt
  die Runde neu startet.
  """
  @spec pending_fire(map()) :: map()
  def pending_fire(state) do
    open_dids = Enum.reject(state.participants, &allowed_now?(state, &1))

    {batch, q} = AnnounceQueue.pending_batch(state.announce_queue, open_dids)

    state = %{state | announce_queue: q, pending_dids: MapSet.new(), pending_timer: nil}

    case batch do
      [] ->
        kick(state)

      dids ->
        q = AnnounceQueue.push(q, {:pending, Enum.map(dids, &speaker_name(state, &1))})
        kick(rearm_pending(%{state | announce_queue: q}))
    end
  end

  # ─── intern ─────────────────────────────────────────────────────────

  defp note_name(state, did, display_name) do
    %{state | announce_queue: AnnounceQueue.note_name(state.announce_queue, did, display_name)}
  end

  # Ein echter Kanal-BEITRITT (kein Mute/Video/Screenshare — die kommen als
  # VOICE_STATE_UPDATE ohne Kanalwechsel und `joined? == false`): Begrüßung
  # reihen (nur beim ersten Mal, AnnounceQueue dedupt) und — falls die Person
  # noch keinen gültigen Consent hat — ins Pending-Debounce-Fenster legen.
  defp handle_join_transition(state, _did, false), do: state

  defp handle_join_transition(state, did, true) do
    {verdict, q} = AnnounceQueue.note_join(state.announce_queue, did)
    state = %{state | announce_queue: q}
    consented? = allowed_now?(state, did)

    state =
      case verdict do
        # Live-Befund #1013: die Begrüßung trägt den Aufnahme-STATUS mit
        # (Wortlaut vom Auftraggeber) — und den Namen aus der vollen Kette
        # (Charakter → Discord → Hub, `speaker_name/2`), nicht nur aus dem
        # member-Cache (dessen Fehlen war der „Eine weitere Person"-Befund).
        :greet ->
          %{
            state
            | announce_queue:
                AnnounceQueue.push(
                  state.announce_queue,
                  {:join, speaker_name(state, did), consented?}
                )
          }

        :skip ->
          state
      end

    state =
      if consented? do
        state
      else
        schedule_pending(%{state | pending_dids: MapSet.put(state.pending_dids, did)})
      end

    kick(state)
  end

  # Wer den Kanal verlässt, fällt aus dem laufenden Pending-Fenster — sonst
  # würde die Sammel-Ansage jemanden erwähnen, der gar nicht mehr da ist.
  defp drop_pending_if_left(state, did, channel_id) do
    if channel_id == state.voice_channel_id do
      state
    else
      %{state | pending_dids: MapSet.delete(state.pending_dids, did)}
    end
  end

  # Issue #1032: ein Beitritt startet die Erinnerungs-Runde komplett neu — Uhr
  # UND Zähler. Die Lage im Kanal hat sich geändert, also bekommt auch eine
  # Person, für die der Deckel schon erreicht war, wieder Erinnerungen.
  #
  # MapSet-Opacity-Quirk (#589-Cut-4-Klasse, `source_refs.ex`-Precedent):
  # `pending_dids` ist ein via MapSet.put/delete gebautes Set; Elixir ≥1.20
  # backt MapSet intern auf `:sets` v2 (opaque), und Dialyzer buchstabiert bei
  # spec-losen privaten Funktionen die Interna am `rearm_pending`-Call aus →
  # `call_with_opaque` nur auf neuem Toolchain (lokal 1.20.2/OTP 29 rot,
  # CI-Image grün). Kein Verhaltens-Effekt, nur die FP-Warnung weg.
  @dialyzer {:no_opaque, schedule_pending: 1}
  defp schedule_pending(state) do
    %{state | announce_queue: AnnounceQueue.reset_pending_told(state.announce_queue)}
    |> rearm_pending()
  end

  # Timer neu stellen, ohne den Zähler anzufassen (Weg der Wiederholung).
  defp rearm_pending(state) do
    if is_reference(state.pending_timer), do: Process.cancel_timer(state.pending_timer)
    %{state | pending_timer: Process.send_after(self(), :pending_fire, @pending_delay_ms)}
  end

  # Hat die Person JETZT einen gültigen Consent? Deckt beide Quellen: die
  # Klick-Historie dieser Session UND den persistierten Consent früherer
  # Abende/des Browser-Pfads. Die Consent-Sicht kommt aus der VoiceSession
  # (`history_for/2`) — geteilt statt dupliziert (eine Lesestelle, wie
  # ConsentGate).
  defp allowed_now?(state, did) do
    elapsed = System.monotonic_time(:millisecond) - state.session_start_ms
    Worker.Discord.ConsentState.granted_at?(VoiceSession.history_for(state, did), elapsed)
  end

  @doc """
  Die Namens-KETTE der Ansagen (Live-Befund #1013, Vorgabe vom Auftraggeber):
  **Charakter-Name der Kampagne → Discord-Name (member-Objekt) →
  Hub-Anzeigename** — `nil` erst, wenn alle drei fehlen (die Texte haben eine
  namenlose Fassung, aber sie ist die letzte Rückfallebene, nicht der
  Normalfall wie im ersten Live-Lauf).

  Der Charakter-Name zuerst: am Tisch ist „Grognak ist beigetreten" die
  nützliche Information, nicht das Discord-Handle.
  """
  @spec speaker_name(map(), String.t()) :: String.t() | nil
  def speaker_name(state, did) do
    campaign_character_name(state.campaign_id, did) ||
      AnnounceQueue.name_for(state.announce_queue, did) ||
      repo_display_name(did)
  end

  # `character_names_for/1` liefert laut Vertrag immer eine Map (Dialyzer-
  # bestätigt) — die Boundary-Defense gegen einen kaputten Repo-Read liegt im
  # rescue, nicht in einer unerreichbaren Catch-all-Klausel.
  defp campaign_character_name(campaign_id, did) do
    campaign_id
    |> Worker.Repo.character_names_for()
    |> Map.get(to_string(did))
  rescue
    _ -> nil
  end

  defp repo_display_name(did) do
    case Worker.Repo.get_user(did) do
      %{display_name: name} when is_binary(name) and name != "" ->
        # Eine nackte Discord-ID als „Name" wäre eine vorgelesene Zahlenkette —
        # dann lieber die namenlose Fassung (AutoMember legt Nutzer ohne
        # erreichbares Profil mit der ID als display_name an).
        if name == to_string(did), do: nil, else: name

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp item_text({:join, name, consented?}), do: Announcement.text_for_join(name, consented?)
  defp item_text({:pending, names}), do: Announcement.text_for_pending(names)
  defp item_text({:granted, name}), do: Announcement.text_for_granted(name)

  # TTS im supervisten Task — piper braucht Sekunden, und der Session-Prozess
  # nimmt 50 Audio-Casts/s/Sprecher an. Das Ergebnis kommt als
  # `{:announce_tts, item, result}` zurück (kein Task.async: der Prozess soll
  # nicht auf DOWN-Refs matchen müssen, der Catch-all loggt echte Streuner).
  defp start_tts(state, item, text) do
    session = self()

    {:ok, _} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        send(session, {:announce_tts, item, Announcement.wav_for_text(text)})
      end)

    %{state | tts_busy?: true, queue_timer: nil}
  end

  # `Voice.play/4` MIT ausgewertetem Rückgabewert — die busy-Ablehnung war
  # vorher als Erfolg durchgegangen. Rückgabe-Vertrag laut Nostrum-Spec (vom
  # 1.19-Typ-Checker bestätigt): `:ok | {:error, binary()}`.
  defp play(guild_id, wav) do
    case Voice.play(guild_id, wav, :url) do
      :ok ->
        :ok

      {:error, reason} ->
        if busy_play_error?(reason), do: :busy, else: {:error, reason}
    end
  rescue
    e -> {:error, {:announce_play_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:announce_play_failed, inspect({kind, reason})}}
  end

  # Nostrums busy-Ablehnung ist ein Fehler-STRING („Audio already playing in
  # voice channel.") — kein Atom, auf das man matchen könnte. Substring-Match
  # mit benanntem Risiko: ändert Nostrum den Wortlaut, wird busy zum normalen
  # Fehler (Item verworfen + Log-Warnung — sichtbar, nicht still). Kein
  # Nicht-Binary-Fallback: der Spec-Vertrag garantiert `binary()`.
  defp busy_play_error?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "already playing")

  defp playing?(guild_id) do
    Voice.playing?(guild_id)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
