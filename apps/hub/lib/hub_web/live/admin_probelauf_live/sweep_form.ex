defmodule HubWeb.AdminProbelaufLive.SweepForm do
  @moduledoc """
  Issue #573: Sweep-Form-Logik-Helpers aus `HubWeb.AdminProbelaufLive` —
  Param-Parser für Stages/Models/Session-Sets, Default-Form-State, Multi-Stage-
  Winner-Auswahl und Dispatch-Mapping isolated? → Commands-Function.
  """

  alias Hub.Commands

  # ─── Param-Parser ────────────────────────────────────────────────

  @spec parse_stage(String.t() | integer() | term()) :: 2 | 3 | 4 | nil
  def parse_stage("2"), do: 2
  def parse_stage("3"), do: 3
  def parse_stage("4"), do: 4
  def parse_stage(2), do: 2
  def parse_stage(3), do: 3
  def parse_stage(4), do: 4
  def parse_stage(_), do: nil

  @spec parse_session_set(map()) :: [String.t()]
  def parse_session_set(params) do
    case params["session_set"] do
      list when is_list(list) ->
        list
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.filter(&(&1 in ["short", "medium", "long", "real"]))

      m when is_map(m) ->
        m
        |> Map.values()
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.filter(&(&1 in ["short", "medium", "long", "real"]))

      _ ->
        []
    end
  end

  @spec parse_models(map()) :: [String.t()]
  def parse_models(params) do
    case params["models"] do
      models when is_list(models) ->
        Enum.reject(models, &(&1 == "" or is_nil(&1)))

      models when is_map(models) ->
        models |> Map.values() |> Enum.reject(&(&1 == "" or is_nil(&1)))

      _ ->
        []
    end
  end

  # Issue #88 (Phase 2b): liest `params["stage_models"]` = %{"2" => [...], ...}
  # in den internen Stage→MapSet-Cache. Stages ohne Eintrag in `params`
  # bleiben beim alten Stand — das verhindert Aushaken aller Auswahlen
  # in Stages, die im aktuellen phx-change-Event nicht angefasst wurden.
  @spec parse_stage_models(map(), map()) :: %{2 => MapSet.t(), 3 => MapSet.t(), 4 => MapSet.t()}
  def parse_stage_models(params, fallback) do
    raw =
      case params["stage_models"] do
        m when is_map(m) -> m
        _ -> %{}
      end

    for stage <- [2, 3, 4], into: %{} do
      key = Integer.to_string(stage)

      ms =
        case Map.fetch(raw, key) do
          {:ok, list} when is_list(list) ->
            list
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> MapSet.new()

          {:ok, m} when is_map(m) ->
            m
            |> Map.values()
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> MapSet.new()

          _ ->
            # Stage nicht im params → unverändert lassen.
            fallback |> Map.get(stage, MapSet.new())
        end

      {stage, ms}
    end
  end

  # ─── Form-State ────────────────────────────────────────────────

  @spec default_sweep_form() :: map()
  def default_sweep_form,
    do: %{
      mode: "full",
      stage: 2,
      models: MapSet.new(),
      session_set: MapSet.new(["short", "medium", "long"]),
      # Issue #88 (Phase 2b): per-Stage Modellauswahl. Ein Multi-Stage-Sweep
      # läuft sequentiell N einzelne Single-Stage-Sweeps (eine pro Stage mit
      # nicht-leerer Modell-Liste), die LV hält sie im Anschluss in
      # `:pending_sweep_queue` und feuert den nächsten, sobald
      # `ProbelaufSweepFinished` für den laufenden eintrifft.
      stage_models: %{2 => MapSet.new(), 3 => MapSet.new(), 4 => MapSet.new()}
    }

  # Issue #88 (Phase 2c): aus einer Liste von SweepAggregator-Summaries die
  # `%{model_stageN: "winner"}`-Map ableiten. Pro Summary die Top-Row
  # nehmen, aber nur wenn success_rate ≥ 0.5 (Quality-Gate). Ein Modell,
  # das mehrfach für unterschiedliche Stages gewinnt, wird allen Stages
  # zugewiesen. Wenn keine Stage ein verwendbares Ergebnis hat, returnt
  # `%{}` und der Caller flashed eine Fehlermeldung.
  @spec multi_stage_winners([map()]) :: %{optional(atom()) => String.t()}
  def multi_stage_winners(summaries) when is_list(summaries) do
    summaries
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn summary, acc ->
      stage = summary[:stage]
      top = summary |> Map.get(:rows, []) |> List.first()

      cond do
        is_nil(stage) -> acc
        is_nil(top) -> acc
        top[:success_rate] == nil -> acc
        top.success_rate < 0.5 -> acc
        not is_binary(top[:model]) -> acc
        true -> Map.put(acc, :"model_stage#{stage}", top.model)
      end
    end)
  end

  # ─── Dispatch ────────────────────────────────────────────────

  @spec dispatch_sweep(boolean(), String.t(), integer(), [String.t()], [String.t()] | nil) ::
          non_neg_integer()
  def dispatch_sweep(isolated?, did, stage, models, session_set) do
    dispatch_fn =
      if isolated?,
        do: &Commands.request_probelauf_sweep_isolated/4,
        else: &Commands.request_probelauf_sweep/4

    dispatch_fn.(did, stage, models, session_set)
  end
end
