# Issue #571: TimerWithoutCleanup disabled — Self-Reschedule-Sweep
# (handle_info(:sweep_ghosts) → send_after(:sweep_ghosts)) und einmaliger
# Recover-Delay-Timer in init. Sweeps sollen forever laufen; Cancel
# nicht nötig (GenServer-Tod nimmt Timer mit). Folge-Cut für Check-Tune offen.
# credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup
defmodule Worker.Recording.AudioBuffer do
  @moduledoc """
  Per-session per-speaker on-disk audio buffer.

  Each active session opens a directory `<audio_dir>/<session_id>/`. As audio
  chunks arrive (base64-encoded `audio/webm;codecs=opus` blobs from each
  player's browser MediaRecorder), they're appended to one file per
  `discord_id`: `<discord_id>.webm`. On `finalize/1` we close the writers
  and hand the file list to `Worker.Recording.Transcribe.run/3`, which
  runs whisper-cli per file and emits `UtteranceAppended` + `SessionEnded`.

  Status of currently-streaming discord_ids per campaign is published on
  the hub's `pipeline_status` PubSub via `Worker.HubClient.publish_status/1`
  so LiveViews can render "currently streaming: alice, bob".

  ## Crash-Recovery (Issue #466/#467)

  Der Recording-State (offene Writer, Session→Dir-Map) lebt nur im RAM. Stürzt
  der Worker mitten in einer Aufnahme ab, bleiben die `.webm`-Dateien zwar auf
  Platte (`IO.binwrite` schreibt pro Chunk direkt an den OS — kein BEAM-Puffer
  ohne `:delayed_write`, ein truncated WebM ist ein dekodierbarer Prefix), aber
  ohne Recovery wüsste nach dem Neustart kein Prozess von ihnen.

  Deshalb: beim Start scannt der Worker den `audio_dir` (verzögert, bis der Rest
  des Trees oben ist) und jagt jede dort verbliebene Session durch denselben
  Transcribe-Handoff wie `finalize` — die Aufnahme bis zum Crash-Zeitpunkt geht
  also nicht verloren. Damit das eindeutig ist, wird ein erfolgreich
  transkribiertes Session-Dir aus `audio_dir` **heraus** verschoben (nach
  `audio_done_dir`, oder gelöscht wenn das `nil` ist). Ein im Live-`audio_dir`
  verbliebenes Dir bedeutet damit immer „abgestürzt, noch nicht transkribiert".

  Hartes Strom-/Maschinen-Aus (un-fsync'ter Tail im Page-Cache verloren) ist
  bewusst out-of-scope — fsync pro Chunk wäre für den 500ms-Hot-Path zu teuer.
  """

  use GenServer

  require Logger

  alias Worker.HubClient
  alias Worker.Recording.AudioBuffer.Presence
  alias Worker.Recording.AudioBuffer.Retention

  # Issue #948: der ALTE feste audio_dir-Default (vor der per-Worker-Ableitung).
  # Bleibt als Migrations-Quelle: Bestandsworker mit (un-transkribiertem) Audio hier
  # ziehen beim ersten Boot auf den neuen abgeleiteten Pfad um. Auch der Fallback,
  # falls Mnesia (wider Erwarten) keinen Dir meldet.
  @legacy_fixed_dir "~/.local/share/lore-worker/audio"

  # Issue #934: TTL-Purge-Intervall (6 h). Retention-Sidecar + Legacy-/tmp-Pfade
  # leben in Worker.Recording.AudioBuffer.Retention.
  @retention_check_interval_ms 6 * 60 * 60 * 1000

  # Issue #392: Chunk-Recency-Liveness. Der Sweep-Timer prüft alle
  # @sweep_interval_ms und broadcastet die geschrumpfte Streamer-Liste über
  # `AudioBuffer.Presence` (Ghost-Timeout dort). Presence ist aus dem
  # natürlichen Datenfluss abgeleitet, kein Cross-BEAM-PID-Monitoring nötig.
  @sweep_interval_ms 2_000

  # Issue #466: Crash-Recovery-Scan beim Start verzögern, bis der restliche
  # Worker-Tree (GpuQueue, Mnesia-Schema, HubClient) sicher oben ist — der Scan
  # spawnt Transcribe-Tasks, die GpuQueue + Worker.Repo brauchen.
  @recover_delay_ms 5_000

  # Issue #949: Late-Append. Trifft ein Chunk nach dem SessionEnded beim
  # Owner-Worker ein (gepufferte Outbox, via target_worker_id hierher geroutet),
  # wird die Session für ein Nach-Schreiben re-geöffnet und nach diesem Fenster
  # ohne weiteren Chunk nach-transkribiert (batcht einen Chunk-Burst).
  @late_append_debounce_ms 10_000

  # Issue #934: Path.expand zur LAUFZEIT (Default hält den `~`-String; expand zur
  # Compile-Zeit würde auf der Build-Maschine auflösen).
  defp audio_dir do
    Worker.Settings.get(:audio_dir, default_audio_dir()) |> Path.expand()
  end

  # Issue #948: Default = `<mnesia_dir>/audio`. Der Mnesia-Dir ist pro Worker-BEAM
  # eindeutig (eigener LORE_MNESIA_DIR, config/runtime.exs) → mehrere Worker auf
  # EINER Maschine teilen sich den audio_dir nicht mehr (Recovery-Contamination).
  # `:mnesia.system_info(:directory)` liefert ihn zur Laufzeit (Charlist); bei
  # nicht-gestartetem Mnesia (im AudioBuffer nie der Fall) Fallback auf den Alt-Pfad.
  defp default_audio_dir do
    :mnesia.system_info(:directory) |> to_string() |> Path.join("audio")
  rescue
    _ -> @legacy_fixed_dir
  end

  # `audio_done_dir` = nil → nach Transkription löschen; sonst der expandierte
  # Archiv-Zielpfad (mit Retention).
  defp done_dir do
    case Worker.Settings.get(:audio_done_dir) do
      nil -> nil
      d when is_binary(d) -> Path.expand(d)
    end
  end

  defp retention_days, do: Worker.Settings.get(:audio_retention_days, 14)

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Register a new session. Creates the on-disk directory.

  Issue #642: die Session ist nur noch ein **Container** — der Aufnahme-Typ wird
  nicht mehr session-weit festgelegt, sondern reist **pro Stream/Chunk** mit
  (`append/4` `source`). Der `mode`-Parameter wird ignoriert (Abwärtskompat für
  Caller, die ihn noch übergeben) und beeinflusst das Routing nicht.
  """
  def open_session(session_id, campaign_id, _mode \\ :mixed) do
    GenServer.call(__MODULE__, {:open, session_id, campaign_id})
  end

  @doc """
  Append a base64-encoded audio chunk from a stream. `mic_mode` (`:per_player |
  :multi`) entscheidet das Routing (Issue #642): `:per_player` → eine Datei pro
  `discord_id`; `:multi` → eine eigene (diarisierte) Raummikro-Spur. Opens a
  writer on first chunk for that routing key.

  Hinweis: `mic_mode` ist NICHT das JS-`source` ("mic"|"system" = Capture-Gerät);
  es ist der per-Spieler-vs-Raummikro-Routing-Typ.
  """
  # Issue #938 (D): `chunk_id` = `{instance_id, seq}` (Chunk-Identität aus der
  # Client-Outbox) oder `nil` (alter Client/Hub ohne Identität). Trägt den
  # Worker-Dedup (Resend nach Reconnect nicht doppelt anhängen) + das E2E-Ack
  # (nach dem Plattenschreiben) — beide no-op bei `nil`.
  def append(session_id, discord_id, mic_mode, b64_chunk, chunk_id \\ nil) do
    GenServer.cast(
      __MODULE__,
      {:append, session_id, to_string(discord_id), normalize_mic_mode(mic_mode), b64_chunk,
       chunk_id}
    )
  end

  # Issue #642: mic_mode-Normalisierung (String vom Wire / Atom intern) →
  # :per_player | :multi. Unbekanntes/fehlendes → :per_player (sicherer Default;
  # eine alte Hub-Payload ohne `mic_mode`-Feld landet hier → per-Spieler).
  defp normalize_mic_mode(m) when m in [:multi, "multi"], do: :multi
  defp normalize_mic_mode(_), do: :per_player

  @doc """
  Close all writers for the session, then trigger transcription. Returns
  immediately — the transcription task emits `UtteranceAppended` and
  finally `SessionEnded` asynchronously.
  """
  def finalize(session_id) do
    GenServer.cast(__MODULE__, {:finalize, session_id})
  end

  @doc "List of discord_ids currently streaming into `session_id`. For tests / UI snapshots."
  def streamers(session_id) do
    GenServer.call(__MODULE__, {:streamers, session_id})
  end

  @doc """
  Issue #392: graceful Mic-Stop. Entfernt `discord_id` sofort aus der
  Presence-Liste der Session (statt auf den Chunk-Recency-Sweep zu warten)
  und broadcastet die aktualisierte Streamer-Liste. Das `.webm`-File-Handle
  bleibt bis `finalize` offen — die bis dahin geschriebene Audio bleibt für
  die Transkription erhalten.
  """
  def drop_streamer(session_id, discord_id) do
    GenServer.cast(__MODULE__, {:drop_streamer, session_id, to_string(discord_id)})
  end

  @doc """
  Issue #233: prüft, ob für die Session-ID gerade ein Transcribe-Task läuft
  (gestartet via finalize/1 unter Task.Supervisor, noch nicht :DOWN).

  Wird vom HubClient.stop_recording-Handler benutzt, um zu erkennen ob der
  `:not_recording`-Fall vom Recorder ein Race-Window während Stage 1 ist
  (dann KEIN Fallback-SessionEnded — Transcribe.run/2 publisht das selber)
  oder ein echter Worker-Restart-Fall (dann Fallback nötig).
  """
  @spec has_pending_transcribe?(String.t()) :: boolean
  def has_pending_transcribe?(session_id) do
    GenServer.call(__MODULE__, {:has_pending_transcribe, session_id})
  end

  @doc """
  Issue #943 (B2): die session_ids mit derzeit offenem Writer. Der `HubClient`
  meldet sie nach einem Hub-Reconnect neu (`handle_join`), damit die
  `pick_leader`-Session-Stickiness (Hub-Tracker `held_sessions`) wiederhergestellt
  wird. `whereis`-Guard: läuft der AudioBuffer (noch) nicht (Boot-Race), `[]`.
  """
  @spec open_session_ids() :: [String.t()]
  def open_session_ids do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :open_session_ids), else: []
  end

  # ─── GenServer ────────────────────────────────────────────────────

  # state: %{
  #   sessions: %{session_id => %{campaign_id, dir, writers, ...}},
  #   pending_transcribes: %{task_pid => session_id}   # Issue #233
  # }
  @impl true
  def init(_) do
    # Issue #934: Alt-/tmp-Audio in die neuen persistenten Ordner ziehen, BEVOR der
    # Recovery-Scan (der nur den neuen audio_dir sieht) läuft.
    # Issue #948: zusätzlich den ALTEN festen audio_dir-Default als Migrations-
    # Quelle mitgeben — Bestandsworker ziehen ihre Sessions von dort auf den neuen
    # per-Worker-Pfad (move_legacy_sessions-Guard verhindert Self-Move).
    Retention.migrate_legacy(audio_dir(), done_dir(), Path.expand(@legacy_fixed_dir))
    File.mkdir_p!(audio_dir())
    # Issue #392: Chunk-Recency-Sweep — GC't Streamer ohne Chunk seit
    # >@ghost_timeout_ms (ungraceful Disconnect / Tab-Crash).
    Process.send_after(self(), :sweep_ghosts, @sweep_interval_ms)
    # Issue #466: verwaiste Session-Dirs aus einem vorherigen Crash wieder
    # aufnehmen (verzögert, s. @recover_delay_ms).
    Process.send_after(self(), :recover_orphans, @recover_delay_ms)
    # Issue #934: TTL-Purge des Archivs (nur transkribiertes Audio; Orphans bleiben).
    Process.send_after(self(), :purge_expired, @recover_delay_ms + 2_000)
    {:ok, %{sessions: %{}, pending_transcribes: %{}}}
  end

  @impl true
  def handle_call({:open, session_id, campaign_id}, _from, state) do
    dir = Path.join(audio_dir(), session_id)
    File.mkdir_p!(dir)
    # Issue #934: Retention-Sidecar bei Session-Geburt; purge_after wird erst bei
    # erfolgreicher Transkription/Archivierung gesetzt.
    Retention.write_sidecar(dir, %{"created_at" => Retention.iso_now(), "purge_after" => nil})

    sessions = Map.put_new(state.sessions, session_id, fresh_session_map(campaign_id, dir))

    Presence.publish_streamers(campaign_id, session_id, [])

    # Issue #355: GpuQueue beobachtet recording_state, um Background-Jobs
    # während aktiver Aufnahme zu pausieren. Broadcast bei jedem :open.
    Phoenix.PubSub.broadcast(
      Worker.PubSub,
      "recording_state",
      {:recording_state_changed, true}
    )

    Logger.info("AudioBuffer: session=#{session_id} opened (dir=#{dir})")

    # Issue #468 Cut 2: Hub via HubClient melden, dass DIESER Worker die
    # Session hält. Hub-Commands.pick_leader im Audio-Hot-Path bevorzugt
    # diesen Worker für nachfolgende forward_audio_chunk-Calls (Stickiness
    # gegen Leader-Wechsel mid-Stream).
    Worker.HubClient.announce_session_held(session_id)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:streamers, session_id}, _from, state) do
    case state.sessions[session_id] do
      nil -> {:reply, [], state}
      sess -> {:reply, Presence.fresh_streamers(sess), state}
    end
  end

  def handle_call({:has_pending_transcribe, session_id}, _from, state) do
    pending? =
      state.pending_transcribes
      |> Map.values()
      |> Enum.member?(session_id)

    {:reply, pending?, state}
  end

  # Issue #943 (B2): offene Session-IDs für den Reconnect-Re-Announce.
  def handle_call(:open_session_ids, _from, state) do
    {:reply, Map.keys(state.sessions), state}
  end

  @impl true
  def handle_cast({:append, session_id, discord_id, mic_mode, b64, chunk_id}, state) do
    case state.sessions[session_id] do
      nil ->
        # Issue #949: Chunk für eine hier nicht offene Session. Ist es UNSERE
        # bereits beendete Session (Owner-Routing via target_worker_id → wir haben
        # sie transkribiert), ist das ein Late-Append: gepufferte Outbox-Audio, die
        # vor dem Stop entstand und nur zu spät ankam → nachschreiben statt
        # verwerfen. Sonst (fremde/aktive Session, transienter Failover) wie bisher
        # nacken.
        case late_append_target(session_id) do
          {:ok, campaign_id} ->
            handle_late_append_chunk(
              state,
              session_id,
              campaign_id,
              discord_id,
              mic_mode,
              b64,
              chunk_id
            )

          :no ->
            # Non-leader workers will routinely see chunks for sessions they don't
            # own — Hub.Commands.pick_leader/1 picks one leader but in-flight frames
            # can still land on others during reconfiguration. Einzelne solche Frames
            # sind benign; ein ANHALTENDER Strom heißt aber: der Session-Halter ist
            # weg und pick_leader fällt dauerhaft auf uns (ohne offenen Sink) zurück
            # → der Chunk geht verloren, während der Hub dem Browser `1` (delivered)
            # meldet. Issue #772: den Drop dem Hub melden (fire-and-forget), der ihn
            # gefenstert an die MicLive des Senders routet — macht den sonst stillen
            # Verlust sichtbar. Der Fensterzähler drüben schluckt transiente Einzel-
            # fälle, sodass nur ein echtes Failover warnt.
            Logger.debug(fn ->
              "AudioBuffer: chunk for unknown session=#{session_id} did=#{discord_id}; dropping (nack)"
            end)

            HubClient.audio_nack(session_id, discord_id)

            {:noreply, state}
        end

      sess ->
        case decode_chunk(b64) do
          {:ok, bin} ->
            # Issue #938 (D): Dedup — ein schon geschriebener Chunk (Client-Resend
            # nach Reconnect) wird NICHT doppelt angehängt, aber ge-ackt (der Client
            # löscht ihn dann aus der Outbox). Sonst: schreiben + written_ids merken
            # + acken. `chunk_id == nil` (alter Client) → kein Dedup/Ack.
            if chunk_id && MapSet.member?(Map.get(sess, :written_ids, MapSet.new()), chunk_id) do
              ack_chunk(session_id, discord_id, chunk_id)
              {:noreply, maybe_reschedule_late_finalize(state, session_id)}
            else
              state = write_chunk(state, session_id, sess, discord_id, mic_mode, bin)
              state = mark_written_and_ack(state, session_id, discord_id, chunk_id)
              # Issue #949: bei einer Late-Append-Session das Debounce-Fenster
              # verlängern, solange noch Chunks nachtröpfeln.
              {:noreply, maybe_reschedule_late_finalize(state, session_id)}
            end

          :error ->
            Logger.warning(
              "AudioBuffer: bad base64 chunk for session=#{session_id} did=#{discord_id}"
            )

            {:noreply, state}
        end
    end
  end

  def handle_cast({:finalize, session_id}, state) do
    case Map.pop(state.sessions, session_id) do
      {nil, _} ->
        Logger.warning(
          "AudioBuffer: finalize for unknown session=#{session_id}; emitting empty SessionEnded"
        )

        publish_session_ended(session_id)
        {:noreply, state}

      {sess, rest} ->
        files = close_writers_and_collect(sess)

        # Notify hub that no one is streaming anymore for this campaign.
        Presence.publish_streamers(sess.campaign_id, session_id, [])

        # Issue #468 Cut 2: Session-Halter-Eintrag aus dem Hub-Tracker
        # raus. Pick_leader fällt für diese Session ab jetzt auf die
        # normale lexikografische Sortierung zurück (Stage-1-Transkription
        # ist eh schon im GpuQueue-Tail — kein Chunk-Routing mehr nötig).
        Worker.HubClient.announce_session_released(session_id)

        Logger.info(
          "AudioBuffer: finalized session=#{session_id} files=#{length(files)} → handing off to Transcribe"
        )

        # Issue #355: SessionEnded firet SOFORT — die Aufnahme IST jetzt
        # beendet, das ist die state-relevante Information für die UI. Die
        # Transkription läuft anschließend asynchron in der GpuQueue weiter
        # und publisht am Ende `UtterancesTranscribed`, worauf die Pipeline
        # triggert.
        #
        # Issue #571: Return matchen statt verwerfen. Bei Hub-Disconnect
        # liefert publish/1 `{:ok, :pending}` — das Event ist lokal via
        # Materializer.apply_local schon angewandt, der Hub-Replay läuft
        # später. publish/1 selbst loggt + zählt pending_total; hier hart
        # auf {:ok, _} matchen, damit ein zukünftiger Return-Shape-Change
        # nicht still durchrutscht.
        {:ok, _} =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.session_ended(),
            "id" => session_id
          })

        # Issue #355: GpuQueue darf Background-Jobs wieder starten, sobald
        # keine weitere Session mehr aktiv ist. Vor dem Transcribe-Spawn,
        # damit der Transcribe-Job selbst auch durchlaufen kann.
        maybe_broadcast_recording_state_off(rest)

        state =
          if files == [] do
            Logger.info(
              "AudioBuffer: no audio files for session=#{session_id} — kein Transcribe-Task, Pipeline wird nicht getriggert (keine Utterances zum Bearbeiten)"
            )

            %{state | sessions: rest}
          else
            %{state | sessions: rest}
            |> start_transcribe_task(session_id, files)
          end

        {:noreply, state}
    end
  end

  # Issue #392: graceful Mic-Stop. Entfernt den Streamer sofort aus der
  # Presence (last_chunk_at) + broadcastet. File-Handle bleibt offen bis
  # finalize.
  def handle_cast({:drop_streamer, session_id, discord_id}, state) do
    case state.sessions[session_id] do
      nil ->
        {:noreply, state}

      sess ->
        sess = %{sess | last_chunk_at: Map.delete(sess.last_chunk_at, discord_id)}
        sess = Presence.maybe_broadcast_streamers(session_id, sess)
        {:noreply, %{state | sessions: Map.put(state.sessions, session_id, sess)}}
    end
  end

  # Issue #355: nach :finalize hat AudioBuffer eine Session aus state.sessions
  # entfernt. Wenn jetzt keine mehr aktiv ist, signalisieren wir der GpuQueue
  # dass Background-Jobs wieder starten dürfen. Bei noch aktiven Sessions
  # bleibt der „active"-State implizit erhalten.
  defp maybe_broadcast_recording_state_off(remaining_sessions) do
    if map_size(remaining_sessions) == 0 do
      Phoenix.PubSub.broadcast(
        Worker.PubSub,
        "recording_state",
        {:recording_state_changed, false}
      )
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.pending_transcribes, pid) do
      {nil, _} ->
        {:noreply, state}

      {session_id, rest} ->
        if reason == :normal do
          # Issue #466/#467: Transkription fertig → Audio aus dem Live-`audio_dir`
          # heraus archivieren (oder löschen), damit der Crash-Recovery-Scan es
          # nicht für einen Absturz hält und re-transkribiert.
          archive_session_audio(session_id)
        else
          Logger.warning(
            "AudioBuffer: Transcribe task for session=#{session_id} exited abnormally: #{inspect(reason)} — Audio bleibt in #{audio_dir()} für Crash-Recovery-Retry"
          )
        end

        {:noreply, %{state | pending_transcribes: rest}}
    end
  end

  # Issue #466: verzögerter Crash-Recovery-Scan. Verwaiste Session-Dirs aus einem
  # vorherigen Worker-Crash durch denselben Transcribe-Handoff jagen wie finalize.
  def handle_info(:recover_orphans, state) do
    {:noreply, recover_orphaned_sessions(state)}
  end

  # Issue #934: TTL-Purge des Archivs. Löscht NUR transkribiertes Audio im done_dir
  # mit überschrittenem, DEKLARIERTEM `purge_after`; Orphans (audio_dir) werden nie
  # angefasst; Sidecar-lose/aktive Dirs bleiben (flag-not-drop).
  def handle_info(:purge_expired, state) do
    Retention.purge_expired(done_dir(), Map.keys(state.sessions))
    Process.send_after(self(), :purge_expired, @retention_check_interval_ms)
    {:noreply, state}
  end

  # Issue #392: Chunk-Recency-Sweep. Pro Session den frischen Streamer-Set
  # neu berechnen; bei Shrinkage (Ghost expirt) broadcasten. Neue Streamer
  # werden bereits vom write_chunk-Pfad gebroadcastet — der Sweep deckt den
  # Fall ab, dass GAR keine Chunks mehr kommen (alle weg / Tab-Crash).
  @impl true
  def handle_info(:sweep_ghosts, state) do
    sessions =
      Map.new(state.sessions, fn {sid, sess} ->
        sess = Presence.maybe_broadcast_streamers(sid, sess)
        sess = Presence.check_silence(sid, sess)
        {sid, sess}
      end)

    Process.send_after(self(), :sweep_ghosts, @sweep_interval_ms)
    {:noreply, %{state | sessions: sessions}}
  end

  # Issue #949: Debounce abgelaufen — keine weiteren Late-Chunks für eine Weile.
  # Die nachgeschriebene Audio dieser bereits beendeten Session transkribieren
  # (frische UtteranceAppended-UUIDs → hängt an, überschreibt nichts; genau ein
  # UtterancesTranscribed → Pipeline zieht die späten Utterances nach). KEIN
  # zweites SessionEnded (die Session ist längst beendet).
  def handle_info({:late_finalize, session_id}, state) do
    case Map.pop(state.sessions, session_id) do
      {%{late?: true} = sess, rest} ->
        files = close_writers_and_collect(sess)

        state =
          if files == [] do
            %{state | sessions: rest}
          else
            Logger.info(
              "AudioBuffer: late-append session=#{session_id} files=#{length(files)} → Nach-Transkription (Issue #949)"
            )

            %{state | sessions: rest}
            |> start_transcribe_task(session_id, files)
          end

        {:noreply, state}

      # Session zwischenzeitlich live re-geöffnet (late? false) oder weg → nichts tun.
      {_other, _rest} ->
        {:noreply, state}
    end
  end

  # ─── Internal ─────────────────────────────────────────────────────

  # Issue #949: ist `session_id` UNSERE bereits beendete Session? Dann darf ein
  # verspäteter Chunk nach-geschrieben werden (Owner-Late-Append). `:completed`
  # ist der SessionEnded-Status (apply1.ex). Dirty-Read reicht — seltener Pfad
  # (nur der ERSTE Late-Chunk pro Session; danach läuft alles über den sess-Zweig).
  defp late_append_target(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{status: :completed, campaign_id: cid} when is_binary(cid) -> {:ok, cid}
      _ -> :no
    end
  end

  # Issue #949: ersten Late-Chunk verarbeiten — Session leichtgewichtig re-öffnen
  # (KEIN announce_session_held / recording_state-Broadcast — sie ist beendet, wir
  # bergen nur Audio), schreiben, acken, Debounce starten.
  defp handle_late_append_chunk(
         state,
         session_id,
         campaign_id,
         discord_id,
         mic_mode,
         b64,
         chunk_id
       ) do
    case decode_chunk(b64) do
      {:ok, bin} ->
        dir = Path.join(audio_dir(), session_id)
        File.mkdir_p!(dir)

        Logger.info(
          "AudioBuffer: Late-Append re-opens ended session=#{session_id} did=#{discord_id} (Issue #949)"
        )

        sess = fresh_session_map(campaign_id, dir, true)
        state = %{state | sessions: Map.put(state.sessions, session_id, sess)}
        state = write_chunk(state, session_id, sess, discord_id, mic_mode, bin)
        state = mark_written_and_ack(state, session_id, discord_id, chunk_id)
        {:noreply, schedule_late_finalize(state, session_id)}

      :error ->
        Logger.warning(
          "AudioBuffer: bad base64 late-chunk for session=#{session_id} did=#{discord_id}"
        )

        {:noreply, state}
    end
  end

  # Issue #949: Debounce (neu) setzen — alten Timer canceln, neuen scharf machen.
  defp schedule_late_finalize(state, session_id) do
    case state.sessions[session_id] do
      %{late?: true} = sess ->
        if sess.late_timer, do: Process.cancel_timer(sess.late_timer)
        ref = Process.send_after(self(), {:late_finalize, session_id}, @late_append_debounce_ms)
        put_in(state.sessions[session_id], %{sess | late_timer: ref})

      _ ->
        state
    end
  end

  # Issue #949: nur nachziehen, wenn die Session tatsächlich eine Late-Append ist.
  defp maybe_reschedule_late_finalize(state, session_id) do
    case state.sessions[session_id] do
      %{late?: true} -> schedule_late_finalize(state, session_id)
      _ -> state
    end
  end

  # Frischer Session-State (geteilt von open_session + Late-Append-Reopen #949,
  # damit die Feldliste nicht driftet). `late?`/`late_timer` sind nur für den
  # Late-Append-Pfad relevant (Nach-Schreiben nach SessionEnded); ein normaler
  # Live-Session-Reopen bleibt `late?: false`.
  defp fresh_session_map(campaign_id, dir, late? \\ false) do
    %{
      campaign_id: campaign_id,
      dir: dir,
      writers: %{},
      # Issue #392: Presence-State, entkoppelt von writers (File-Handles).
      # last_chunk_at: key => monotonic_ms; streamers_broadcast: zuletzt
      # gebroadcastete Key-Liste (für Shrinkage-Erkennung im Sweep).
      # MUSS hier initialisiert sein, sonst crasht der erste update_in.
      last_chunk_at: %{},
      streamers_broadcast: [],
      # Issue #399: server-side Stille-Watchdog. Set der discord_ids
      # für die wir bereits einen `streamer_silent`-pipeline_status
      # geschickt haben — verhindert Re-Spam und ermöglicht die
      # Hysteresis "silent → recovered" beim nächsten Chunk.
      silent_streamers: MapSet.new(),
      # Issue #469: Segment-Rotation bei mid-session WebM-Re-Header. `writers`
      # wird pro Chunk-Rotation neu-keyed (flat_key = `<base>` oder
      # `<base>.<n>`), die `active_flat`-Map hält für jede Speaker-Base
      # (`<did>` bzw. `multi_<did>`) den derzeit aktiven flat_key. Ältere,
      # bereits rotierte Segments werden in `rotated_paths` festgehalten,
      # damit `close_writers_and_collect` sie mit einsammelt — das
      # `next_seg_index` zählt pro Speaker-Base hoch.
      active_flat: %{},
      rotated_paths: [],
      next_seg_index: %{},
      # Issue #938 (D): geschriebene Chunk-IDs {instance_id, seq} für den Dedup.
      written_ids: MapSet.new(),
      # Issue #949: Late-Append-Marker + Debounce-Timer-Ref (nil im Live-Fall).
      late?: late?,
      late_timer: nil
      # Issue #642: kein session-weiter `mode` mehr — Routing pro Stream
      # (write_chunk) anhand des Chunk-`source`.
    }
  end

  # Issue #938 (D): nach dem Write die Chunk-ID merken (Dedup-Basis) + E2E-Ack an
  # den Client (der löscht den Chunk dann aus der Outbox). nil = alter Client/Hub
  # ohne Identität → no-op (delete-on-ack degradiert client-seitig auf Fallback).
  defp mark_written_and_ack(state, _session_id, _discord_id, nil), do: state

  defp mark_written_and_ack(state, session_id, discord_id, chunk_id) do
    ack_chunk(session_id, discord_id, chunk_id)

    case state.sessions[session_id] do
      nil ->
        state

      sess ->
        written = MapSet.put(Map.get(sess, :written_ids, MapSet.new()), chunk_id)
        put_in(state.sessions[session_id], Map.put(sess, :written_ids, written))
    end
  end

  defp ack_chunk(session_id, discord_id, {instance_id, seq}) do
    HubClient.audio_ack(session_id, discord_id, instance_id, seq)
  end

  defp ack_chunk(_session_id, _discord_id, _), do: :ok

  defp decode_chunk(nil), do: :error
  defp decode_chunk(""), do: :error

  defp decode_chunk(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.decode64(b64, padding: false)
    end
  end

  defp write_chunk(state, session_id, sess, discord_id, mic_mode, bin) do
    # Issue #642: Routing pro Stream/Chunk (statt session-weit). `:per_player`
    # → eine Datei pro discord_id (eigene Spur/Transkript). `:multi` (Raummikro)
    # → `multi_<discord_id>.webm` (Unterstrich, KEIN ':' — der key wird zum
    # Dateinamen, und ':' ist ein ffmpeg/whisper-Footgun; numerische Discord-IDs
    # kollidieren nie mit dem `multi_`-Prefix). Pro Raummikro-Gerät eine eigene,
    # post-session diarisierte Spur. Das `multi_`-Prefix ist load-bearing:
    # finalize + Crash-Recovery routen darüber.
    #
    # Issue #469: "Base-Key" = semantischer Speaker (`<did>` bzw. `multi_<did>`);
    # "flat_key" = aktuelle Segment-Datei (initial gleich base, nach Rotation
    # `<base>.<n>`). Die Presence-/Streamers-Ansicht bleibt an der Base — für
    # den Sweep + UI ist ein Speaker ein Speaker, egal auf welchem Segment.
    base_key = base_key_for(discord_id, mic_mode)
    active_flat = Map.get(sess.active_flat, base_key, base_key)

    # Issue #469: mid-session EBML-Re-Header erkennt einen neu instanziierten
    # MediaRecorder (nach Device-Re-Plug / Auto-Resume, siehe #397). Wir
    # rotieren ab hier auf ein neues Segment, damit ein potentiell strauchelnder
    # Decoder-Pfad den zweiten Header nicht still verwirft (der Verdacht war für
    # ffmpeg 8.1.2 in `webm_concat_repro_test` widerlegt, aber die Klasse ist
    # billig zu vermeiden — jede Datei bleibt strukturell trivial).
    {sess, active_flat} =
      case sess.writers[active_flat] do
        {_file, _path, bytes_before} when bytes_before > 0 ->
          if ebml_header?(bin) do
            rotate_segment(sess, session_id, base_key, active_flat)
          else
            {sess, active_flat}
          end

        _ ->
          {sess, active_flat}
      end

    # Issue #757: pro Writer die bereits geschriebenen Bytes mit-tracken, damit
    # `ChunkManifest.append/4` die kumulierte Position nach jeder Chunk kennt
    # (Byte-Position → WAV-ms via bytes_per_ms später im Transcribe).
    #
    # Beim frischen Writer-Öffnen die on-disk-Größe lesen — bei einer neuen
    # Datei ist das 0, bei einem writer-state-loss-Reopen (#758) das bisher
    # geschriebene Volumen; der Sidecar wächst dann weiter monoton, seine
    # Anker bleiben durchgehend gültig. Kein Reset unter :append (das würde
    # die Wall-Clock-History der schon geschriebenen Audio wegwerfen).
    {file, path, bytes_before} =
      case sess.writers[active_flat] do
        {file, path, bytes_before} ->
          {file, path, bytes_before}

        nil ->
          path = Path.join(sess.dir, "#{active_flat}.webm")

          # Issue #758: :append statt :write. Der :write-Modus truncatete eine
          # bereits existierende Datei beim Öffnen — verlor der GenServer den
          # Writer-State für einen Key mitten in der Session (Supervisor-Restart,
          # Session-Reopen, partieller State-Loss), überschrieb der nächste Chunk
          # die bis dahin gesammelte Audio dieses Speakers komplett. :append
          # bewahrt sie (WebM bleibt ein dekodierbarer Prefix + neue Cluster).
          # Eine im opened_new?-Zweig schon existierende Datei IST genau dieses
          # State-Loss-Ereignis — laut warnen, damit der Ops-Betrieb es sieht
          # (im Normalfall ist der erste Chunk pro Key immer eine neue Datei).
          if File.exists?(path) do
            Logger.warning(
              "AudioBuffer: writer-state loss — reopening existing #{path} in append mode " <>
                "(session=#{session_id} key=#{active_flat}); prior audio preserved (was truncated with :write)"
            )
          end

          file = File.open!(path, [:append, :binary])
          {file, path, existing_bytes(path)}
      end

    :ok = IO.binwrite(file, bin)
    bytes_after = bytes_before + byte_size(bin)

    # System.system_time (nicht monotonic) — die Wall-Clock landet später in
    # DateTime.from_unix!/2 für den UtteranceAppended-Timestamp.
    Worker.Recording.ChunkManifest.append(
      sess.dir,
      active_flat,
      System.system_time(:millisecond),
      bytes_after
    )

    sess = %{
      sess
      | writers: Map.put(sess.writers, active_flat, {file, path, bytes_after})
    }

    # Issue #392/#469: Chunk-Recency aktualisieren + bei Set-Änderung broadcasten.
    # Presence ist an der Speaker-Base festgemacht — Segment-Rotation verändert
    # nichts an "gerade dabei-Sein".
    sess = %{sess | last_chunk_at: Map.put(sess.last_chunk_at, base_key, now_ms())}
    sess = Presence.maybe_broadcast_streamers(session_id, sess)

    %{state | sessions: Map.put(state.sessions, session_id, sess)}
  end

  # Issue #469: liest die Speaker-Base ("<did>" oder "multi_<did>"), unabhängig
  # von möglichen Segment-Rotationen.
  defp base_key_for(discord_id, mic_mode) do
    case normalize_mic_mode(mic_mode) do
      :multi -> "multi_" <> discord_id
      _ -> discord_id
    end
  end

  # Issue #469: WebM EBML-Magic — jeder neu instanziierte MediaRecorder-Stream
  # beginnt damit. Sitzt der Magic am Anfang eines Chunks, während für den
  # Speaker schon Bytes geschrieben wurden, ist das ein Re-Header (neuer
  # Recorder nach Device-Re-Plug / Auto-Resume, #397). Beliebige interne
  # Cluster-Bytes kollidieren praktisch nicht — die 4-Byte-Sequenz startet nur
  # ein EBML-Dokument, und MediaRecorder emittert einen Chunk immer an einer
  # sinnvollen Boundary.
  defp ebml_header?(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: true
  defp ebml_header?(_), do: false

  # Issue #469: Datei-Rotation. Alten Writer schließen, in `rotated_paths`
  # aufheben (finalize sammelt die mit), neuen flat_key `<base>.<n>` als
  # aktiven Slot vormerken. Der neue Writer wird erst durch den write_chunk-
  # Nil-Zweig eröffnet — kein doppelter Open-Zyklus, alles Weitere fluppt
  # symmetrisch zum Erst-Chunk-Pfad (inkl. #758-Warnung, falls die neue Datei
  # existiert).
  defp rotate_segment(sess, session_id, base_key, old_flat) do
    {file, old_path, _bytes} = sess.writers[old_flat]

    try do
      File.close(file)
    rescue
      _ -> :ok
    end

    next_seg = Map.get(sess.next_seg_index, base_key, 0) + 1
    new_flat = "#{base_key}.#{next_seg}"

    Logger.warning(
      "AudioBuffer: session=#{session_id} base=#{base_key} mid-stream EBML re-header " <>
        "detected → rotating segment #{old_flat} → #{new_flat} (Issue #469)"
    )

    sess = %{
      sess
      | writers: Map.delete(sess.writers, old_flat),
        rotated_paths: [{old_flat, old_path} | sess.rotated_paths],
        active_flat: Map.put(sess.active_flat, base_key, new_flat),
        next_seg_index: Map.put(sess.next_seg_index, base_key, next_seg)
    }

    {sess, new_flat}
  end

  defp close_writers_and_collect(sess) do
    opened =
      sess.writers
      |> Enum.map(fn {flat_key, {file, path, _bytes}} ->
        try do
          File.close(file)
        rescue
          _ -> :ok
        end

        {flat_key, path}
      end)

    # Issue #469: zuvor rotierte Segments einsammeln. `rotated_paths` ist
    # umgekehrt (LIFO); wir kippen es einmal zurück, damit die Segment-
    # Reihenfolge in `finalize` chronologisch bleibt (0, 1, 2, …).
    closed = Enum.reverse(sess.rotated_paths)
    opened ++ closed
  end

  # Issue #757: bei writer-state-loss-Reopen unter :append (#758) die bereits
  # geschriebene Byte-Länge ermitteln, damit der ChunkManifest-Zähler
  # kontinuierlich weiterläuft und die alten Anker gültig bleiben. Fresh file
  # oder unlesbarer Stat → 0 (Sidecar startet dann anker-frei mit dieser Chunk).
  defp existing_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  # Issue #292/#233: GPU-schwere Schritte (Whisper + Diarisierung) durch die
  # zentrale GpuQueue routen; äußerer Task bleibt für PID-Tracking in
  # `pending_transcribes`. Gemeinsam genutzt von finalize/1 (Live-Stop) und der
  # Crash-Recovery (Issue #466) — beide übergeben dieselbe `files`-Form
  # (`[{key, path}]`), nur kommen die Files einmal aus offenen Writern und einmal
  # von der Platte.
  #
  # Issue #642: pro File nach key routen — `multi_*` (Raummikro, diarisiert) bzw.
  # das alte `single_source` (Abwärtskompat für in-flight/recovered Sessions)
  # gehen in den Diarisierungs-Pfad, alles andere (numerische discord_ids) in
  # den Per-Spieler-Pfad. Beide Pfade laufen additiv in EINEM `run_mixed`-Lauf
  # (genau ein `UtterancesTranscribed` → Pipeline triggert einmal).
  defp start_transcribe_task(state, session_id, files) do
    {multi_files, per_player_files} =
      Enum.split_with(files, fn {key, _path} ->
        key == "single_source" or String.starts_with?(key, "multi_")
      end)

    {:ok, pid} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        Worker.GpuQueue.run(
          fn ->
            Worker.Recording.Transcribe.run_mixed(session_id, per_player_files, multi_files)
          end,
          label: "transcribe:#{session_id}"
        )
      end)

    Process.monitor(pid)
    %{state | pending_transcribes: Map.put(state.pending_transcribes, pid, session_id)}
  end

  # Issue #466: scanne den Live-`audio_dir` nach Session-Dirs, die ein vorheriger
  # Worker-Crash verwaist hinterlassen hat (beim Start ist `state.sessions` leer,
  # erfolgreiche Sessions sind via archive_session_audio bereits weg), und jage
  # jede durch den Transcribe-Handoff. SessionEnded wird nachgeholt, weil ein
  # mid-recording-Crash nie finalize erreicht hat.
  defp recover_orphaned_sessions(state) do
    dir = audio_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.reduce(state, &recover_one(&2, &1))

      {:error, _} ->
        state
    end
  end

  defp recover_one(state, session_id) do
    sdir = Path.join(audio_dir(), session_id)
    webms = sdir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))

    case recover_files(sdir, webms) do
      {:skip, reason} ->
        Logger.warning(
          "AudioBuffer: recovery — überspringe verwaistes Dir #{session_id} (#{reason})"
        )

        state

      {:ok, files} ->
        Logger.warning(
          "AudioBuffer: recovery — re-transkribiere verwaiste session=#{session_id} files=#{length(files)} (Worker-Crash während der Aufnahme)"
        )

        # SessionEnded nachholen — ein mid-recording-Crash hat finalize/1 (das es
        # sonst publisht) nie erreicht. Idempotent genug (Status → :ended).
        # Issue #571: Return matchen (siehe finalize/1 oben).
        {:ok, _} =
          Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

        start_transcribe_task(state, session_id, files)
    end
  end

  @doc false
  # Datei-Liste aus dem Dir-Inhalt rekonstruieren — je `.webm` ein {key, path},
  # key = Basename (numerische discord_id, `multi_<id>` oder das alte
  # `single_source`). Das Routing (per-Spieler vs. diarisiert) macht
  # `start_transcribe_task` anhand des key-Prefix (Issue #642). Public für Tests.
  def recover_files(_sdir, []), do: {:skip, "keine .webm-Dateien"}

  def recover_files(sdir, webms) do
    files = Enum.map(webms, fn f -> {Path.basename(f, ".webm"), Path.join(sdir, f)} end)
    {:ok, files}
  end

  @doc false
  # Issue #466/#467: erfolgreich transkribiertes Session-Dir aus dem Live-
  # `audio_dir` entfernen. `audio_done_dir` gesetzt → dorthin verschieben
  # (Rohaudio bleibt erhalten); `nil` → löschen. Rename fällt bei FS-Grenzen
  # (EXDEV, z.B. tmpfs → Disk) auf cp+rm zurück. Public für Unit-Tests.
  def archive_session_audio(session_id) do
    src = Path.join(audio_dir(), session_id)

    if File.dir?(src) do
      case done_dir() do
        nil ->
          File.rm_rf(src)
          Logger.info("AudioBuffer: session=#{session_id} Audio gelöscht (audio_done_dir=nil)")

        dest_root when is_binary(dest_root) ->
          File.mkdir_p!(dest_root)
          dest = Path.join(dest_root, session_id)
          File.rm_rf(dest)

          case File.rename(src, dest) do
            :ok ->
              Retention.stamp_purge_after(dest, retention_days())
              Logger.info("AudioBuffer: session=#{session_id} Audio archiviert → #{dest}")

            {:error, reason} ->
              Logger.warning(
                "AudioBuffer: rename #{src} → #{dest} fehlgeschlagen (#{inspect(reason)}), copy-Fallback"
              )

              File.cp_r!(src, dest)
              File.rm_rf(src)
              Retention.stamp_purge_after(dest, retention_days())
          end
      end
    end

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp publish_session_ended(session_id) do
    # Issue #589 (Cut 4): Intents.publish/1 ist total ({:ok, seq | :pending}) —
    # Fehler werden intern abgefangen (#475). Der `err ->`-Zweig war tot.
    {:ok, _seq} =
      Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

    :ok
  end
end
