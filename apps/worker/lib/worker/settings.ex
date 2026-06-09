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

    # Issue #510: Cloud-API-Keys pro Backend. nil = nicht konfiguriert →
    # Cloud-Backend lookt zuerst Settings, dann fällt auf System.get_env/1
    # zurück (Backward-Compat für CLI-User die das so weiter nutzen).
    # Keys werden NIE im Snapshot durchgereicht — Worker.Repo.snapshot/1
    # liefert nur den Status ("set" / nil).
    anthropic_api_key: nil,
    openai_api_key: nil,
    gemini_api_key: nil,
    # HTTP-Timeout für Ollama-Calls in `Worker.LLM.Local`. Faustregel:
    #   - 7B-Modell:   2 min reichen (kann auf 120_000 runter)
    #   - 13B–14B:     5–10 min
    #   - 30B+ (qwen3, command-r, gemma4:31b): 15–20 min bei langem Stage-3-
    #     Prompt (alle Resümees aneinandergehängt). Default 20 Minuten —
    #     kürzer macht CampaignReplay anfällig für Avalanches (Issue #118).
    http_timeout_ms: 1_200_000,
    # Stage 1 (transcribe) has its own whisper-cli config; no Ollama model.
    model_stage1: nil,
    # Reasonable bootstrap defaults — fresh installs work without manual
    # /settings configuration. Override per worker via the settings UI.
    model_stage2: "qwen2.5:7b",
    model_stage3: "qwen2.5:7b",
    model_stage4: "qwen2.5:7b",

    # LLM-Context-Größe pro Stage (Tokens). Stage 3 braucht mehr weil
    # mehrere Resümees zusammen kommen.
    ctx_stage2: 8192,
    ctx_stage3: 16384,
    ctx_stage4: 8192,

    # Issue #651 (Wahrheitsbild, Phase C): Pipeline-Modus.
    #   :chain        — die bestehende Prosa-Kette (Stage 2→3→4). Default.
    #   :wahrheitsbild — Extraktion → Verify → Geschwister-Render (Resümee/
    #                    Timeline/Epos aus verifizierten Fakten).
    # Default bleibt :chain bis der Eval (#647, command-r) belegt, dass
    # :wahrheitsbild die verbesserte Chain-Baseline schlägt (+ Tom-OK).
    pipeline_mode: :chain,

    # Issue #417: Ziel-Token-Budget für den Transkript-Anteil EINES Map-Chunks
    # in Stage 2 (Resümee). Lange Sessions (4 h ≈ 3.000–7.000 Utterances)
    # sprengen sonst ctx_stage2 → Ollama trunkiert still den Transkript-Anfang.
    # Überschreitet das gerenderte Transkript dieses Budget, schaltet Stage 2 auf
    # Map-Reduce um (pro Chunk ein Teil-Resümee, dann reduzieren). Bewusst unter
    # ctx_stage2=8192, damit Prompt-Gerüst + Output Headroom haben. Analog
    # http_timeout_ms per Worker via Worker.Settings.put/2 tunbar.
    stage2_chunk_tokens: 6000,

    # Issue #683: eigenes (kleineres) Chunk-Budget für die Fakt-Extraktion. Die
    # Extraktion erzeugt pro Input-Token DICHTEREN Output als ein Resümee (viele
    # Fakten je mit claim+refs) → ein 6000-Token-Chunk timeoutet beim starken
    # Extraktor in der Generierung. Kleinere Chunks (mehr davon) halten jeden
    # Map-Chunk-Call schnell + zuverlässig.
    extract_chunk_tokens: 3500,

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
    whisper_lang: "de",
    # Pfad zu einem Silero-VAD-`.bin` (z.B. `ggml-silero-v5.1.2.bin`).
    # Default `nil` = aus. Wenn gesetzt: VAD-Pre-Segmentierung vor Whisper im
    # Batch-Pfad (das WAV wird
    #     anhand von Stille in Sätze gesplittet, jeder Slice einzeln durch
    #     whisper-cli). ⚠️ Schlechte Kombination mit `whisper_initial_prompt`
    #     — bei kurzen Slices dominiert der Prompt und Whisper halluziniert
    #     Vokabular aus dem Prompt direkt ins Transkript. Wer VAD-Batch
    #     nutzt, sollte `whisper_initial_prompt` auf `""` setzen.
    whisper_vad_model: nil,
    # Issue #399: Server-side Stille-Watchdog. Der Worker prüft im Sweep
    # (alle ~2s) pro Streamer den letzten Chunk-Timestamp. Bleibt ein
    # discord_id länger als diese Schwelle ohne Audio-Chunk (Browser-Crash,
    # eingefrorener Tab, defekte Permission-Resync), wird ein
    # `streamer_silent`-pipeline_status an alle Hub-LVs broadcasted und
    # bei Recovery analog `streamer_recovered`. Banner in der CampaignLive
    # ist server-getrieben — überlebt damit Browser-Crashes des Streamers,
    # die der Client-Watchdog (record_mic.js SILENCE_LIMIT_MS) nicht
    # erkennen kann. Default 5 min — analog zum Client-Watchdog.
    silence_alert_threshold_ms: 300_000,

    # Halluzinations-Unterdrückung: Segmente unter no_speech_thold werden als
    # Stille gewertet und weggelassen. entropy_thold verwirft chaotischen Text
    # (Whisper ist sich selbst nicht einig). logprob_thold verwirft Segmente
    # mit zu niedriger Vorhersage-Konfidenz.
    whisper_no_speech_thold: 0.5,
    whisper_entropy_thold: 2.0,
    whisper_logprob_thold: -0.7,
    # ffmpeg-Filterchain vor Whisper. highpass schneidet Tieffrequenz-Brummen
    # weg; loudnorm normalisiert leise Sprecher auf -16 LUFS damit Whisper
    # nicht auf stillen Passagen halluziniert. Leerer String = kein Filter.
    whisper_audio_filter: "highpass=f=100,loudnorm=I=-16:TP=-1.5:LRA=11",
    # Initial Prompt für whisper-cli (--prompt) — RPG-Vokabular damit
    # „Initiative" nicht zu „Demonstrative" und „W20" nicht zu „wie 20" wird.
    # Bewusst KEINE spielerspezifischen Namen — nur generisches Fachvokabular.
    # Empirisch gemessen: „Initiative"+„W20" werden mit diesem Prompt korrekt
    # transkribiert, ohne ist beides fehlerhaft. Leerer String = kein Prompt.
    whisper_initial_prompt:
      "Pen-und-Paper-Rollenspiel. Würfel: W4, W6, W8, W10, W12, W20, W100. " <>
        "Begriffe: Initiative, Trefferpunkte, Lebenspunkte, Rüstungsklasse, " <>
        "Rettungswurf, Zauberspruch, Spielleiter, Kurzschwert, Langschwert, " <>
        "Streitaxt, Kettenhemd, Schild, Goblin, Ork, Troll, Drache, Elf, Zwerg, " <>
        "Halbling, Magier, Krieger, Schurke, Kleriker.",
    # Segment-Länge limitieren damit Whisper nicht ganze Absätze ohne
    # Pause zu einem Mega-String verschmilzt (z.B. zwei Sätze →
    # „kurzschwertbegreifenden"). 0 = unbegrenzt (Whisper-Default).
    whisper_max_len: 120,
    # An Wortgrenzen statt an Tokens splitten — sauberere Outputs.
    whisper_split_on_word: true,

    # Issue #470: Prozess-Timeouts (ms) für die externen Stage-1-Tools.
    # System.cmd hat selbst KEINEN Timeout — ein hängender Prozess (GPU-
    # Deadlock, korrupte WAV, ROCm-Stall) würde sonst den einzigen GpuQueue-Slot
    # dauerhaft blockieren und die gesamte Transkription/Pipeline lahmlegen. Bei
    # Überschreitung wird der Prozess hart gekillt, der Slot frei, der Fehler als
    # stage1-Failure geloggt. whisper großzügig (lange Sessions / große Modelle),
    # ffmpeg + VAD knapper (laufen normalerweise in Sekunden). Pro Worker via
    # Worker.Settings.put/2 tunbar, analog http_timeout_ms / diarization_timeout_ms.
    whisper_timeout_ms: 600_000,
    ffmpeg_timeout_ms: 120_000,
    vad_timeout_ms: 120_000,

    # Issue #11 Phase 2: NLI-Sidecar für Faithfulness-Scoring.
    # Auf nil lassen wenn kein Sidecar läuft — Worker überspringt das Scoring
    # graceful und publiziert kein SessionFaithfulnessScored-Event.
    faithfulness_sidecar_url: nil,

    # Issue #675: Schwellen für den Wahrheitsbild-Verify-Gate (verify.ex
    # nli_verify_one/2). Ein Fakt gilt als geerdet, wenn die NLI-entailment-
    # Wahrscheinlichkeit seines Claims `>= entail_min` UND die contradiction-
    # Wahrscheinlichkeit `<= max_contra` ist (statt des früheren strikten
    # Argmax-"entailment"-Gates, das deutsche Paare durchweg ablehnte). Tunbar
    # ohne Redeploy; via `mix lore.eval.verify --samples N` gegen das Skandal-
    # Fixture kalibrieren (TPR auf echten Fakten hoch, FPR auf Decoys ~0).
    faithfulness_verify_entail_min: 0.5,
    faithfulness_verify_max_contra: 0.5,

    # Issue #677: Grounding-Methode des Verify-Gates (verify.ex ground_one/2).
    # :nli = NLI-Entailment via Sidecar (faithfulness_verify_*-Schwellen);
    # :llm_judge = LLM-as-Judge (Stage-Modell beurteilt inhaltliche Stützung).
    # Default :nli, bis mix lore.eval.verify belegt, dass :llm_judge die TPR hebt
    # ohne FPR (Decoys) zu heben (#675-Befund: NLI scheitert an abstraktiven
    # Fakten + Decoy-Präzision, beides per Schwelle nicht trennbar).
    grounding_method: :nli,

    # Issue #677: Modell für den LLM-as-Judge-Grounding-Call. nil = model_stage2
    # (derselbe wie der Extraktor). Erlaubt einen stärkeren Judge als den Extraktor
    # (die Judge-Prompts sind kurz — ein großes Modell ist hier schnell, kein
    # Extraktions-Timeout-Risiko).
    judge_model: nil,

    # Issue #19: Diarisierungs-Sidecar (pyannote 3.3.2) für Single-Source-
    # Aufnahmen. nil = kein Sidecar → :single_source-Sessions schlagen mit
    # {:error, :sidecar_offline} fehl. URL inkl. Schema+Port, z.B.
    # "http://localhost:8766". Der HF-Token wird NICHT hier gehalten — er
    # geht als Env-Var HUGGINGFACE_TOKEN an den uvicorn-Prozess (systemd
    # unit), weil das Modell beim Sidecar-Start geladen wird.
    diarization_sidecar_url: nil,
    # Diarisierung läuft auf dem vollen Session-Audio — Minuten bei langen
    # Aufnahmen. Großzügiges Timeout (Default 10 min).
    diarization_timeout_ms: 600_000,
    # Optionaler num_speakers-Hint-Override. nil = aus Campaign-Member-Count
    # ableiten. pyannote nutzt den Hint um Clustering-Fehler zu reduzieren
    # (TTRPG-Audio hat hohe Confusion-Rate, arXiv 2502.12714).
    diarization_num_speakers: nil,

    # System-Pfade — vom Worker-OS abhängig, deshalb pro Worker.
    ffmpeg_bin: "ffmpeg",
    audio_dir: "/tmp/lore_audio",
    # Issue #466/#467: nach erfolgreicher Transkription wird das Session-Audio-
    # Dir aus `audio_dir` HIER HIN verschoben (statt gelöscht). Damit bleibt der
    # Live-`audio_dir` klein (der Crash-Recovery-Scan beim Worker-Start findet
    # dort nur noch tatsächlich abgestürzte, un-transkribierte Sessions →
    # eindeutig), und die Rohaudios bleiben für spätere Auswertung erhalten
    # (wichtig in der Testphase). `nil` = stattdessen löschen (Disk-Reclaim,
    # wenn keine Aufbewahrung mehr nötig). Das Archiv selbst wächst monoton —
    # bei Bedarf später eine Retention/Prune-Policy ergänzen oder manuell leeren.
    audio_done_dir: "/tmp/lore_audio_done",

    # Issue #289 Phase 2: Anzahl Retries bei Format-Fehler in der LLM-
    # Pipeline (heute nur Stage 2 — Stage 4 hat eigene hardcoded Retry-
    # Logik). 0 = Retry deaktiviert (Pre-Phase-2-Verhalten), 1 = ein Retry
    # mit Korrektur-Prompt bei Parse-Fallback. Höhere Werte erhöhen
    # LLM-Kosten linear ohne empirisch wachsenden Erfolg → Default 1.
    pipeline_max_format_retries: 1,

    # Issue #289 Phase 3: Self-Correction Loop (Worker.FormatCorrector).
    # Pflegt Rolling-Window der letzten N format_notes/Stage; bei Non-OK-
    # Rate > threshold wird temperature_stageN um step gesenkt — bis zu
    # temperature_min_stageN. 0er-Threshold = jede Beobachtung triggert
    # (nicht sinnvoll, nur für Tests).
    format_corrector_window_size: 10,
    format_corrector_threshold: 0.4,
    format_corrector_step: 0.05,
    temperature_min_stage2: 0.05,
    temperature_min_stage3: 0.05,
    temperature_min_stage4: 0.05,

    # Issue #605: Retention für die `pipeline_errors`-Tabelle. Worker.PipelineErrorLog
    # haelt die letzten N Errors (sortiert nach occurred_at desc), pruned den Rest
    # einmal beim Boot + dann alle `:pipeline_errors_prune_interval_ms`. Default
    # 1000 reicht für /admin/errors-Diagnostik bei mehrtaegigem Daemon-Lauf ohne
    # nennenswerten Mnesia-Bloat.
    pipeline_errors_keep_n: 1000,
    pipeline_errors_prune_interval_ms: 3_600_000
  }

  @doc """
  Voreinstellung für `:whisper_model`. Wird in Settings-Snapshot als
  Anzeige-Wert verwendet wenn der User noch nichts gesetzt hat — kann nicht
  in `@defaults` selbst stehen weil `Path.expand` zur Compile-Zeit auf der
  Build-Maschine evaluiert würde statt zur Laufzeit auf dem Worker.
  """
  def whisper_model_fallback do
    candidates = [
      "~/.cache/whisper/ggml-large-v3-turbo-german.bin",
      "~/.cache/whisper/ggml-large-v3-turbo.bin",
      "~/.cache/whisper/ggml-large-v3.bin",
      "~/.cache/whisper/ggml-medium.bin",
      "~/.cache/whisper/ggml-small.bin",
      "~/.cache/whisper/ggml-base.bin"
    ]

    Enum.find_value(candidates, Path.expand("~/.cache/whisper/ggml-base.bin"), fn path ->
      expanded = Path.expand(path)
      if File.exists?(expanded), do: expanded
    end)
  end

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
