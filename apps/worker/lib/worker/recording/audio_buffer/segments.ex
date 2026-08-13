defmodule Worker.Recording.AudioBuffer.Segments do
  @moduledoc """
  Segment-Rotation + Key-Ableitung des AudioBuffers (herausgelöst beim
  #1026-Fix, God-Module-Grenze #544): die Transformationen rund um
  Speaker-Base-Keys (#642/#469) und die mid-stream-EBML-Rotation (#469) —
  ohne GenServer-Zustand, ohne I/O außer File-Close + Rotations-Log.

  Kontext: `flat_key` = aktuelle Segment-Datei (`<base>` oder `<base>.<n>`),
  `base_key` = semantischer Speaker (`<did>` bzw. `multi_<did>`). Der
  periodische Discord-Flush (#1009) macht die Rotation zum Minuten-Normalfall
  statt zum Ausnahme-Ereignis — Details an den Funktionen.
  """

  require Logger

  # Issue #642: mic_mode-Normalisierung (String vom Wire / Atom intern) →
  # :per_player | :multi. Unbekanntes/fehlendes → :per_player (sicherer Default;
  # eine alte Hub-Payload ohne `mic_mode`-Feld landet hier → per-Spieler).
  def normalize_mic_mode(m) when m in [:multi, "multi"], do: :multi
  def normalize_mic_mode(_), do: :per_player

  # Issue #469: liest die Speaker-Base ("<did>" oder "multi_<did>"), unabhängig
  # von möglichen Segment-Rotationen.
  def base_key_for(discord_id, mic_mode) do
    case normalize_mic_mode(mic_mode) do
      :multi -> "multi_" <> discord_id
      _ -> discord_id
    end
  end

  # Issue #469: WebM EBML-Magic — jeder neu instanziierte MediaRecorder-Stream
  # beginnt damit. Sitzt der Magic am Anfang eines Chunks, während für den
  # Speaker schon Bytes geschrieben wurden, ist das ein Re-Header (neuer
  # Recorder nach Device-Re-Plug / Auto-Resume, #397). Beliebige interne
  # Cluster-Bytes kollidieren praktisch nicht — die 4-Byte-Sequenz startet nur
  # ein EBML-Dokument, und MediaRecorder emittert einen Chunk immer an einer
  # sinnvollen Boundary.
  def ebml_header?(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: true
  def ebml_header?(_), do: false

  # Issue #469: Datei-Rotation. Alten Writer schließen, in `rotated_paths`
  # aufheben (finalize sammelt die mit), neuen flat_key `<base>.<n>` als
  # aktiven Slot vormerken. Der neue Writer wird erst durch den write_chunk-
  # Nil-Zweig eröffnet — kein doppelter Open-Zyklus, alles Weitere fluppt
  # symmetrisch zum Erst-Chunk-Pfad (inkl. #758-Warnung, falls die neue Datei
  # existiert).
  def rotate(sess, session_id, base_key, old_flat) do
    {file, old_path, _bytes} = sess.writers[old_flat]

    try do
      File.close(file)
    rescue
      _ -> :ok
    end

    next_seg = Map.get(sess.next_seg_index, base_key, 0) + 1
    new_flat = "#{base_key}.#{next_seg}"

    Logger.warning(
      "AudioBuffer: session=#{session_id} base=#{base_key} mid-stream EBML re-header " <>
        "detected → rotating segment #{old_flat} → #{new_flat} (Issue #469)"
    )

    sess = %{
      sess
      | writers: Map.delete(sess.writers, old_flat),
        rotated_paths: [{old_flat, old_path} | sess.rotated_paths],
        active_flat: Map.put(sess.active_flat, base_key, new_flat),
        next_seg_index: Map.put(sess.next_seg_index, base_key, next_seg)
    }

    {sess, new_flat}
  end
end
