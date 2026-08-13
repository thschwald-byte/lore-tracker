defmodule Worker.Recording.WavCheck do
  @moduledoc """
  Issue #979: Validierung eines WAV **bevor** es an whisper geht.

  Der reale Vorfall: ffmpeg meldete beim webm→wav-Convert `done`, aber das
  Ergebnis war undecodierbar — sowohl das VAD-Tool als auch whisper-cli
  scheiterten mit `failed to ffmpeg decode`, und whisper-cli brach mit Exit 2
  und seinem **VAD-Options-Hilfetext** ab. Der Pipelinefehler zeigte damit eine
  scheinbare Flag-/VAD-Meldung statt der echten Ursache (kaputtes Input-WAV aus
  einer weg-bereinigten Quell-webm) — das kostete beim Debuggen genau die
  Runde, die dieses Modul künftig spart.

  **Bewusst reine Header-Prüfung, kein ffprobe:** ffprobe ist nicht als
  Setting konfiguriert (nur `ffmpeg_bin`), und den Pfad aus dem ffmpeg-Pfad zu
  raten wäre ein stiller Fehlpfad auf Systemen mit getrennten Paketen. Die
  Header-Prüfung ist dependency-frei und fängt die real beobachtete Klasse
  (Header-only-/leere-Daten-WAVs aus kaputten Quellen); ein WAV mit gültigem
  Header und kaputten SAMPLES fängt sie nicht — das failt dann weiterhin bei
  whisper, nur eben als benannter `whisper_failed` mit intaktem Input. Ehrliche
  Grenze, im Fehlerbild dokumentiert.

  Format-Annahme: die WAVs kommen aus UNSEREM ffmpeg-Aufruf (`-ac 1 -ar
  16000`, PCM) — kanonisches RIFF/WAVE mit `fmt `- und `data`-Chunks.
  """

  # Unter dieser Datenmenge ist nichts Transkribierbares drin (16 kHz mono
  # 16-bit ⇒ 32 Bytes/ms; 1024 Bytes ≈ 32 ms). Schwelle bewusst winzig — sie
  # soll leere/abgerissene Dateien fangen, keine kurzen Äußerungen.
  @min_data_bytes 1024

  @type failure ::
          :missing | :unreadable | :too_small | :not_riff_wave | :no_data_chunk | :empty_data

  @doc """
  `{:ok, data_bytes}` wenn das WAV einen plausiblen RIFF/WAVE-Header und einen
  nicht-leeren `data`-Chunk hat; sonst `{:error, failure()}`.
  """
  @spec check(Path.t()) :: {:ok, pos_integer()} | {:error, failure()}
  def check(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:error, :missing}

      {:error, _} ->
        {:error, :unreadable}

      {:ok, %{size: size}} when size < 44 ->
        # 44 Bytes = minimaler kanonischer WAV-Header — darunter kann nicht
        # einmal der Header vollständig sein.
        {:error, :too_small}

      {:ok, _} ->
        case File.open(path, [:read, :binary], &read_header(&1)) do
          {:ok, result} -> result
          {:error, _} -> {:error, :unreadable}
        end
    end
  end

  @doc "Wie `check/1`, auf einem bereits gelesenen Binary (Tests)."
  @spec check_binary(binary()) :: {:ok, pos_integer()} | {:error, failure()}
  def check_binary(<<"RIFF", _size::32-little, "WAVE", rest::binary>>),
    do: find_data_chunk(rest)

  def check_binary(bin) when is_binary(bin) and byte_size(bin) < 44, do: {:error, :too_small}
  def check_binary(bin) when is_binary(bin), do: {:error, :not_riff_wave}

  # ─── intern ─────────────────────────────────────────────────────────

  # Nur die ersten 64 KB lesen — die Chunk-Kette bis `data` liegt am Anfang;
  # die Datei kann Stunden Audio tragen und gehört nicht in den Speicher.
  defp read_header(io) do
    case IO.binread(io, 65_536) do
      bin when is_binary(bin) -> check_binary(bin)
      _ -> {:error, :unreadable}
    end
  end

  # Durch die RIFF-Chunk-Kette bis zum `data`-Chunk laufen (fmt/LIST/etc.
  # überspringen — ffmpeg schreibt gelegentlich Metadaten-Chunks dazwischen).
  defp find_data_chunk(<<"data", size::32-little, _rest::binary>>) do
    cond do
      size == 0 -> {:error, :empty_data}
      size < @min_data_bytes -> {:error, :empty_data}
      true -> {:ok, size}
    end
  end

  defp find_data_chunk(<<_id::binary-size(4), size::32-little, rest::binary>>) do
    # Chunks sind auf gerade Längen gepadded (RIFF-Spec).
    skip = size + rem(size, 2)

    case rest do
      <<_skipped::binary-size(^skip), next::binary>> -> find_data_chunk(next)
      _ -> {:error, :no_data_chunk}
    end
  end

  defp find_data_chunk(_), do: {:error, :no_data_chunk}
end
