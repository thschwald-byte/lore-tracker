defmodule HubWeb.Probelauf.SweepAggregator do
  @moduledoc """
  Aggregator (Phase 2a, Issue #88): aus den `runs` eines Sweeps eine
  Pro-Modell-Zusammenfassung ableiten — Median-Dauer für die variierte
  Stage + Success-Rate über alle Sessions.

  Reine Datentransformation. Wird aus `AdminProbelaufLive.load_data/1`
  aufgerufen, wenn der Snapshot ein `last_sweep`-Feld liefert.

  ## Sub-Stage-Variation

  Ein Sweep variiert **genau eine Stage** — die anderen zwei Stages laufen
  mit dem Default-Modell und sind Noise. Mess-relevant ist nur die
  konfigurierte Stage. Diese Aggregation ignoriert die übrigen Stages
  bewusst.

  ## Output-Form

  Map mit `:rows`, sortiert nach (Success-Rate ↓, Median ↑) — beste Wahl
  oben. Jede Row hat `:model`, `:median_ms`, `:success_rate` (0.0..1.0),
  `:run_count`, `:session_count`.
  """

  alias HubWeb.Probelauf.Heuristik

  @doc """
  Aggregiert die `runs` (eine Liste von ProbelaufFinished-Payloads,
  wie sie aus dem Worker-Snapshot kommen) pro `sweep_variant.model`.

  Akzeptiert nil → returnt nil.
  """
  @spec aggregate(map() | nil) :: map() | nil
  def aggregate(nil), do: nil

  # Issue #281: isolated-Sweep (start_sweep_isolated/3) trägt sein Ergebnis
  # in `variants` statt in `runs`. Pro Variant ist `sessions` eine flache
  # Liste mit `stage` + `duration_ms` + `outcome` direkt — keine
  # `sweep_variant`-Indirection, kein nested `stages`-Map. Diese Clause muss
  # vor der `runs`-Clause stehen, weil ein isolated Sweep beide Keys mitführen
  # kann (variants gefüllt, runs leer).
  def aggregate(%{"variants" => variants} = sweep) when is_list(variants) and variants != [] do
    stage = sweep["stage"]
    stage_key = "stage#{stage}"

    rows =
      variants
      |> Enum.map(fn %{"model" => model, "sessions" => sessions} ->
        row_for_isolated(model, sessions)
      end)
      |> Enum.sort_by(fn row ->
        success_score = -(row.success_rate * 1.0e9)
        duration_score = row.median_ms || 9_999_999_999
        success_score + duration_score
      end)

    %{
      sweep_id: sweep["sweep_id"],
      stage: stage,
      stage_key: stage_key,
      default_model: sweep["default_model"],
      started_at: sweep["started_at"],
      finished_at: sweep["finished_at"],
      rows: rows
    }
  end

  def aggregate(%{"runs" => runs} = sweep) when is_list(runs) do
    stage = sweep["stage"]
    stage_key = "stage#{stage}"

    by_model =
      Enum.group_by(runs, fn r ->
        get_in(r, ["sweep_variant", "model"]) || "(unknown)"
      end)

    rows =
      by_model
      |> Enum.map(fn {model, model_runs} -> row_for(model, model_runs, stage_key) end)
      |> Enum.sort_by(fn row ->
        success_score = -(row.success_rate * 1.0e9)
        duration_score = row.median_ms || 9_999_999_999
        success_score + duration_score
      end)

    %{
      sweep_id: sweep["sweep_id"],
      stage: stage,
      stage_key: stage_key,
      default_model: sweep["default_model"],
      started_at: sweep["started_at"],
      finished_at: sweep["finished_at"],
      rows: rows
    }
  end

  def aggregate(_), do: nil

  defp row_for_isolated(model, sessions) do
    outcomes = Enum.map(sessions, & &1["outcome"])
    durations = sessions |> Enum.map(& &1["duration_ms"]) |> Enum.reject(&is_nil/1)

    total = Enum.count(outcomes, &(&1 != nil))
    ok = Enum.count(outcomes, &(&1 == "ok"))

    %{
      model: model,
      median_ms: Heuristik.median(durations),
      success_rate: if(total == 0, do: 0.0, else: ok / total),
      run_count: 1,
      session_count: length(sessions)
    }
  end

  defp row_for(model, runs, stage_key) do
    sessions = Enum.flat_map(runs, &(&1["sessions"] || []))
    outcomes = Enum.map(sessions, fn s -> get_in(s, ["stages", stage_key, "outcome"]) end)

    durations =
      sessions
      |> Enum.map(fn s -> get_in(s, ["stages", stage_key, "duration_ms"]) end)
      |> Enum.reject(&is_nil/1)

    total = Enum.count(outcomes, &(&1 != nil))
    ok = Enum.count(outcomes, &(&1 == "ok"))

    %{
      model: model,
      median_ms: Heuristik.median(durations),
      success_rate: if(total == 0, do: 0.0, else: ok / total),
      run_count: length(runs),
      session_count: length(sessions)
    }
  end
end
