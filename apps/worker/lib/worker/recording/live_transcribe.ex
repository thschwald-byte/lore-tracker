defmodule Worker.Recording.LiveTranscribe do
  @moduledoc """
  Per-(session_id, discord_id) live-transcription GenServer.

  Audio chunks arrive via `append/3` from `AudioBuffer.write_chunk` (only
  when the session's mode is `:live`). The chunks are raw fragmented
  webm/opus bytes; we append them to a rolling `<dir>/live/<discord_id>.webm`
  that grows as the session continues. The actual on-disk session file
  (one level up, used by the batch re-pass) is owned by AudioBuffer; we
  keep our own copy here so we can read it without coordinating with that
  GenServer.

  Two periodic ticks (interleaved):

  1. **Commit tick** (every 1 s): transcode to 16k mono WAV via `ffmpeg`,
     run `whisper-vad-speech-segments` to find speech segments. Any segment
     whose `end_ms` is far enough back from the current tail (≥ 600 ms
     silence padding) is "committed": its audio slice is cut out with
     `ffmpeg -ss/-to`, run through `whisper-cli`, and emitted as a real
     `UtteranceAppended` event with `status: "live"`. `last_committed_end_ms`
     advances so we don't re-emit.

  2. **Partial tick** (every 1.5 s): the tail after `last_committed_end_ms`
     is run through `whisper-cli` (no VAD, fast) and shipped as a transient
     `transcript_chunk` `publish_status`. NOT persisted.

  When the session ends, `close/2` runs one final commit tick (drain), then
  the GenServer terminates. AudioBuffer then publishes
  `LiveUtterancesCleared` so the live-status rows in Mnesia get wiped, and
  the regular batch `Transcribe.run/2` overwrites the truth.
  """

  use GenServer

  require Logger

  alias Worker.{HubClient, Intents}

  @tick_interval_ms 1_000
  @partial_interval_ms 1_500
  @vad_silence_ms 600
  @min_commit_audio_s 0.3
  @partial_after_commit_min_s 0.5

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Spawn a live-transcribe worker for one speaker. Returns `{:ok, pid}`,
  `:ignore` (env not configured — degrades to batch silently for this
  session), or `{:error, reason}`.
  """
  def open(session_id, campaign_id, discord_id, session_dir) do
    Worker.Recording.LiveTranscribe.Supervisor.start_child(
      {session_id, campaign_id, discord_id, session_dir}
    )
  end

  def append(session_id, discord_id, bin) when is_binary(bin) do
    case Registry.lookup(registry(), {session_id, discord_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:append, bin})
      [] -> :no_transcriber
    end
  end

  @doc """
  Synchronously drain + terminate every live-transcriber for a session.
  Called by AudioBuffer.finalize/1 right before the batch re-pass.
  """
  def close_session(session_id) do
    Registry.select(registry(), [
      {{{:"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", session_id}], [:"$3"]}
    ])
    |> Enum.each(fn pid ->
      try do
        GenServer.call(pid, :close, 15_000)
      catch
        :exit, reason ->
          Logger.warning("LiveTranscribe.close_session: pid=#{inspect(pid)} exit #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp registry, do: Worker.Recording.LiveTranscribe.Registry

  # ─── GenServer ──────────────────────────────────────────────────────

  def start_link({session_id, _campaign_id, discord_id, _dir} = args) do
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {registry(), {session_id, discord_id}}})
  end

  @impl true
  def init({session_id, campaign_id, discord_id, dir}) do
    vad_model = Worker.Settings.get(:whisper_vad_model)

    cond do
      is_nil(vad_model) or vad_model == "" ->
        Logger.error(
          "LiveTranscribe: WHISPER_VAD_MODEL is not set — live mode degrades to batch for this session"
        )

        :ignore

      not File.exists?(vad_model) ->
        Logger.error(
          "LiveTranscribe: WHISPER_VAD_MODEL=#{vad_model} does not exist — live mode degrades to batch"
        )

        :ignore

      true ->
        live_dir = Path.join(dir, "live")
        File.mkdir_p!(live_dir)

        webm = Path.join(live_dir, "#{discord_id}.webm")
        wav = webm <> ".wav"
        writer = File.open!(webm, [:write, :binary])

        state = %{
          session_id: session_id,
          campaign_id: campaign_id,
          discord_id: discord_id,
          webm: webm,
          wav: wav,
          writer: writer,
          bytes_written: 0,
          last_processed_bytes: 0,
          last_committed_end_ms: 0,
          last_partial_at: 0,
          session_started_at: DateTime.utc_now(),
          vad_model: vad_model
        }

        schedule_tick(@tick_interval_ms)

        Logger.info(
          "LiveTranscribe: spawned session=#{session_id} did=#{discord_id} webm=#{webm}"
        )

        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:append, bin}, state) do
    :ok = IO.binwrite(state.writer, bin)
    {:noreply, %{state | bytes_written: state.bytes_written + byte_size(bin)}}
  end

  @impl true
  def handle_call(:close, _from, state) do
    state = run_tick(state, :final)
    safe_close(state.writer)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = run_tick(state, :periodic)
    schedule_tick(@tick_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    safe_close(state.writer)
    :ok
  end

  defp safe_close(nil), do: :ok

  defp safe_close(writer) do
    try do
      File.close(writer)
    rescue
      _ -> :ok
    end
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  # ─── Tick pipeline ──────────────────────────────────────────────────

  defp run_tick(%{bytes_written: bw, last_processed_bytes: lpb} = state, _) when bw == lpb do
    state
  end

  defp run_tick(state, kind) do
    case to_wav(state.webm, state.wav) do
      :ok ->
        case run_vad(state.wav, state.vad_model) do
          {:ok, segments} ->
            state = commit_segments(state, segments, kind)
            state = maybe_partial(state, segments, kind)
            %{state | last_processed_bytes: state.bytes_written}

          {:error, reason} ->
            Logger.debug(fn -> "LiveTranscribe: VAD pass skipped — #{inspect(reason)}" end)
            state
        end

      {:error, reason} ->
        Logger.debug(fn -> "LiveTranscribe: ffmpeg not ready — #{inspect(reason)}" end)
        state
    end
  end

  defp commit_segments(state, segments, kind) do
    pad_ms = if kind == :final, do: 0, else: @vad_silence_ms

    {tail_ms, _} = tail_duration_ms(state.wav)

    ready =
      Enum.filter(segments, fn {_s_ms, e_ms} ->
        e_ms > state.last_committed_end_ms and
          e_ms + pad_ms <= tail_ms and
          e_ms - max(state.last_committed_end_ms, 0) >= @min_commit_audio_s * 1000
      end)

    Enum.reduce(ready, state, fn {s_ms, e_ms}, acc ->
      acc
      |> maybe_emit_utterance(s_ms, e_ms)
      |> Map.put(:last_committed_end_ms, e_ms)
    end)
  end

  defp maybe_emit_utterance(state, s_ms, e_ms) do
    case slice_and_transcribe(state.wav, s_ms, e_ms, state.session_id, state.campaign_id) do
      {:ok, ""} ->
        state

      {:ok, text} ->
        utt_id = UUIDv7.generate()
        ts = DateTime.add(state.session_started_at, s_ms, :millisecond)

        payload = %{
          "kind" => Shared.Events.utterance_appended(),
          "id" => utt_id,
          "session_id" => state.session_id,
          "discord_id" => state.discord_id,
          "timestamp" => DateTime.to_iso8601(ts),
          "text" => text,
          "confidence" => nil,
          "status" => "live"
        }

        case Intents.publish(payload) do
          {:ok, _seq} ->
            Logger.debug(fn ->
              "LiveTranscribe: committed #{state.discord_id} #{s_ms}..#{e_ms}ms text=#{String.slice(text, 0, 40)}"
            end)

          err ->
            Logger.warning("LiveTranscribe: Intents.publish failed: #{inspect(err)}")
        end

        state

      {:error, reason} ->
        Logger.warning("LiveTranscribe: slice/transcribe failed: #{inspect(reason)}")
        state
    end
  end

  defp maybe_partial(state, _segments, :final), do: state

  defp maybe_partial(state, _segments, _kind) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - state.last_partial_at < @partial_interval_ms ->
        state

      true ->
        {tail_ms, _} = tail_duration_ms(state.wav)
        tail_start_ms = max(state.last_committed_end_ms, 0)

        if tail_ms - tail_start_ms < @partial_after_commit_min_s * 1000 do
          state
        else
          case partial_transcribe(state.wav, tail_start_ms, tail_ms, state.session_id, state.campaign_id) do
            {:ok, text} when text != "" ->
              HubClient.publish_status(%{
                "kind" => "transcript_chunk",
                "campaign_id" => state.campaign_id,
                "session_id" => state.session_id,
                "discord_id" => state.discord_id,
                "text" => text,
                "at_ts" =>
                  state.session_started_at
                  |> DateTime.add(tail_start_ms, :millisecond)
                  |> DateTime.to_iso8601()
              })

            _ ->
              :ok
          end

          %{state | last_partial_at: now}
        end
    end
  end

  # ─── External tools ────────────────────────────────────────────────

  defp to_wav(webm, wav) do
    base_args = ["-y", "-loglevel", "error", "-i", webm, "-ac", "1", "-ar", "16000"]

    filter_args =
      case Worker.Settings.get(:whisper_audio_filter, "") do
        f when is_binary(f) and f != "" -> ["-af", f]
        _ -> []
      end

    args = base_args ++ filter_args ++ [wav]

    case System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:ffmpeg, code, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:ffmpeg_exception, Exception.message(e)}}
  end

  defp run_vad(wav, vad_model) do
    args = [
      "-vm", vad_model,
      "-vsd", Integer.to_string(@vad_silence_ms),
      "-np",
      "-f", wav
    ]

    case System.cmd("whisper-vad-speech-segments", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse_vad_segments(out)}
      {out, code} -> {:error, {:vad_failed, code, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:vad_exception, Exception.message(e)}}
  end

  @doc """
  Parse whisper-vad-speech-segments output into `[{start_ms, end_ms}]`.
  Accepts both human-readable `[ 0.000 --> 1.234]` lines and bare
  `0.000 1.234` pairs — whisper.cpp's output format varies by version.
  Public for unit tests.
  """
  def parse_vad_segments(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_vad_line/1)
  end

  # whisper.cpp-hip 1.8.3's `whisper-vad-speech-segments` writes values in
  # 10ms-frame units (centiseconds). Empirically a 33.5 s wav file produces
  # ranges with end ≈ 3350.00, not 33.5. The ×10 scaling below converts to
  # milliseconds. If a future whisper-cpp version emits sub-second floats
  # (e.g. 1.234 s), the result would be ~12 ms, which `commit_segments`
  # would correctly never accept — safe either way.
  @vad_patterns [
    # whisper.cpp 1.8.3-hip primary format:
    # "Speech segment 0: start = 579.00, end = 694.00"
    ~r/start\s*=\s*(-?\d+(?:\.\d+)?)\s*,?\s*end\s*=\s*(-?\d+(?:\.\d+)?)/,
    # older / arrow format:
    # "[ 0.000 --> 1.234 ]"
    ~r/(-?\d+(?:\.\d+)?)\s*-->\s*(-?\d+(?:\.\d+)?)/,
    # bare-pair on its own line:
    # "0.000 1.234"
    ~r/^\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*$/
  ]

  defp parse_vad_line(line) do
    trimmed = String.trim(line)

    Enum.find_value(@vad_patterns, [], fn re ->
      case Regex.run(re, trimmed) do
        [_, s, e] ->
          with {sf, ""} <- Float.parse(s),
               {ef, ""} <- Float.parse(e) do
            [{round(sf * 10), round(ef * 10)}]
          else
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp tail_duration_ms(wav) do
    case System.cmd(
           "ffprobe",
           [
             "-v", "error",
             "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1",
             wav
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Float.parse(String.trim(out)) do
          {dur, _} -> {round(dur * 1000), :ok}
          _ -> {0, :ok}
        end

      _ ->
        {0, :error}
    end
  rescue
    _ -> {0, :error}
  end

  defp slice_and_transcribe(wav, s_ms, e_ms, session_id, campaign_id) do
    slice = wav <> ".slice.wav"

    ffmpeg_args = [
      "-y", "-loglevel", "error",
      "-ss", ms_to_s(s_ms),
      "-to", ms_to_s(e_ms),
      "-i", wav,
      "-ac", "1", "-ar", "16000",
      slice
    ]

    with {_, 0} <- System.cmd(ffmpeg_bin(), ffmpeg_args, stderr_to_stdout: true),
         {:ok, text} <- whisper_cli_text(slice, session_id, campaign_id) do
      File.rm(slice)
      {:ok, text}
    else
      {out, code} -> {:error, {:ffmpeg_slice, code, String.slice(out, 0, 200)}}
      err -> err
    end
  end

  defp partial_transcribe(wav, s_ms, e_ms, session_id, campaign_id) do
    slice = wav <> ".partial.wav"

    ffmpeg_args = [
      "-y", "-loglevel", "error",
      "-ss", ms_to_s(s_ms),
      "-to", ms_to_s(e_ms),
      "-i", wav,
      "-ac", "1", "-ar", "16000",
      slice
    ]

    with {_, 0} <- System.cmd(ffmpeg_bin(), ffmpeg_args, stderr_to_stdout: true),
         {:ok, text} <- whisper_cli_text(slice, session_id, campaign_id) do
      File.rm(slice)
      {:ok, text}
    else
      {_, _code} -> {:error, :partial_ffmpeg}
      err -> err
    end
  end

  defp whisper_cli_text(wav, session_id, campaign_id) do
    out_prefix = wav <> ".out"

    base_args = [
      "-m", whisper_model(),
      "-l", whisper_lang(),
      "--no-speech-thold", float_setting(:whisper_no_speech_thold, 0.7),
      "--entropy-thold",   float_setting(:whisper_entropy_thold, 2.4),
      "--logprob-thold",   float_setting(:whisper_logprob_thold, -0.5)
    ]

    prompt = Worker.Recording.PromptBuilder.build(session_id, campaign_id)

    prompt_args =
      if prompt != "", do: ["--prompt", prompt], else: []

    max_len_args =
      case Worker.Settings.get(:whisper_max_len, 0) do
        n when is_integer(n) and n > 0 -> ["--max-len", Integer.to_string(n)]
        _ -> []
      end

    split_args =
      if Worker.Settings.get(:whisper_split_on_word, false), do: ["--split-on-word"], else: []

    args =
      base_args ++ prompt_args ++ max_len_args ++ split_args ++ ["-oj", "-of", out_prefix, wav]

    case System.cmd(whisper_bin(), args, stderr_to_stdout: true) do
      {_, 0} ->
        json_path = out_prefix <> ".json"

        cond do
          File.exists?(json_path) ->
            text = read_whisper_text(json_path)
            File.rm(json_path)
            {:ok, text}

          true ->
            {:error, :no_json}
        end

      {out, code} ->
        {:error, {:whisper_failed, code, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:whisper_exception, Exception.message(e)}}
  end

  defp read_whisper_text(path) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body) do
      data
      |> Map.get("transcription", [])
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join(" ")
      |> String.trim()
    else
      _ -> ""
    end
  end

  defp ms_to_s(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)

  defp whisper_bin, do: Worker.Settings.get(:whisper_bin, "whisper-cli")
  defp ffmpeg_bin, do: Worker.Settings.get(:ffmpeg_bin, "ffmpeg")

  defp whisper_model,
    do: Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()

  defp whisper_lang, do: Worker.Settings.get(:whisper_lang, "auto")

  defp float_setting(key, default) do
    val = Worker.Settings.get(key, default)
    :erlang.float_to_binary(val / 1, decimals: 2)
  end
end
