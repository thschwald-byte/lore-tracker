defmodule Worker.Recording.ChunkManifest do
  @moduledoc """
  Per-Speaker-Sidecar für Chunk-Arrival-Wall-Clocks (Issue #757).

  Jede eingehende MediaRecorder-Chunk-Payload wird in `AudioBuffer.write_chunk/6`
  auch als eine Zeile in `<key>.chunks.jsonl` neben der `<key>.webm` festgehalten:

      {"wc": 1720557000000, "b": 4096}
      {"wc": 1720557000500, "b": 8192}
      ...

  - `wc`: `System.system_time(:millisecond)` bei Server-Ankunft der Chunk.
  - `b` : kumulierte Byte-Länge der `<key>.webm` NACH dem Schreiben dieser Chunk.

  `Worker.Recording.Transcribe.emit_utterances/5` liest die Datei zurück und
  rechnet für jedes Whisper-Segment über `resolve/4` einen Wall-Clock aus statt
  den bisherigen `session.started_at + offset_ms`. Damit sind Late-Mic-Join
  (Speaker beginnt nach Session-Start) und Mid-Session-Writer-Reset
  (Wall-Clock schreitet fort, WAV-Position nicht) korrekt anchoriert — jede
  Chunk hat ihre eigene Wall-Clock-Referenz.

  Fällt der Sidecar (fehlt, leer, kaputt) → `resolve/4` gibt `nil`, der Caller
  fällt auf `started_at + offset_ms` zurück (Alt-Verhalten, Backwards-Compat).
  """

  require Logger

  @type manifest :: [{integer(), non_neg_integer()}]

  @doc """
  Truncate the sidecar file to zero length. Called when the writer opens the
  `.webm` in `:write`-mode (fresh session, oder nach Writer-State-Verlust unter
  `:write`-Semantik) — dann darf die alte Chunk-History nicht mehr als Anker
  für post-Truncate-Bytes gelten. Unter `:append`-Semantik (nach #758) nicht
  aufrufen.
  """
  @spec reset(String.t(), String.t()) :: :ok
  def reset(session_dir, key) do
    path = manifest_path(session_dir, key)
    # File.write!/2 with :binary opens :write-mode → truncates.
    File.write!(path, "")
    :ok
  end

  @doc """
  Append one arrival record.

  `wall_clock_ms` sollte `System.system_time(:millisecond)` sein (nicht monotonic
  — die Utterances kriegen daraus einen UTC-`DateTime`). `bytes_after` ist die
  kumulative Datei-Länge nach dem Schreiben der Chunk.
  """
  @spec append(String.t(), String.t(), integer(), non_neg_integer()) :: :ok
  def append(session_dir, key, wall_clock_ms, bytes_after)
      when is_integer(wall_clock_ms) and is_integer(bytes_after) and bytes_after >= 0 do
    path = manifest_path(session_dir, key)
    line = Jason.encode!(%{"wc" => wall_clock_ms, "b" => bytes_after}) <> "\n"

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, line)
        after
          File.close(io)
        end

      {:error, reason} ->
        Logger.warning(
          "ChunkManifest: konnte Sidecar #{path} nicht öffnen (#{inspect(reason)}) — " <>
            "Utterance-Timestamps werden für dieses Segment auf started_at+offset zurückfallen"
        )
    end

    :ok
  end

  @doc """
  Load the manifest for `key` from `session_dir`, sortiert nach `wc` aufsteigend.
  Leere Datei / fehlender Sidecar / defekte Zeilen → `[]`.
  """
  @spec load(String.t(), String.t()) :: manifest()
  def load(session_dir, key) do
    path = manifest_path(session_dir, key)

    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)
        |> Enum.sort_by(fn {wc, _b} -> wc end)

      {:error, _} ->
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"wc" => wc, "b" => b}} when is_integer(wc) and is_integer(b) and b >= 0 ->
        [{wc, b}]

      _ ->
        []
    end
  end

  @doc """
  Rechnet für ein Whisper-Segment mit `offset_ms` in der WAV einen Wall-Clock in
  Millisekunden (System-Epoch) aus.

  - `manifest`: sortiertes `[{wc_ms, cumulative_bytes}]`, aus `load/2`.
  - `offset_ms`: Whisper-Segment-Start in der (decodierten) WAV, in ms.
  - `total_bytes`: Größe der `.webm`-Quelldatei in Bytes.
  - `decoded_duration_ms`: geschätzte WAV-Länge in ms (i.d.R. `max(segment.end_ms)`
    oder aus ffprobe; das Verhältnis muss zur WAV passen, nicht zur WebM — wir
    brauchen sie nur, um `bytes_per_ms` fürs Byte-Position-Mapping zu ermitteln).

  Modell: die WebM wächst wall-clock-synchron mit dem Recorder — bei einer
  Pause/einem Netz-Blip stoppen sowohl die eintreffenden Chunks als auch die
  Byte-Länge, während die Server-Uhr weiterläuft. Aus `total_bytes /
  decoded_duration_ms` ergibt sich ein globaler `bytes_per_ms`, mit dem wir
  `offset_ms` auf eine Byte-Position im WebM abbilden. Die enthaltende Chunk
  im Manifest liefert die Wall-Clock-Anker; innerhalb der Chunk interpolieren
  wir linear (mit der Byte-Länge dieser Chunk als lokalem Slice — das ist
  robust gegen variable Chunk-Größen und schließt Gap-Anker sauber ein, weil
  ein Gap-Chunk kaum größer ist als eine normale 500-ms-Slice und trotzdem
  einen um Gap-Wall-Clock verschobenen `wc` trägt).

  Nicht-auflösbar (leerer Manifest, Null-Bytes, Null-Dauer) → `nil`, damit der
  Caller auf `started_at + offset_ms` zurückfallen kann (Backwards-Compat).
  """
  @spec resolve(manifest(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          integer() | nil
  def resolve([], _offset_ms, _total_bytes, _decoded_ms), do: nil
  def resolve(_manifest, _offset_ms, 0, _decoded_ms), do: nil
  def resolve(_manifest, _offset_ms, _total_bytes, 0), do: nil

  def resolve(manifest, offset_ms, total_bytes, decoded_duration_ms)
      when is_integer(offset_ms) and offset_ms >= 0 do
    bytes_per_ms = total_bytes / decoded_duration_ms
    byte_pos = offset_ms * bytes_per_ms

    case find_containing(manifest, byte_pos, 0) do
      :none ->
        # offset überschießt die letzte Chunk → snap auf deren Wall-Clock.
        case List.last(manifest) do
          {wc, _b} -> wc
          _ -> nil
        end

      {{wc, b_end}, b_start} ->
        slice_bytes = max(1, b_end - b_start)
        slice_ms = slice_bytes / bytes_per_ms
        frac = (byte_pos - b_start) / slice_bytes
        # Chunk-Ankunft ist der End-Wall-Clock der Slice; frac läuft vom
        # Chunk-Anfang (frac=0 → wc-slice_ms) bis Chunk-Ende (frac=1 → wc).
        round(wc - slice_ms + frac * slice_ms)
    end
  end

  # Rekursion mit prev_bytes = Startpunkt der aktuellen Chunk.
  defp find_containing([], _byte_pos, _prev_bytes), do: :none

  defp find_containing([{_wc, b_end} = chunk | _rest], byte_pos, prev_bytes)
       when byte_pos <= b_end,
       do: {chunk, prev_bytes}

  defp find_containing([{_wc, b_end} | rest], byte_pos, _prev_bytes),
    do: find_containing(rest, byte_pos, b_end)

  @doc "Absoluter Sidecar-Pfad zu `<session_dir>/<key>.chunks.jsonl`. Public für Tests."
  @spec manifest_path(String.t(), String.t()) :: String.t()
  def manifest_path(session_dir, key), do: Path.join(session_dir, "#{key}.chunks.jsonl")

  @doc """
  Baut den Resolve-Kontext für alle Segmente EINER `.webm`-Datei einmalig auf
  (Manifest-Load + Dateilänge + geschätzte decodierte Dauer aus
  `max(segment.end_ms)`). Fehlt der Sidecar oder ist die Datei leer / die
  Dauer 0 → `nil`, damit `wall_clock_for/3` sauber auf `started_at +
  offset_ms` zurückfallen kann.
  """
  @spec build_resolve_ctx(String.t(), String.t(), [map()]) ::
          %{manifest: manifest(), total_bytes: non_neg_integer(), decoded_ms: non_neg_integer()}
          | nil
  def build_resolve_ctx(webm_path, manifest_key, segments)
      when is_binary(webm_path) and is_binary(manifest_key) and is_list(segments) do
    manifest = load(Path.dirname(webm_path), manifest_key)

    if manifest == [] do
      nil
    else
      total_bytes = file_size(webm_path)

      decoded_ms =
        segments
        |> Enum.map(&Map.get(&1, "end_ms", 0))
        |> Enum.max(fn -> 0 end)

      if total_bytes > 0 and decoded_ms > 0 do
        %{manifest: manifest, total_bytes: total_bytes, decoded_ms: decoded_ms}
      else
        nil
      end
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  @doc """
  Löst für ein Segment mit `offset_ms` den `DateTime` auf. Fällt bei leerem
  Kontext oder nicht-auflösbaren Manifests auf `DateTime.add(started_at,
  offset_ms, :millisecond)` zurück (Backwards-Compat für Alt-Sessions).
  """
  @spec wall_clock_for(
          nil | %{manifest: manifest(), total_bytes: non_neg_integer(), decoded_ms: non_neg_integer()},
          non_neg_integer(),
          DateTime.t()
        ) :: DateTime.t()
  def wall_clock_for(nil, offset_ms, started_at),
    do: DateTime.add(started_at, offset_ms, :millisecond)

  def wall_clock_for(
        %{manifest: manifest, total_bytes: total_bytes, decoded_ms: decoded_ms},
        offset_ms,
        started_at
      ) do
    case resolve(manifest, offset_ms, total_bytes, decoded_ms) do
      nil -> DateTime.add(started_at, offset_ms, :millisecond)
      wc_ms when is_integer(wc_ms) -> DateTime.from_unix!(wc_ms, :millisecond)
    end
  end
end
