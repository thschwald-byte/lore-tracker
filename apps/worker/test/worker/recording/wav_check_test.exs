defmodule Worker.Recording.WavCheckTest do
  @moduledoc """
  Issue #979: die WAV-Validierung vor whisper. Der reale Vorfall: ffmpeg
  meldete `done`, das WAV war aber undecodierbar → whisper-cli Exit 2 mit
  VAD-Hilfetext → irreführendes Fehlerbild. Diese Tests bauen die kaputten
  Formen nach, die die Prüfung fangen MUSS — und pinnen die ehrliche Grenze
  (gültiger Header + kaputte Samples wird NICHT gefangen).
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.WavCheck

  # Kanonisches Mini-WAV: RIFF + fmt-Chunk (PCM mono 16 kHz) + data-Chunk.
  defp wav(data_bytes) do
    fmt =
      <<1::16-little, 1::16-little, 16_000::32-little, 32_000::32-little, 2::16-little,
        16::16-little>>

    data = :binary.copy(<<0>>, data_bytes)

    body =
      <<"WAVE", "fmt ", byte_size(fmt)::32-little>> <>
        fmt <> <<"data", data_bytes::32-little>> <> data

    <<"RIFF", byte_size(body)::32-little>> <> body
  end

  describe "check_binary/1" do
    test "gültiges WAV mit genug Daten" do
      assert {:ok, 4096} = WavCheck.check_binary(wav(4096))
    end

    test "REGRESSION (der Vorfall): data-Chunk mit Größe 0 → :empty_data" do
      assert {:error, :empty_data} = WavCheck.check_binary(wav(0))
    end

    test "Mini-Datenmenge unter der Schwelle → :empty_data" do
      # 512 Bytes ≈ 16 ms bei 16 kHz mono 16-bit — abgerissener Convert, kein Audio.
      assert {:error, :empty_data} = WavCheck.check_binary(wav(512))
    end

    test "kein RIFF/WAVE-Header → :not_riff_wave" do
      garbage = :binary.copy(<<0xAB>>, 200)
      assert {:error, :not_riff_wave} = WavCheck.check_binary(garbage)
    end

    test "zu klein für jeden Header → :too_small" do
      assert {:error, :too_small} = WavCheck.check_binary(<<"RIFF", 0, 0>>)
    end

    test "RIFF/WAVE ohne data-Chunk (Header-only) → :no_data_chunk" do
      fmt =
        <<1::16-little, 1::16-little, 16_000::32-little, 32_000::32-little, 2::16-little,
          16::16-little>>

      body = <<"WAVE", "fmt ", byte_size(fmt)::32-little>> <> fmt
      bin = <<"RIFF", byte_size(body)::32-little>> <> body <> :binary.copy(<<0>>, 30)

      assert {:error, :no_data_chunk} = WavCheck.check_binary(bin)
    end

    test "Metadaten-Chunks VOR data werden übersprungen (ffmpeg schreibt z.B. LIST)" do
      fmt =
        <<1::16-little, 1::16-little, 16_000::32-little, 32_000::32-little, 2::16-little,
          16::16-little>>

      list = <<"LIST", 5::32-little, "INFOx", 0>>
      data = :binary.copy(<<0>>, 2048)

      body =
        <<"WAVE", "fmt ", byte_size(fmt)::32-little>> <>
          fmt <> list <> <<"data", 2048::32-little>> <> data

      bin = <<"RIFF", byte_size(body)::32-little>> <> body

      assert {:ok, 2048} = WavCheck.check_binary(bin)
    end

    test "EHRLICHE GRENZE: gültiger Header + Müll-Samples geht DURCH" do
      # Die Header-Prüfung fängt Struktur-Defekte, keine Inhalts-Defekte —
      # kaputte Samples failen weiterhin erst bei whisper (dann aber mit
      # intaktem Input und ehrlichem whisper_failed). Dieser Test pinnt die
      # dokumentierte Grenze, damit niemand mehr Schutz annimmt als da ist.
      fmt =
        <<1::16-little, 1::16-little, 16_000::32-little, 32_000::32-little, 2::16-little,
          16::16-little>>

      noise = :crypto.strong_rand_bytes(4096)

      body =
        <<"WAVE", "fmt ", byte_size(fmt)::32-little>> <>
          fmt <> <<"data", 4096::32-little>> <> noise

      bin = <<"RIFF", byte_size(body)::32-little>> <> body

      assert {:ok, 4096} = WavCheck.check_binary(bin)
    end
  end

  describe "check/1 (Datei-Ebene)" do
    @tag :tmp_dir
    test "fehlende Datei → :missing", %{tmp_dir: dir} do
      assert {:error, :missing} = WavCheck.check(Path.join(dir, "gibts-nicht.wav"))
    end

    @tag :tmp_dir
    test "gültige Datei auf Platte", %{tmp_dir: dir} do
      path = Path.join(dir, "ok.wav")
      File.write!(path, wav(4096))
      assert {:ok, 4096} = WavCheck.check(path)
    end

    @tag :tmp_dir
    test "0-Byte-Datei (abgebrochener Convert) → :too_small", %{tmp_dir: dir} do
      path = Path.join(dir, "leer.wav")
      File.write!(path, "")
      assert {:error, :too_small} = WavCheck.check(path)
    end
  end
end
