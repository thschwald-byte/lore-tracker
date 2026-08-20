defmodule Worker.Recording.ErrorClass do
  @moduledoc """
  Die Fehler-Taxonomie für `/admin/errors`: Reason → Code (Issue #68).

  Ausgelagert aus `Worker.Recording.Pipeline` (Issue #1008), das damit die
  1000-Zeilen-Grenze des God-Module-Checks (#544) riss. Der Schnitt ist
  inhaltlich und nicht bloß nach Zeilenzahl gewählt: das hier ist eine reine,
  seiteneffektfreie Musterzuordnung ohne jeden Bezug zum Pipeline-Ablauf, und
  sie ist der am häufigsten erweiterte Teil (jede neue Fehlerklasse fügt eine
  Klausel hinzu — #820, #832, #889, #989, #1008 …).

  `Worker.Recording.Pipeline.classify_pipeline_error/1` delegiert hierher; unter
  diesem Namen ist die Funktion an rund 40 Stellen eingeführt.

  **Die Reihenfolge der Klauseln ist load-bearing** — die spezifischen Tupel
  müssen vor dem Wrapper-Strip und dem Atom-Fallback stehen (s. die #589-Lektion
  im ersten Kommentar unten).
  """

  # Issue #589 (Cut 3): Stage-Bodies wrappen ihren inneren Fehler als
  # `{:error, {:stageN, inner_reason}}` (stages.ex, Z. 101/475/525/712).
  # `with_status` reicht den *gewrappten* Reason hier rein — ohne diese
  # Unwrap-Klausel matchte keine der spezifischen Klauseln unten (die alle den
  # INNEREN Reason erwarten: :no_key_configured, :timeout, {:network_error,_} …),
  # sodass JEDER Pipeline-Fehler auf den `_ -> "other"`-Fallback fiel. Die ganze
  # #68-Error-Taxonomie für /admin/errors war damit tot (jeder Fehler "other",
  # ohne den gezielten Recovery-Hint). Fix: Wrapper strippen + auf den inneren
  # Reason rekursieren → korrekte Klassifikation.
  # #716: leere Extraktion VOR dem generischen Wrapper-Strip — nach dem Strip
  # wäre `:empty` zu vage für einen gezielten Hint.
  def classify({:extraction, :empty}), do: "extraction_empty"

  # #716: die Wahrheitsbild-Schritt-Tags (:extraction aus stages.ex,
  # :verify/:render aus run_wahrheitsbild, :timeline/:render_epos aus den
  # #752-Geschwister-Artefakten, :render_arc_progressions aus #838) strippen —
  # Klassifikation läuft auf dem inneren Reason. Der arc_id-Bezug bleibt
  # bewusst außerhalb der Taxonomie, im Klartext der Fehlermeldung
  # (log_arc_progression_error/4) statt als eigene Fehlerklasse.
  def classify({stage, reason})
      when stage in [
             :extraction,
             :verify,
             :render,
             :timeline,
             :render_epos,
             :render_arc_progressions
           ],
      do: classify(reason)

  # #716: Wahrheitsbild-Fehlerklassen (Phase C). Die Atom-Catch-all-Klausel
  # unten würde dieselben Strings liefern — explizit, weil an jede Klasse ein
  # KnownIssues-Hint + type_label im Hub gekoppelt ist (Drift-Schutz).
  def classify(:sidecar_offline), do: "sidecar_offline"
  def classify(:no_facts), do: "no_facts"
  def classify(:no_verified_facts), do: "no_verified_facts"
  def classify(:all_chunks_failed), do: "all_chunks_failed"

  # Issue #1115: Extraktion an der Kontextdecke abgeschnitten, die vollständigen
  # Fakten des Präfixes wurden gerettet. KEIN Fehlschlag — die Stage lief durch;
  # sichtbar, weil eine Rettung bedeutet, dass Prompt + Denkphase + Inhalt nicht
  # mehr in ctx_stage2 passen und der num_predict-Deckel nicht greifen kann.
  def classify(:truncated_salvaged), do: "truncated_salvaged"

  # Issue #820: EntityRegistry.parse_clustering/1-Reasons — eigene Codes statt
  # dem generischen Atom-Fallback, damit sie einen eigenen type_label bekommen.
  def classify(:parse_failed), do: "entity_registry_parse_failed"
  def classify(:no_entities_key), do: "entity_registry_no_entities_key"

  # Issue #832: ThreadRegistry.parse_clustering/1-Reasons (distinkt von den
  # Entity-Codes, damit resolve_threads-Fehler eigen sichtbar sind).
  def classify(:thread_parse_failed), do: "thread_registry_parse_failed"
  def classify(:no_threads_key), do: "thread_registry_no_threads_key"

  def classify(:no_key_configured), do: "no_key_configured"
  def classify(:upstream_auth), do: "upstream_auth"
  def classify(:upstream_rate_limit), do: "upstream_rate_limit"

  # Issue #68 Phase 3: Ollama-Connection-Refused → eigener Code für
  # gezielten "ollama serve"-Recovery-Hint.
  def classify({:network_error, :econnrefused}), do: "ollama_unreachable"
  def classify({:network_error, :nxdomain}), do: "ollama_unreachable"
  def classify({:network_error, _}), do: "network_error"

  # Issue #68 Phase 3: Ollama-Model-Not-Found → "ollama pull"-Hint.
  # Local-Backend wrapped Ollama-404 als {:http, 404, body}, body kann String
  # oder geparste Map sein je nach Pfad.
  def classify({:http, 404, body}) when is_binary(body) do
    if String.contains?(body, "model") and String.contains?(body, "not found") do
      "model_not_found"
    else
      "http_error"
    end
  end

  def classify({:http, 404, %{"error" => msg}}) when is_binary(msg) do
    if String.contains?(msg, "not found"), do: "model_not_found", else: "http_error"
  end

  def classify({:upstream_error, _, _}), do: "upstream_error"
  def classify({:http, _, _}), do: "http_error"
  def classify(:timeout), do: "timeout"
  def classify(:no_campaign), do: "no_campaign"
  def classify(:no_session), do: "no_session"

  # Issue #178: Cap-Limit für Cloud-LLM-Calls.
  def classify(:spend_cap_exceeded), do: "spend_cap_exceeded"

  # Issue #68 Phase 3 — Stage-1-Whisper-Codes (falls je aus Pipeline bubbled).
  def classify(:whisper_binary_missing), do: "whisper_binary_missing"
  def classify(:whisper_model_missing), do: "whisper_model_missing"
  def classify(:whisper_failed), do: "whisper_failed"
  def classify({:whisper_failed, _}), do: "whisper_failed"
  def classify(:whisper_empty), do: "whisper_empty"

  # #889/#909: Render-Prompt sprengt num_ctx (nur Local-Backend) — fail-loud
  # statt Ollama-Silent-Truncation + Entschuldigungs-Resümee.
  def classify({:prompt_too_large, _est, _cap}), do: "render_prompt_too_large"

  # Issue #989: Consent-Ansage beim Discord-Voice-Join. Ohne diese beiden
  # Tupel-Klauseln fielen sie in den `_`-Fallback („other") und wären in
  # /admin/errors nicht als Ansage-Problem erkennbar.
  def classify({:tts_failed, _}), do: "tts_failed"
  def classify({:announce_play_failed, _}), do: "announce_play_failed"

  # Issue #1008: Discord-Aufnahme ohne Ergebnis. Die beiden Atome
  # (`:no_frames_captured`, `:unresolved_ssrc_frames`) fallen schon über den
  # Atom-Fallback auf ihren eigenen Namen; dieses Tupel braucht eine eigene
  # Klausel, sonst landet ein gescheiterter Clip-Bau in „other".
  def classify({:clip_build_failed, _}), do: "clip_build_failed"

  def classify(atom) when is_atom(atom), do: Atom.to_string(atom)
  def classify(_), do: "other"
end
