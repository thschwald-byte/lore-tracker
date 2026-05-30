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
      File.mkdir_p!(Path.join(dir, "live"))

      sessions =
        Map.put_new(state.sessions, session_id, %{
          campaign_id: campaign_id,
          dir: dir,
          writers: %{},
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

      if mode == :live do
        vad = Worker.Settings.get(:whisper_vad_model)

        cond do
          is_nil(vad) or vad == "" ->
            Logger.warning(
              "AudioBuffer: mode=live but :whisper_vad_model setting is not set — live transcription will silently degrade to batch. " <>
                "Set it in the Einstellungen page (Stage 1) or download silero-v5.1.2.bin."
            )

          not File.exists?(vad) ->
            Logger.warning(
              "AudioBuffer: mode=live but WHISPER_VAD_MODEL=#{vad} doesn't exist — live transcription will degrade to batch."
            )

          true ->
            :ok
        end
      end

      {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  def handle_call({:streamers, session_id}, _from, state) do
    case state.sessions[session_id] do
      nil -> {:reply, [], state}
      %{writers: w} -> {:reply, Map.keys(w), state}
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

        # In live mode: drain + terminate the LiveTranscribe children for
        # this session, then publish LiveUtterancesCleared so the
        # Materializer wipes the transient live-status rows. The batch
        # re-pass below replaces them with confirmed truth.
        if sess.mode == :live do
          :ok = Worker.Recording.LiveTranscribe.close_session(session_id)
          publish_live_utterances_cleared(session_id)
        end

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

    if opened_new? do
      publish_streamers(sess.campaign_id, session_id, Map.keys(sess.writers))
    end

    if sess.mode == :live, do: live_tee(session_id, sess, discord_id, bin)

    %{state | sessions: Map.put(state.sessions, session_id, sess)}
  end

  # Forward an audio chunk to the per-speaker LiveTranscribe GenServer.
  # On first chunk per (session, discord_id), lazily spawn the child.
  # If spawn returns :ignore (WHISPER_VAD_MODEL not set), the function
  # logs once and is then a no-op for this (session, discord_id).
  defp live_tee(session_id, sess, discord_id, bin) do
    case Worker.Recording.LiveTranscribe.append(session_id, discord_id, bin) do
      :no_transcriber ->
        case Worker.Recording.LiveTranscribe.open(
               session_id,
               sess.campaign_id,
               discord_id,
               sess.dir
             ) do
          {:ok, _pid} ->
            Worker.Recording.LiveTranscribe.append(session_id, discord_id, bin)

          :ignore ->
            :ok

          {:error, {:already_started, _pid}} ->
            Worker.Recording.LiveTranscribe.append(session_id, discord_id, bin)

          {:error, reason} ->
            Logger.warning(
              "AudioBuffer: LiveTranscribe.open failed for did=#{discord_id}: #{inspect(reason)}"
            )

            :ok
        end

      _ ->
        :ok
    end
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

  defp publish_session_ended(session_id) do
    case Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id}) do
      {:ok, _seq} -> :ok
      err -> Logger.warning("AudioBuffer: SessionEnded publish failed: #{inspect(err)}")
    end
  end

  defp publish_live_utterances_cleared(session_id) do
    case Worker.Intents.publish(%{
           "kind" => Shared.Events.live_utterances_cleared(),
           "session_id" => session_id
         }) do
      {:ok, _seq} -> :ok
      err -> Logger.warning("AudioBuffer: LiveUtterancesCleared publish failed: #{inspect(err)}")
    end
  end
end
