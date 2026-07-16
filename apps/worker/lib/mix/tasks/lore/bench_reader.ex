# Issue #571: Bench-Task ist Test-Fixture (Mix.raise auf :prod, siehe run/1).
# Hardcoded Event-Kinds sind hier OK — Bench-Korrektheit hängt davon ab, dass
# wir den exakten Wire-Shape erzeugen, den der Materializer auch von echten
# Events sieht. Auto-Rename via Shared.Events.x() würde den Bench gegen den
# Hub aus dem Tritt bringen, wenn jemand einen Kind umbenennt.
# credo:disable-for-this-file LoreTracker.Credo.Check.HardcodedEventKind
defmodule Mix.Tasks.Lore.BenchReader do
  use Mix.Task

  @shortdoc "Reader + Materializer Performance-Baseline für skalierende Event-Logs"

  @moduledoc """
  Misst wie das Event-Sourcing-Setup mit wachsendem Event-Log skaliert.

  Pro Skala (N Events pro Bench-Campaign):

  1. Materializer-Throughput (cold apply): Events/s beim initialen Schreiben
     via `Worker.Materializer.apply_local/1`.
  2. Reader-Latenz `Worker.Repo.get_campaign/1`: p50/p95 über 200 Samples.
  3. Reader-Latenz `Worker.Repo.snapshot/1` (volle Campaign-View): p50/p95.
  4. Materializer-Throughput (replay-skip): events/s wenn alle event_ids
     bereits in `worker_applied_event_ids` stehen — der Hub-Catch-Up-Pfad.
  5. Mnesia-Disk-Footprint: Bytes pro Event aus dem `du -sb` der
     `worker_campaign_events_<uuid>`-Tabelle.

  Cleanup via `CampaignDeleted` am Schluss — droppt die dynamische
  Event-Tabelle + alle Sessions/Utterances/Marker per Cascade.

  ## Verwendung

      mix lore.bench_reader                 # Default: 10_000 + 100_000 Events
      mix lore.bench_reader --scale 1000    # Single Custom-Scale
      mix lore.bench_reader --scale 1000000 # 1M (Achtung: ~5-10 Minuten)
      mix lore.bench_reader --keep          # Cleanup ueberspringen (zum Debuggen)
      mix lore.bench_reader --read-samples 500   # mehr Samples für genauere p95

  Refuses :prod (Sicherheits-Gate).
  """

  alias Worker.Materializer
  alias Worker.Repo, as: WRepo
  alias Worker.Schema.DynamicTables

  @default_scales [10_000, 100_000]
  @default_read_samples 200
  @utterance_text "Lorem ipsum dolor sit amet, consectetur adipiscing elit."

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise("Refuse :prod — bench-task ist dev/test-only")
    end

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          scale: :integer,
          keep: :boolean,
          read_samples: :integer
        ]
      )

    scales =
      case opts[:scale] do
        nil -> @default_scales
        n -> [n]
      end

    read_samples = opts[:read_samples] || @default_read_samples
    keep = opts[:keep] || false

    Application.put_env(:worker, :no_browser, true)
    Application.ensure_all_started(:worker)

    # Ohne Pairing startet Worker.Application weder PubSub noch Materializer —
    # die brauchen wir aber für apply_local/apply_event. Idempotent starten.
    case Phoenix.PubSub.Supervisor.start_link(name: Worker.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Worker.Materializer.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    scales_display = scales |> Enum.map(&format_int/1) |> Enum.join(", ")

    Mix.shell().info(
      "Reader+Materializer Bench — Skalen: [#{scales_display}] | Read-Samples: #{read_samples}"
    )

    Mix.shell().info(String.duplicate("═", 75))

    results =
      for scale <- scales do
        run_scale(scale, read_samples, keep)
      end

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 75))
    Mix.shell().info("Matrix-Zusammenfassung (Markdown — kopierbar nach docs/Performance.md):")
    Mix.shell().info("")
    print_matrix_table(results)
  end

  defp run_scale(n, read_samples, keep) do
    bench_id = UUIDv7.generate()
    bench_did = "bench-user-" <> String.replace(bench_id, "-", "")
    session_id = UUIDv7.generate()

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("─", 75))
    Mix.shell().info("Scale: #{format_int(n)} Events  |  Bench-Campaign: #{bench_id}")
    Mix.shell().info(String.duplicate("─", 75))

    # Setup: CampaignCreated + SessionScheduled
    :ok = Materializer.apply_local(envelope(campaign_created(bench_id, bench_did)))
    :ok = Materializer.apply_local(envelope(session_scheduled(bench_id, session_id)))

    # Phase 1: Cold-Apply — pumpt N UtteranceAppended events
    utterance_events =
      for i <- 1..n, do: envelope(utterance_appended(bench_id, session_id, bench_did, i))

    {us_cold, _} =
      :timer.tc(fn ->
        Enum.each(utterance_events, &Materializer.apply_local/1)
      end)

    cold_per_s = if us_cold > 0, do: n * 1_000_000 / us_cold, else: 0.0

    Mix.shell().info(
      "  Cold-Apply:   #{format_int(n)} events in #{format_ms(us_cold)}  →  #{format_int(round(cold_per_s))} events/s"
    )

    # Phase 2: get_campaign Latenz
    {p50_get, p95_get} = measure_percentiles(read_samples, fn -> WRepo.get_campaign(bench_id) end)

    Mix.shell().info(
      "  get_campaign:        p50=#{format_us(p50_get)}  p95=#{format_us(p95_get)}"
    )

    # Phase 3: Snapshot (volle Campaign-View — Reader.read äquivalent)
    snapshot_scope = %{"kind" => "campaign", "id" => bench_id, "viewer_discord_id" => bench_did}

    {p50_snap, p95_snap} =
      measure_percentiles(read_samples, fn -> WRepo.snapshot(snapshot_scope) end)

    Mix.shell().info(
      "  snapshot(campaign):  p50=#{format_us(p50_snap)}  p95=#{format_us(p95_snap)}"
    )

    # Phase 4: Replay-Skip (alle event_ids schon bekannt)
    {us_skip, _} =
      :timer.tc(fn ->
        Enum.each(utterance_events, fn ev ->
          # Simuliert Hub-Broadcast mit seq — apply_event geht über GenServer
          hub_event = Map.put(ev, "seq", :rand.uniform(1_000_000))
          Materializer.apply_event(hub_event)
        end)
      end)

    skip_per_s = if us_skip > 0, do: n * 1_000_000 / us_skip, else: 0.0

    Mix.shell().info(
      "  Skip-Apply:   #{format_int(n)} events in #{format_ms(us_skip)}  →  #{format_int(round(skip_per_s))} events/s"
    )

    # Phase 5: Mnesia-Disk-Footprint
    table = DynamicTables.table_name(bench_id)
    rows = :mnesia.table_info(table, :size)
    memory_words = :mnesia.table_info(table, :memory)
    memory_bytes = memory_words * :erlang.system_info(:wordsize)
    bytes_per_event = if rows > 0, do: div(memory_bytes, rows), else: 0

    Mix.shell().info(
      "  Mnesia-RAM:   #{format_int(memory_bytes)} bytes  (#{format_int(rows)} rows  →  ~#{bytes_per_event} bytes/event)"
    )

    # Cleanup (oder keep für Diagnose)
    unless keep do
      :ok = Materializer.apply_local(envelope(campaign_deleted(bench_id)))
      Mix.shell().info("  Cleanup:      CampaignDeleted → cascade dropped")
    end

    %{
      scale: n,
      cold_per_s: round(cold_per_s),
      skip_per_s: round(skip_per_s),
      get_p50_us: p50_get,
      get_p95_us: p95_get,
      snap_p50_us: p50_snap,
      snap_p95_us: p95_snap,
      bytes_per_event: bytes_per_event
    }
  end

  # ─── Event-Konstruktoren ──────────────────────────────────────────────────

  defp envelope(payload) do
    %{
      "event_id" => UUIDv7.generate(),
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "bench-reader",
      "payload" => payload
    }
  end

  defp campaign_created(campaign_id, owner_did) do
    %{
      "kind" => "CampaignCreated",
      "id" => campaign_id,
      "name" => "Bench-Reader " <> binary_part(campaign_id, 0, 8),
      "icon_url" => nil,
      "theme_blurb" => nil,
      "owner_discord_id" => owner_did,
      "owner_display_name" => "Bench User"
    }
  end

  defp session_scheduled(campaign_id, session_id) do
    %{
      "kind" => "SessionScheduled",
      "id" => session_id,
      "campaign_id" => campaign_id,
      "number" => 1,
      "name" => "Bench Session",
      "scheduled_for" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp utterance_appended(campaign_id, session_id, discord_id, i) do
    %{
      "kind" => "UtteranceAppended",
      "id" => UUIDv7.generate(),
      "campaign_id" => campaign_id,
      "session_id" => session_id,
      "discord_id" => discord_id,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "text" => @utterance_text <> " #{i}",
      # Issue #376: einheitliches Map-Format (vorher Float 0.95).
      "confidence" => Worker.Recording.Transcribe.to_confidence_map(0.95),
      "status" => "confirmed"
    }
  end

  defp campaign_deleted(campaign_id) do
    %{"kind" => "CampaignDeleted", "campaign_id" => campaign_id}
  end

  # ─── Mess-Helpers ─────────────────────────────────────────────────────────

  defp measure_percentiles(n, fun) do
    samples =
      for _ <- 1..n do
        {us, _result} = :timer.tc(fun)
        us
      end
      |> Enum.sort()

    {percentile(samples, 50), percentile(samples, 95)}
  end

  defp percentile(sorted, pct) do
    n = length(sorted)
    idx = min(n - 1, max(0, round(n * pct / 100) - 1))
    Enum.at(sorted, idx)
  end

  # ─── Output-Formatter ─────────────────────────────────────────────────────

  defp print_matrix_table(results) do
    Mix.shell().info(
      "| Scale | Cold-Apply (events/s) | Skip-Apply (events/s) | get_campaign p50 / p95 | snapshot p50 / p95 | Bytes/Event |"
    )

    Mix.shell().info("|---:|---:|---:|---:|---:|---:|")

    for r <- results do
      Mix.shell().info(
        "| #{format_int(r.scale)} | #{format_int(r.cold_per_s)} | #{format_int(r.skip_per_s)} | #{format_us(r.get_p50_us)} / #{format_us(r.get_p95_us)} | #{format_us(r.snap_p50_us)} / #{format_us(r.snap_p95_us)} | #{r.bytes_per_event} |"
      )
    end
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join("_")
    |> String.reverse()
  end

  defp format_us(us) when us < 1000, do: "#{us}µs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1000, 2)}ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp format_ms(us) when us < 1_000_000, do: "#{Float.round(us / 1000, 1)}ms"
  defp format_ms(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
