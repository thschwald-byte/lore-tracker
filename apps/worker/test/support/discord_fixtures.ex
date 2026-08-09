defmodule Worker.Discord.TestFixtures do
  @moduledoc """
  Issue #985 Slice 1: Lädt die committeten Beispiel-Opus-Frames
  (`test/fixtures/discord_voice/sample_opus_frames.bin`) — 26 echte, von
  `ffmpeg -c:a libopus` erzeugte 20ms-Opus-Pakete (48kHz, aus einem
  Sinuston), extrahiert aus einer echten Ogg-Opus-Datei. Stehen stellvertretend
  für bereits dave_decrypt'te Discord-Voice-Frames (dieselbe Opus-Paket-Form —
  Discord liefert Rohpakete, keinen Container). Format: Sequenz von
  `<<len::little-16, packet::binary-size(len)>>`.
  """

  @fixture_path Path.join([__DIR__, "..", "fixtures", "discord_voice", "sample_opus_frames.bin"])

  @doc "Alle 26 Beispiel-Opus-Pakete als Liste von Binaries, in Aufnahme-Reihenfolge."
  @spec sample_opus_packets() :: [binary()]
  def sample_opus_packets do
    @fixture_path
    |> File.read!()
    |> unpack([])
  end

  defp unpack(<<>>, acc), do: Enum.reverse(acc)

  defp unpack(<<len::little-16, packet::binary-size(len), rest::binary>>, acc),
    do: unpack(rest, [packet | acc])
end
