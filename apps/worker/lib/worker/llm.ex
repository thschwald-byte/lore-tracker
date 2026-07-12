defmodule Worker.LLM do
  @moduledoc """
  Stage-aware dispatch in front of `Worker.LLM.Backend` implementations.

  Seit #783 Phase 2 hat jeder Wahrheitsbild-Schritt sein eigenes Backend:
  `complete(:summary, prompt)` (Extraktion) liest `:backend_stage2`,
  `complete(:verify, prompt)` liest `:backend_stage3`, `complete(:render,
  prompt)` liest `:backend_stage4`. Transcription has its own backend setting
  (`:backend_stage1`) and lives in `transcribe/2`.
  """

  alias Worker.Settings

  @stage_to_setting %{
    transcribe: :backend_stage1,
    summary: :backend_stage2,
    verify: :backend_stage3,
    render: :backend_stage4
  }

  # Issue #783 Phase 2: Stage-Atom → Stage-Nummer, für den Cap-Estimate-
  # Modell-Lookup in `complete/3` — dieselbe Zuordnung wie `@stage_to_setting`,
  # aber als n statt als Settings-Key (Worker.Settings.model_for/2 erwartet n).
  @stage_to_n %{summary: 2, verify: 3, render: 4}

  # Issue #632: Spend-Cap-Härtung.
  # Fix #2 — Pre-Call-Token-Estimate: konservative fixe Output-Token-Annahme
  # (der tatsächliche Output ist vor dem Call unbekannt; lieber zu hoch
  # schätzen als den Cap durchrutschen lassen).
  @estimated_output_tokens 4096

  # Fix #3 — Per-Action-Burst-Limit: max N Cloud-Calls in einem M-Sekunden-
  # Fenster pro discord_id. Fängt z.B. CampaignReplay über viele Sessions
  # ab, bevor der Monats-Cap überhaupt greifen könnte.
  @burst_limit_calls 50
  @burst_limit_window_seconds 60

  @backend_modules %{
    local: Worker.LLM.Local,
    anthropic: Worker.LLM.Anthropic,
    openai: Worker.LLM.OpenAI,
    google: Worker.LLM.Google
    # :bundled registers here in M9b
  }

  @spec complete(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(stage, prompt, opts \\ []) do
    backend_atom = Settings.get(Map.fetch!(@stage_to_setting, stage), :local)
    mod = module_for(backend_atom)

    # Issue #178/#632: Spend-Cap-Gate vor Cloud-Calls. Local-Backend ist
    # kostenlos und braucht keinen Check. Bei Überschreitung: ein
    # `{:error, _}` bubbled in die Pipeline und schlägt sichtbar fehl — kein
    # silent Fallback auf Ollama (das maskiert sonst Cap-Erreichung).
    #
    # #783 Phase 2: das Cost-Estimate muss das Modell DER AUFRUFENDEN STAGE
    # sehen, nicht immer Stage 2 — sonst schätzt ein Verify/Render-Call auf
    # einem Cloud-Backend die Kosten mit dem (evtl. ganz anderen) Extraktor-
    # Modell, was den Cap-Estimate systematisch falsch macht.
    model = Settings.model_for(Map.fetch!(@stage_to_n, stage), backend_atom)

    with :ok <-
           check_spend_cap(backend_atom, Worker.Repo.get_state(:admin_discord_id), model, prompt) do
      mod.complete(prompt, Keyword.put_new(opts, :stage, stage))
    end
  end

  @spec transcribe(binary() | Path.t(), keyword()) ::
          {:ok, [%{discord_id: String.t(), text: String.t(), timestamp: DateTime.t()}]}
          | {:error, term()}
  def transcribe(audio, opts \\ []) do
    backend_for(:transcribe).transcribe(audio, opts)
  end

  defp backend_for(stage) do
    setting_key = Map.fetch!(@stage_to_setting, stage)
    backend_atom = Settings.get(setting_key, :local)
    module_for(backend_atom)
  end

  defp module_for(backend_atom) do
    case Map.get(@backend_modules, backend_atom) do
      nil ->
        require Logger

        Logger.warning(
          "Worker.LLM: backend #{inspect(backend_atom)} not implemented, falling back to :local"
        )

        Worker.LLM.Local

      mod ->
        mod
    end
  end

  # Issue #178/#632: Cap-Check vor jedem Cloud-Call. Local-Backend = kein
  # Check (kostenlos, egal welche discord_id). Drei Härtungs-Lücken (#632):
  #
  #   Fix #1 — nil admin_discord_id auf einem Cloud-Backend heißt "Worker vor
  #   dem Pairing / nach Storage-Reset" — das ist KEIN unbegrenzter Freifahrt-
  #   schein mehr, sondern harte Verweigerung (`{:error, :no_admin}`).
  #
  #   Fix #2 — der bisherige Check prüfte nur `spent >= cap`, also den Stand
  #   VOR dem Call. Ein Call kurz unter dem Cap konnte den Cap beliebig weit
  #   überschießen (riesiger Prompt); geblockt wurde erst der NÄCHSTE Call.
  #   Jetzt wird `spent + estimate(prompt)` gegen den Cap geprüft.
  #
  #   Fix #3 — Burst-Limit (siehe `@burst_limit_calls`/`@burst_limit_window_
  #   seconds`) fängt viele sequenzielle Calls aus einem einzelnen User-Klick
  #   ab (z.B. CampaignReplay über etliche Sessions), die der Monats-Cap erst
  #   am Monatsende sehen würde. Läuft VOR dem Cap-Estimate-Check (billiger).
  #
  # Fehlender Cap (`monthly_spend_cap_usd == nil`): weiterhin erlaubt (nil =
  # unbegrenzt) — Burst-Limit greift trotzdem, unabhängig vom Cap.
  @spec check_spend_cap(atom(), String.t() | nil, String.t() | nil, String.t()) ::
          :ok
          | {:error, :no_admin | :burst_limit_exceeded | :cap_estimate_exceeded}
  def check_spend_cap(:local, _discord_id, _model, _prompt), do: :ok

  def check_spend_cap(backend, nil, _model, _prompt) do
    require Logger

    Logger.warning(
      "Worker.LLM: no_admin für backend=#{inspect(backend)} — kein admin_discord_id gepaired " <>
        "(Worker vor Pairing / nach Storage-Reset?), Cloud-Call blockiert"
    )

    {:error, :no_admin}
  end

  def check_spend_cap(backend, discord_id, model, prompt)
      when is_binary(discord_id) and is_binary(prompt) do
    with :ok <- check_burst_limit(backend, discord_id) do
      check_cap_estimate(backend, discord_id, model, prompt)
    end
  end

  defp check_burst_limit(backend, discord_id) do
    count = Worker.Repo.recent_call_count(discord_id, @burst_limit_window_seconds)

    if count >= @burst_limit_calls do
      require Logger

      Logger.warning(
        "Worker.LLM: burst_limit_exceeded für discord_id=#{discord_id} backend=#{inspect(backend)} " <>
          "(#{count} Calls in den letzten #{@burst_limit_window_seconds}s, Limit=#{@burst_limit_calls}) — Cloud-Call blockiert"
      )

      {:error, :burst_limit_exceeded}
    else
      :ok
    end
  end

  defp check_cap_estimate(backend, discord_id, model, prompt) do
    case Worker.Repo.get_user(discord_id) do
      %{monthly_spend_cap_usd: cap} when is_number(cap) ->
        spent = Worker.Repo.monthly_spend_usd(discord_id)
        estimate = estimate_cost(backend, model, prompt)

        if spent + estimate >= cap do
          require Logger

          Logger.warning(
            "Worker.LLM: cap_estimate_exceeded für discord_id=#{discord_id} " <>
              "(spent=$#{Float.round(spent * 1.0, 2)}, estimate=$#{Float.round(estimate * 1.0, 4)}, cap=$#{cap}) — Cloud-Call blockiert"
          )

          {:error, :cap_estimate_exceeded}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # Grobe chars/4-Heuristik fürs Input-Token-Estimate (10-20% Fehler laut
  # Issue akzeptiert) + fixe konservative Output-Token-Annahme. Unbekanntes/
  # fehlendes Modell → `cost_for/4` liefert bereits 0.0 (kein falscher Block).
  defp estimate_cost(_backend, nil, _prompt), do: 0.0

  defp estimate_cost(backend, model, prompt) do
    input_tokens = div(String.length(prompt), 4)
    cost_for(Atom.to_string(backend), model, input_tokens, @estimated_output_tokens)
  end

  # Issue #177: Cost-Berechnung aus Provider-Pricing-Konstanten + Token-Counts.
  # `provider` ist "anthropic" (heute) | "openai" | "google" (Folge-Issues).
  # Returnt USD-Float. Bei unbekanntem Provider/Modell: 0.0 (Spend bleibt
  # sichtbar via Token-Counts, nur die Geld-Spalte zeigt 0).
  @spec cost_for(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def cost_for(provider, model, input_tokens, output_tokens)
      when is_binary(provider) and is_binary(model) do
    case lookup_model(provider, model) do
      nil ->
        0.0

      %{cost_input_per_1m: in_per_1m, cost_output_per_1m: out_per_1m} ->
        input_tokens / 1_000_000 * in_per_1m + output_tokens / 1_000_000 * out_per_1m
    end
  end

  # Issue #463: `pricing/1` pro Cloud-Backend statt der alten statischen
  # `models/0`-Liste. Die Modell-AUSWAHL kommt jetzt live aus `list_models/0`
  # gegen den jeweiligen Provider — die Pricing-Tabelle bleibt hardcoded
  # (small, ändert sich selten, sauberes 0.0-Fallback bei unbekanntem
  # Modell).
  defp lookup_model("anthropic", model), do: Worker.LLM.Anthropic.pricing(model)
  defp lookup_model("openai", model), do: Worker.LLM.OpenAI.pricing(model)
  defp lookup_model("google", model), do: Worker.LLM.Google.pricing(model)
  defp lookup_model(_, _), do: nil

  @doc """
  Issue #177: stage-atom → "stageN"-String für das LLMCallBilled-Event-Payload.
  Seit #783 Phase 2 bedeuten "stage3"/"stage4" wieder etwas — Verify/Render
  statt der Chain-Ära-Bedeutung (Epos/Chronik, entfernt mit #786). Historische
  Spend-Events mit diesen Labels aus der Zeit VOR diesem PR meinten die alte
  Bedeutung — zeitstempel-bewusst lesen, falls über den Cutover hinweg
  ausgewertet wird.
  """
  @spec stage_label(atom()) :: String.t()
  def stage_label(:summary), do: "stage2"
  def stage_label(:verify), do: "stage3"
  def stage_label(:render), do: "stage4"
  def stage_label(:transcribe), do: "stage1"
  def stage_label(other), do: Atom.to_string(other)
end
