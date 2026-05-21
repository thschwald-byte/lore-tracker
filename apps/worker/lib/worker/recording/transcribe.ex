defmodule Worker.Recording.Transcribe do
  @moduledoc """
  Stage 1: convert per-speaker recording files to text via `whisper-cli`.

  Input: list of `{discord_id, webm_path}` from `AudioBuffer.finalize/1`.
  For each file: convert webm/opus → 16k mono WAV via `ffmpeg`, run
  whisper-cli with `-oj` to get a JSON transcript, parse segments, and
  emit one `UtteranceAppended` event per non-empty segment with a
  timestamp computed from session start + segment offset.

  After all files have been processed, emit `SessionEnded` so the
  pipeline (stages 2-4) sees a complete transcript.

  Env-driven config:
  - `:whisper_bin`   (default `whisper-cli`)
  - `:whisper_model` (default `~/.cache/whisper/ggml-base.bin`)
  - `:whisper_lang`  (default `auto`)
  - `:ffmpeg_bin`    (default `ffmpeg`)
  """

  require Logger

  alias Worker.Intents

  def run(session_id, files) do
    started_at = session_started_at(session_id)

    count =
      files
      |> Enum.map(fn {discord_id, path} -> transcribe_one(session_id, discord_id, path, started_at) end)
      |> Enum.sum()

    Logger.info("Transcribe: session=#{session_id} → #{count} utterances")

    {:ok, _} =
      Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

    :ok
  end

  # ─── per-file ────────────────────────────────────────────────────

  defp transcribe_one(session_id, discord_id, webm_path, started_at) do
    size = file_size(webm_path)

    if size < 256 do
      Logger.info(
        "Transcribe: skipping #{discord_id} (size=#{size} bytes — likely no real audio)"
      )

      0
    else
      with {:ok, wav_path} <- to_wav(webm_path),
           {:ok, segments} <- transcribe_wav(wav_path) do
        filtered = filter_hallucinations(segments)
        dropped_hal = length(segments) - length(filtered)

        if dropped_hal > 0 do
          Logger.info(
            "Transcribe: did=#{discord_id} dropped #{dropped_hal} hallucination segment(s)"
          )
        end

        emit_utterances(session_id, discord_id, filtered, started_at)
      else
        {:error, reason} ->
          Logger.warning(
            "Transcribe: failed for did=#{discord_id} path=#{webm_path}: #{inspect(reason)}"
          )

          0
      end
    end
  end

  defp emit_utterances(session_id, discord_id, segments, started_at) do
    deduped = dedupe_consecutive(segments)
    dropped = length(segments) - length(deduped)

    if dropped > 0 do
      Logger.info(
        "Transcribe: did=#{discord_id} dropped #{dropped} duplicate segment(s) (whisper repetition)"
      )
    end

    Enum.reduce(deduped, 0, fn seg, acc ->
      text = seg |> Map.get("text", "") |> String.trim()

      if text == "" do
        acc
      else
        offset_ms = seg |> Map.get("offset_ms", 0)
        ts = DateTime.add(started_at, offset_ms, :millisecond)

        {:ok, _} =
          Intents.publish(%{
            "kind" => Shared.Events.utterance_appended(),
            "id" => UUIDv7.generate(),
            "session_id" => session_id,
            "discord_id" => to_string(discord_id),
            "timestamp" => DateTime.to_iso8601(ts),
            "text" => text,
            "confidence" => nil,
            "status" => "confirmed"
          })

        acc + 1
      end
    end)
  end

  # Whisper neigt zu Wiederholungen auf stillen/rauschigen Passagen (klassische
  # Halluzination). Schmeißt aufeinanderfolgende Segmente raus, deren
  # normalisierter Text identisch ist. Konservativ — keine Levenshtein-Fuzzy,
  # damit echte Wiederholungen wie „Ja. Ja." (zwei Sätze) erhalten bleiben,
  # während eine wiederholte Identität in Folge gedroppt wird.
  # Public weil per Test reflexiv aufgerufen.
  def dedupe_consecutive(segments) do
    {acc, _last_norm} =
      Enum.reduce(segments, {[], nil}, fn seg, {kept, last_norm} ->
        norm = seg |> Map.get("text", "") |> normalize_for_dedupe()

        cond do
          norm == "" -> {kept, last_norm}
          norm == last_norm -> {kept, last_norm}
          true -> {[seg | kept], norm}
        end
      end)

    Enum.reverse(acc)
  end

  defp normalize_for_dedupe(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Bekannte Whisper-Halluzinations-Strings die auf Stille, Hintergrundmusik
  # oder sehr leisen Passagen entstehen. Public für Tests.
  @hallucination_patterns [
    ~r/^\[BLANK_AUDIO\]$/i,
    ~r/^\[Stille\]$/i,
    ~r/^\[ *Stille *\]$/i,
    ~r/^\[Musik\]$/i,
    ~r/^\[ *Musik *\]$/i,
    ~r/^\(Musik\)$/i,
    ~r/^Danke fürs Zuschauen\.?$/i,
    ~r/^Vielen Dank\.?$/i,
    ~r/^Vielen Dank fürs? Zuschauen\.?$/i,
    ~r/^Tschüss\.?$/i,
    ~r/^Auf Wiedersehen\.?$/i,
    ~r/^Bis zum nächsten Mal\.?$/i,
    ~r/^Bis bald\.?$/i,
    ~r/^Untertitel(?:ung)? (?:von|des|im Auftrag) .+$/i,
    ~r/^Abonniert? (?:jetzt|den Kanal)\.?$/i,
    ~r/^\[.*?Applaus.*?\]$/i,
    ~r/^\[.*?Gelächter.*?\]$/i,
    ~r/^www\.\S+$/i
  ]

  def filter_hallucinations(segments) do
    Enum.reject(segments, fn seg ->
      text = seg |> Map.get("text", "") |> String.trim()
      Enum.any?(@hallucination_patterns, &Regex.match?(&1, text))
    end)
  end

  # ─── ffmpeg / whisper-cli ────────────────────────────────────────

  defp to_wav(webm_path) do
    wav_path = Path.rootname(webm_path) <> ".wav"

    base_args = ["-y", "-loglevel", "error", "-i", webm_path, "-ac", "1", "-ar", "16000"]

    filter_args =
      case Worker.Settings.get(:whisper_audio_filter, "") do
        f when is_binary(f) and f != "" -> ["-af", f]
        _ -> []
      end

    args = base_args ++ filter_args ++ [wav_path]

    case System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, wav_path}
      {out, code} -> {:error, {:ffmpeg_failed, code, String.slice(out, 0, 400)}}
    end
  rescue
    e -> {:error, {:ffmpeg_exception, Exception.message(e)}}
  end

  # Wenn ein VAD-Modell konfiguriert ist: das WAV per whisper-vad-speech-
  # segments in Sätze segmentieren und jedes Segment einzeln durch
  # whisper-cli jagen. Verhindert Run-Together-Probleme („kurzschwert-
  # begreifenden Goblin") weil jeder VAD-Slice ein eigener Whisper-Lauf
  # mit eigenem Initial-Prompt-Kontext ist. Fällt sauber auf den
  # Single-Pass-Pfad zurück wenn kein VAD konfiguriert.
  defp transcribe_wav(wav_path) do
    case Worker.Settings.get(:whisper_vad_model) do
      nil ->
        single_pass(wav_path)

      "" ->
        single_pass(wav_path)

      vad_model ->
        if File.exists?(vad_model) do
          case run_vad(wav_path, vad_model) do
            {:ok, []} ->
              Logger.info("Transcribe: VAD found no speech segments, falling back to full pass")
              single_pass(wav_path)

            {:ok, vad_segments} ->
              Logger.info("Transcribe: VAD found #{length(vad_segments)} speech segment(s)")
              transcribe_via_vad(wav_path, vad_segments)

            {:error, reason} ->
              Logger.warning(
                "Transcribe: VAD failed (#{inspect(reason)}), falling back to full pass"
              )

              single_pass(wav_path)
          end
        else
          Logger.warning(
            "Transcribe: VAD model #{vad_model} not found, falling back to full pass"
          )

          single_pass(wav_path)
        end
    end
  end

  defp single_pass(wav_path) do
    with {:ok, json_path} <- run_whisper(wav_path) do
      read_segments(json_path)
    end
  end

  defp run_vad(wav_path, vad_model) do
    args = [
      "-vm", vad_model,
      # 400 ms Stille-Padding zwischen Sätzen — etwas aggressiver als Live-Mode
      # (600 ms) um auch bei knappen Pausen sauber zu splitten.
      "-vsd", "400",
      "-np",
      "-f", wav_path
    ]

    case System.cmd("whisper-vad-speech-segments", args, stderr_to_stdout: true) do
      {out, 0} ->
        # Wiederverwendung des Parsers aus LiveTranscribe (public).
        {:ok, Worker.Recording.LiveTranscribe.parse_vad_segments(out)}

      {out, code} ->
        {:error, {:vad_failed, code, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:vad_exception, Exception.message(e)}}
  end

  defp transcribe_via_vad(wav_path, vad_segments) do
    segments =
      vad_segments
      |> Enum.flat_map(fn {s_ms, e_ms} -> transcribe_slice(wav_path, s_ms, e_ms) end)

    {:ok, segments}
  end

  defp transcribe_slice(wav_path, s_ms, e_ms) do
    slice = wav_path <> ".slice-#{s_ms}-#{e_ms}.wav"

    ffmpeg_args = [
      "-y", "-loglevel", "error",
      "-ss", ms_to_s(s_ms),
      "-to", ms_to_s(e_ms),
      "-i", wav_path,
      "-ac", "1", "-ar", "16000",
      slice
    ]

    with {_, 0} <- System.cmd(ffmpeg_bin(), ffmpeg_args, stderr_to_stdout: true),
         {:ok, json_path} <- run_whisper(slice),
         {:ok, slice_segments} <- read_segments(json_path) do
      File.rm(slice)
      File.rm(json_path)
      # Slice-interne offsets auf globale Timeline umrechnen.
      Enum.map(slice_segments, fn seg -> Map.update(seg, "offset_ms", s_ms, &(&1 + s_ms)) end)
    else
      err ->
        Logger.warning(
          "Transcribe: slice #{s_ms}-#{e_ms} failed: #{inspect(err)}"
        )

        File.rm(slice)
        []
    end
  end

  defp ms_to_s(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)

  defp run_whisper(wav_path) do
    out_prefix = Path.rootname(wav_path)

    base_args = [
      "-m", whisper_model(),
      "-l", whisper_lang(),
      "--no-speech-thold", float_setting(:whisper_no_speech_thold, 0.7),
      "--entropy-thold",   float_setting(:whisper_entropy_thold, 2.4),
      "--logprob-thold",   float_setting(:whisper_logprob_thold, -0.5)
    ]

    prompt_args =
      case Worker.Settings.get(:whisper_initial_prompt, "") do
        s when is_binary(s) and s != "" -> ["--prompt", s]
        _ -> []
      end

    max_len_args =
      case Worker.Settings.get(:whisper_max_len, 0) do
        n when is_integer(n) and n > 0 -> ["--max-len", Integer.to_string(n)]
        _ -> []
      end

    split_args =
      if Worker.Settings.get(:whisper_split_on_word, false), do: ["--split-on-word"], else: []

    args =
      base_args ++
        prompt_args ++ max_len_args ++ split_args ++ ["-oj", "-of", out_prefix, wav_path]

    case System.cmd(whisper_bin(), args, stderr_to_stdout: true) do
      {_, 0} ->
        json_path = out_prefix <> ".json"

        cond do
          File.exists?(json_path) -> {:ok, json_path}
          File.exists?(wav_path <> ".json") -> {:ok, wav_path <> ".json"}
          true -> {:error, {:whisper_no_json, out_prefix}}
        end

      {out, code} ->
        {:error, {:whisper_failed, code, String.slice(out, -400, 400) || out}}
    end
  rescue
    e -> {:error, {:whisper_exception, Exception.message(e)}}
  end

  defp read_segments(json_path) do
    with {:ok, body} <- File.read(json_path),
         {:ok, data} <- Jason.decode(body) do
      segments =
        data
        |> Map.get("transcription", [])
        |> Enum.map(fn seg ->
          %{
            "text" => Map.get(seg, "text", ""),
            "offset_ms" =>
              seg
              |> get_in(["timestamps", "from"])
              |> parse_ts_to_ms()
          }
        end)

      {:ok, segments}
    else
      err -> {:error, {:whisper_json_unreadable, err}}
    end
  end

  # ─── helpers ─────────────────────────────────────────────────────

  # Whisper "HH:MM:SS,mmm" → integer milliseconds
  defp parse_ts_to_ms(nil), do: 0
  defp parse_ts_to_ms(""), do: 0

  defp parse_ts_to_ms(s) when is_binary(s) do
    case String.split(s, ",") do
      [hms, ms] ->
        case String.split(hms, ":") do
          [h, m, sec] ->
            with {h, ""} <- Integer.parse(h),
                 {m, ""} <- Integer.parse(m),
                 {sec, ""} <- Integer.parse(sec),
                 {ms, ""} <- Integer.parse(ms) do
              ((h * 60 + m) * 60 + sec) * 1000 + ms
            else
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp session_started_at(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{started_at: %DateTime{} = ts} -> ts
      _ -> DateTime.utc_now()
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp whisper_bin, do: Worker.Settings.get(:whisper_bin, "whisper-cli")

  defp whisper_model,
    do: Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()

  defp whisper_lang, do: Worker.Settings.get(:whisper_lang, "auto")

  defp ffmpeg_bin, do: Worker.Settings.get(:ffmpeg_bin, "ffmpeg")

  defp float_setting(key, default) do
    val = Worker.Settings.get(key, default)
    :erlang.float_to_binary(val / 1, decimals: 2)
  end
end
