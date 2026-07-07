defmodule HubWeb.Probelauf.Heuristik do
  @moduledoc """
  Heuristik (Phase 1, Issue #74): aus den Per-Stage-Metriken eines
  Probelaufs ein Markdown-Text mit Empfehlung + ein Settings-KV-Map
  ableiten.

  Reine Datentransformation — keine I/O, kein Mnesia, kein LLM. So sind
  Tests trivial: gib Mock-Daten rein, prüf den Output.

  Empfehlungs-Regeln:
  - Stage hat 100 % `ok` UND median < 30 s → „beibehalten", kein KV.
  - Irgendeine Session mit `timeout` → `http_timeout_ms` auf 600_000.
  - Stage 4 mit `empty_output`/`parse_error` → `model_stage4` auf ein
    JSON-fähiges Fallback-Modell (mistral-nemo:12b, command-r).
  - Sonst Hinweis „manueller Blick nötig", kein KV.
  """

  @stages ["stage2", "stage3", "stage4"]

  @doc "Stages-Liste, an die sich die UI-Heatmap hängt."
  def stages, do: @stages

  @typedoc """
  Eine Session aus dem `ProbelaufFinished`-Payload — JSON-Map mit
  String-Keys, wie sie aus dem Worker-Snapshot über die Wire kommt.
  """
  @type session :: %{optional(String.t()) => term()}

  @doc """
  Liefert `{markdown_text, settings_kv_map}` für die UI.

  - `markdown_text` ist der menschlich lesbare Empfehlungs-Text (eine
    Zeile pro Stage).
  - `settings_kv_map` enthält die Worker.Settings-Keys, die der
    „Empfehlung übernehmen"-Button schreiben würde. Leer → Button
    disabled.
  """
  @spec build([session()], [String.t()]) :: {String.t(), map()}
  def build(sessions, available_models) when is_list(sessions) and is_list(available_models) do
    stage_outcomes =
      Enum.into(@stages, %{}, fn stage ->
        outcomes = Enum.map(sessions, fn s -> get_in(s, ["stages", stage, "outcome"]) end)
        durations = Enum.map(sessions, fn s -> get_in(s, ["stages", stage, "duration_ms"]) end)
        {stage, %{outcomes: outcomes, durations: durations}}
      end)

    {lines, kv} =
      Enum.reduce(@stages, {[], %{}}, fn stage, {lines, kv} ->
        %{outcomes: outcomes, durations: durations} = stage_outcomes[stage]
        {line, kv_add} = recommend_stage(stage, outcomes, durations, available_models)
        {lines ++ [line], Map.merge(kv, kv_add)}
      end)

    {Enum.join(lines, "\n\n"), kv}
  end

  @doc """
  Wählt aus den vom Worker installierten Modellen das beste mit
  JSON-Mode-Support. Fällt auf „mistral-nemo:12b" zurück wenn keines
  der bevorzugten Modelle installiert ist (User muss dann pullen).
  """
  @spec pick_json_capable_model([String.t()]) :: String.t()
  def pick_json_capable_model(available_models) do
    preferred = ["mistral-nemo:12b", "command-r:latest", "command-r"]

    Enum.find(preferred, fn name -> name in available_models end) || "mistral-nemo:12b"
  end

  @doc "Median aus einer Liste von Zahlen (ms). `nil` bei leerer Liste."
  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  # ─── intern ─────────────────────────────────────────────────────

  defp recommend_stage(stage, outcomes, durations, available_models) do
    all_ok? = Enum.all?(outcomes, &(&1 == "ok"))
    any_timeout? = Enum.any?(outcomes, &(&1 == "timeout"))
    any_empty_or_parse? = Enum.any?(outcomes, &(&1 in ["empty_output", "parse_error"]))

    valid_durations = Enum.reject(durations, &is_nil/1)
    med = median(valid_durations)

    cond do
      all_ok? and is_number(med) and med < 30_000 ->
        {"**#{stage}** → ✅ alle Sessions erfolgreich (Median #{format_ms(med)}). Aktuelle Config beibehalten.",
         %{}}

      any_timeout? ->
        {"**#{stage}** → ⏱ Timeout(s) — `http_timeout_ms` hochsetzen ODER schnelleres Modell wählen.",
         %{"http_timeout_ms" => 600_000}}

      stage == "stage4" and any_empty_or_parse? ->
        fallback = pick_json_capable_model(available_models)

        {"**stage4** → 🚫 Chronik nicht extrahierbar (Modell ohne sauberen JSON-Mode). Empfohlen: `#{fallback}`.",
         %{"model_stage4" => fallback}}

      true ->
        {"**#{stage}** → ⚠ Mixed outcomes (#{Enum.join(filter_known(outcomes), ", ")}). Manueller Blick nötig.",
         %{}}
    end
  end

  defp filter_known(outcomes), do: Enum.reject(outcomes, &is_nil/1)

  # nur unter `is_number(med) and med < 30_000` aufgerufen → number-only Klauseln
  # reichen (Elixir 1.19 warnt einen nil-catch-all als unerreichbar).
  defp format_ms(ms) when is_number(ms) and ms < 1000, do: "#{round(ms)} ms"
  defp format_ms(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)} s"
end
