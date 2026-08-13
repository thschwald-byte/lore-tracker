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

  # Debounce der Pending-Erinnerung: Beitritte kommen in Grüppchen (Session-
  # Start, Rückkehr aus der Pause) — das Fenster sammelt sie zu EINER
  # Sammel-Ansage. 10 s ist bewusst länger als typisches Join-Getröpfel und
  # kürzer als jede Gesprächspause, in der die Erinnerung noch Sinn ergibt.
  @pending_debounce_ms 10_000

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
          AnnounceQueue.push(state.announce_queue, {:granted, participant_name(state, did)}),
        pending_dids: MapSet.delete(state.pending_dids, did)
    }
    |> kick()
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
  `:pending_fire` — das Debounce-Fenster ist zu: alle im Fenster gesammelten
  Beitritte, die JETZT NOCH anwesend sind und JETZT NOCH nicht zugestimmt
  haben, werden als EINE Sammel-Ansage gereiht („nur bei Bedarf" + Sammelform
  statt Einzel-Unterbrechungen). Der Erinnerungs-Deckel pro Person sitzt in
  `AnnounceQueue.pending_batch/2`.
  """
  @spec pending_fire(map()) :: map()
  def pending_fire(state) do
    due_dids =
      state.pending_dids
      |> MapSet.to_list()
      |> Enum.filter(&(&1 in state.participants))
      |> Enum.reject(&allowed_now?(state, &1))

    {batch, q} = AnnounceQueue.pending_batch(state.announce_queue, due_dids)

    q =
      case batch do
        [] -> q
        dids -> AnnounceQueue.push(q, {:pending, Enum.map(dids, &AnnounceQueue.name_for(q, &1))})
      end

    kick(%{state | announce_queue: q, pending_dids: MapSet.new(), pending_timer: nil})
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

    q =
      case verdict do
        :greet -> AnnounceQueue.push(q, {:join, AnnounceQueue.name_for(q, did)})
        :skip -> q
      end

    state = %{state | announce_queue: q}

    state =
      if allowed_now?(state, did) do
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

  # Debounce-Timer (re)starten: jeder weitere Beitritt im Fenster schiebt die
  # Ansage hinaus — so wird aus zwei Personen eine Sammel-Ansage.
  defp schedule_pending(state) do
    if is_reference(state.pending_timer), do: Process.cancel_timer(state.pending_timer)
    %{state | pending_timer: Process.send_after(self(), :pending_fire, @pending_debounce_ms)}
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

  # Name für die Granted-Bestätigung: Session-Cache zuerst (member-Objekt),
  # sonst der Hub-Anzeigename (die Person war evtl. schon vor dem Bot im Kanal
  # und hatte nie ein member-tragendes Event). `nil` ist ok — die Texte haben
  # eine namenlose Fassung.
  defp participant_name(state, did) do
    AnnounceQueue.name_for(state.announce_queue, did) || repo_display_name(did)
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

  defp item_text({:join, name}), do: Announcement.text_for_join(name)
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
