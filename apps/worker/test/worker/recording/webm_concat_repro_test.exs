defmodule Worker.Recording.WebmConcatReproTest do
  @moduledoc """
  Issue #469: Repro-Test für den Verdacht, dass zwei konkatenierte WebM-Streams
  (der Fall, den ein Auto-Resume nach Device-Re-Plug via neu-gebauter
  MediaRecorder-Instanz produziert) beim Server-side ffmpeg-Decode still
  abgeschnitten werden — der Rest nach dem zweiten EBML-Header geht verloren.

  Der Test **erzeugt** die Situation deterministisch: zwei kurze WebM/opus-
  Files aus Sinus-Ton (via ffmpeg auf einer lavfi-Quelle, wie Client-
  MediaRecorder pro Recorder-Instanz einen kompletten EBML/Segment-Header
  schreibt), konkateniert sie **binär** genau so wie
  `AudioBuffer.write_chunk/6` es tut (`IO.binwrite`), decodiert dann durch
  denselben ffmpeg-Aufruf wie `Transcribe.to_wav/2` (`-loglevel error -ac 1
  -ar 16000`) und vergleicht die decodierte WAV-Dauer gegen die Summe der
  beiden Input-Dauern.

  Wenn die Output-Dauer nur ~= Dauer1 ist (statt Dauer1 + Dauer2), ist der Bug
  bestätigt: ffmpeg beendet den Decode am zweiten EBML-Header still und
  verwirft alles danach.

  Nicht getaggt (kein `@moduletag`), läuft in `mix test` mit — der Test ist
  schnell (~1 s ffmpeg-Runtime) und braucht nur `ffmpeg`/`ffprobe` im PATH,
  die im Dev-Setup ohnehin da sind.
  """

  use ExUnit.Case, async: true

  @dur1_s 3.0
  @dur2_s 4.0
  # Wenn das Output-WAV länger als (dur1 + dur2) * 0.9 ist → beide Teile
  # dekodiert. Wenn kürzer als (dur1) * 1.1 → nur der erste Teil, zweiter
  # nach EBML-Reboundary silently verworfen (Bug bestätigt).
  @combined_lower_bound (@dur1_s + @dur2_s) * 0.9

  setup do
    dir = Path.join(System.tmp_dir!(), "webm_concat_repro_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Skip auf CI-Runnern, denen ffmpeg/ffprobe/libopus fehlen (das Codeberg-
  # Woodpecker `hexpm/elixir`-Image bringt sie nicht mit). Der Test ist ein
  # Regressions-Guard gegen ein Sub-Verhalten des lokalen ffmpeg — wenn die
  # Werkzeuge nicht da sind, gibt es hier nichts zu prüfen.
  defp ffmpeg_available? do
    System.find_executable("ffmpeg") != nil and System.find_executable("ffprobe") != nil
  end

  test "zwei konkatenierte MediaRecorder-artige WebMs werden vollständig dekodiert (Bug widerlegt/bestätigt)",
       %{dir: dir} do
    if not ffmpeg_available?() do
      IO.puts(
        :stderr,
        "webm_concat_repro_test: skipping — ffmpeg/ffprobe nicht im PATH (Regressions-Guard braucht die Werkzeuge lokal)"
      )
    else
      run_repro(dir)
    end
  end

  defp run_repro(dir) do
    webm1 = Path.join(dir, "part1.webm")
    webm2 = Path.join(dir, "part2.webm")
    concat = Path.join(dir, "concat.webm")
    wav_out = Path.join(dir, "concat.wav")

    # Zwei kurze WebM/opus-Clips aus lavfi-Sinus (unterschiedliche Frequenzen,
    # damit ein späteres Debugging Teil 1 vs Teil 2 hören könnte). Format
    # entspricht MediaRecorder-Output: WebM-Container, Opus-Codec.
    assert :ok = make_webm(webm1, freq: 440, duration_s: @dur1_s)
    assert :ok = make_webm(webm2, freq: 660, duration_s: @dur2_s)

    d1 = ffprobe_duration(webm1)
    d2 = ffprobe_duration(webm2)

    assert d1 > 0.0 and d2 > 0.0,
           "ffprobe konnte die Test-Fixture-Dauern nicht lesen (webm1=#{d1}, webm2=#{d2})"

    # Server-side Byte-Append: genau so tut es `AudioBuffer.write_chunk/6`.
    # Kein Remuxing, kein Container-Anbau, nur bin_write append.
    :ok =
      File.open!(concat, [:write, :binary], fn out ->
        IO.binwrite(out, File.read!(webm1))
        IO.binwrite(out, File.read!(webm2))
      end)
      |> then(fn _ -> :ok end)

    assert File.stat!(concat).size == File.stat!(webm1).size + File.stat!(webm2).size

    # Server-side Decode: identisch zu `Transcribe.to_wav/2` (-loglevel error,
    # 16 kHz Mono, kein extra Filter).
    {out, exit_code} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-loglevel",
          "error",
          "-i",
          concat,
          "-ac",
          "1",
          "-ar",
          "16000",
          wav_out
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "ffmpeg-Decode-Konkat scheitert hart: #{out}"

    decoded = ffprobe_duration(wav_out)

    assert decoded >= @combined_lower_bound,
           """
           Repro BESTÄTIGT (Issue #469): decodiertes WAV nur #{Float.round(decoded, 3)} s statt \
           erwarteten ~#{Float.round(@dur1_s + @dur2_s, 2)} s (part1=#{Float.round(d1, 3)}, \
           part2=#{Float.round(d2, 3)}). ffmpeg schluckt den zweiten EBML-Header still — \
           Audio nach Device-Re-Plug geht in Prod-Transkription verloren.

           ffmpeg-stderr: #{String.trim(out)}
           """
  end

  # ── ffmpeg / ffprobe helpers ─────────────────────────────────────

  # Baut ein MediaRecorder-vergleichbares WebM/opus-File aus einer lavfi-
  # Sinusquelle. Explicit `-c:a libopus` + 48 kHz + niedriges Bitrate =
  # der Codec-Pfad, den Chrome/Firefox MediaRecorder auch wählen.
  defp make_webm(path, opts) do
    freq = Keyword.fetch!(opts, :freq)
    dur = Keyword.fetch!(opts, :duration_s)

    {_out, code} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=#{freq}:duration=#{dur}",
          "-c:a",
          "libopus",
          "-b:a",
          "24k",
          "-ar",
          "48000",
          "-ac",
          "1",
          path
        ],
        stderr_to_stdout: true
      )

    if code == 0, do: :ok, else: {:error, code}
  end

  defp ffprobe_duration(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        [
          "-v",
          "error",
          "-show_entries",
          "format=duration",
          "-of",
          "default=noprint_wrappers=1:nokey=1",
          path
        ],
        stderr_to_stdout: true
      )

    case out |> String.trim() |> Float.parse() do
      {n, _} -> n
      :error -> 0.0
    end
  end
end
