defmodule Worker.MultiSourceEval.AudioBuilder do
  @moduledoc """
  Konvertiert Per-Sprecher-Multitrack-WAVs zu WebM/Opus 16 kHz mono — das
  Format das `Worker.Recording.AudioBuffer.append/3` als Base64 erwartet
  (Issue #377 Plan v5 Section D).

  Bitrate ist auf 64 kbps gepinnt. Chrome MediaRecorder benutzt ohne
  expliziten `audioBitsPerSecond` (siehe `apps/hub/assets/js/hooks/record_mic.js`)
  seinen Codec-Default — 64 kbps liegt im Bereich, in dem Opus Speech
  transparent macht und ist reproduzierbar pinnbar. Der wichtigere
  Fidelity-Hebel ist 16 kHz Mono durch den Round-Trip; das passiert hier
  über `-ar 16000 -ac 1`.
  """

  @bitrate "64k"
  @sample_rate 16_000
  @channels 1

  @doc """
  Konvertiert eine WAV-Datei nach WebM/Opus 16kHz mono und gibt den
  Base64-encoded Inhalt zurück.

  `out_path` (optional): Pfad für die Zwischen-WebM-Datei. Default: gleicher
  Stem wie die WAV, mit `.webm`-Endung im selben Verzeichnis.
  """
  @spec wav_to_webm_b64(Path.t(), Path.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def wav_to_webm_b64(wav_path, out_path \\ nil) do
    out_path = out_path || (Path.rootname(wav_path) <> ".webm")

    if not File.exists?(wav_path) do
      {:error, {:wav_missing, wav_path}}
    else
      args = [
        "-i",
        wav_path,
        "-c:a",
        "libopus",
        "-b:a",
        @bitrate,
        "-ar",
        Integer.to_string(@sample_rate),
        "-ac",
        Integer.to_string(@channels),
        "-f",
        "webm",
        "-y",
        out_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_out, 0} ->
          {:ok, Base.encode64(File.read!(out_path))}

        {out, status} ->
          {:error, {:ffmpeg, status, out}}
      end
    end
  end

  @doc """
  Baut pro Sprecher einer Session den WebM-Audiostream (Base64) — liest
  die Multitrack-WAVs aus `<fixtures>/multitrack/<session_name>/<variant>/<speaker>.wav`.

  Returnt `[%{speaker: name, discord_id: id, audio_b64: binary}]`.
  """
  @spec build_for_session(map(), String.t(), Path.t()) ::
          {:ok, [map()]} | {:error, term()}
  def build_for_session(session, variant, fixtures_root) do
    speakers = Map.fetch!(session, "speakers")
    session_name = Map.fetch!(session, "name")

    results =
      Enum.map(speakers, fn {speaker_name, discord_id} ->
        wav =
          Path.join([
            fixtures_root,
            "multitrack",
            session_name,
            variant,
            "#{speaker_name}.wav"
          ])

        case wav_to_webm_b64(wav) do
          {:ok, b64} ->
            %{speaker: speaker_name, discord_id: discord_id, audio_b64: b64}

          {:error, reason} ->
            {:error, {speaker_name, reason}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, results}
      err -> err
    end
  end

  @doc "Gepinnte Konstanten für Doku/Tests."
  def settings, do: %{bitrate: @bitrate, sample_rate: @sample_rate, channels: @channels}
end
