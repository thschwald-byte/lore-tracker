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
           {:ok, json_path} <- run_whisper(wav_path),
           {:ok, segments} <- read_segments(json_path) do
        emit_utterances(session_id, discord_id, segments, started_at)
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
    Enum.reduce(segments, 0, fn seg, acc ->
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

  # ─── ffmpeg / whisper-cli ────────────────────────────────────────

  defp to_wav(webm_path) do
    wav_path = Path.rootname(webm_path) <> ".wav"

    args = [
      "-y",
      "-loglevel", "error",
      "-i", webm_path,
      "-ac", "1",
      "-ar", "16000",
      wav_path
    ]

    case System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, wav_path}
      {out, code} -> {:error, {:ffmpeg_failed, code, String.slice(out, 0, 400)}}
    end
  rescue
    e -> {:error, {:ffmpeg_exception, Exception.message(e)}}
  end

  defp run_whisper(wav_path) do
    out_prefix = Path.rootname(wav_path)

    args = [
      "-m", whisper_model(),
      "-l", whisper_lang(),
      "-oj",
      "-of", out_prefix,
      wav_path
    ]

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

  defp whisper_bin, do: Application.get_env(:worker, :whisper_bin) || "whisper-cli"

  defp whisper_model,
    do:
      Application.get_env(:worker, :whisper_model) ||
        Path.expand("~/.cache/whisper/ggml-base.bin")

  defp whisper_lang, do: Application.get_env(:worker, :whisper_lang) || "auto"

  defp ffmpeg_bin, do: Application.get_env(:worker, :ffmpeg_bin) || "ffmpeg"
end
