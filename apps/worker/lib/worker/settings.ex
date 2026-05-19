defmodule Worker.Settings do
  @moduledoc """
  Worker-local settings (backend choices, model names, endpoints).

  Settings are NOT replicated through the event log — each worker has its
  own hardware/installation and picks its own backends. They live as keys
  in `worker_state` and are updated via `Hub.Commands.update_worker_settings/2`
  (channel push, not event).

  Defaults:
    :backend_stage1 = :local  # transcribe (M10-BMP runs whisper-cli directly,
                              # this setting is only consulted by
                              # Worker.LLM.transcribe/2 if anything ever calls it)
    :backend_stage2 = :local  # summary
    :backend_stage3 = :local  # epos
    :backend_stage4 = :local  # chronik
    :local_endpoint = "http://localhost:11434"   # Ollama default
    :model_stage{n} = nil     # backend-specific
  """

  @defaults %{
    backend_stage1: :local,
    backend_stage2: :local,
    backend_stage3: :local,
    backend_stage4: :local,
    local_endpoint: "http://localhost:11434",
    model_stage1: nil,
    model_stage2: nil,
    model_stage3: nil,
    model_stage4: nil
  }

  def defaults, do: @defaults

  @spec get(atom(), term()) :: term()
  def get(key, fallback \\ nil) when is_atom(key) do
    case Worker.Repo.get_state(key) do
      nil -> Map.get(@defaults, key, fallback)
      v -> v
    end
  end

  @spec put(atom(), term()) :: :ok
  def put(key, value) when is_atom(key), do: Worker.Repo.put_state(key, value)

  @spec put_many(map() | keyword()) :: :ok
  def put_many(kv), do: Worker.Repo.put_state_many(kv)

  @doc "Snapshot of all settings (defaults overlaid with persisted values)."
  def snapshot do
    Enum.into(@defaults, %{}, fn {k, default} -> {k, get(k, default)} end)
  end
end
