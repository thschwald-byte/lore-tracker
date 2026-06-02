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
  """

  use GenServer

  require Logger

  alias Worker.HubClient

  @default_dir "/tmp/lore_audio"

  # Issue #392: Chunk-Recency-Liveness. Ein Streamer gilt als "weg", wenn seit
  # >@ghost_timeout_ms kein Audio-Chunk mehr kam (= 8 verpasste 500ms-Chunks).
  # Der Sweep-Timer prüft das alle @sweep_interval_ms und broadcastet die
  # geschrumpfte Liste. Presence ist damit aus dem natürlichen Datenfluss
  # abgeleitet, kein Cross-BEAM-PID-Monitoring nötig.
  @ghost_timeout_ms 4_000
  @sweep_interval_ms 2_000

  defp audio_dir do
    Worker.Settings.get(:audio_dir, @default_dir)
  end

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Register a new session. Creates the on-disk directory.

  `mode` selects the recording path:
  - `:default` — read `:transcribe_mode` from `Worker.Settings` (`:batch` /
    `:live` / `:listen`), one file per `discord_id`.
  - `:single_source` — Issue #19: one combined `single_source.webm` for the
    whole table, diarized post-session before transcription.
  """
  def open_session(session_id, campaign_id, mode \\ :default) do
    GenServer.call(__MODULE__, {:open, session_id, campaign_id, mode})
  end

  @doc """
  Append a base64-encoded audio chunk from a player. Opens a writer on
  first chunk for that `discord_id`.
  """
  def append(session_id, discord_id, b64_chunk) do
    GenServer.cast(__MODULE__, {:append, session_id, to_string(discord_id), b64_chunk})
  end

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

  # ─── GenServer ────────────────────────────────────────────────────

  # state: %{
  #   sessions: %{session_id => %{campaign_id, dir, writers, ...}},
  #   pending_transcribes: %{task_pid => session_id}   # Issue #233
  # }
  @impl true
  def init(_) do
    File.mkdir_p!(audio_dir())
    # Issue #392: Chunk-Recency-Sweep — GC't Streamer ohne Chunk seit
    # >@ghost_timeout_ms (ungraceful Disconnect / Tab-Crash).
    Process.send_after(self(), :sweep_ghosts, @sweep_interval_ms)
    {:ok, %{sessions: %{}, pending_transcribes: %{}}}
  end

  @impl true
  def handle_call({:open, session_id, campaign_id, requested_mode}, _from, state) do
    mode =
      case requested_mode do
        :single_source -> :single_source
        _ -> Worker.Settings.get(:transcribe_mode, :batch)
      end

    # Dev-only: refuse Listen mode in a prod release. UI guards too, but
    # defense in depth — a stale persisted setting or an admin poking the
    # Mnesia state directly shouldn't be able to flip a Listen session on
    # in production.
    if mode == :listen and Application.get_env(:worker, :env, :prod) == :prod do
      Logger.error("AudioBuffer: refusing :listen-mode session=#{session_id} in prod env")

      {:reply, {:error, :listen_in_prod}, state}
    else
      dir = Path.join(audio_dir(), session_id)
      File.mkdir_p!(dir)

      sessions =
        Map.put_new(state.sessions, session_id, %{
          campaign_id: campaign_id,
          dir: dir,
          writers: %{},
          # Issue #392: Presence-State, entkoppelt von writers (File-Handles).
          # last_chunk_at: key => monotonic_ms; streamers_broadcast: zuletzt
          # gebroadcastete Key-Liste (für Shrinkage-Erkennung im Sweep).
          # MUSS hier initialisiert sein, sonst crasht der erste update_in.
          last_chunk_at: %{},
          streamers_broadcast: [],
          mode: mode
        })

      publish_streamers(campaign_id, session_id, [])

      # Issue #355: GpuQueue beobachtet recording_state, um Background-Jobs
      # während aktiver Aufnahme zu pausieren. Broadcast bei jedem :open.
      Phoenix.PubSub.broadcast(
        Worker.PubSub,
        "recording_state",
        {:recording_state_changed, true}
      )

      Logger.info("AudioBuffer: session=#{session_id} opened (mode=#{mode}, dir=#{dir})")

      {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  def handle_call({:streamers, session_id}, _from, state) do
    case state.sessions[session_id] do
      nil -> {:reply, [], state}
      sess -> {:reply, fresh_streamers(sess), state}
    end
  end

  def handle_call({:has_pending_transcribe, session_id}, _from, state) do
    pending? =
      state.pending_transcribes
      |> Map.values()
      |> Enum.member?(session_id)

    {:reply, pending?, state}
  end

  @impl true
  def handle_cast({:append, session_id, discord_id, b64}, state) do
    case state.sessions[session_id] do
      nil ->
        # Non-leader workers will routinely see chunks for sessions they don't
        # own — Hub.Commands.pick_leader/1 picks one leader but in-flight
        # frames can still land on others during reconfiguration. Benign.
        Logger.debug(fn ->
          "AudioBuffer: chunk for unknown session=#{session_id} did=#{discord_id}; dropping"
        end)

        {:noreply, state}

      sess ->
        case decode_chunk(b64) do
          {:ok, bin} ->
            {:noreply, write_chunk(state, session_id, sess, discord_id, bin)}

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
        publish_streamers(sess.campaign_id, session_id, [])

        Logger.info(
          "AudioBuffer: finalized session=#{session_id} mode=#{sess.mode} files=#{length(files)} → handing off to Transcribe"
        )

        # Issue #355: SessionEnded firet SOFORT — die Aufnahme IST jetzt
        # beendet, das ist die state-relevante Information für die UI. Die
        # Transkription läuft anschließend asynchron in der GpuQueue weiter
        # und publisht am Ende `UtterancesTranscribed`, worauf die Pipeline
        # triggert.
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
            # Issue #292: GPU-schwere Schritte (Whisper + pyannote-Diarisierung)
            # durch die zentrale Queue routen. Issue #233: äußerer Task bleibt
            # für PID-Tracking in `pending_transcribes`.
            {:ok, pid} =
              Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
                Worker.GpuQueue.run(
                  fn ->
                    if sess.mode == :single_source do
                      # Issue #19: eine kombinierte Datei → Diarisierung +
                      # per-Segment-Whisper statt per-discord_id-Transkription.
                      [{_key, path} | _] = files
                      Worker.Recording.Transcribe.run_single_source(session_id, path)
                    else
                      Worker.Recording.Transcribe.run(session_id, files)
                    end
                  end,
                  label: "transcribe:#{session_id}"
                )
              end)

            Process.monitor(pid)
            pending = Map.put(state.pending_transcribes, pid, session_id)

            %{state | sessions: rest, pending_transcribes: pending}
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
        sess = maybe_broadcast_streamers(session_id, sess)
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
        if reason != :normal do
          Logger.warning(
            "AudioBuffer: Transcribe task for session=#{session_id} exited abnormally: #{inspect(reason)}"
          )
        end

        {:noreply, %{state | pending_transcribes: rest}}
    end
  end

  # Issue #392: Chunk-Recency-Sweep. Pro Session den frischen Streamer-Set
  # neu berechnen; bei Shrinkage (Ghost expirt) broadcasten. Neue Streamer
  # werden bereits vom write_chunk-Pfad gebroadcastet — der Sweep deckt den
  # Fall ab, dass GAR keine Chunks mehr kommen (alle weg / Tab-Crash).
  @impl true
  def handle_info(:sweep_ghosts, state) do
    sessions =
      Map.new(state.sessions, fn {sid, sess} ->
        {sid, maybe_broadcast_streamers(sid, sess)}
      end)

    Process.send_after(self(), :sweep_ghosts, @sweep_interval_ms)
    {:noreply, %{state | sessions: sessions}}
  end

  # ─── Internal ─────────────────────────────────────────────────────

  defp decode_chunk(nil), do: :error
  defp decode_chunk(""), do: :error

  defp decode_chunk(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.decode64(b64, padding: false)
    end
  end

  defp write_chunk(state, session_id, sess, discord_id, bin) do
    # Single-Source (Issue #19): alle Chunks vom Tisch-Laptop landen in EINER
    # Datei, egal welche discord_id der Browser mitschickt. Die Sprecher-
    # Trennung passiert erst post-session via Diarisierung.
    key = if sess.mode == :single_source, do: "single_source", else: discord_id

    {file, path, opened_new?} =
      case sess.writers[key] do
        {file, path} ->
          {file, path, false}

        nil ->
          path = Path.join(sess.dir, "#{key}.webm")
          file = File.open!(path, [:write, :binary])
          {file, path, true}
      end

    :ok = IO.binwrite(file, bin)

    sess =
      if opened_new? do
        %{sess | writers: Map.put(sess.writers, key, {file, path})}
      else
        sess
      end

    # Issue #392: Chunk-Recency aktualisieren + bei Set-Änderung broadcasten.
    # Ersetzt den alten opened_new?-only-Broadcast: ein neuer Key lässt das
    # Set wachsen (→ Broadcast), ein zwischenzeitlich expirter Key der wieder
    # Chunks sendet wird hier re-added (self-healing nach transientem Gap).
    sess = %{sess | last_chunk_at: Map.put(sess.last_chunk_at, key, now_ms())}
    sess = maybe_broadcast_streamers(session_id, sess)

    %{state | sessions: Map.put(state.sessions, session_id, sess)}
  end

  defp close_writers_and_collect(sess) do
    sess.writers
    |> Enum.map(fn {discord_id, {file, path}} ->
      try do
        File.close(file)
      rescue
        _ -> :ok
      end

      {discord_id, path}
    end)
  end

  defp publish_streamers(campaign_id, session_id, discord_ids) do
    HubClient.publish_status(%{
      "kind" => "mic_streamers",
      "campaign_id" => campaign_id,
      "session_id" => session_id,
      "discord_ids" => discord_ids
    })
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Issue #392: frische Streamer = Keys in last_chunk_at, deren letzter Chunk
  # nicht älter als @ghost_timeout_ms ist. Sortiert für stabilen Vergleich.
  defp fresh_streamers(sess, now \\ nil) do
    now = now || now_ms()

    sess
    |> Map.get(:last_chunk_at, %{})
    |> Enum.filter(fn {_key, ts} -> now - ts <= @ghost_timeout_ms end)
    |> Enum.map(fn {key, _ts} -> key end)
    |> Enum.sort()
  end

  # Berechnet den frischen Set und broadcastet NUR wenn er sich gegenüber dem
  # zuletzt gebroadcasteten unterscheidet (Wachstum durch neuen Streamer,
  # Shrinkage durch expirten Ghost). Idempotent — gibt die ggf. mit dem neuen
  # streamers_broadcast aktualisierte Session zurück.
  defp maybe_broadcast_streamers(session_id, sess) do
    fresh = fresh_streamers(sess)

    if fresh == sess.streamers_broadcast do
      sess
    else
      publish_streamers(sess.campaign_id, session_id, fresh)
      %{sess | streamers_broadcast: fresh}
    end
  end

  defp publish_session_ended(session_id) do
    case Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id}) do
      {:ok, _seq} -> :ok
      err -> Logger.warning("AudioBuffer: SessionEnded publish failed: #{inspect(err)}")
    end
  end
end
