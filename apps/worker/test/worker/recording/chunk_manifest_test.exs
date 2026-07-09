defmodule Worker.Recording.ChunkManifestTest do
  # Testet den Sidecar für Chunk-Ankunfts-Wall-Clocks (Issue #757). Die zwei
  # Ziele: (a) File-I/O append/load/reset arbeitet robust, (b) `resolve/4`
  # interpoliert korrekt und deckt die drei Fehlermodi ab, für die der Bug
  # überhaupt geöffnet wurde: Late-Mic-Join, Mid-Session-Gap, und Backwards-
  # Compat für Sessions ohne Sidecar.
  use ExUnit.Case, async: true

  alias Worker.Recording.ChunkManifest

  setup do
    dir =
      Path.join(System.tmp_dir!(), "chunk_manifest_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # ── File-I/O ──────────────────────────────────────────────────────

  test "append/4 + load/2: roundtripped Chunks kommen sortiert nach wc zurück", %{dir: dir} do
    ChunkManifest.append(dir, "did-a", 2_000, 8_192)
    ChunkManifest.append(dir, "did-a", 1_500, 4_096)
    ChunkManifest.append(dir, "did-a", 2_500, 12_288)

    assert ChunkManifest.load(dir, "did-a") == [
             {1_500, 4_096},
             {2_000, 8_192},
             {2_500, 12_288}
           ]
  end

  test "load/2 auf leeres Verzeichnis → []", %{dir: dir} do
    assert ChunkManifest.load(dir, "never-existed") == []
  end

  test "load/2 überspringt defekte Zeilen still", %{dir: dir} do
    path = ChunkManifest.manifest_path(dir, "did-a")
    File.write!(path, ~s({"wc":1000,"b":100}\ngar-nix-json\n{"wc":2000,"b":200}\n))

    assert ChunkManifest.load(dir, "did-a") == [{1_000, 100}, {2_000, 200}]
  end

  test "reset/2 truncated einen existenten Sidecar", %{dir: dir} do
    ChunkManifest.append(dir, "did-a", 1_000, 100)
    refute ChunkManifest.load(dir, "did-a") == []

    ChunkManifest.reset(dir, "did-a")
    assert ChunkManifest.load(dir, "did-a") == []
  end

  # ── Basis-Interpolation ────────────────────────────────────────────

  test "resolve/4 auf leerem Manifest → nil (Caller nutzt started_at-Fallback)" do
    assert ChunkManifest.resolve([], 500, 8_192, 1_000) == nil
  end

  test "resolve/4 mit 0 Bytes → nil" do
    assert ChunkManifest.resolve([{1_000, 0}], 500, 0, 1_000) == nil
  end

  test "resolve/4 mit 0 decoded_ms → nil (Segment-Ende ist 0 = keine Signaldauer)" do
    assert ChunkManifest.resolve([{1_000, 4_096}], 500, 4_096, 0) == nil
  end

  test "resolve/4: real-time-Aufnahme, offset in der Mitte, wc trifft Mitte" do
    # 3 Chunks à 500ms, kein Gap: Chunks kommen alle 500ms an, Bytes wachsen
    # gleichmäßig. Für offset=750ms sollte die Wall-Clock in der Mitte der 2.
    # Chunk liegen. Manifest: [{1000, 4096}, {1500, 8192}, {2000, 12288}].
    manifest = [{1_000, 4_096}, {1_500, 8_192}, {2_000, 12_288}]
    # total_bytes=12288, decoded_ms=1500 (whisper max end_ms) → bpm=8.192
    # byte_pos für offset=750: 6144. Fällt in Chunk 2 (b_start=4096, b_end=8192).
    # Slice-Bytes 4096 = 500ms. frac = (6144-4096)/4096 = 0.5. wc = 1500 - 500 + 250 = 1250.
    assert ChunkManifest.resolve(manifest, 750, 12_288, 1_500) == 1_250
  end

  test "resolve/4: overshoot (offset > decoded_ms) → letzte wc" do
    manifest = [{1_000, 4_096}, {1_500, 8_192}]
    # byte_pos = 5000 * 5.461 ≈ 27305 (überschießt 8192, klemmt an letzter Chunk)
    assert ChunkManifest.resolve(manifest, 5_000, 8_192, 1_500) == 1_500
  end

  # ── Late-Mic-Join ─────────────────────────────────────────────────

  test "resolve/4: Late-Mic-Join — Speaker startet 180s nach Session-Start" do
    # Session hat session_started_at = 0. Speaker klickt Mic bei wall-clock
    # 180_000. Sein WAV startet dort. Manifest liegt komplett post-180000.
    # Ohne Sidecar würde offset_ms=0 → started_at+0 = 0 (falsch, 180s zu
    # früh). Mit Sidecar sollte die Wall-Clock der 1. Chunk direkt reflektieren.
    manifest = [
      {180_000, 4_096},
      {180_500, 8_192},
      {181_000, 12_288}
    ]

    # offset=0 → byte_pos=0 → landet in Chunk 1 (b_start=0, b_end=4096).
    # frac=0. slice_ms = 4096 / (12288/1000) = 333ms. wc = 180000 - 333 + 0 = 179667.
    # Für den Test die exakte Zahl akzeptieren, +/-1ms Rundungs-Toleranz.
    assert_in_delta ChunkManifest.resolve(manifest, 0, 12_288, 1_000), 179_667, 2

    # Zum Vergleich: naive Rechnung "started_at + offset_ms" = 0 → Drift 180s.
    # Mit Sidecar liegt der Start korrekt kurz vor der Chunk-Ankunft.
  end

  # ── Mid-Session-Gap ───────────────────────────────────────────────

  test "resolve/4: Mid-Session-Gap — 30s Wall-Clock-Sprung ohne WAV-Fortschritt" do
    # Der Fall Free Seattle liv1708: bis wc=T pre-gap-Chunks, dann 30s
    # Netzblip / Pause, dann continue mit den nächsten Chunks. WAV-Bytes
    # wachsen weiter monoton (unter #758 :append), Wall-Clock trägt den Gap.
    #
    # Manifest:
    #   [{  1000, 4096}, {  1500, 8192},   ← real-time bis hier
    #    { 31500, 12288}, { 32000, 16384}]  ← nach 30s Gap
    #
    # total_bytes = 16384, decoded_ms = 2000 (Whisper sieht 2s Audio,
    # kein Gap im WAV — der Gap ist rein wall-clock-seitig).
    # → bytes_per_ms = 8.192.
    manifest = [{1_000, 4_096}, {1_500, 8_192}, {31_500, 12_288}, {32_000, 16_384}]

    # Segment bei offset=1000ms → byte_pos=8192. Am Grenzübergang zur post-gap
    # Chunk 3 (b_end=8192 in Chunk 2 unter <=): landet auf Chunk 2, wc=1500.
    # (Pre-Gap, kein Drift.)
    wc_pre = ChunkManifest.resolve(manifest, 1_000, 16_384, 2_000)
    assert wc_pre == 1_500

    # Segment bei offset=1250ms → byte_pos=10240. Fällt in Chunk 3 (b_start=8192,
    # b_end=12288). Slice-Bytes 4096; slice_ms = 4096/8.192 = 500ms.
    # frac=(10240-8192)/4096 = 0.5. wc = 31500 - 500 + 250 = 31250.
    # Cross-check: pre-gap wc bei ähnlichem Segment wäre ~1250. Delta ≈ 30s.
    wc_post = ChunkManifest.resolve(manifest, 1_250, 16_384, 2_000)
    assert wc_post == 31_250
    assert wc_post - 1_250 == 30_000
  end

  # ── Real-World-Größenordnung ──────────────────────────────────────

  test "resolve/4: rundet monoton bei aufsteigenden Offsets", %{dir: dir} do
    # Sidecar mit 200 Chunks bauen, jeder ~ 500ms Realzeit + eine Injektion
    # eines 25s-Gaps in der Mitte. Danach für aufsteigende Offsets prüfen,
    # dass die Wall-Clocks monoton wachsen.
    slice_ms = 500
    slice_bytes = 4_096
    total_chunks = 200
    gap_at = 100
    gap_ms = 25_000

    manifest =
      Enum.map(0..(total_chunks - 1), fn i ->
        wc =
          if i < gap_at do
            (i + 1) * slice_ms
          else
            (i + 1) * slice_ms + gap_ms
          end

        bytes = (i + 1) * slice_bytes
        {wc, bytes}
      end)

    Enum.each(manifest, fn {wc, b} -> ChunkManifest.append(dir, "did-a", wc, b) end)

    loaded = ChunkManifest.load(dir, "did-a")
    assert length(loaded) == total_chunks

    total_bytes = total_chunks * slice_bytes
    decoded_ms = total_chunks * slice_ms

    resolved =
      Enum.map(0..9, fn n ->
        offset = div(n * decoded_ms, 10)
        ChunkManifest.resolve(loaded, offset, total_bytes, decoded_ms)
      end)

    # Monoton wachsend.
    assert resolved == Enum.sort(resolved)

    # Mindestens ein 25s-Sprung im Verlauf sichtbar (die Gap-Kante).
    deltas =
      resolved
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    assert Enum.any?(deltas, &(&1 >= 20_000))
  end
end
