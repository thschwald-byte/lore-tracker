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
    :backend_stage2 = :local  # Extraktion (Wahrheitsbild)
    :backend_stage3 = :local  # Verify (Grounding + Attribution)
    :backend_stage4 = :local  # Render-Resümee
    :backend_stage5 = :local  # Render-Epos (Kapitel)

  Issue #783 Phase 2: Extraktion/Verify/Render hatten sich bis #786 EINEN
  LLM-Slot geteilt — jeder Schritt hat jetzt sein eigenes Backend + Modell
  (`model_stage{2,3,4}_<backend>`). Die früheren `judge_model`/`render_model`-
  Overrides (#783 Phase 1, gleiches Backend, nur anderes Modell) sind mit der
  vollen Trennung entfernt.

  ## Single-Source-Map (`@settings`) — Whitelist + Default-Werte entkoppelt

  `@settings` ist die **eine** Quelle der Wahrheit: Key → Default-Wert | `nil` |
  Sentinel `:no_default`. Daraus abgeleitet (kein Zwei-Listen-Drift):

    * `@known_keys` = `Map.keys/1` → die **Write-Whitelist** (`rpc.ex` prüft
      eingehende Settings-Keys dagegen; unbekannte werden verworfen).
    * `@defaults`   = alle Einträge mit `v != :no_default` → nur **echte**
      Default-Werte (was `get/2` ausliefert).

  `:no_default` = der Key ist schreibbar, wird aber OHNE Default ausgeliefert
  (muss pro Worker konfiguriert werden; unkonfiguriert → fail-loud am
  Nutzungsort statt spätem, kryptischem Fehler). Betrifft die „Phantom"-
  Defaults, die auf eine *installierte* Ressource zeigten: `local_endpoint`,
  `whisper_bin`, `ffmpeg_bin`, `model_stage2_local` (+ die Cloud-Modell-
  Keys, die ohnehin nie einen sinnvollen Default hatten).

  `nil` = intendierter nil-Default (Feature aus / ENV-Fallback), z.B.
  `anthropic_api_key` (→ `System.get_env`), `whisper_model`
  (→ `whisper_model_fallback/0`), `*_sidecar_url` (Feature aus).
  """

  @settings %{
    backend_stage1: :local,
    # Issue #783 Phase 2 (+ Nachtrag): die Wahrheitsbild-Schritte hatten sich
    # bis hierhin EINEN Backend-Slot geteilt (#786) — jetzt bekommt jeder
    # Schritt sein eigenes Backend + Modell: Stage 2 = Extraktion, Stage 3 =
    # Verify (Grounding + Attribution), Stage 4 = Render-Resümee, Stage 5 =
    # Render-Epos (Kapitel). Resümee und Epos-Kapitel liefen anfangs noch
    # zusammen auf Stage 4 — Nachtrag trennt sie, weil ein Resümee (kurz,
    # faktentreu) andere Modell-Anforderungen hat als ein Epos-Kapitel
    # (länger, literarischer). Struktur jeder Stage ist identisch (Backend +
    # pro-Backend-Modelle + Endpoint + Sampling) — Stage 2 unten als Vorlage,
    # 3/4/5 spiegeln sie 1:1.
    backend_stage2: :local,
    # :no_default (Phantom-Cleanup): kein Ollama-Endpoint hartcodieren. Fehlt er,
    # scheitert Worker.LLM.Local fail-loud mit :no_local_endpoint_configured statt
    # eine "nil/api/…"-URL zu bauen. Universeller Wert wäre "http://localhost:11434".
    local_endpoint: :no_default,

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
    # Issue #690: Cold-Start-Pull-Antworten (pull_response / pull_response_global)
    # werden in Byte-Budget-Chunks aufgeteilt, damit ein grosser Sync (z.B. 15110
    # Events) nicht als EIN WebSocket-Frame durch den Gigalixir/Google-Cloud-Proxy
    # geht (der killt zu grosse Frames mit 502 → Endlos-Retry, frischer Worker bleibt
    # leer). 200 KB liegt grosszuegig unter jeder plausiblen Frame-Grenze und haelt
    # die Chunk-Zahl klein. Pro Worker via Worker.Settings.put/2 tunbar.
    pull_chunk_max_bytes: 200_000,
    # Issue #693: Intervall des periodischen Sync-Ticks im HubClient. Jeder Tick
    # pullt alle Scopes (global + jede lokale Campaign) ab ihrer Sync-Wasserlinie
    # (Worker.SyncWatermark) — deckt Quelle-war-offline, verlorene Pull-Responses
    # und verlorene Live-Events (Regeneration binnen eines Ticks). Steady-State-
    # Kosten: 1 Mini-Request pro Scope/Tick, Antwort meist leer.
    sync_tick_ms: 60_000,
    # Stage 1 (transcribe) has its own whisper-cli config; no Ollama model.
    model_stage1: nil,

    # Issue #451 (Track C): pro-Backend-Modellwahl je Stage. Jedes Backend
    # behält seine eigene Modellwahl — ein Backend-Wechsel in /settings
    # verliert die anderen Configs nicht mehr. Aktiv ist immer nur das Modell
    # des in `backend_stage{n}` gewählten Backends (Lookup: `model_for/2`).
    #
    # Die un-suffixierten LEGACY-Keys `model_stage{2,3,4}` sind seit dem
    # Phantom-/Legacy-Cleanup (#784) ENTFERNT — kein Default, nicht schreibbar
    # (nicht in @known_keys). Ein Bestandsworker mit persistiertem Legacy-Wert
    # wird beim Boot gewarnt (Worker.Application.warn_stale_legacy_model_settings!).
    #
    # :no_default (Phantom-Cleanup): kein Modellname hartcodieren — ein
    # unkonfiguriertes Modell scheitert fail-loud (:no_model_configured) statt
    # still "qwen2.5:7b" anzunehmen (das für ein Cloud-Backend sogar an die
    # falsche API ginge). Frische Installs setzen ihr Modell in /settings.
    model_stage2_local: :no_default,

    # Issue #736: Ollama-Endpoint pro Stage-Local-Backend.
    #   :generate — POST /api/generate (Default, bisheriges Verhalten). Passt
    #               für nicht-reasoning-Modelle (qwen2.5, command-r, mistral).
    #   :chat     — POST /api/chat mit messages: [{role: "user", content: prompt}].
    #               Für Reasoning-Modelle (gpt-oss, gemma4, qwen3-a3b), deren
    #               Thinking-/Reasoning-Block bei /api/generate + Format-Constraint
    #               den `response`-String leert. Bei :chat liegt der Reasoning-
    #               Block in `message.thinking`, das eigentliche JSON in
    #               `message.content` — Format-Schema wirkt dort korrekt.
    # Der Reasoning-Block selbst wird verworfen (nicht persistiert, nicht geloggt).
    model_stage2_local_endpoint: :generate,
    # :no_default statt nil (Punkt 5, Konsistenz): ein ungesetztes Cloud-Modell
    # IST kein intendierter Default. Verhalten identisch (model_for liefert bei
    # beiden nil → fail-loud), aber source/1 unterscheidet jetzt sauber
    # :default (echter Wert) von :unset (nie sinnvoll gedefaulted).
    model_stage2_anthropic: :no_default,
    model_stage2_openai: :no_default,
    model_stage2_google: :no_default,

    # Issue #783 Phase 2: Verify (Stage 3) — Backend + pro-Backend-Modelle,
    # Struktur identisch zu Stage 2 oben. Bestandsworker bekommen diese Werte
    # beim ersten Boot nach dem Update automatisch von Stage 2 übernommen
    # (`Worker.Application.migrate_stage2_to_stage34_if_unset!/0`) — kein
    # stiller Hard-Break, wenn der GM nichts geändert hat.
    backend_stage3: :local,
    model_stage3_local: :no_default,
    model_stage3_local_endpoint: :generate,
    model_stage3_anthropic: :no_default,
    model_stage3_openai: :no_default,
    model_stage3_google: :no_default,
    ctx_stage3: 8192,
    # #755 Reopen: die Stage-3-Sampling-Knöpfe wirken jetzt tatsächlich auf
    # die Verify-Judge-Calls (Grounding + Attribution in verify.ex) — vorher
    # hartcodiert temperature:0, UI-Werte still ignoriert. Defaults auf
    # Judge-Determinismus (0.0/1.0/1.0 = greedy, keine Penalty), damit ein
    # unkonfigurierter Worker exakt das bisherige Urteil-Verhalten behält.
    temperature_stage3: 0.0,
    top_p_stage3: 1.0,
    repeat_penalty_stage3: 1.0,

    # Issue #783 Phase 2: Render-Resümee (Stage 4) — Backend + pro-Backend-
    # Modelle, Struktur identisch zu Stage 2/3.
    backend_stage4: :local,
    model_stage4_local: :no_default,
    model_stage4_local_endpoint: :generate,
    model_stage4_anthropic: :no_default,
    model_stage4_openai: :no_default,
    model_stage4_google: :no_default,
    ctx_stage4: 8192,
    temperature_stage4: 0.15,
    top_p_stage4: 0.7,
    repeat_penalty_stage4: 1.1,

    # Issue #783 Phase 2 (Nachtrag): Render-Epos (Stage 5) — eigenes Backend
    # + Modell, getrennt von Stage 4 (Resümee). Bestandsworker bekommen diese
    # Werte beim ersten Boot nach dem Update von Stage 4 übernommen
    # (`Worker.Application.migrate_stage4_to_stage5_if_unset!/0`).
    backend_stage5: :local,
    model_stage5_local: :no_default,
    model_stage5_local_endpoint: :generate,
    model_stage5_anthropic: :no_default,
    model_stage5_openai: :no_default,
    model_stage5_google: :no_default,
    ctx_stage5: 8192,
    temperature_stage5: 0.15,
    top_p_stage5: 0.7,
    repeat_penalty_stage5: 1.1,

    # LLM-Context-Größe (Tokens) für Stage 2 (Extraktion).
    ctx_stage2: 8192,

    # Issue #683: eigenes (kleineres) Chunk-Budget für die Fakt-Extraktion. Die
    # Extraktion erzeugt pro Input-Token DICHTEREN Output als ein Resümee (viele
    # Fakten je mit claim+refs) → ein 6000-Token-Chunk timeoutet beim starken
    # Extraktor in der Generierung. Kleinere Chunks (mehr davon) halten jeden
    # Map-Chunk-Call schnell + zuverlässig.
    extract_chunk_tokens: 3500,

    # Issue #763: Output-Deckel pro Extraktions-Chunk-Call. Die #683-Begründung
    # gegen das Stage-2-Cap (400 würde den Fakt-JSON abschneiden) bleibt richtig
    # — aber OHNE Obergrenze frisst ein degenerierter Generier-Loop den vollen
    # Timeout+Retry-Zyklus (~55 min/Chunk im Free-Seattle-Lauf, 2 von 11 Chunks).
    # 4096 ≈ 3× legitimer Chunk-Output (800–1500 Tokens) → kappt Degeneration
    # nach ~3 min; der gekappte Output wäre ohnehin :parse_failed.
    extract_num_predict_cap: 4096,

    # Sampling-Knöpfe gegen LLM-Halluzinationen (Issue #11; seit #783 Phase 2
    # pro Stage — Extraktion/Verify/Render haben je eigene Werte, s. Stage 3/4
    # oben). Niedrige Temperatur + moderates top_p + repeat_penalty drücken
    # die Phantasie-Quote. Per Worker überschreibbar. Kein num_predict-Key:
    # die Extraktion deckelt via extract_num_predict_cap (#763), Verify-Judge-
    # Calls setzen temperature: 0 im Code, Render terminiert selbst.
    temperature_stage2: 0.15,
    top_p_stage2: 0.7,
    repeat_penalty_stage2: 1.1,

    # Stage 1 (Whisper) — vorher per Application.get_env(:worker, …) versteckt,
    # jetzt UI-tunbar pro Worker.
    # :no_default (Phantom-Cleanup): kein "whisper-cli" hartcodieren. Fehlt das
    # Binary, scheitert Stage 1 fail-loud mit whisper_binary_missing (Vokabular
    # kennt classify_stage1_error/1 schon) statt Port.open(nil)-Crash.
    whisper_bin: :no_default,
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
    # Issue #704: 120_000 riss 2h-Tracks (~100 MB webm) → Spur still verloren.
    # Jetzt Floor 15 min; der Voll-Track-to_wav skaliert zusätzlich dynamisch
    # mit der Dateigröße (ffmpeg_timeout_per_mb_ms). ffmpeg ist I/O-bound und
    # braucht selbst für 2h nur wenige Minuten — großzügiger Floor ist billig.
    ffmpeg_timeout_ms: 900_000,
    ffmpeg_timeout_per_mb_ms: 5_000,
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
    # Default seit #675 (Free-Seattle-Reproduktion): :llm_judge. NLI liefert auf
    # deutschen Real-World-Sessions ~0/N grounded (abstraktive Fakten fallen
    # unter die entailment-Schwelle, Decoys entailen mit ~0.96 — beides per
    # Schwelle nicht trennbar). LLM-Judge liefert auf denselben Sessions
    # 30-50 % grounded (qwen2.5:7b) bei FPR ~0 (#677-Messung + #675-Reprise).
    grounding_method: :llm_judge,

    # Issue #815: Nachbar-Utterances-Fenster für Grounding/Attribution-Judge
    # (verify.ex restrict_to_refs/2) — je zitiertem source_ref werden ±N
    # Nachbar-Turns im Transkript zusätzlich in den Judge-Kontext gegeben.
    # Reiner Kontext-Zugewinn: ändert NICHTS an den gespeicherten source_refs
    # oder der Extraktions-Prompt-Disziplin ("so wenige wie möglich" bleibt).
    # 0 = altes Verhalten (exakt nur die zitierten Refs). Tunbar via
    # mix lore.eval.verify (TPR hoch, FPR bei Decoys muss 0 bleiben).
    grounding_context_window: 1,

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
    # :no_default (Phantom-Cleanup): kein "ffmpeg" hartcodieren. Fehlt das
    # Binary, scheitert Stage 1 fail-loud mit ffmpeg_binary_missing statt
    # Port.open(nil)-Crash.
    ffmpeg_bin: :no_default,
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

    # Issue #704: gescheiterte Einzel-Spuren (z.B. ffmpeg-Timeout auf einem
    # langen Track) werden HIER HIN kopiert — BEWUSST außerhalb `audio_dir`,
    # damit der Crash-Recovery-Scan sie NICHT als Session mis-scannt und die
    # ganze Session re-runt (das würde erfolgreiche Spuren duplizieren, frische
    # UUIDv7-Utterances + Stage-2-4-Re-Trigger). So bleibt die Roh-webm für
    # einen gezielten manuellen Rerun (`Transcribe.run/2`) erhalten. Wächst
    # monoton (wie audio_done_dir) — Prune-Policy bei Bedarf später.
    audio_failed_dir: "/tmp/lore_audio_failed",

    # Issue #605: Retention für die `pipeline_errors`-Tabelle. Worker.PipelineErrorLog
    # haelt die letzten N Errors (sortiert nach occurred_at desc), pruned den Rest
    # einmal beim Boot + dann alle `:pipeline_errors_prune_interval_ms`. Default
    # 1000 reicht für /admin/errors-Diagnostik bei mehrtaegigem Daemon-Lauf ohne
    # nennenswerten Mnesia-Bloat.
    pipeline_errors_keep_n: 1000,
    pipeline_errors_prune_interval_ms: 3_600_000
  }

  # Abgeleitet aus @settings — kein Zwei-Listen-Drift (s. @moduledoc).
  # @known_keys = Write-Whitelist; @defaults = nur echte Default-Werte.
  @known_keys @settings |> Map.keys() |> MapSet.new()
  @defaults for {k, v} <- @settings, v != :no_default, into: %{}, do: {k, v}

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

  @doc "Nur die echten Default-Werte (`:no_default`-Keys ausgeschlossen)."
  def defaults, do: @defaults

  @doc "Die Write-Whitelist: alle gültigen Setting-Keys (auch `:no_default`)."
  def known_keys, do: @known_keys

  @doc """
  Woher der effektive Wert von `key` kommt:

    * `:store`   — persistiert im `worker_state` (überschreibt jeden Default)
    * `:default` — nicht persistiert, aber `@settings` hält einen echten Default
    * `:unset`   — gültiger Key ohne persistierten Wert UND ohne Default
      (`:no_default`) → `get/2` liefert `nil`, Nutzung scheitert fail-loud

  Diagnose-Einstieg für „welcher Wert gilt und warum" — ersetzt die frühere
  `Settings.all`-Lücke (die als `:undef` Teil des Schmerzes war).
  """
  @spec source(atom()) :: :store | :default | :unset
  def source(key) when is_atom(key) do
    cond do
      Worker.Repo.get_state(key) != nil -> :store
      Map.has_key?(@defaults, key) -> :default
      true -> :unset
    end
  end

  @llm_backends [:local, :anthropic, :openai, :google]

  @doc """
  Issue #451 (Track C), erweitert #783 Phase 2 (+ Nachtrag): das aktive
  Modell für Stage `n` (2=Extraktion, 3=Verify, 4=Render-Resümee,
  5=Render-Epos) unter Backend `backend`.

  Auflösung (seit #784, Legacy-`model_stage{n}` entfernt):

  1. persistierter pro-Backend-Key `model_stage{n}_{backend}`
  2. dessen Default aus `@settings` (für die per-Backend-Keys `:no_default`
     → `nil` → fail-loud am Nutzungsort: `Worker.LLM.Local` meldet
     `:no_model_configured`, statt still ein hartcodiertes Modell anzunehmen)

  Leere Strings zählen als nicht gesetzt. Unbekanntes Backend → `nil`.
  """
  @spec model_for(2..5, atom() | String.t()) :: String.t() | nil
  def model_for(n, backend) when n in 2..5 do
    case normalize_backend(backend) do
      nil ->
        nil

      b ->
        per_key = :"model_stage#{n}_#{b}"

        blank_to_nil(Worker.Repo.get_state(per_key)) ||
          Map.get(@defaults, per_key)
    end
  end

  @doc """
  Der Settings-Key, den `model_for/2` für (Stage, Backend) liest — also der
  Key, auf den Schreiber (Probelauf-Sweeps, Box-Save, Heuristik) schreiben
  müssen, damit ihr Wert gewinnt. Unbekanntes/`nil`-Backend → der Local-Key
  (sicherer Default statt des entfernten Legacy-Keys).
  """
  @spec model_key(2..5, atom() | String.t()) :: atom()
  def model_key(n, backend) when n in 2..5 do
    case normalize_backend(backend) do
      nil -> :"model_stage#{n}_local"
      b -> :"model_stage#{n}_#{b}"
    end
  end

  defp normalize_backend(b) when b in @llm_backends, do: b

  defp normalize_backend(b) when is_binary(b) do
    Enum.find(@llm_backends, fn a -> Atom.to_string(a) == b end)
  end

  defp normalize_backend(_), do: nil

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(other), do: other

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

  @doc """
  Effective-View aller Settings: `@defaults` überlagert mit dem `worker_state`.
  Iteriert `@known_keys` (nicht `@defaults`), damit `:no_default`-Keys weiter
  — als `nil` — im Snapshot erscheinen (der Settings-Snapshot speist u.a. die
  Modellfelder der UI; fielen sie raus, verschwänden die Eingabefelder-Werte).

  Der Diagnose-Einstieg für „welcher Wert gilt"; `source/1` sagt zusätzlich,
  ob er aus Store, Default oder gar nicht kommt.
  """
  def snapshot do
    Enum.into(@known_keys, %{}, fn k -> {k, get(k)} end)
  end
end
