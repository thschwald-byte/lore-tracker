defmodule Worker.Discord.AudioBridge do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage F: verbindet
  `Worker.Discord.FrameBuffer` (Zeitkorrektur) + `Worker.Discord.OggOpusMuxer`
  (Container) zu fertigen WebM/Opus-Base64-Blobs, wie sie
  `Worker.Recording.AudioBuffer.append/5` erwartet (dasselbe Format, das
  `Worker.MultiSourceEval.AudioBuilder.wav_to_webm_b64/2` bereits für
  synthetische Test-Audio erzeugt — hier wiederverwendet, nicht dupliziert).

  **Pipeline (jeder Schritt empirisch gegen echte, ffmpeg-erzeugte Opus-Pakete
  verifiziert, s. `OggOpusMuxer`-Moduledoc):**

  1. `FrameBuffer.segment/1` — Zeitkorrektur, liefert pro Sprecher eine
     chronologische Liste `%{opus:, silence_before_ms:}`.
  2. `OggOpusMuxer.mux/2` — NUR die echten Opus-Pakete (lückenlos) in einen
     validen Ogg-Opus-Container.
  3. `ffmpeg` dekodiert den Container zu rohem PCM (48kHz/Stereo/s16le) —
     verifiziert: die Paket-Reihenfolge bleibt erhalten, jedes 20ms-Opus-
     Paket dekodiert (bei `PreSkip=0` im OpusHead) zu GENAU 960 Samples,
     ohne Drift über die ganze Datei.
  4. **Stille wird HIER, auf PCM-Ebene, eingefügt** (Null-Bytes) — nicht als
     Opus-Paket-Trick (s. `OggOpusMuxer`-Moduledoc für den empirischen
     Negativ-Befund: eine Granule-Lücke im Container wird von ffmpeg NICHT
     automatisch mit Stille aufgefüllt). Auf PCM-Ebene ist Stille trivial +
     garantiert korrekt.
  5. Das resultierende PCM wird in eine neue WAV-Datei geschrieben und über
     das bestehende, bereits geprüfte `AudioBuilder.wav_to_webm_b64/2`
     (Issue #377) nach WebM/Opus konvertiert — derselbe Pfad, den
     `AudioBuffer.append/5` von Browser-Chunks erwartet.

  **Ungelöste Grenze (v1, ehrlich benannt):** die Byte-genaue 960-Samples-
  pro-Paket-Annahme ist gegen synthetische, mit ffmpeg selbst erzeugte
  Opus-Pakete verifiziert — NICHT gegen echte, live von Nostrum
  dave_decrypt'te Discord-Pakete (die dieser Session-Umgebung nicht zur
  Verfügung standen). Das Discord-Voice-Protokoll ist öffentlich als 48kHz/
  Stereo/20ms-Opus dokumentiert, was dieselbe Annahme stützt, aber die
  End-to-End-Kette (echte Discord-Pakete → hörbares/transkribierbares
  Ergebnis) braucht eine PR-Test-Verifikation mit echtem Discord-Server
  (s. Plan-Verifikation), bevor dieser Pfad als vollständig funktionsfähig
  gilt.
  """

  require Logger

  alias Worker.Discord.{FrameBuffer, OggOpusMuxer}

  @channels 2
  @sample_rate 48_000
  @frame_duration_ms 20
  @bytes_per_sample 2

  @bytes_per_frame div(@sample_rate * @frame_duration_ms, 1000) * @channels * @bytes_per_sample
  @bytes_per_ms div(@sample_rate * @channels * @bytes_per_sample, 1000)

  @doc """
  `frames`: rohe `%{ssrc:, opus:, arrival_ms:}`-Liste (gemischt über alle
  Sprecher einer Voice-Session). Liefert `%{ssrc => {:ok, base64_webm} |
  {:error, term()}}` — ein Fehler bei einem Sprecher darf die anderen nicht
  mitreißen (Design-Präzedenz: Fehlerisolierung pro Bogen bei den
  Arc-Progressionen, #838).
  """
  @spec build_speaker_clips([map()]) :: %{term() => {:ok, binary()} | {:error, term()}}
  def build_speaker_clips(frames) when is_list(frames) do
    frames
    |> FrameBuffer.segment()
    |> Map.new(fn {ssrc, segments} -> {ssrc, build_clip(segments)} end)
  end

  defp build_clip([]), do: {:error, :no_frames}

  defp build_clip(segments) do
    opus_packets = Enum.map(segments, & &1.opus)
    ogg = OggOpusMuxer.mux(opus_packets)

    with {:ok, ogg_path} <- write_tmp(ogg, ".opus"),
         {:ok, pcm} <- decode_to_pcm(ogg_path),
         spliced <- splice_silence(pcm, segments),
         {:ok, wav_path} <- write_wav(spliced),
         {:ok, b64} <- Worker.MultiSourceEval.AudioBuilder.wav_to_webm_b64(wav_path) do
      cleanup([ogg_path, wav_path, Path.rootname(wav_path) <> ".webm"])
      {:ok, b64}
    else
      {:error, reason} = err ->
        Logger.error("Worker.Discord.AudioBridge: build_clip fehlgeschlagen: #{inspect(reason)}")
        err
    end
  end

  defp write_tmp(binary, ext) do
    path = Path.join(System.tmp_dir!(), "discord_voice_#{UUIDv7.generate()}#{ext}")

    case File.write(path, binary) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:tmp_write_failed, reason}}
    end
  end

  defp decode_to_pcm(ogg_path) do
    ffmpeg = Worker.Settings.get(:ffmpeg_bin)
    pcm_path = Path.rootname(ogg_path) <> ".pcm"

    args = [
      "-i",
      ogg_path,
      "-f",
      "s16le",
      "-ar",
      Integer.to_string(@sample_rate),
      "-ac",
      Integer.to_string(@channels),
      "-y",
      pcm_path
    ]

    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_out, 0} ->
        pcm = File.read!(pcm_path)
        File.rm(pcm_path)
        {:ok, pcm}

      {out, status} ->
        {:error, {:ffmpeg_decode_failed, status, out}}
    end
  end

  # Stille wird VOR jedem Frame eingefügt (Null-Bytes, s. Moduledoc) —
  # `silence_before_ms` kommt 1:1 aus `FrameBuffer.segment/1`. Jeder Frame
  # entspricht exakt `@bytes_per_frame` Bytes im dekodierten PCM (verifiziert:
  # 20ms @ 48kHz/Stereo/s16le, PreSkip=0 im OpusHead → keine Drift).
  defp splice_silence(pcm, segments) do
    {result, _rest} =
      Enum.reduce(segments, {[], pcm}, fn seg, {acc, remaining_pcm} ->
        <<frame_bytes::binary-size(@bytes_per_frame), rest::binary>> = remaining_pcm
        silence = :binary.copy(<<0>>, seg.silence_before_ms * @bytes_per_ms)
        {[frame_bytes, silence | acc], rest}
      end)

    result |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp write_wav(pcm) do
    path = Path.join(System.tmp_dir!(), "discord_voice_#{UUIDv7.generate()}.wav")
    data_size = byte_size(pcm)
    byte_rate = @sample_rate * @channels * @bytes_per_sample
    block_align = @channels * @bytes_per_sample

    header = <<
      "RIFF",
      36 + data_size::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      1::little-16,
      @channels::little-16,
      @sample_rate::little-32,
      byte_rate::little-32,
      block_align::little-16,
      @bytes_per_sample * 8::little-16,
      "data",
      data_size::little-32
    >>

    case File.write(path, <<header::binary, pcm::binary>>) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:tmp_write_failed, reason}}
    end
  end

  defp cleanup(paths), do: Enum.each(paths, &File.rm/1)
end
