defmodule Worker.Discord.OggOpusMuxer do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage F: minimaler
  Ogg-Opus-Muxer (RFC 3533 Ogg-Framing + RFC 7845 Opus-in-Ogg-Mapping) für
  rohe, bereits dave_decrypt'te Opus-Pakete aus Nostrum.

  **Empirisch verifiziert, nicht geraten:** der Ogg-CRC32 (Polynom
  `0x04c11db7`, MSB-first, kein Reflect, Init 0 — NICHT der zlib/Standard-
  CRC32) wurde gegen echte, von `ffmpeg -c:a libopus -f opus` erzeugte
  Ogg-Seiten geprüft (bitgenaue Übereinstimmung). Ein damit gemuxtes
  Test-File wurde erfolgreich von `ffmpeg` dekodiert.

  **Wichtiger Negativ-Befund (ebenfalls empirisch verifiziert):** eine
  Granule-Position-Lücke im Container (um Sprechpausen zu markieren, ohne
  echte Stille-Bytes zu schreiben) wird von ffmpegs Opus-Decoder NICHT
  automatisch mit Stille aufgefüllt — der Decoder liefert nur die
  tatsächlich vorhandenen Pakete, ignoriert die Lücke. Deshalb macht dieser
  Muxer NUR lückenlose Container aus echten Paketen; die Zeitkorrektur
  (`Worker.Discord.FrameBuffer`) wird NACH dem Decode auf PCM-Ebene
  appliziert (`Worker.Discord.AudioBridge`), wo Stille trivial + garantiert
  korrekt ist (Null-Bytes) statt eines Opus-Kodierungs-Tricks mit
  unsicherer Decoder-Kompatibilität.

  Discord-Voice ist 48kHz/Stereo-Opus (öffentlich dokumentiertes
  Discord-Voice-Protokoll) — als `channel_count`/`input_sample_rate` im
  OpusHead fest codiert, nicht aus den Paketen selbst ableitbar (Opus-Pakete
  tragen das nicht im Klartext).
  """

  import Bitwise

  @channel_count 2
  @sample_rate 48_000

  @doc """
  Muxt eine Liste roher Opus-Pakete (bereits dave_decrypt't, ohne Lücken —
  Stille wird NICHT hier, sondern nach dem Decode appliziert) in einen
  vollständigen Ogg-Opus-Byte-String. `serial` identifiziert den logischen
  Bitstream (beliebiger 32-Bit-Wert, muss nur innerhalb EINER Datei stabil
  sein).
  """
  @spec mux([binary()], non_neg_integer()) :: binary()
  def mux(opus_packets, serial \\ 1) when is_list(opus_packets) do
    id_header = build_id_header()
    comment_header = build_comment_header()

    pages =
      [
        page(2, 0, serial, 0, [id_header]),
        page(0, 0, serial, 1, [comment_header])
      ] ++ audio_pages(opus_packets, serial)

    IO.iodata_to_binary(pages)
  end

  # RFC 7845 §5.1 — "OpusHead": Magic(8) + Version(1)=1 + ChannelCount(1) +
  # PreSkip(2 LE)=0 (kein Encoder-seitiges Priming) + InputSampleRate(4 LE) +
  # OutputGain(2 LE signed)=0 + ChannelMappingFamily(1)=0 (RTP-Standard-Mapping).
  defp build_id_header do
    <<"OpusHead", 1, @channel_count, 0::little-16, @sample_rate::little-32, 0::little-signed-16,
      0>>
  end

  # RFC 7845 §5.2 — "OpusTags": Magic(8) + VendorStringLength(4 LE) +
  # VendorString + UserCommentListLength(4 LE)=0 (keine Kommentare nötig).
  defp build_comment_header do
    vendor = "lore-tracker"
    <<"OpusTags", byte_size(vendor)::little-32, vendor::binary, 0::little-32>>
  end

  # Ein Ogg-Packet pro Ogg-Page (kein Multiplexen mehrerer Pakete pro Page
  # nötig — Einfachheit vor Effizienz, die Dateien sind klein). granule_position
  # = kumulative Sample-Anzahl (48kHz) NACH diesem Paket (RFC 7845 §4).
  defp audio_pages(opus_packets, serial) do
    frame_samples = div(@sample_rate * 20, 1000)

    opus_packets
    |> Enum.with_index(2)
    |> Enum.map(fn {packet, seq} ->
      granule = (seq - 1) * frame_samples
      header_type = if seq == length(opus_packets) + 1, do: 4, else: 0
      page(header_type, granule, serial, seq, [packet])
    end)
  end

  defp page(header_type, granule, serial, seq, packets) do
    {seg_table, payload} = lace(packets)
    nseg = byte_size(seg_table)

    header =
      <<"OggS", 0, header_type, granule::little-64, serial::little-32, seq::little-32,
        0::little-32, nseg, seg_table::binary>>

    full = <<header::binary, payload::binary>>
    crc = crc32(full)
    <<before::binary-22, _old_crc::binary-4, rest::binary>> = full
    <<before::binary, crc::little-32, rest::binary>>
  end

  # Segment-Tabelle (Lacing) nach RFC 3533 §6: pro Packet eine Folge von
  # 255-Werten für jeden vollen 255-Byte-Block, terminiert durch einen Wert
  # <255 (auch 0, falls die Packet-Länge exakt durch 255 teilbar ist).
  defp lace(packets) do
    Enum.reduce(packets, {<<>>, <<>>}, fn packet, {seg_acc, payload_acc} ->
      n = byte_size(packet)
      full = div(n, 255)
      rem = rem(n, 255)
      seg = :erlang.list_to_binary(List.duplicate(255, full) ++ [rem])
      {<<seg_acc::binary, seg::binary>>, <<payload_acc::binary, packet::binary>>}
    end)
  end

  # Ogg-CRC32: Polynom 0x04c11db7, MSB-first, kein Reflect, Init 0, kein
  # Final-XOR — empirisch gegen echte ffmpeg-Ogg-Pages verifiziert (s.
  # Moduledoc). NICHT der Standard-/zlib-CRC32 (:erlang.crc32/1 wäre falsch).
  @spec crc32(binary()) :: non_neg_integer()
  def crc32(binary) do
    for <<byte <- binary>>, reduce: 0 do
      crc -> step_byte(crc, byte)
    end
  end

  defp step_byte(crc, byte) do
    Enum.reduce(0..7, Bitwise.bxor(crc, byte <<< 24), fn _, acc ->
      if Bitwise.band(acc, 0x80000000) != 0 do
        Bitwise.band(Bitwise.bxor(acc <<< 1, 0x04C11DB7), 0xFFFFFFFF)
      else
        Bitwise.band(acc <<< 1, 0xFFFFFFFF)
      end
    end)
  end

  @doc "Gepinnte Konstanten für Doku/Tests/AudioBridge."
  def settings, do: %{channel_count: @channel_count, sample_rate: @sample_rate}
end
