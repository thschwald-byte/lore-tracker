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

  @default_dir "/tmp/lore_audio"

  # Issue #392: Chunk-Recency-Liveness. Ein Streamer gilt als "weg", wenn seit
  # >@ghost_timeout_ms kein Audio-Chunk mehr kam (= 8 verpasste 500ms-Chunks).
  # Der Sweep-Timer prüft das alle @sweep_interval_ms und broadcastet die
  # geschrumpfte Liste. Presence ist damit aus dem natürlichen Datenfluss
  # abgeleitet, kein Cross-BEAM-PID-Monitoring nötig.
  @ghost_timeout_ms 4_000
  @sweep_interval_ms 2_000

  # Issue #466: Crash-Recovery-Scan beim Start verzögern, bis der restliche
  # Worker-Tree (GpuQueue, Mnesia-Schema, HubClient) sicher oben ist — der Scan
  # spawnt Transcribe-Tasks, die GpuQueue + Worker.Repo brauchen.
  @recover_delay_ms 5_000

  defp audio_dir do
    Worker.Settings.get(:audio_dir, @default_dir)
  end

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Register a new session. Creates the on-disk directory.

  `mode` selects the recording path:
  - `:default` — Batch-Transkription (Post-Roll nach SessionEnded), eine
    Datei pro `discord_id`.
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
    # Issue #466: verwaiste Session-Dirs aus einem vorherigen Crash wieder
    # aufnehmen (verzögert, s. @recover_delay_ms).
    Process.send_after(self(), :recover_orphans, @recover_delay_ms)
    {:ok, %{sessions: %{}, pending_transcribes: %{}}}
  end

  @impl true
  def handle_call({:open, session_id, campaign_id, requested_mode}, _from, state) do
    mode = if requested_mode == :single_source, do: :single_source, else: :batch

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

        # Issue #468 Cut 2: Session-Halter-Eintrag aus dem Hub-Tracker
        # raus. Pick_leader fällt für diese Session ab jetzt auf die
        # normale lexikografische Sortierung zurück (Stage-1-Transkription
        # ist eh schon im GpuQueue-Tail — kein Chunk-Routing mehr nötig).
        Worker.HubClient.announce_session_released(session_id)

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
            %{state | sessions: rest}
            |> start_transcribe_task(session_id, sess.mode, files)
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

  # Issue #292/#233: GPU-schwere Schritte (Whisper + Diarisierung) durch die
  # zentrale GpuQueue routen; äußerer Task bleibt für PID-Tracking in
  # `pending_transcribes`. Gemeinsam genutzt von finalize/1 (Live-Stop) und der
  # Crash-Recovery (Issue #466) — beide haben am Ende dieselbe (session_id, mode,
  # files)-Form, nur kommen die Files einmal aus offenen Writern und einmal von
  # der Platte.
  defp start_transcribe_task(state, session_id, mode, files) do
    {:ok, pid} =
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        Worker.GpuQueue.run(
          fn ->
            if mode == :single_source do
              # Issue #19: eine kombinierte Datei → Diarisierung + per-Segment-
              # Whisper statt per-discord_id-Transkription.
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

      {mode, files} ->
        Logger.warning(
          "AudioBuffer: recovery — re-transkribiere verwaiste session=#{session_id} mode=#{mode} files=#{length(files)} (Worker-Crash während der Aufnahme)"
        )

        # SessionEnded nachholen — ein mid-recording-Crash hat finalize/1 (das es
        # sonst publisht) nie erreicht. Idempotent genug (Status → :ended).
        Worker.Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

        start_transcribe_task(state, session_id, mode, files)
    end
  end

  @doc false
  # Mode + Datei-Liste aus dem Dir-Inhalt rekonstruieren. single_source.webm →
  # :single_source; sonst je `.webm` ein {discord_id, path}-Batch-Eintrag.
  # Public für Unit-Tests.
  def recover_files(_sdir, []), do: {:skip, "keine .webm-Dateien"}

  def recover_files(sdir, webms) do
    if "single_source.webm" in webms do
      {:single_source, [{"single_source", Path.join(sdir, "single_source.webm")}]}
    else
      files = Enum.map(webms, fn f -> {Path.basename(f, ".webm"), Path.join(sdir, f)} end)
      {:batch, files}
    end
  end

  @doc false
  # Issue #466/#467: erfolgreich transkribiertes Session-Dir aus dem Live-
  # `audio_dir` entfernen. `audio_done_dir` gesetzt → dorthin verschieben
  # (Rohaudio bleibt erhalten); `nil` → löschen. Rename fällt bei FS-Grenzen
  # (EXDEV, z.B. tmpfs → Disk) auf cp+rm zurück. Public für Unit-Tests.
  def archive_session_audio(session_id) do
    src = Path.join(audio_dir(), session_id)

    if File.dir?(src) do
      case Worker.Settings.get(:audio_done_dir) do
        nil ->
          File.rm_rf(src)
          Logger.info("AudioBuffer: session=#{session_id} Audio gelöscht (audio_done_dir=nil)")

        done_dir when is_binary(done_dir) ->
          File.mkdir_p!(done_dir)
          dest = Path.join(done_dir, session_id)
          File.rm_rf(dest)

          case File.rename(src, dest) do
            :ok ->
              Logger.info("AudioBuffer: session=#{session_id} Audio archiviert → #{dest}")

            {:error, reason} ->
              Logger.warning(
                "AudioBuffer: rename #{src} → #{dest} fehlgeschlagen (#{inspect(reason)}), copy-Fallback"
              )

              File.cp_r!(src, dest)
              File.rm_rf(src)
          end
      end
    end

    :ok
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
