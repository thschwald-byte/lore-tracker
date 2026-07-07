defmodule HubWeb.KnownIssues do
  @moduledoc """
  Issue #68 (Phase 2): Mappt klassifizierte `error_type`-Strings aus
  `PipelineErrorLogged`-Events auf human-readable Hinweise. Wird vom
  /admin/errors-LV pro Eintrag aufgerufen und in der expandierten Reihe
  angezeigt.

  Whitelist — unbekannte Types fallen auf `nil` zurück, dann zeigt das
  UI keinen Hint-Block.

  Phase 3 (#68 Folge-PR) bringt: docs/Troubleshooting.md mit langem
  Format + Retry-Buttons. Diese Hints hier sind die Kurzform.
  """

  @type hint :: %{
          required(:icon) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @doc """
  Liefert eine Hint-Map für den gegebenen `error_type`, oder `nil` wenn
  keiner gemappt ist. Context wird (bislang) nicht ausgewertet — Phase 3
  könnte z.B. den Cloud-Provider aus dem Context lesen, um konkretere
  Env-Var-Namen zu nennen.
  """
  @spec hint(String.t() | nil, map() | nil) :: hint() | nil
  def hint(error_type, context \\ %{})

  def hint("empty_chronik", _ctx) do
    %{
      icon: "⚠️",
      title: "Stage 4 lieferte keine Chronik-Einträge",
      body:
        "Das Modell hat auch nach Retry keine parsebaren Chronik-JSON-Einträge produziert. Bekannte Ursache (Issue #75): kleinere oder Thinking-Modelle (`qwen3:30b-a3b`, `qwen2.5:0.5b` bei langen Sessions) scheitern hier. Lösung: in /settings ein größeres Modell für Stage 4 wählen oder den `:http_timeout_ms` erhöhen."
    }
  end

  def hint("no_key_configured", ctx) do
    provider =
      case ctx do
        %{"provider" => p} when is_binary(p) -> String.upcase(p)
        _ -> "<PROVIDER>"
      end

    %{
      icon: "🔑",
      title: "Cloud-LLM: API-Key fehlt",
      body:
        "Der Worker hat keine `#{provider}_API_KEY` Env-Var. Setze sie im Worker-Start-Environment (`.env` neben dem Worker oder direkt vor `mix run`) und starte den Worker neu. Per Etappe 5b (#162) lebt der Key pro-Worker, nicht im Hub-Settings-UI."
    }
  end

  def hint("upstream_auth", _ctx) do
    %{
      icon: "🚫",
      title: "Cloud-LLM lehnte Auth ab (401/403)",
      body:
        "Der API-Key ist gesetzt, aber der Provider hat ihn verworfen. Prüfen: 1) Key ist nicht abgelaufen/widerrufen, 2) Key-Tier hat Zugriff auf das gewählte Modell, 3) Worker-Prozess sieht die richtige Env-Var (nicht versehentlich aus einer alten Shell-Session)."
    }
  end

  def hint("upstream_rate_limit", _ctx) do
    %{
      icon: "⏱️",
      title: "Cloud-LLM Rate-Limit erreicht (429)",
      body:
        "Der Provider drosselt. Worker macht bereits 2× exponentielles Backoff. Optionen: kurz warten + nochmal anstoßen, anderes Modell wählen, oder Per-User-Spend-Cap (#178) prüfen — bei großen Sweeps ist der Free-Tier schnell aufgebraucht."
    }
  end

  def hint("network_error", _ctx) do
    %{
      icon: "🌐",
      title: "Netzwerk-Fehler beim Cloud-LLM-Call",
      body:
        "Worker erreichte den Provider nicht (Timeout, DNS, Firewall). Lokal: Internet-Verbindung prüfen. Self-Hosted hinter Proxy: outbound HTTPS zu `api.anthropic.com` / `api.openai.com` / `generativelanguage.googleapis.com` freischalten."
    }
  end

  def hint("upstream_error", _ctx) do
    %{
      icon: "💥",
      title: "Cloud-LLM Provider 5xx",
      body:
        "Provider-seitiger Server-Fehler. Status auf der Provider-Status-Seite checken; meist transient. Worker macht bereits 2× exponentielles Backoff, ggf. später nochmal versuchen."
    }
  end

  def hint("timeout", _ctx) do
    %{
      icon: "🕐",
      title: "LLM-Call hat das HTTP-Timeout überschritten",
      body:
        "Das Modell hat zu lange für die Antwort gebraucht. Lösung: in /settings das HTTP-Timeout (`:http_timeout_ms`, Default 600s) erhöhen, ein kleineres/schnelleres Modell wählen, oder den Prompt-Kontext kürzen."
    }
  end

  def hint("no_summary", _ctx) do
    %{
      icon: "📝",
      title: "Stage 2 lieferte kein parsebares Resümee",
      body:
        "Das Resümee-Modell hat keinen verwertbaren JSON-Output produziert. Häufig bei sehr kleinen Modellen, die das Schema nicht halten. Größeres Stage-2-Modell in /settings versuchen."
    }
  end

  def hint("no_epos", _ctx) do
    %{
      icon: "📜",
      title: "Stage 3 lieferte kein Epos",
      body:
        "Stage 3 hat keinen Epos-Text geliefert. Meist Modell-Timeout (siehe `:http_timeout_ms` in /settings) oder Modell-Crash. Ein kleineres Modell oder erhöhtes Timeout versuchen."
    }
  end

  def hint("no_campaign", _ctx) do
    %{
      icon: "❓",
      title: "Kampagne nicht gefunden",
      body:
        "Die Session referenziert eine Kampagne, die im Worker-Snapshot nicht existiert. Bug, kein User-fixbarer Konfig-Fehler — bitte als Ticket öffnen (Codeberg `tomloresys/lore-tracker`) mit dem error_id."
    }
  end

  def hint("no_session", _ctx) do
    %{
      icon: "❓",
      title: "Session nicht gefunden",
      body:
        "Pipeline wurde für eine Session getriggert, die im Worker-Snapshot fehlt. Worker-Resync via Re-Pair oder `pull_since`/`pull_since_global` aus anderen Workern derselben Kampagne (siehe CLAUDE.md → Disaster-Recovery)."
    }
  end

  # Issue #68 Phase 3 — Folge-Hints für Local-Backend (Ollama) und
  # zusätzliche Codes die in Phase 2 noch fehlten.

  def hint("ollama_unreachable", _ctx) do
    %{
      icon: "🔌",
      title: "Ollama läuft nicht (Connection Refused)",
      body:
        "Der Worker erreicht den Ollama-Daemon nicht. Im Terminal `ollama serve` starten (Default-Port 11434). Bei Docker-Setup: `localhost` zeigt nicht auf den Host — `host.docker.internal` (Mac/Win) oder `172.17.0.1` (Linux) als `local_endpoint` setzen."
    }
  end

  def hint("model_not_found", _ctx) do
    %{
      icon: "📦",
      title: "Ollama-Modell nicht installiert",
      body:
        "Das in /settings gewählte Modell ist im Ollama-Cache nicht vorhanden. `ollama pull <model>` im Worker-Terminal ausführen — exakter Name + Tag wichtig (z.B. `qwen2.5:7b`, nicht nur `qwen2.5`)."
    }
  end

  def hint("http_error", _ctx) do
    %{
      icon: "🔧",
      title: "Unerwarteter HTTP-Status vom Provider",
      body:
        "Provider hat einen Status zurückgegeben, den wir nicht erwartet haben. Aufgeklappten Kontext-Block prüfen für genauen Code. Bei wiederkehrendem Fehler: Provider-Status-Page checken oder anderen Backend testweise."
    }
  end

  def hint("spend_cap_exceeded", _ctx) do
    %{
      icon: "💸",
      title: "Monats-Cap für Cloud-LLM erreicht",
      body:
        "Per-User-Cap (Issue #178) für diesen Monat ist ausgeschöpft. Admin kann den Cap in /admin/users hochsetzen — oder bis Anfang des nächsten Monats warten (Cap-Reset implicit per Datums-Filter)."
    }
  end

  def hint("no_worker_token", _ctx) do
    %{
      icon: "🔐",
      title: "Worker nicht gepairt",
      body:
        "Worker hat keinen gültigen Hub-Token. Über /settings → 'Worker neu pairen' den Pairing-Flow durchlaufen (Issue #160 — JWT-basiert seit Etappe 5a)."
    }
  end

  # Stage-1-Whisper-Coverage (Issue #68 Phase 3).
  def hint("whisper_binary_missing", _ctx) do
    %{
      icon: "🎤",
      title: "Whisper-CLI nicht gefunden",
      body:
        "Das `whisper_bin` (Default: `whisper-cli`) liegt nicht im PATH. Installation: whisper.cpp builden + Binary ins PATH legen, oder vollen Pfad in /settings → `whisper_bin` setzen."
    }
  end

  def hint("whisper_model_missing", _ctx) do
    %{
      icon: "🎤",
      title: "Whisper-Modell-Datei nicht gefunden",
      body:
        "Das in /settings → `whisper_model` konfigurierte File existiert nicht. Modell downloaden (z.B. `ggml-base.bin` aus huggingface.co/ggerganov/whisper.cpp) und Pfad korrigieren."
    }
  end

  def hint("whisper_failed", _ctx) do
    %{
      icon: "🎤",
      title: "Whisper-Prozess abgebrochen",
      body:
        "Whisper-CLI hat einen Fehler-Exit oder Crash produziert. Worker-Log checken. Häufige Ursachen: korruptes WAV-File (zu kurz / falsches Format), zu wenig RAM für das gewählte Modell (large braucht ~5 GB), oder veraltete whisper.cpp-Version."
    }
  end

  def hint("whisper_empty", _ctx) do
    %{
      icon: "🎤",
      title: "Whisper lieferte keinen Text",
      body:
        "Audio war stumm oder zu kurz. Mikro-Setup checken — Browser-Konsole bei phx-Hook `RecordMic` zeigt RMS-Levels. Wenn die durchgehend 0 sind, ist das Mikro nicht aktiv."
    }
  end

  def hint("whisper_sidecar_offline", _ctx) do
    %{
      icon: "🎤",
      title: "Diarisierungs-Sidecar offline",
      body:
        "Im Single-Source-Modus (Issue #19) wird der pyannote-Diarisierungs-Sidecar benötigt. Python-Prozess auf Port 8766 ist nicht erreichbar — siehe `docs/Worker-Setup.md` für den uvicorn-Start mit der venv."
    }
  end

  # Issue #716: Wahrheitsbild-Pfad (Phase C) — Extraktion/Verify/Render.

  def hint("sidecar_offline", _ctx) do
    %{
      icon: "🔬",
      title: "Verify-Gate: NLI-Sidecar nicht erreichbar",
      body:
        "Das Wahrheitsbild-Verify braucht den Faithfulness-Sidecar (`faithfulness_sidecar_url` in den Worker-Settings, Default-Port 8765). Sidecar starten (`apps/worker/priv/sidecar/faithfulness_sidecar.py`, uvicorn — siehe `docs/Worker-Setup.md`) oder die URL im Setting prüfen. Ohne Sidecar wird bewusst NICHT verifiziert (sonst sähe „alles unverifiziert\" wie ein echtes Ergebnis aus)."
    }
  end

  def hint("no_facts", _ctx) do
    %{
      icon: "🗂️",
      title: "Wahrheitsbild: keine extrahierten Fakten für die Session",
      body:
        "Das Verify-Gate fand keinen SessionFactsExtracted-Eintrag — die Extraktion ist nie gelaufen oder hat nichts persistiert. Session-Pipeline neu anstoßen (🔄 neu generieren); wenn es wieder passiert, die Extraktion-Fehler weiter oben in dieser Liste prüfen."
    }
  end

  def hint("no_verified_facts", _ctx) do
    %{
      icon: "🚧",
      title: "Wahrheitsbild: 0 Fakten haben das Verify-Gate passiert",
      body:
        "Der Render hat nichts zu erzählen, weil kein Fakt `verified?` wurde. Häufigste Ursache: zu strikte Verify-Schwellen (Issue #675 — `faithfulness_verify_entail_min` / `_max_contra` in den Worker-Settings) oder ein NLI-Modell, das deutsche Paare pauschal `neutral` labelt. Kalibrierung prüfen, dann Session regenerieren."
    }
  end

  def hint("extraction_empty", _ctx) do
    %{
      icon: "📭",
      title: "Extraktion lieferte 0 Fakten",
      body:
        "Das Extraktions-LLM hat für die Session keinen einzigen Fakt produziert. Bekannte Ursachen: zu kleines Modell für den Fakt-JSON-Schema-Mode, oder `ctx_stage2` zu klein für den Chunk. Größeres Stage-2-Modell wählen oder `extract_chunk_tokens` senken (Issue #683)."
    }
  end

  def hint("all_chunks_failed", _ctx) do
    %{
      icon: "🧩",
      title: "Extraktion: alle Map-Chunks fehlgeschlagen",
      body:
        "Beim Map-Reduce über die Session ist JEDER Chunk gescheitert (Timeout/Parse). Meist ein Modell-/Timeout-Problem: `http_timeout_ms` erhöhen, kleineres `extract_chunk_tokens`-Budget, oder stärkeres Stage-2-Modell. Einzel-Chunk-Fehler stehen als eigene Einträge in dieser Liste."
    }
  end

  def hint(_unknown, _ctx), do: nil

  @doc """
  Liefert die kanonische Liste aller bekannten `error_type`-Strings.
  Die /admin/errors-LV nutzt das für das Filter-Dropdown.
  """
  @spec known_types() :: [String.t()]
  def known_types do
    [
      "empty_chronik",
      "no_key_configured",
      "upstream_auth",
      "upstream_rate_limit",
      "network_error",
      "upstream_error",
      "http_error",
      "timeout",
      "no_summary",
      "no_epos",
      "no_campaign",
      "no_session",
      # Issue #68 Phase 3 — Local-Backend + zusätzliche Codes.
      "ollama_unreachable",
      "model_not_found",
      "spend_cap_exceeded",
      "no_worker_token",
      # Stage-1-Whisper-Coverage (Issue #68 Phase 3).
      "whisper_binary_missing",
      "whisper_model_missing",
      "whisper_failed",
      "whisper_empty",
      "whisper_sidecar_offline",
      # Issue #716: Wahrheitsbild-Pfad (Phase C).
      "sidecar_offline",
      "no_facts",
      "no_verified_facts",
      "extraction_empty",
      "all_chunks_failed",
      "other"
    ]
  end
end
