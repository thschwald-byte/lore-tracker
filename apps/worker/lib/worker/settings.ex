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
    # Stage 1 (transcribe) has its own whisper-cli config; no Ollama model.
    model_stage1: nil,
    # Reasonable bootstrap defaults — fresh installs work without manual
    # /settings configuration. Override per worker via the settings UI.
    model_stage2: "qwen2.5:7b",
    model_stage3: "qwen2.5:7b",
    model_stage4: "qwen2.5:7b",
    # Stage 1 transcription mode: :batch (post-session only), :live
    # (VAD-gated streaming during the session, with a final batch re-pass
    # on stop), or :listen (dev-only — capture browser tab/system audio
    # instead of the mic, useful for reproducible Whisper-quality testing
    # with known input). Frozen per-session at AudioBuffer.open_session.
    transcribe_mode: :batch
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
