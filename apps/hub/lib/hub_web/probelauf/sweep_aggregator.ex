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
      |> sort_rows()

    %{
      sweep_id: sweep["sweep_id"],
      stage: stage,
      stage_key: stage_key,
      default_model: sweep["default_model"],
      started_at: sweep["started_at"],
      finished_at: sweep["finished_at"],
      session_set: derive_session_set_from_variants(sweep["session_set"], variants),
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
      |> sort_rows()

    %{
      sweep_id: sweep["sweep_id"],
      stage: stage,
      stage_key: stage_key,
      default_model: sweep["default_model"],
      started_at: sweep["started_at"],
      finished_at: sweep["finished_at"],
      session_set: derive_session_set_from_runs(sweep["session_set"], runs),
      rows: rows
    }
  end

  def aggregate(_), do: nil

  # Issue #281b: Sortierung berücksichtigt jetzt auch faithfulness_avg (Qualität).
  # Reihenfolge: Qualität ↓ (nil sortiert ans Ende), Success-Rate ↓, Median-Dauer ↑.
  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row ->
      faith_score = -(row[:faithfulness_avg] || -1.0)
      success_score = -row.success_rate
      duration_score = row.median_ms || 9_999_999_999

      {faith_score, success_score, duration_score}
    end)
  end

  defp row_for_isolated(model, sessions) do
    outcomes = Enum.map(sessions, & &1["outcome"])
    durations = sessions |> Enum.map(& &1["duration_ms"]) |> Enum.reject(&is_nil/1)
    faithfulness = sessions |> Enum.map(& &1["faithfulness_score"]) |> Enum.reject(&is_nil/1)

    total = Enum.count(outcomes, &(&1 != nil))
    ok = Enum.count(outcomes, &(&1 == "ok"))

    %{
      model: model,
      median_ms: Heuristik.median(durations),
      success_rate: if(total == 0, do: 0.0, else: ok / total),
      faithfulness_avg: avg(faithfulness),
      run_count: 1,
      session_count: length(sessions),
      # Issue #288: erste Non-OK-Format-Note als Variant-Indikator. nil
      # wenn alle Sessions sauber durchgelaufen sind (oder kein
      # format_notes-Feld da war — pre-#288-Sweeps).
      format_issue: first_non_ok_format_note(sessions),
      # Issue #288: Sichtbarmachen ob bei dieser Variant ein Timeout
      # auftrat. Hängt am `outcome`-Feld (timeout setzt outcome="timeout"
      # in probelauf.ex/classify_outcome).
      has_timeout: Enum.any?(outcomes, &(&1 == "timeout"))
    }
  end

  defp first_non_ok_format_note(sessions) do
    sessions
    |> Enum.map(& &1["format_notes"])
    |> Enum.find(fn n -> is_binary(n) and n != "ok" end)
  end

  defp avg([]), do: nil
  defp avg(list) when is_list(list), do: Enum.sum(list) / length(list)

  # Issue #284: leitet die session_set-Tags aus den variants ab, falls der
  # Sweep das Feld nicht selbst mitgeschickt hat (alte Sweeps vor #284).
  # Aus der `session.number` (1/2/3) wird "short"/"medium"/"long" abgeleitet.
  defp derive_session_set_from_variants(explicit, _variants) when is_list(explicit) and explicit != [],
    do: explicit

  defp derive_session_set_from_variants(_, variants) do
    variants
    |> Enum.flat_map(fn v -> v["sessions"] || [] end)
    |> Enum.map(& &1["number"])
    |> session_numbers_to_tags()
  end

  defp derive_session_set_from_runs(explicit, _runs) when is_list(explicit) and explicit != [],
    do: explicit

  defp derive_session_set_from_runs(_, runs) do
    runs
    |> Enum.flat_map(fn r -> r["sessions"] || [] end)
    |> Enum.map(& &1["number"])
    |> session_numbers_to_tags()
  end

  defp session_numbers_to_tags(numbers) do
    numbers
    |> Enum.uniq()
    |> Enum.map(fn
      1 -> "short"
      2 -> "medium"
      3 -> "long"
      4 -> "real"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
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
      faithfulness_avg: nil,
      run_count: length(runs),
      session_count: length(sessions)
    }
  end
end
