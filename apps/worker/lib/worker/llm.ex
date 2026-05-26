defmodule Worker.LLM do
  @moduledoc """
  Stage-aware dispatch in front of `Worker.LLM.Backend` implementations.

  `complete(:summary, prompt)` reads `:backend_stage2` from `Worker.Settings`
  and routes to the matching backend module. Likewise for `:epos` (stage 3)
  and `:chronik` (stage 4). Transcription has its own backend setting
  (`:backend_stage1`) and lives in `transcribe/2`.
  """

  alias Worker.Settings

  @stage_to_setting %{
    transcribe: :backend_stage1,
    summary: :backend_stage2,
    epos: :backend_stage3,
    chronik: :backend_stage4
  }

  @backend_modules %{
    local: Worker.LLM.Local,
    anthropic: Worker.LLM.Anthropic,
    openai: Worker.LLM.OpenAI
    # :bundled registers here in M9b
  }

  @spec complete(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(stage, prompt, opts \\ []) do
    mod = backend_for(stage)
    mod.complete(prompt, Keyword.put_new(opts, :stage, stage))
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

  defp lookup_model("anthropic", model) do
    Enum.find(Worker.LLM.Anthropic.models(), fn m -> m.name == model end)
  end

  defp lookup_model(_, _), do: nil

  @doc """
  Issue #177: stage-atom → "stage2"/"stage3"/"stage4"/"transcribe"-String
  für das LLMCallBilled-Event-Payload.
  """
  @spec stage_label(atom()) :: String.t()
  def stage_label(:summary), do: "stage2"
  def stage_label(:epos), do: "stage3"
  def stage_label(:chronik), do: "stage4"
  def stage_label(:transcribe), do: "stage1"
  def stage_label(other), do: Atom.to_string(other)
end
