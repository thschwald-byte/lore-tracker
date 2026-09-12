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
      title: "Sidecar nicht erreichbar",
      body:
        "Ein Python-Sidecar hat nicht geantwortet. Seit #1124 gibt es davon nur noch einen: die Diarisierung (`diarization_sidecar_url`, Default-Port 8766), gebraucht für Aufnahmen aus EINER Quelle. Sidecar-Zustand in den Worker-Logs prüfen (`Sidecar[diarization]`), venv und Modell-Cache vorhanden? — siehe `docs/Worker-Setup.md`. Ältere Einträge dieser Klasse können noch vom entfernten Faithfulness-Sidecar (Port 8765) stammen; die sind gegenstandslos."
    }
  end

  def hint("no_facts", _ctx) do
    %{
      icon: "🗂️",
      title: "Wahrheitsbild: keine extrahierten Fakten für die Session",
      body:
        "Der Render fand keinen SessionFactsExtracted-Eintrag — Jack (Stufe 2) ist nie gelaufen oder hat nichts persistiert. Session-Pipeline neu anstoßen (🔄 neu generieren); wenn es wieder passiert, Jacks Fehler weiter oben in dieser Liste prüfen. (Einträge vor J4 meldete an dieser Stelle das entfallene Verify-Gate.)"
    }
  end

  def hint("no_verified_facts", _ctx) do
    %{
      icon: "🚧",
      title: "Wahrheitsbild: kein verifizierter Fakt für den Render",
      body:
        "Der Render hat nichts zu erzählen, weil kein Fakt `verified?` trägt. Seit J4 setzt das Jack: jede eingetragene Aussage hat seine Belegprüfung bestanden, ein zweiter Prüfer (Stufe 3) entfällt. Häufigste Ursachen jetzt: alle Fakten der Session wurden in der Fakten-Spalte ausgeblendet oder als unverifiziert markiert, oder Jacks Bestand ist leer. Fakten-Spalte prüfen, dann Session regenerieren. Einträge vor J4 stammen vom entfallenen Verify-Gate."
    }
  end

  def hint("extraction_empty", _ctx) do
    %{
      icon: "📭",
      title: "Stufe 2 lieferte 0 Fakten",
      body:
        "Jack hat für die Session keine gültige Aussage eingetragen. Häufige Ursachen: ein Modell, das mit Jacks Werkzeugen nicht zurechtkommt, oder ein Lauf, der vor der ersten Aussage endete. Jacks Lauf im Worker-Log bzw. in der Laufsicht ansehen und das Modell im Block „Jack: Extract/verify“ der Einstellungen prüfen. Einträge vor J4 stammen aus der entfernten Extraktion — die dort empfohlenen Regler (`ctx_stage2`, `extract_chunk_tokens`, Thinking-Level der Stage 2) gibt es nicht mehr."
    }
  end

  def hint("truncated_salvaged", _ctx) do
    %{
      icon: "✂️",
      title: "Extraktion abgeschnitten — Fakten wurden gerettet",
      body:
        "Nur noch Alteinträge: die Antwort der vor J4 entfernten Extraktion wurde am Kontextfenster gekappt, mitten in einem Fakt-Objekt; die bereits vollständig geschriebenen Fakten wurden übernommen (Issue #1115). Die damals empfohlenen Regler (`ctx_stage2`, `extract_chunk_tokens`, `extract_num_predict_cap`, Thinking-Level der Stage 2) gibt es nicht mehr — Stufe 2 ist jetzt Jack (Block „Jack: Extract/verify“ in den Einstellungen). Ein Regenerate der Session lässt Jack neu laufen."
    }
  end

  def hint("all_chunks_failed", _ctx) do
    %{
      icon: "🧩",
      title: "Extraktion: alle Map-Chunks fehlgeschlagen",
      body:
        "Nur noch Alteinträge: beim Map-Reduce der vor J4 entfernten Extraktion ist JEDER Chunk gescheitert (Timeout/Parse). Die damals empfohlenen Regler (`extract_chunk_tokens`, Stage-2-Backend) gibt es nicht mehr — Stufe 2 ist jetzt Jack (Block „Jack: Extract/verify“ in den Einstellungen). Ein Regenerate der Session lässt Jack neu laufen."
    }
  end

  def hint("render_prompt_too_large", _ctx) do
    %{
      icon: "📏",
      title: "Render-Prompt sprengt das Kontextfenster (Stage 4/5)",
      body:
        "Der Prompt einer Bogen-Progression (Stage 4) oder des Epos (Stage 5) ist größer als `ctx_stage4`/`ctx_stage5` — der Lauf bricht bewusst ab, statt dass Ollama still trunkiert und eine Assistenten-Entschuldigung als Text persistiert (Issue #889). Abhilfe: `ctx_stage4`/`ctx_stage5` in den Worker-Settings erhöhen (VRAM-Grenze beachten) oder Fakten kuratieren (rauschen/context-Stränge markieren). Einträge beim Resümee stammen aus der Zeit vor J5 — das Resümee schreibt seitdem der Resümee-Jack. Gilt nur fürs Local-Backend; Cloud-Backends melden Oversize als HTTP-Fehler."
    }
  end

  # J5 (#1209): der Resümee-Jack schreibt das Resümee in drei Läufen.
  def hint("resuemee_ueberblick_ohne_abschluss", _ctx) do
    %{
      icon: "📝",
      title: "Resümee-Jack: Überblick ohne Abschluss",
      body:
        "Der erste Lauf des Resümee-Jack (Fakten lesen, Form und Gliederung notieren) endete ohne `fertig` — für diese Sitzung wurde kein neues Resümee geschrieben, und Chronik, Epos und Bogen-Progressionen liefen nicht. Das bisherige Resümee bleibt stehen. Den Lauf in der Laufsicht bzw. im Worker-Log ansehen und das Modell im Block „Jack: Extract/verify“ prüfen (`resuemee_jack_model`, leer = Jacks Modell); danach die Session neu generieren."
    }
  end

  def hint("resuemee_schreiben_ohne_abschluss", _ctx) do
    %{
      icon: "📝",
      title: "Resümee-Jack: Schreiben ohne Abschluss",
      body:
        "Der zweite Lauf des Resümee-Jack (Absatz für Absatz schreiben, jeder Satz mit seinen Fakten) endete ohne `fertig` — für diese Sitzung wurde kein neues Resümee geschrieben, und Chronik, Epos und Bogen-Progressionen liefen nicht. Das bisherige Resümee bleibt stehen. Den Lauf in der Laufsicht bzw. im Worker-Log ansehen und das Modell im Block „Jack: Extract/verify“ prüfen (`resuemee_jack_model`); danach die Session neu generieren."
    }
  end

  def hint("resuemee_durchsicht_gescheitert", _ctx) do
    %{
      icon: "🔍",
      title: "Resümee-Jack: Durchsicht gescheitert",
      body:
        "Der dritte Lauf (Durchsicht des Entwurfs gegen die Fakten) ist gescheitert. Das ist kein Ausfall: veröffentlicht wurde der Entwurf aus dem Schreiben, jeder seiner Sätze nennt seine Fakten — nur grobe Schnitzer hat niemand mehr korrigiert. Der Grund steht in der Meldung. Häufen sich die Einträge, das Modell im Block „Jack: Extract/verify“ prüfen (`resuemee_jack_model`)."
    }
  end

  def hint("no_model_configured", _ctx) do
    %{
      icon: "🧠",
      title: "Kein Modell eingestellt",
      body:
        "Für diese Stufe ist kein Modell gesetzt, sie startet deshalb nicht (kein stiller Rückfall). Jack und der Resümee-Jack lesen `model_stage2_local` (Block „Jack: Extract/verify“ in den Einstellungen); der Resümee-Jack nimmt stattdessen `resuemee_jack_model`, wenn es gesetzt ist."
    }
  end

  # Issue #820: EntityRegistry-Clustering ist best-effort — der Lauf selbst
  # ist erfolgreich, nur das campaign-weite Guise-Merging bleibt aus (Fakten
  # behalten ihre per-Oberflächenform-entity_ids).
  def hint("entity_registry_parse_failed", _ctx) do
    %{
      icon: "🧩",
      title: "Entity-Registry: Cluster-Antwort nicht parsebar",
      body:
        "Das Clustering-LLM hat kein valides JSON geliefert. Figuren dieser Kampagne werden NICHT campaign-weit zusammengeführt (jede Oberflächenform bleibt eine eigene Entität) — die Session-Pipeline selbst lief trotzdem durch. Bei wiederholtem Auftreten: Jacks Modell prüfen — die Figuren-Zuordnung läuft seit J4 auf demselben Modell (`model_stage2_local`, Block „Jack: Extract/verify“ in den Einstellungen)."
    }
  end

  # J4 (#1207): Jack startet nicht, weil `ctx_jack` die Kompaktierung nicht fasst.
  def hint("ctx_jack_ungueltig", _ctx) do
    %{
      icon: "📐",
      title: "Jack: Kontextfenster ungültig",
      body:
        "`ctx_jack` ist kleiner als das Mindestfenster oder keine ganze Zahl — Jack startet für diese Session nicht. Das Fenster muss Reserve und Behalten seiner Kompaktierung fassen; der Mindestwert steht im Fehlergrund. In den Einstellungen im Block „Jack: Extract/verify“ ein größeres Kontextfenster setzen, passend zu dem, womit Ollama das Modell lädt (Modelfile `num_ctx` bzw. `OLLAMA_CONTEXT_LENGTH`; Default 98 304), dann die Session regenerieren."
    }
  end

  def hint("entity_registry_no_entities_key", _ctx) do
    %{
      icon: "🧩",
      title: "Entity-Registry: Antwort ohne 'entities'-Key",
      body:
        "Das Clustering-LLM hat JSON ohne das erwartete `entities`-Feld geliefert. Figuren dieser Kampagne werden NICHT campaign-weit zusammengeführt — die Session-Pipeline selbst lief trotzdem durch. Meist ein Modell, das dem JSON-Schema nicht zuverlässig folgt."
    }
  end

  # Issue #832: ThreadRegistry-Clustering ist best-effort (analog #820) — der
  # Lauf ist erfolgreich, nur das campaign-weite Strang-Clustering bleibt aus
  # (Fakten behalten ihr Roh-`thread`-Label, der Reader fällt darauf zurück).
  def hint("thread_registry_parse_failed", _ctx) do
    %{
      icon: "🧵",
      title: "Thread-Registry: Cluster-Antwort nicht parsebar",
      body:
        "Das Clustering-LLM hat kein valides JSON geliefert. Die Handlungsstränge dieser Kampagne werden NICHT campaign-weit zusammengeführt (jedes Roh-Label bleibt getrennt) — die Session-Pipeline selbst lief trotzdem durch. Bei wiederholtem Auftreten: Jacks Modell prüfen — die Strang-Zuordnung läuft seit J4 auf demselben Modell (`model_stage2_local`)."
    }
  end

  def hint("thread_registry_no_threads_key", _ctx) do
    %{
      icon: "🧵",
      title: "Thread-Registry: Antwort ohne 'threads'-Key",
      body:
        "Das Clustering-LLM hat JSON ohne das erwartete `threads`-Feld geliefert. Die Handlungsstränge werden NICHT zusammengeführt — die Session-Pipeline selbst lief trotzdem durch. Meist ein Modell, das dem JSON-Schema nicht zuverlässig folgt."
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
      # Issue #1115: Kontextdecke — Prompt + Denkphase + Inhalt passen nicht.
      "truncated_salvaged",
      # J4 (#1207): Jacks Kontextfenster fasst die Kompaktierung nicht.
      "ctx_jack_ungueltig",
      # #889/#909: fail-loud Prompt-Größen-Guard der Render-Stages.
      "render_prompt_too_large",
      # J5 (#1209): der Resümee-Jack, und ein fehlendes Modell (Jack wie er).
      "resuemee_ueberblick_ohne_abschluss",
      "resuemee_schreiben_ohne_abschluss",
      "resuemee_durchsicht_gescheitert",
      "no_model_configured",
      # Issue #820: EntityRegistry-Clustering (best-effort, "resolve"-Stage).
      "entity_registry_parse_failed",
      "entity_registry_no_entities_key",
      # Issue #832: ThreadRegistry-Clustering (best-effort, "resolve_threads"-Stage).
      "thread_registry_parse_failed",
      "thread_registry_no_threads_key",
      "other"
    ]
  end
end
