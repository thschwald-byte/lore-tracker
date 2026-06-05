defmodule Mix.Tasks.Lore.CoverageFloor do
  @shortdoc "Issue #537: prueft per-Modul-Coverage-Floors gegen die ExCoveralls-Reports"
  @moduledoc """
  Issue #537: Coverage-**Floor** pro kritischem Modul.

  `ExCoveralls` kennt nur einen *globalen* `minimum_coverage`. Diese Task prueft
  pro kritischem Modul (bzw. Modul-Cluster nach den God-Module-Splits #581-#583)
  einen eigenen Floor -- wer ihn reisst (z.B. neue `apply_kind`-Klausel ohne Test
  -> Materializer-Coverage faellt), bricht das Gate.

  ## Ablauf

      cd apps/hub    && MIX_ENV=test mix coveralls.json   # -> apps/hub/cover/excoveralls.json
      cd apps/worker && MIX_ENV=test mix coveralls.json   # -> apps/worker/cover/excoveralls.json
      mix lore.coverage_floor                             # vom Umbrella-Root

  Liest beide JSON-Reports, aggregiert pro Floor `hit`/`relevant` ueber alle
  passenden Dateien und vergleicht den Prozentsatz mit dem Floor.

  ## Ratchet, nicht Aspiration

  Die Floors sind als **Ratchet auf dem heutigen Stand** kalibriert (knapp unter
  der aktuellen Coverage), nicht auf den Ziel-Werten aus #537 -- letztere
  (Commands 70%, Pipeline 60%, ApiKey 90% ...) brauchen erst Test-Backfill und
  wuerden das Gate sofort rot faerben. Der Ratchet erfuellt den Issue-Kern
  (Coverage faellt -> CI bricht) und verhindert Drift; beim Test-Backfill den
  Floor mit-anheben (siehe CONTRIBUTING.md). `--bump` druckt die aktuellen Werte
  als Vorschlag fuer neue Floors.
  """
  use Mix.Task

  # {Label, [Pfad-Substrings die zum Modul/Cluster gehoeren], Floor-Prozent}
  @floors [
    {"HubWeb.Permissions", ["hub_web/permissions.ex"], 80},
    {"Hub.EventBridge", ["hub/event_bridge.ex"], 88},
    {"Hub.Commands", ["hub/commands.ex"], 30},
    {"Worker.Materializer", ["worker/materializer.ex", "worker/materializer/"], 70},
    {"Worker.Recording.Pipeline",
     ["worker/recording/pipeline.ex", "worker/recording/pipeline/"], 35},
    {"Worker.Repo", ["worker/repo.ex", "worker/repo/"], 68},
    {"Worker.LLM.CloudHelper", ["worker/llm/cloud_helper.ex"], 60}
  ]

  @json_paths ["apps/hub/cover/excoveralls.json", "apps/worker/cover/excoveralls.json"]

  @impl true
  def run(args) do
    bump? = "--bump" in args
    source_files = load_source_files()

    if source_files == [] do
      Mix.raise(
        "Keine Coverage-Daten gefunden (#{Enum.join(@json_paths, ", ")}). " <>
          "Erst `MIX_ENV=test mix coveralls.json` pro App laufen lassen."
      )
    end

    results =
      Enum.map(@floors, fn {label, patterns, floor} ->
        {hit, rel} = aggregate(source_files, patterns)
        pct = if rel > 0, do: 100.0 * hit / rel, else: 0.0
        {label, floor, pct, hit, rel}
      end)

    print_table(results)

    breaches =
      Enum.filter(results, fn {_l, floor, pct, _h, rel} -> rel > 0 and pct < floor end)

    cond do
      bump? ->
        Mix.shell().info("\nVorschlag (aktuelle Werte minus 3 als neue Floors):")

        Enum.each(results, fn {label, _floor, pct, _h, _r} ->
          Mix.shell().info("  #{label}: #{floor_for(pct)}")
        end)

      breaches == [] ->
        Mix.shell().info("\nOK -- alle Coverage-Floors gehalten")

      true ->
        msg =
          Enum.map_join(breaches, "\n", fn {label, floor, pct, hit, rel} ->
            "  #{label}: #{fmt(pct)}% < Floor #{floor}% (#{hit}/#{rel} Zeilen)"
          end)

        Mix.raise(
          "Coverage-Floor unterschritten:\n#{msg}\n\n" <>
            "Neuer Code in einem kritischen Modul braucht Tests ZUSAETZLICH " <>
            "(nicht ersatzweise). Siehe CONTRIBUTING.md, Abschnitt Coverage-Floor."
        )
    end
  end

  defp load_source_files do
    @json_paths
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(fn path ->
      path |> File.read!() |> Jason.decode!() |> Map.get("source_files", [])
    end)
  end

  defp aggregate(source_files, patterns) do
    source_files
    |> Enum.filter(fn sf -> Enum.any?(patterns, &String.contains?(sf["name"], &1)) end)
    |> Enum.reduce({0, 0}, fn sf, {hit, rel} ->
      Enum.reduce(sf["coverage"] || [], {hit, rel}, fn
        nil, acc -> acc
        n, {h, r} when n > 0 -> {h + 1, r + 1}
        _n, {h, r} -> {h, r + 1}
      end)
    end)
  end

  defp print_table(results) do
    Mix.shell().info("Coverage-Floor (Issue #537) -- Ratchet auf heutigem Stand:\n")

    Enum.each(results, fn {label, floor, pct, hit, rel} ->
      status = if rel > 0 and pct < floor, do: "x", else: "ok"

      Mix.shell().info(
        "  [#{status}] #{String.pad_trailing(label, 28)} #{fmt(pct)}% (Floor #{floor}%, #{hit}/#{rel})"
      )
    end)
  end

  defp fmt(pct), do: :erlang.float_to_binary(pct, decimals: 1)
  defp floor_for(pct), do: max(0, trunc(pct) - 3)
end
