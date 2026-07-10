defmodule HubWeb.EinstellungenLive.Options do
  @moduledoc """
  Issue #451 (Track C) + Codebase-Review 2026-07-07: die reinen Options-/
  Normalisierungs-Helfer der Settings-LV, aus dem LiveView-Modul entflochten
  (Colocation-Muster wie `campaign_live/`).

  Enthält keine Socket-/Prozess-Logik — alles pure Funktionen über die
  Snapshot-Assigns (`available_models` / `cloud_models` / `cloud_errors` /
  `worker_aggregate`) und die Form-Param-Normalisierung.
  """

  @doc """
  Issue #463: Backend-aware Modell-Liste. Bei `local` → Ollama-Liste +
  passender Placeholder. Bei Cloud-Backends → fetched Liste aus der
  `cloud_models`-Map des Snapshots + spezifischer Placeholder. Returnt
  `{models_list, cloud_error_string_or_nil, placeholder_text}`.
  """
  def stage_model_options("anthropic", %{cloud_models: cm, cloud_errors: ce}) do
    {Map.get(cm, "anthropic", []), Map.get(ce, "anthropic"), "Claude-Modell — klicken für Liste"}
  end

  def stage_model_options("openai", %{cloud_models: cm, cloud_errors: ce}) do
    {Map.get(cm, "openai", []), Map.get(ce, "openai"), "GPT-/o1-Modell — klicken für Liste"}
  end

  def stage_model_options("google", %{cloud_models: cm, cloud_errors: ce}) do
    {Map.get(cm, "google", []), Map.get(ce, "google"), "Gemini-Modell — klicken für Liste"}
  end

  def stage_model_options(_local_or_other, %{available_models: am}) do
    {am, nil, "z.B. qwen2.5:0.5b — klicken für alle Modelle"}
  end

  def cloud_env_var("anthropic"), do: "ANTHROPIC_API_KEY"
  def cloud_env_var("openai"), do: "OPENAI_API_KEY"
  def cloud_env_var("google"), do: "GEMINI_API_KEY"
  def cloud_env_var(_), do: nil

  @doc """
  Baut die Options-Liste für live_select: pro Modell ein Map mit `label`
  (inkl. Multi-Worker-Hint falls > 1 Worker connected ist) und `value`.
  """
  def model_options(available_models, worker_aggregate, filter_text \\ nil) do
    total = worker_aggregate.total

    available_models
    |> filter_by_text(filter_text)
    |> Enum.map(fn name ->
      count = Map.get(worker_aggregate.counts, name, total)

      label =
        if total > 1 and count < total do
          "#{name}  ·  nur auf #{count}/#{total} Workern"
        else
          name
        end

      %{label: label, value: name}
    end)
  end

  defp filter_by_text(models, nil), do: models
  defp filter_by_text(models, ""), do: models

  defp filter_by_text(models, text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.filter(models, fn name -> String.contains?(String.downcase(name), lower) end)
  end

  @doc """
  #451 Track C: das ANZEIGE-Modell einer Backend-Box = der pro-Backend-Key
  `model_stage{n}_{backend}`. Spiegelt die Worker-seitige `Settings.model_for/2`-
  Auflösung.

  Seit #784 ist der Legacy-Key `model_stage{n}` entfernt (weder Default noch im
  Settings-Snapshot) — der frühere Legacy-Fallback für das aktive Backend
  entfällt damit ersatzlos.
  """
  def display_model(settings, n, backend) do
    blank_to_nil(settings["model_stage#{n}_#{backend}"])
  end

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  # ─── Form-Param-Normalisierung (Save-Pfade) ───────────────────────

  @numeric_float_keys ~w(
    temperature_stage2 temperature_stage3 temperature_stage4
    top_p_stage2 top_p_stage3 top_p_stage4
    repeat_penalty_stage2 repeat_penalty_stage3 repeat_penalty_stage4
  )
  @numeric_int_keys ~w(
    num_predict_stage2 num_predict_stage3 num_predict_stage4
    ctx_stage2 ctx_stage3 ctx_stage4
    http_timeout_ms
  )

  @doc """
  Normalisiert die `settings`-Form-Params für den Command-Push: numerische
  Keys → Float/Int, Strings getrimmt, leere Werte + live_select-Hilfsfelder
  raus. Gemeinsam für den globalen Save und die Box-Saves.
  """
  def normalize_settings_params(params) when is_map(params) do
    params
    |> Enum.reject(fn {k, _} -> String.ends_with?(k, "_text_input") end)
    |> Enum.into(%{}, fn {k, v} -> {k, normalize_value(k, v)} end)
    |> Map.reject(fn {_, v} -> v in [nil, ""] end)
  end

  def normalize_value(_key, ""), do: nil
  def normalize_value(key, v) when key in @numeric_float_keys, do: parse_float(v)
  def normalize_value(key, v) when key in @numeric_int_keys, do: parse_int(v)
  def normalize_value(_key, value) when is_binary(value), do: String.trim(value)
  def normalize_value(_key, value), do: value

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
end
