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
    # HTTP-Timeout für Ollama-Calls in `Worker.LLM.Local`. 120 s war für
    # 7B-Modelle ausreichend, 30B-Modelle (qwen3, command-r) brauchen bei
    # langem Stage-3-Prompt (alle Resümees) deutlich länger und kippen sonst
    # mit `{:error, :timeout}`. Default 10 Minuten — User kann pro Worker
    # runter drehen wenn sie ein schnelles Modell verwenden.
    http_timeout_ms: 600_000,
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
    transcribe_mode: :batch,

    # LLM-Context-Größe pro Stage (Tokens). Stage 3 braucht mehr weil
    # mehrere Resümees zusammen kommen.
    ctx_stage2: 8192,
    ctx_stage3: 16384,
    ctx_stage4: 8192,

    # Sampling-Knöpfe pro Stage gegen LLM-Halluzinationen (Issue #11).
    # Niedrige Temperatur + moderates top_p + repeat_penalty drücken die
    # Phantasie-Quote. Per Worker via Worker.Settings.put/2 überschreibbar.
    # num_predict_stage4 = nil → kein Cap (JSON-Mode terminiert selbst).
    temperature_stage2: 0.15,
    temperature_stage3: 0.2,
    temperature_stage4: 0.1,
    top_p_stage2: 0.7,
    top_p_stage3: 0.7,
    top_p_stage4: 0.7,
    num_predict_stage2: 400,
    num_predict_stage3: 4000,
    num_predict_stage4: nil,
    repeat_penalty_stage2: 1.1,
    repeat_penalty_stage3: 1.1,
    repeat_penalty_stage4: 1.1,

    # Stage 1 (Whisper) — vorher per Application.get_env(:worker, …) versteckt,
    # jetzt UI-tunbar pro Worker.
    whisper_bin: "whisper-cli",
    whisper_model: nil,
    whisper_lang: "auto",
    whisper_vad_model: nil,
    # Halluzinations-Unterdrückung: Segmente unter no_speech_thold werden als
    # Stille gewertet und weggelassen. entropy_thold verwirft chaotischen Text
    # (Whisper ist sich selbst nicht einig). logprob_thold verwirft Segmente
    # mit zu niedriger Vorhersage-Konfidenz.
    whisper_no_speech_thold: 0.7,
    whisper_entropy_thold: 2.4,
    whisper_logprob_thold: -0.5,
    # ffmpeg-Filterchain vor Whisper. highpass schneidet Tieffrequenz-Brummen
    # weg; loudnorm normalisiert leise Sprecher auf -16 LUFS damit Whisper
    # nicht auf stillen Passagen halluziniert. Leerer String = kein Filter.
    whisper_audio_filter: "highpass=f=100,loudnorm=I=-16:TP=-1.5:LRA=11",

    # Issue #11 Phase 2: NLI-Sidecar für Faithfulness-Scoring.
    # Auf nil lassen wenn kein Sidecar läuft — Worker überspringt das Scoring
    # graceful und publiziert kein SessionFaithfulnessScored-Event.
    faithfulness_sidecar_url: nil,

    # System-Pfade — vom Worker-OS abhängig, deshalb pro Worker.
    ffmpeg_bin: "ffmpeg",
    audio_dir: "/tmp/lore_audio"
  }

  @doc """
  Voreinstellung für `:whisper_model`. Wird in Settings-Snapshot als
  Anzeige-Wert verwendet wenn der User noch nichts gesetzt hat — kann nicht
  in `@defaults` selbst stehen weil `Path.expand` zur Compile-Zeit auf der
  Build-Maschine evaluiert würde statt zur Laufzeit auf dem Worker.
  """
  def whisper_model_fallback, do: Path.expand("~/.cache/whisper/ggml-small.bin")

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
