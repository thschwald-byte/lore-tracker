defmodule HubWeb.Probelauf.Heuristik do
  @moduledoc """
  Heuristik (Issue #74; seit #786 Wahrheitsbild-nativ): aus den
  Per-Schritt-Metriken + dem Verify-Trichter eines Probelaufs einen
  Markdown-Text mit Empfehlung + ein Settings-KV-Map ableiten.

  Reine Datentransformation — keine I/O, kein Mnesia, kein LLM. So sind
  Tests trivial: gib Mock-Daten rein, prüf den Output.

  Empfehlungs-Regeln (Outcome-Vokabular: ok/failed/timeout/skipped,
  Fehlerklassen aus dem persistierten #716-Error-Log):
  - Irgendein Schritt mit `timeout` → `http_timeout_ms` hochsetzen + Hint
    auf `extract_chunk_tokens`/`extract_num_predict_cap`.
  - `extract` failed mit Parse-/Empty-Klasse → Extraktor-Modell-Empfehlung
    auf den pro-Backend-Key `model_stage2_<backend>` (#784-Pattern).
  - `verify` failed mit `sidecar_offline` → Text-Hint NLI-Sidecar (kein KV).
  - Verify-Trichter `n_verified/n_facts < 0.3` → Text-Hint Stage 3
    (Verify) Backend/Modell stärker wählen (#783 Phase 2).
  - `timeline` failed → deterministischer Schritt, Bug melden (kein KV).
  - Alt-Reports (Chain, ohne `"facts"`-Key) → nur Hinweis, keine Empfehlung.
  """

  @stages ~w(extract verify render timeline render_epos)

  # Fehlerklassen (#716), bei denen ein stärkeres/JSON-fähigeres
  # Extraktor-Modell die wahrscheinlichste Abhilfe ist.
  @extract_model_error_types ~w(extraction_empty all_chunks_failed parse_error empty_output)

  # Unterhalb dieser Verify-Rate (n_verified/n_facts) lohnt ein Blick auf
  # den Judge (unterkalibrierter Judge lehnt zu viel ab — Referenzlauf #762).
  @funnel_warn_threshold 0.3

  @doc "Schritte-Liste, an die sich die UI-Heatmap hängt."
  def stages, do: @stages

  @typedoc """
  Eine Session aus dem `ProbelaufFinished`-Payload — JSON-Map mit
  String-Keys, wie sie aus dem Worker-Snapshot über die Wire kommt.
  """
  @type session :: %{optional(String.t()) => term()}

  @doc """
  Liefert `{markdown_text, settings_kv_map}` für die UI.

  - `markdown_text` ist der menschlich lesbare Empfehlungs-Text.
  - `settings_kv_map` enthält die Worker.Settings-Keys, die der
    „Empfehlung übernehmen"-Button schreiben würde. Leer → Button disabled.
  - `stage2_backend` ist das aktive `backend_stage2` (z.B. `"local"`) —
    die Extraktor-Modell-Empfehlung schreibt auf den GEWINNENDEN
    pro-Backend-Key `model_stage2_<backend>` (#784). Default `"local"`.
  """
  @spec build([session()], [String.t()], String.t()) :: {String.t(), map()}
  def build(sessions, available_models, stage2_backend \\ "local")

  def build([], _available_models, _stage2_backend),
    do: {"Keine Sessions gemessen — Probelauf erneut starten.", %{}}

  def build(sessions, available_models, stage2_backend)
      when is_list(sessions) and is_list(available_models) do
    if wahrheitsbild_report?(sessions) do
      build_wahrheitsbild(sessions, available_models, stage2_backend)
    else
      {"⚠ Alt-Report aus der entfernten Chain-Pipeline (Stage 2/3/4) — " <>
         "Empfehlungen gibt es nur für Wahrheitsbild-Läufe. Neuen Probelauf starten.", %{}}
    end
  end

  # Wahrheitsbild-Reports tragen den Verify-Trichter pro Session (#786);
  # Chain-Alt-Reports haben nur die stages-Map.
  defp wahrheitsbild_report?(sessions),
    do: Enum.any?(sessions, &is_map(&1["facts"]))

  defp build_wahrheitsbild(sessions, available_models, stage2_backend) do
    per_step =
      Enum.into(@stages, %{}, fn step ->
        {step,
         %{
           outcomes: Enum.map(sessions, &get_in(&1, ["stages", step, "outcome"])),
           durations: Enum.map(sessions, &get_in(&1, ["stages", step, "duration_ms"])),
           error_types: Enum.map(sessions, &get_in(&1, ["stages", step, "error_type"]))
         }}
      end)

    funnel = funnel_totals(sessions)

    {lines, kv} =
      []
      |> rule_all_ok(per_step)
      |> rule_timeout(per_step)
      |> rule_extract_model(per_step, available_models, stage2_backend)
      |> rule_sidecar(per_step)
      |> rule_funnel(funnel)
      |> rule_timeline(per_step)
      |> rule_no_verified_facts(per_step)
      |> then(fn {lines, kv} -> {[funnel_line(funnel) | Enum.reverse(lines)], kv} end)

    {Enum.join(lines, "\n\n"), kv}
  end

  # Regeln arbeiten auf {lines (reversed), kv}-Akku; Listen-Only-Eingang
  # wird beim ersten Aufruf normalisiert.
  defp rule_all_ok(lines, per_step) when is_list(lines) do
    all_ok? =
      Enum.all?(@stages, fn step ->
        Enum.all?(per_step[step].outcomes, &(&1 == "ok"))
      end)

    if all_ok? do
      med =
        @stages
        |> Enum.flat_map(fn step -> per_step[step].durations end)
        |> Enum.reject(&is_nil/1)
        |> median()

      {[
         "✅ Alle Schritte in allen Sessions erfolgreich" <>
           if(is_number(med), do: " (Schritt-Median #{format_ms(med)})", else: "") <>
           ". Aktuelle Config beibehalten."
       ], %{}}
    else
      {lines, %{}}
    end
  end

  defp rule_timeout({lines, kv}, per_step) do
    timeout_steps =
      Enum.filter(@stages, fn step ->
        Enum.any?(per_step[step].outcomes, &(&1 == "timeout"))
      end)

    if timeout_steps == [] do
      {lines, kv}
    else
      line =
        "⏱ Timeout in #{Enum.join(timeout_steps, ", ")} — `http_timeout_ms` hochsetzen. " <>
          "Wenn die Extraktion hängt, zusätzlich `extract_chunk_tokens` senken / " <>
          "`extract_num_predict_cap` prüfen (#763-Klasse)."

      {[line | lines], Map.put(kv, "http_timeout_ms", 600_000)}
    end
  end

  defp rule_extract_model({lines, kv}, per_step, available_models, stage2_backend) do
    bad_extract? =
      per_step["extract"].outcomes
      |> Enum.zip(per_step["extract"].error_types)
      |> Enum.any?(fn {outcome, error_type} ->
        outcome == "failed" and error_type in @extract_model_error_types
      end)

    if bad_extract? do
      fallback = pick_json_capable_model(available_models)
      key = "model_stage2_#{sanitize_backend(stage2_backend)}"

      line =
        "🚫 Extraktion liefert kein verwertbares JSON (Modell ohne sauberen " <>
          "JSON-Mode oder degenerierende Chunks). Empfohlen: `#{fallback}`."

      {[line | lines], Map.put(kv, key, fallback)}
    else
      {lines, kv}
    end
  end

  defp rule_sidecar({lines, kv}, per_step) do
    sidecar_offline? = Enum.any?(per_step["verify"].error_types, &(&1 == "sidecar_offline"))

    if sidecar_offline? do
      line =
        "🔌 Verify-Gate ohne NLI-Sidecar — Sidecar starten oder " <>
          "`faithfulness_sidecar_url` in /settings setzen (kein Auto-Fix)."

      {[line | lines], kv}
    else
      {lines, kv}
    end
  end

  defp rule_funnel({lines, kv}, %{n_facts: n_facts, n_verified: n_verified}) do
    if n_facts > 0 and n_verified / n_facts < @funnel_warn_threshold do
      line =
        "⚖ Verify-Rate niedrig (#{n_verified}/#{n_facts} verifiziert) — " <>
          "Backend/Modell von Stage 3 (Verify) stärker wählen (sollte stärker " <>
          "sein als der Extraktor) und source_refs-Dichte der Extraktion prüfen."

      {[line | lines], kv}
    else
      {lines, kv}
    end
  end

  defp rule_timeline({lines, kv}, per_step) do
    if Enum.any?(per_step["timeline"].outcomes, &(&1 == "failed")) do
      line =
        "🐛 Timeline-Schritt fehlgeschlagen — der ist deterministisch (kein LLM). " <>
          "Das ist ein Bug, bitte /admin/errors prüfen + Issue melden."

      {[line | lines], kv}
    else
      {lines, kv}
    end
  end

  defp rule_no_verified_facts({lines, kv}, per_step) do
    starved? =
      ["render", "render_epos"]
      |> Enum.flat_map(fn step -> per_step[step].error_types end)
      |> Enum.any?(&(&1 == "no_verified_facts"))

    if starved? do
      line =
        "🪫 Render ohne verifizierte Fakten — Ursache liegt VOR dem Render " <>
          "(Extraktion/Verify, siehe Trichter oben)."

      {[line | lines], kv}
    else
      {lines, kv}
    end
  end

  defp funnel_totals(sessions) do
    Enum.reduce(sessions, %{n_facts: 0, n_grounded: 0, n_verified: 0}, fn s, acc ->
      facts = s["facts"] || %{}

      %{
        n_facts: acc.n_facts + (facts["n_facts"] || 0),
        n_grounded: acc.n_grounded + (facts["n_grounded"] || 0),
        n_verified: acc.n_verified + (facts["n_verified"] || 0)
      }
    end)
  end

  defp funnel_line(%{n_facts: f, n_grounded: g, n_verified: v}) do
    rate = if f > 0, do: " (#{round(100 * v / f)} %)", else: ""

    "**Verify-Trichter** über alle Sessions: #{f} Fakten → #{g} geerdet → #{v} verifiziert#{rate}."
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

  # Issue #784: nur die vier bekannten Backends ergeben einen gültigen
  # `model_stage2_<backend>`-Key; alles andere (nil, Tippfehler) → "local".
  @known_backends ~w(local anthropic openai google)
  defp sanitize_backend(b) when b in @known_backends, do: b
  defp sanitize_backend(_), do: "local"

  defp format_ms(ms) when is_number(ms) and ms < 1000, do: "#{round(ms)} ms"
  defp format_ms(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)} s"
end
