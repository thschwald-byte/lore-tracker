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
    local: Worker.LLM.Local
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
end
