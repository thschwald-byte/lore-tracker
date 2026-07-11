defmodule HubWeb.AdminProbelaufLive.SweepForm do
  @moduledoc """
  Issue #573: Sweep-Form-Logik-Helpers aus `HubWeb.AdminProbelaufLive` —
  Param-Parser für Models/Session-Sets + Default-Form-State.

  Seit #786 (Wahrheitsbild-nativ) gibt es nur noch den Extraktor-Modell-
  Sweep: keine Stage-Wahl, kein Isolated-Modus, kein Multi-Stage-Queueing.
  """

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

  @spec default_sweep_form() :: map()
  def default_sweep_form,
    do: %{
      models: MapSet.new(),
      session_set: MapSet.new(["short", "medium", "long"])
    }
end
