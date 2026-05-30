defmodule Worker.Recording.Pipeline do
  @moduledoc """
  Listens for `SessionEnded` events on the worker-local PubSub and runs
  the per-session post-recording pipeline sequentially:

      Stage 2: snippets → Resümee   (Worker.LLM.complete(:summary, ...))
      Stage 3: snippets + Resümee → Epos  (Worker.LLM.complete(:epos, ...))
      Stage 4: Epos → Chronik bullets (Worker.LLM.complete(:chronik, ...))

  Each stage emits the corresponding event via `Worker.Intents.publish/1`,
  so other workers and the LiveView see the new content via the regular
  event-sourcing flow.

  Stage 1 (audio → text) is owned by `Worker.Recording.AudioCapture` once
  the Discord bot lands (M10); for now utterances arrive via the
  fake-session task and Pipeline starts at Stage 2.

  Nur Worker, deren `admin_discord_id` als Member der Kampagne registriert
  ist, fahren die Pipeline (Issue #236). Vorher war der Check auf
  `campaign.owner_discord_id` — seit Issue #140 ist `owner_discord_id`
  aber nur noch abgeleiteter Wert aus dem ersten `:spielleiter`-Member,
  also fragil bei Multi-GM-Setups. Member-Check ist die robuste Variante.

  Bei mehreren connected Member-Workern entscheidet die Leader-Election
  in `Hub.Commands.pick_leader/2` welcher Worker den Trigger bekommt —
  hier feuert die Pipeline einfach, wenn die `SessionEnded`-Event ankommt
  und der Worker Member ist.
  """

  use GenServer

  require Logger

  alias Worker.{Intents, LLM, Repo}

  # Issue #230: LLM-Sentinel-Strings die selbst-eingestandene Fabrication
  # markieren. Wenn einer davon in `in_game_date`, `label` oder `summary`
  # eines Chronik-Eintrags auftaucht, droppt `filter_fabricated_chronik/1`
  # den Eintrag mit Logger.warning. Konservativ gehalten — nur explizite
  # Placeholder, keine subjektiven Unsicherheits-Wörter (legitime Plot-
  # Texte dürfen "vermutet" oder "unklar" enthalten).
  @fabrication_sentinels [
    ~r/nicht im transkript/iu,
    ~r/nicht erwähnt/iu,
    ~r/keine angabe/iu,
    ~r/^unbekannt$/iu,
    ~r/^n\/a$/i,
    ~r/^---+$/
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Manueller Pipeline-Trigger für eine Session — direkt aufgerufen aus
  `CampaignReplay`, `Probelauf` und dem UI-Pfad (`Worker.HubClient`
  beim `start_session_regenerate`-Push). Kein Event-Roundtrip durch
  den Hub.

  Räumt eine etwaige stuck/finished prior-run Markierung aus dem
  `running`-Set, damit ein hängengebliebener Vorlauf den Retry nicht
  blockiert.
  """
  @spec run_for_session(String.t()) :: :ok
  def run_for_session(session_id) when is_binary(session_id) do
    run_for_session(session_id, [])
  end

  @doc """
  Issue #201: optionaler `only_stages: [2 | 3 | 4]`-Schlüssel führt nur die
  angegebenen Stages aus. Pre-Stage-Inputs werden aus dem Repo geladen
  (Stage 3 liest Goldstandard-Summary, Stage 4 liest Goldstandard-Epos).

  Wird vom Probelauf-Sweep genutzt um Modell-Vergleiche pro Stage fair
  zu messen — ohne Beifang-Stages und ohne Pre-Stage-Output-Drift.

  Ohne `only_stages`: alle Stages 2/3/4 wie gehabt.
  """
  @spec run_for_session(String.t(), keyword()) :: :ok
  def run_for_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    # Synchroner Call: returnt erst nachdem der `running`-Marker gesetzt ist,
    # damit CampaignReplay.wait_pipeline_idle/1 nicht race-conditional gegen
    # einen noch nicht verarbeiteten Cast pollt.
    GenServer.call(__MODULE__, {:run_for_session, session_id, opts}, :infinity)
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_call({:run_for_session, session_id, opts}, _from, state) do
    Logger.info(
      "Pipeline: manual re-run requested for session=#{session_id} opts=#{inspect(opts)}"
    )

    state = %{state | running: MapSet.delete(state.running, session_id)}

    # Issue #226: manueller Re-Run = explizite Variation gewünscht. Stage 3
    # bekommt einen Re-Run-Hint + temperature-Override, damit das LLM nicht
    # den bisherigen Epos-Text bit-identisch wiederholt.
    #
    # Issue #201: `only_stages` aus opts merged mit force? — Probelauf-Sweep
    # ruft mit `only_stages: [N]` an und braucht KEIN force-regen-Hint
    # (Goldstandard-Setup soll wiederholbar sein).
    merged_opts = Keyword.put_new(opts, :force?, not Keyword.has_key?(opts, :only_stages))

    case maybe_run(session_id, state, merged_opts) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info({:applied, %{"payload" => %{"kind" => "SessionEnded"} = payload}}, state) do
    session_id = payload["id"]

    if not MapSet.member?(state.running, session_id) do
      maybe_run(session_id, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:applied, _}, state), do: {:noreply, state}

  def handle_info({:stage_done, session_id}, state) do
    # Issue #354: PubSub-Broadcast für CampaignReplay.wait_pipeline_idle/1.
    # Statt 2s-Polling auf `:sys.get_state(Pipeline)` kann der Caller direkt
    # auf das Topic subscriben und das Done-Event abwarten.
    Phoenix.PubSub.broadcast(
      Worker.PubSub,
      "pipeline_sessions",
      {:pipeline_session_done, session_id}
    )

    {:noreply, %{state | running: MapSet.delete(state.running, session_id)}}
  end

  # ─── Internal ─────────────────────────────────────────────────────

  defp maybe_run(session_id, state, opts \\ []) do
    case session_and_campaign(session_id) do
      {:ok, session, campaign} ->
        admin = Repo.get_state(:admin_discord_id)

        if Repo.member?(campaign.id, admin) do
          Logger.info(
            "Pipeline: starting stages for session=#{session_id} campaign=#{campaign.id}"
          )

          me = self()

          # Issue #292: Stages 2-4 (lokales Ollama / Cloud-LLM) durch die GPU-
          # Queue routen. Outer Task bleibt für das `{:stage_done, session_id}`-
          # Signal an die Pipeline-State-Machine. De-Dup-MapSet (`state.running`)
          # bleibt orthogonal — verhindert SessionEnded-Reapply-Doppelstarts.
          Task.start(fn ->
            Worker.GpuQueue.run(
              fn -> run_stages(session, campaign, opts) end,
              label: "pipeline:#{session_id}"
            )

            send(me, {:stage_done, session_id})
          end)

          {:noreply, %{state | running: MapSet.put(state.running, session_id)}}
        else
          Logger.warning(
            "Pipeline: session=#{session_id} campaign=#{campaign.id} — " <>
              "admin=#{admin} is not a member; skipping. " <>
              "Add the admin as member to enable Stages 2-4."
          )

          {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("Pipeline: cannot resolve session=#{session_id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp session_and_campaign(session_id) do
    sessions =
      :worker_sessions
      |> :mnesia.dirty_read(session_id)

    case sessions do
      [{_, _, campaign_id, _num, _name, _status, _sched, _start, _end}] ->
        case Repo.get_campaign(campaign_id) do
          nil -> {:error, :no_campaign}
          campaign -> {:ok, %{id: session_id, campaign_id: campaign_id}, campaign}
        end

      [] ->
        {:error, :no_session}
    end
  end

  defp run_stages(session, campaign, opts \\ []) do
    utterances = Repo.list_utterances(session.id)

    if utterances == [] do
      Logger.info("Pipeline: session=#{session.id} has no utterances; skipping LLM stages")
    else
      only_stages = Keyword.get(opts, :only_stages)

      # Issue #114: Stage 2 returnt jetzt %{content_md, source_refs} statt
      # nur den String. Stage 3 braucht weiterhin nur den content_md (zieht
      # ihre Inputs aus dem Repo); Faithfulness bekommt die ganze Map damit
      # source_refs als direkte NLI-Premise dienen können.
      result =
        with {:ok, %{content_md: summary_md} = summary} <-
               run_or_load_stage2(only_stages, utterances, session, campaign),
             :ok <- maybe_faithfulness(only_stages, summary, utterances, session, campaign),
             {:ok, epos_md} <-
               run_or_load_stage3(only_stages, summary_md, session, campaign, opts),
             :ok <- maybe_stage4(only_stages, epos_md, session, campaign) do
          :ok
        end

      case result do
        :ok ->
          Logger.info(
            "Pipeline: completed for session=#{session.id} only_stages=#{inspect(only_stages)}"
          )

        {:error, reason} ->
          Logger.error("Pipeline: failed for session=#{session.id}: #{inspect(reason)}")
      end
    end
  end

  # Issue #201: Stage-Skip-Helpers. Wenn `only_stages` gesetzt und die Stage
  # NICHT enthalten ist, wird das prior-Stage-Output aus dem Repo geladen
  # (Goldstandard-Pre-Seed im Probelauf-Sweep). Sonst läuft die Stage normal.

  defp run_or_load_stage2(nil, utterances, session, campaign) do
    with_status(campaign.id, "stage2", session.id, fn ->
      stage2(utterances, session.id, campaign)
    end)
  end

  defp run_or_load_stage2(only_stages, utterances, session, campaign) do
    if 2 in only_stages do
      with_status(campaign.id, "stage2", session.id, fn ->
        stage2(utterances, session.id, campaign)
      end)
    else
      load_summary_from_repo(session.id)
    end
  end

  defp run_or_load_stage3(nil, summary_md, _session, campaign, opts) do
    with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign, opts) end)
  end

  defp run_or_load_stage3(only_stages, summary_md, _session, campaign, opts) do
    if 3 in only_stages do
      with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign, opts) end)
    else
      load_epos_from_repo(campaign.id)
    end
  end

  defp maybe_stage4(nil, epos_md, session, campaign) do
    with_status(campaign.id, "stage4", session.id, fn -> stage4(epos_md, session.id, campaign) end)
  end

  defp maybe_stage4(only_stages, epos_md, session, campaign) do
    if 4 in only_stages do
      with_status(campaign.id, "stage4", session.id, fn ->
        stage4(epos_md, session.id, campaign)
      end)
    else
      :ok
    end
  end

  defp maybe_faithfulness(nil, summary, utterances, session, campaign) do
    stage_faithfulness(summary, utterances, session.id, campaign.id)
  end

  # Bei isoliertem Sweep läuft Faithfulness separat im Sweep-Code (gegen
  # Goldstandard), nicht hier in der Pipeline.
  defp maybe_faithfulness(_only_stages, _summary, _utterances, _session, _campaign), do: :ok

  defp load_summary_from_repo(session_id) do
    case Repo.get_session_summary(session_id) do
      %{content_md: md} = sum when is_binary(md) and md != "" ->
        # Issue #114: source_refs aus dem Repo mit-laden (Goldstandard-Pre-Seed
        # hat sie nach Stage-2-Replay; Pre-Seed-Assets aus #201 haben aktuell []).
        {:ok, %{content_md: md, source_refs: Map.get(sum, :source_refs, [])}}

      _ ->
        {:error,
         {:stage2,
          {:no_goldstandard,
           "session=#{session_id} hat kein Stage-2-Output im Repo (Pre-Seed fehlt)"}}}
    end
  end

  defp load_epos_from_repo(campaign_id) do
    case Repo.get_epos_entry(campaign_id) do
      %{content_md: md} when is_binary(md) and md != "" ->
        {:ok, md}

      _ ->
        {:error,
         {:stage3,
          {:no_goldstandard,
           "campaign=#{campaign_id} hat kein Stage-3-Output im Repo (Pre-Seed fehlt)"}}}
    end
  end

  defp with_status(campaign_id, stage, fun), do: with_status(campaign_id, stage, nil, fun)

  defp with_status(campaign_id, stage, session_id, fun) do
    # Issue #288: format_notes-Slot pro Stage-Run resetten. Stage-Body
    # setzt ihn via put_format_notes/1 nach jedem Parse.
    Process.delete(:format_notes)
    notify_status(campaign_id, stage, "started", nil)
    result = fun.()

    {status, error_msg, error_reason} =
      case result do
        {:ok, _} -> {"ended", nil, nil}
        :ok -> {"ended", nil, nil}
        {:error, reason} -> {"failed", format_error(reason), reason}
        _ -> {"failed", nil, :unknown}
      end

    notify_status(campaign_id, stage, status, error_msg)
    # Issue #68 (Phase 1): persistierter Fehler-Log für /admin/errors.
    if status == "failed",
      do: publish_pipeline_error(campaign_id, stage, session_id, error_reason, error_msg)

    result
  end

  # Issue #68 (Phase 1): publisht ein `PipelineErrorLogged`-Event. Best-effort,
  # Publish-Fehler werden geloggt aber nicht propagiert — sonst würde der
  # ursprüngliche Stage-Fehler durch einen Hub-Sync-Fehler maskiert.
  defp publish_pipeline_error(campaign_id, stage, session_id, reason, message) do
    payload = %{
      "kind" => Shared.Events.pipeline_error_logged(),
      "error_id" => UUIDv7.generate(),
      "session_id" => session_id,
      "campaign_id" => campaign_id,
      "stage" => stage,
      "error_type" => classify_pipeline_error(reason),
      "message" => message || "Pipeline-Stage fehlgeschlagen",
      "context" => %{"reason" => inspect(reason)},
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Intents.publish(payload) do
      {:ok, _seq} ->
        :ok

      {:error, publish_reason} ->
        Logger.warning("Pipeline: publish PipelineErrorLogged failed: #{inspect(publish_reason)}")

        :ok
    end
  end

  defp classify_pipeline_error(:empty_chronik), do: "empty_chronik"
  defp classify_pipeline_error(:no_key_configured), do: "no_key_configured"
  defp classify_pipeline_error(:upstream_auth), do: "upstream_auth"
  defp classify_pipeline_error(:upstream_rate_limit), do: "upstream_rate_limit"

  # Issue #68 Phase 3: Ollama-Connection-Refused → eigener Code für
  # gezielten "ollama serve"-Recovery-Hint.
  defp classify_pipeline_error({:network_error, :econnrefused}), do: "ollama_unreachable"
  defp classify_pipeline_error({:network_error, :nxdomain}), do: "ollama_unreachable"
  defp classify_pipeline_error({:network_error, _}), do: "network_error"

  # Issue #68 Phase 3: Ollama-Model-Not-Found → "ollama pull"-Hint.
  # Local-Backend wrapped Ollama-404 als {:http, 404, body}, body kann String
  # oder geparste Map sein je nach Pfad.
  defp classify_pipeline_error({:http, 404, body}) when is_binary(body) do
    if String.contains?(body, "model") and String.contains?(body, "not found") do
      "model_not_found"
    else
      "http_error"
    end
  end

  defp classify_pipeline_error({:http, 404, %{"error" => msg}}) when is_binary(msg) do
    if String.contains?(msg, "not found"), do: "model_not_found", else: "http_error"
  end

  defp classify_pipeline_error({:upstream_error, _, _}), do: "upstream_error"
  defp classify_pipeline_error({:http, _, _}), do: "http_error"
  defp classify_pipeline_error(:timeout), do: "timeout"
  defp classify_pipeline_error(:no_summary), do: "no_summary"
  defp classify_pipeline_error(:no_epos), do: "no_epos"
  defp classify_pipeline_error(:no_campaign), do: "no_campaign"
  defp classify_pipeline_error(:no_session), do: "no_session"

  # Issue #178: Cap-Limit für Cloud-LLM-Calls.
  defp classify_pipeline_error(:spend_cap_exceeded), do: "spend_cap_exceeded"

  # Issue #68 Phase 3 — Stage-1-Whisper-Codes (falls je aus Pipeline bubbled).
  defp classify_pipeline_error(:whisper_binary_missing), do: "whisper_binary_missing"
  defp classify_pipeline_error(:whisper_model_missing), do: "whisper_model_missing"
  defp classify_pipeline_error(:whisper_failed), do: "whisper_failed"
  defp classify_pipeline_error({:whisper_failed, _}), do: "whisper_failed"
  defp classify_pipeline_error(:whisper_empty), do: "whisper_empty"

  defp classify_pipeline_error(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp classify_pipeline_error(_), do: "other"

  # Issue #288: Stage-Body merkt sich die Format-Notes via Process-Dict;
  # notify_status liest sie beim "ended"/"failed"-Event ins Payload.
  # Process-Dict ist hier safe weil Stage-Run + notify_status im selben
  # Prozess laufen (vgl. Logger.metadata-Pattern).
  defp put_format_notes(notes) when is_binary(notes), do: Process.put(:format_notes, notes)
  defp put_format_notes(_), do: :ok

  defp notify_status(campaign_id, stage, status, error_msg) do
    payload =
      %{
        "kind" => "pipeline_stage",
        "campaign_id" => campaign_id,
        "stage" => stage,
        "status" => status,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> then(fn p -> if error_msg, do: Map.put(p, "error", error_msg), else: p end)
      |> then(fn p ->
        # Issue #288: format_notes nur bei terminalen Stati publishen — bei
        # "started" gibt's noch nichts zu vermelden.
        case Process.get(:format_notes) do
          notes when is_binary(notes) and status in ["ended", "failed"] ->
            Map.put(p, "format_notes", notes)

          _ ->
            p
        end
      end)

    Worker.HubClient.publish_status(payload)

    # Worker-lokaler Mit-Listener (Issue #74): Probelauf-Engine läuft im
    # selben BEAM und braucht Per-Stage-Timings ohne den Umweg über Hub.
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})

    # Issue #289 Phase 3: FormatCorrector beobachtet format_notes pro
    # Stage. Skip für Probelauf-Eval-Campaigns (sonst würde ein laufender
    # Sweep die Temperature ändern die er gerade misst).
    maybe_feed_format_corrector(stage, status, payload["format_notes"], campaign_id)
  end

  defp maybe_feed_format_corrector(stage, status, notes, campaign_id)
       when status in ["ended", "failed"] and is_binary(notes) and is_binary(stage) do
    unless probelauf_campaign?(campaign_id) do
      case stage_to_int(stage) do
        n when n in [2, 3, 4] -> Worker.FormatCorrector.record(n, notes)
        _ -> :ok
      end
    end

    :ok
  end

  defp maybe_feed_format_corrector(_, _, _, _), do: :ok

  defp probelauf_campaign?(campaign_id) when is_binary(campaign_id),
    do: String.starts_with?(campaign_id, "probelauf-")

  defp probelauf_campaign?(_), do: false

  defp stage_to_int("stage" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp stage_to_int(_), do: nil

  # Issue #27: aus dem internen Pipeline-Reason eine UI-lesbare Message machen.
  # Reasons kommen in mehreren Formen rein:
  #   {:stage2, {:upstream, code, status, msg}}  ← Anthropic-Backend
  #   {:stage4, :empty_chronik}                  ← Stage-4-empty-Output
  #   {:stage3, :timeout}                        ← HTTP-Timeout
  #   {:stage_n, atom_or_term}                   ← sonstiges
  defp format_error({_stage, {:upstream, code, status, msg}}) when is_binary(msg),
    do: "Cloud-Backend (#{code} #{status}): #{msg}"

  defp format_error({_stage, {:upstream, code, status, _}}),
    do: "Cloud-Backend (#{code} #{status})"

  defp format_error({_stage, :empty_chronik}), do: "LLM lieferte keine Chronik-Einträge"
  defp format_error({_stage, :timeout}), do: "Timeout — LLM antwortet nicht"
  defp format_error({_stage, :no_key_configured}), do: "Kein Cloud-API-Key konfiguriert"
  defp format_error({_stage, :no_worker_token}), do: "Worker nicht gepairt"

  defp format_error({_stage, :spend_cap_exceeded}),
    do: "Cap erreicht — Admin kontaktieren (siehe /admin/users)"

  defp format_error({_stage, reason}), do: "Fehler: #{inspect(reason)}"
  defp format_error(reason), do: inspect(reason)

  # ─── Stages ─────────────────────────────────────────────────────

  defp stage2(utterances, session_id, campaign) do
    speaker_names = resolve_speaker_names(campaign.id)
    num_ctx = Worker.Settings.get(:ctx_stage2, 8192)

    prompt =
      build_summary_prompt(
        utterances,
        speaker_names,
        campaign[:flavors] || %{},
        heading_directive(stage_heading(campaign, "summary"), "summary")
      )

    guard_prompt_size(prompt, num_ctx, "stage2")
    # Issue #114: JSON-Mode für strukturierten Output (content_md + source_refs).
    # Pattern analog Stage 4 (parse_chronik_json). Bei Parse-Fehler fällt der
    # Helper auf {trim(raw), []} zurück — Pipeline läuft weiter, Audit-Refs
    # nur fehlend statt Crash.
    # Issue #289 Phase 1: JSON-Schema statt nur "json" — Ollamas GBNF-
    # Grammatik macht invalides JSON token-seitig unmöglich + eliminiert
    # `<think>`-Block-Vorräute strukturell.
    opts = [format: stage2_json_schema(), num_ctx: num_ctx] ++ sampling_opts(2)

    # Issue #289 Phase 2: Bei Parse-Fallback (LLM hat keinen
    # `{"content_md": ...}`-JSON-Output geliefert) ein Retry mit
    # Korrektur-Prompt triggern. Anzahl konfigurierbar via Settings.
    max_retries = Worker.Settings.get(:pipeline_max_format_retries, 1)

    case stage2_llm_with_retry(prompt, opts, utterances, max_retries) do
      {:ok, summary_md, source_refs} ->
        publish_event(%{
          "kind" => Shared.Events.session_summary_generated(),
          "session_id" => session_id,
          "campaign_id" => campaign.id,
          "content_md" => summary_md,
          "source" => "llm",
          "source_refs" => source_refs
        })
        |> case do
          :ok -> {:ok, %{content_md: summary_md, source_refs: source_refs}}
          {:error, reason} -> {:error, {:stage2, {:publish_failed, reason}}}
        end

      {:error, reason} ->
        {:error, {:stage2, reason}}
    end
  end

  # Issue #289 Phase 2: LLM-Call mit Korrektur-Retry. Geht max_retries-mal
  # erneut ans Modell wenn der Parser auf den raw-Fallback fällt (kein
  # `{"content_md": ...}`-JSON geliefert). Returnt im Erfolgsfall die
  # geparste Variante, sonst die Fallback-Variante (raw als content_md,
  # keine refs) — die Pipeline läuft in beiden Fällen weiter, der
  # Unterschied ist nur die Audit-Qualität der source_refs.
  defp stage2_llm_with_retry(prompt, opts, utterances, max_retries) do
    stage2_llm_attempt(prompt, opts, utterances, max_retries, :first_try)
  end

  defp stage2_llm_attempt(prompt, opts, utterances, retries_left, attempt) do
    case LLM.complete(:summary, prompt, opts) do
      {:ok, raw} ->
        case parse_summary_json_with_status(raw, utterances) do
          {:parsed, md, refs, notes} ->
            if attempt != :first_try do
              Logger.info("stage2: format_retry retry_ok (attempt=#{inspect(attempt)})")
            end

            put_format_notes(notes)
            {:ok, md, refs}

          {:fallback, _fallback_md, _notes} when retries_left > 0 ->
            Logger.info(
              "stage2: format-fallback erkannt — Retry mit Korrektur-Prompt " <>
                "(retries_left=#{retries_left})"
            )

            retry_prompt = build_summary_retry_prompt(prompt, raw)
            stage2_llm_attempt(retry_prompt, opts, utterances, retries_left - 1, :retry)

          {:fallback, fallback_md, notes} ->
            if attempt != :first_try do
              Logger.warning(
                "stage2: format_retry retry_failed — Fallback nach #{inspect(attempt)}"
              )
            end

            # Pipeline läuft mit raw-Fallback weiter (heutiges Verhalten ohne #289).
            put_format_notes(notes)
            {:ok, fallback_md, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Issue #289 Phase 2: Korrektur-Prompt für Stage 2 nach Format-Fallback.
  # Format genau wie im Issue spezifiziert.
  defp build_summary_retry_prompt(original_prompt, faulty_output) do
    """
    #{original_prompt}

    --- Vorheriger Versuch (fehlerhaft) ---
    #{faulty_output}

    --- Anweisung ---
    Kein valides JSON. Korrigiere. Antworte ausschließlich mit dem korrigierten JSON.
    """
  end

  # Issue #11 Phase 2: Faithfulness-Score gegen Quell-Transkript.
  # Sidecar-Aufruf ist optional — bei Fehler/Offline läuft die Pipeline
  # ohne Score weiter (Status-Notifikation als "ended" mit warning).
  defp stage_faithfulness(summary, utterances, session_id, campaign_id) do
    notify_status(campaign_id, "faithfulness", "started", nil)

    %{content_md: summary_md, source_refs: source_refs} = summary

    case Worker.LLM.Faithfulness.score(summary_md, utterances, source_refs) do
      {:ok, %{score: score, claims: claims}} ->
        # Faithfulness ist optional — Publish-Failure soll die Pipeline nicht
        # blocken, nur als warning loggen.
        _ =
          publish_event(%{
            "kind" => Shared.Events.session_faithfulness_scored(),
            "session_id" => session_id,
            "campaign_id" => campaign_id,
            "score" => score,
            "claims" => Enum.map(claims, &Map.new(&1, fn {k, v} -> {to_string(k), v} end)),
            "scored_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        notify_status(campaign_id, "faithfulness", "ended", nil)
        :ok

      {:error, :sidecar_offline} ->
        Logger.info("Pipeline: faithfulness sidecar offline — skipping for session=#{session_id}")
        notify_status(campaign_id, "faithfulness", "ended", "sidecar offline")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline: faithfulness scoring failed for session=#{session_id}: #{inspect(reason)}"
        )

        notify_status(campaign_id, "faithfulness", "ended", "scoring failed")
        :ok
    end
  end

  defp stage3(_summary_md, campaign, opts \\ []) do
    force? = Keyword.get(opts, :force?, false)

    # Issue #277: Bei force=true (manueller „🔄 neu generieren") wird der
    # bestehende Epos NICHT mehr als Referenz mitgegeben. User-Intent ist
    # Reset, nicht Kontinuität — wenn der existing_md vergiftet ist (z.B.
    # Wortsalat aus einem Modellwechsel), würde der Re-Run das Pattern
    # sonst als Stil-Vorlage übernehmen und reproduzieren.
    existing_md =
      if force? do
        ""
      else
        existing = Repo.get_epos_entry(campaign.id)
        (existing && existing.content_md) || ""
      end

    # Use all summaries of the campaign, not just the just-generated one —
    # so the Epos has the full chronological context.
    all_summaries =
      Repo.list_session_summaries(campaign.id)
      |> Enum.sort_by(& &1.generated_at, {:asc, DateTime})

    # Issue #313: Darstellungsform (Fließtext|Stichpunkte) aus der Campaign-
    # Vorgabe für die epos-Stage; default Fließtext.
    darstellungsform =
      case campaign[:vorgaben] do
        %{"epos" => %{darstellungsform: f}} when is_binary(f) and f != "" -> f
        _ -> "fliesstext"
      end

    prompt =
      build_epos_prompt(
        existing_md,
        all_summaries,
        campaign[:flavors] || %{},
        force?,
        darstellungsform,
        heading_directive(stage_heading(campaign, "epos"), "epos")
      )

    # Issue #226: Diagnostik IMMER aktiv (auch ohne force?). Macht künftig
    # diagnostizierbar ob "same prompt → same output" (LLM-Determinismus bei
    # niedrig-temp) oder "different prompt → same output" (echtes Caching
    # irgendwo, was wir heute nicht haben aber sicherheitshalber checken).
    Logger.info(
      "Pipeline: Stage 3 prompt sha=#{short_sha(prompt)} #{byte_size(prompt)} bytes #{length(all_summaries)} summaries force=#{force?}"
    )

    # Issue #114: JSON-Mode für strukturierten Output (content_md + source_refs).
    num_ctx = Worker.Settings.get(:ctx_stage3, 16384)
    guard_prompt_size(prompt, num_ctx, "stage3")
    base_llm_opts = [format: "json", num_ctx: num_ctx] ++ sampling_opts(3)

    # Issue #226: bei manuellem Re-Run temperature hochsetzen — sonst
    # bleibt das LLM bei temp=0.2 + nahezu identischem Prompt deterministisch
    # auf dem bisherigen Output kleben.
    llm_opts =
      if force?, do: Keyword.put(base_llm_opts, :temperature, 0.5), else: base_llm_opts

    # Issue #114: Fallback-Source-Refs sind die Union aller einfließenden
    # Summary-Refs (deduped). Falls Stage-3-LLM den JSON-Output nicht sauber
    # liefert, behält der Epos wenigstens die Audit-Spur seiner Quell-Resümees.
    fallback_refs =
      all_summaries
      |> Enum.flat_map(fn s -> Map.get(s, :source_refs, []) end)
      |> Enum.uniq()

    case LLM.complete(:epos, prompt, llm_opts) do
      {:ok, raw} ->
        {new_md, source_refs, notes} = parse_epos_json_with_notes(raw, fallback_refs)
        put_format_notes(notes)

        Logger.info(
          "Pipeline: Stage 3 output sha=#{short_sha(new_md)} #{byte_size(new_md)} bytes refs=#{length(source_refs)}"
        )

        publish_event(%{
          "kind" => Shared.Events.epos_entry_edited(),
          "entry_id" => campaign.id,
          "campaign_id" => campaign.id,
          "new_md" => new_md,
          "edited_by" => "llm",
          "source" => "llm",
          "source_refs" => source_refs
        })
        |> case do
          :ok -> {:ok, new_md}
          {:error, reason} -> {:error, {:stage3, {:publish_failed, reason}}}
        end

      {:error, reason} ->
        {:error, {:stage3, reason}}
    end
  end

  defp short_sha(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp stage4(epos_md, session_id, campaign) do
    # Issue #289 Phase 1: JSON-Schema-Mode (statt nur "json"), siehe stage2/3.
    opts =
      [format: stage4_json_schema(), num_ctx: Worker.Settings.get(:ctx_stage4, 8192)] ++
        sampling_opts(4)

    flavors = campaign[:flavors] || %{}
    heading = heading_directive(stage_heading(campaign, "chronik"), "chronik")

    # Issue #114: Stage 4 sieht nur Epos-MD (Campaign-weit aggregiert), aber
    # source_refs sollen auf utterance_ids dieser Session zeigen. Wir geben
    # dem LLM die Utterance-IDs der triggernden Session als Whitelist + Hint,
    # welche Refs in welche Chronik-Einträge gehören. Der Materializer
    # filtert eh nochmal über normalize_entry_refs (kein junk-passthrough).
    session_utterances = Repo.list_utterances(session_id)

    # Issue #307: Index-Map deckungsgleich mit der Whitelist im Prompt
    # (Enum.take(60) + 1-basierter Index). valid_ids über alle Utterances für
    # den UUID-Passthrough (Robustheit).
    index_map = utterance_index_map(Enum.take(session_utterances, 60))
    valid_ids = MapSet.new(session_utterances, & &1.id)

    with {:ok, entries} <-
           stage4_extract(epos_md, opts, :first_try, flavors, session_utterances, heading),
         {:ok, entries} <-
           maybe_retry_stage4(entries, epos_md, opts, flavors, session_utterances, heading) do
      entries
      |> resolve_entry_refs(index_map, valid_ids)
      |> stage4_publish(session_id, campaign)
    else
      {:error, reason} -> {:error, {:stage4, reason}}
    end
  end

  # Issue #307: pro Chronik-Eintrag die Kurz-ID-source_refs auf echte UUIDs
  # auflösen + gegen die Whitelist filtern. Ersetzt den ungeprüften
  # normalize_entry_refs-Passthrough, durch den der Prompt-Platzhalter
  # `<utterance-id-3>` (#114) in eine prod-Chronik durchgeleakt ist.
  defp resolve_entry_refs(entries, index_map, valid_ids) do
    Enum.map(entries, fn
      %{} = entry ->
        resolved = resolve_source_refs(Map.get(entry, "source_refs"), index_map, valid_ids)
        Map.put(entry, "source_refs", resolved)

      other ->
        other
    end)
  end

  defp stage4_extract(epos_md, opts, attempt, flavors, session_utterances, heading) do
    prompt = build_chronik_prompt(epos_md, attempt, flavors, session_utterances, heading)
    guard_prompt_size(prompt, Keyword.get(opts, :num_ctx, 8192), "stage4")

    case LLM.complete(:chronik, prompt, opts) do
      {:ok, json_str} ->
        {raw_entries, notes} = parse_chronik_json_with_notes(json_str)
        put_format_notes(notes)
        entries = filter_fabricated_chronik(raw_entries)

        if entries == [] do
          Logger.warning(
            "Stage 4 (#{attempt}): LLM returned 0 entries (after fabrication-filter). " <>
              "Raw output (truncated): " <> String.slice(json_str || "", 0, 400)
          )
        end

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Issue #289 Phase 1: JSON-Schema-Maps für Ollama-Strict-Mode ────
  #
  # Ollama akzeptiert für `format` entweder den String `"json"` (loser
  # JSON-Mode) oder eine JSON-Schema-Map (GBNF-Grammatik-Enforcement —
  # invalides JSON ist token-seitig unmöglich, Think-Blocks werden als
  # Nebeneffekt eliminiert). Die Schemata decken genau das ab, was
  # `parse_summary_json/2` und `parse_chronik_json/1` als kanonische Form
  # erwarten. Die defensiven Parser-Fallbacks (think-strip, code-fence-
  # strip, JSON-extract, Alt-Wrapper wie "chronik"/"timeline") bleiben für
  # Cloud-Backends (Anthropic/OpenAI) und ältere Modelle, die ohne
  # Schema-Mode laufen.
  defp stage2_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "content_md" => %{"type" => "string"},
        "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["content_md"]
    }
  end

  defp stage4_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "entries" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "in_game_date" => %{"type" => "string"},
              "label" => %{"type" => "string"},
              "summary" => %{"type" => "string"},
              "source_refs" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["in_game_date", "label", "summary"]
          }
        }
      },
      "required" => ["entries"]
    }
  end

  # Retry once with a sharper prompt if the first pass yielded no entries —
  # qwen2.5 sometimes returns {} on its first JSON-mode answer and resolves
  # with one nudge.
  defp maybe_retry_stage4([] = _empty, epos_md, opts, flavors, session_utterances, heading) do
    case stage4_extract(epos_md, opts, :retry, flavors, session_utterances, heading) do
      {:ok, entries} -> {:ok, entries}
      err -> err
    end
  end

  defp maybe_retry_stage4(entries, _epos_md, _opts, _flavors, _session_utterances, _heading),
    do: {:ok, entries}

  # Tries hard to extract a JSON array of chronik entries from arbitrary LLM
  # output. Issue #75: qwen3 (Thinking-Mode) prefixes every answer with a
  # `<think>...</think>` block, which busts Ollama's strict `format: "json"`
  # mode AND defeats `Jason.decode/1` if the model falls back to free-form
  # text. We strip the thinking-block, peel off Markdown code-fences, and
  # finally regex out the first JSON object/array if it's still embedded in
  # prose. Empty input or undecodable output return [], which the caller
  # treats as a stage failure (`stage4_publish/2`).
  @doc false
  def parse_chronik_json(raw) do
    {entries, _notes} = parse_chronik_json_with_notes(raw)
    entries
  end

  # Issue #288: Notes-Variante. Returns {entries, format_notes} damit der
  # Caller (stage4 / probelauf) die Strip-Diagnostik im pipeline_stage-
  # Event mit-publishen kann.
  @doc false
  @spec parse_chronik_json_with_notes(binary() | nil) :: {[map()], binary()}
  def parse_chronik_json_with_notes(raw) when is_binary(raw) do
    case parse_with_notes_decode(raw) do
      {{:ok, %{"entries" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, %{"chronik" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, %{"timeline" => list}}, notes} when is_list(list) -> {list, notes}
      {{:ok, list}, notes} when is_list(list) -> {list, notes}
      {{:ok, _other}, _notes} -> {[], "parse_failed"}
      {:parse_failed, notes} -> {[], notes}
    end
  end

  def parse_chronik_json_with_notes(_), do: {[], "ok"}

  # Issue #114: Parser für Stage-2-JSON-Output. Erwartetes Schema:
  #   {"content_md": "...", "source_refs": ["utt-id-1", ...]}
  # Robustness analog parse_chronik_json/1 (strip thinking-blocks + fences +
  # JSON-extract). Bei Parse-Fehler: Fallback auf den Trim des Raw-Outputs
  # als content_md mit leeren refs — die Pipeline läuft weiter, nur der
  # Audit-Trail fehlt.
  #
  # `valid_utterance_ids` ist die Whitelist der Utterance-IDs aus der Session.
  # Source-refs die nicht in dieser Liste sind (LLM-Halluzination) werden
  # silent gefiltert — der Output bleibt dadurch konsistent mit dem Repo.
  @doc false
  @spec parse_summary_json(binary() | nil, [map()]) :: {binary(), [binary()]}
  def parse_summary_json(raw, utterances) do
    case parse_summary_json_with_status(raw, utterances) do
      {:parsed, md, refs, _notes} -> {md, refs}
      {:fallback, md, _notes} -> {md, []}
    end
  end

  # Issue #289 Phase 2: Status-Variante. Differenziert zwischen
  # erfolgreichem JSON-Parse (`:parsed`) und Fallback auf raw-Text
  # (`:fallback`). Der Caller (stage2/3) entscheidet auf der Statusbasis
  # ob ein Retry mit Korrektur-Prompt sinnvoll ist.
  # Issue #288: 4. Tupel-Element ist `format_notes` (siehe strip_and_note/1)
  # — propagiert sich ins `pipeline_stage`-Status-Event.
  @doc false
  @spec parse_summary_json_with_status(binary() | nil, [map()]) ::
          {:parsed, binary(), [binary()], binary()} | {:fallback, binary(), binary()}
  def parse_summary_json_with_status(raw, utterances) when is_binary(raw) do
    valid_ids = MapSet.new(utterances, & &1.id)

    case parse_with_notes_decode(raw) do
      {{:ok, %{"content_md" => md} = m}, notes} when is_binary(md) ->
        # Issue #307: Kurz-IDs (`u3`) über die Index-Map zurück auf echte UUIDs
        # auflösen. Dual-akzeptierend, damit echte UUIDs (alte Pfade / Tests)
        # weiterhin durchgehen.
        index_map = utterance_index_map(utterances)
        refs = resolve_source_refs(Map.get(m, "source_refs"), index_map, valid_ids)

        {:parsed, String.trim(md), refs, notes}

      {{:ok, _other}, _notes} ->
        # JSON geparst, aber kein content_md → kein Schema-Match → "parse_failed"
        {:fallback, String.trim(raw), "parse_failed"}

      {:parse_failed, notes} ->
        # Fallback: Modell hat freie Form geantwortet — nimm den ganzen Text
        # als content_md, keine refs.
        {:fallback, String.trim(raw), notes}
    end
  end

  def parse_summary_json_with_status(_, _), do: {:fallback, "", "ok"}

  # Issue #114: Stage-3-JSON-Parser. Robustness analog parse_summary_json.
  # Bei Parse-Fehler: Fallback content_md = trim(raw), refs = fallback_refs
  # (= Vereinigung der einfließenden Summary-Refs aus stage3/3).
  @doc false
  @spec parse_epos_json(binary() | nil, [binary()]) :: {binary(), [binary()]}
  def parse_epos_json(raw, fallback_refs) do
    {md, refs, _notes} = parse_epos_json_with_notes(raw, fallback_refs)
    {md, refs}
  end

  # Issue #288: Notes-Variante (analog parse_chronik_json_with_notes).
  @doc false
  @spec parse_epos_json_with_notes(binary() | nil, [binary()]) ::
          {binary(), [binary()], binary()}
  def parse_epos_json_with_notes(raw, fallback_refs)
      when is_binary(raw) and is_list(fallback_refs) do
    case parse_with_notes_decode(raw) do
      {{:ok, %{"content_md" => md} = m}, notes} when is_binary(md) ->
        refs =
          case Map.get(m, "source_refs") do
            list when is_list(list) ->
              list |> Enum.filter(&is_binary/1) |> Enum.uniq()

            _ ->
              fallback_refs
          end

        {String.trim(md), refs, notes}

      {{:ok, _other}, _notes} ->
        {String.trim(raw), fallback_refs, "parse_failed"}

      {:parse_failed, notes} ->
        {String.trim(raw), fallback_refs, notes}
    end
  end

  def parse_epos_json_with_notes(_, fallback_refs) when is_list(fallback_refs),
    do: {"", fallback_refs, "ok"}

  # Issue #114: pro Chronik-Eintrag die LLM-source_refs robust machen —
  # erwarten Liste of binaries, filtern Junk raus, dedupe, fallback [].
  defp normalize_entry_refs(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_entry_refs(_), do: []

  # Issue #307: Kurz-ID-Mapping. Bildet die Lauf-Indizes `u1`…`uN` (im Prompt)
  # auf die echten Utterance-UUIDs ab — dieselbe `Enum.with_index/2`-Reihenfolge
  # wie der Prompt-Builder, daher muss keine Map durch die Pipeline gereicht
  # werden, der Parser rekonstruiert sie aus der Utterance-Liste.
  defp utterance_index_map(utterances) do
    utterances
    |> Enum.with_index(1)
    |> Map.new(fn {u, i} -> {"u#{i}", u.id} end)
  end

  # Issue #307: LLM-source_refs auf echte UUIDs auflösen. Dual: erst Kurz-ID
  # über die Index-Map, sonst Passthrough wenn der Ref schon eine valide echte
  # UUID ist (Robustheit + Backward-Compat zu Tests/alten Pfaden). Alles andere
  # — Halluzinationen, Prompt-Platzhalter wie `<utterance-id-3>` (#114-Leak) —
  # fällt raus.
  defp resolve_source_refs(refs, index_map, valid_ids) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_short_ref/1)
    |> Enum.map(fn ref ->
      cond do
        Map.has_key?(index_map, ref) -> Map.fetch!(index_map, ref)
        MapSet.member?(valid_ids, ref) -> ref
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_source_refs(_, _, _), do: []

  defp normalize_short_ref(ref) do
    ref
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim()
  end

  # Issue #307: grobe Token-Schätzung (Deutsch + Kurz-IDs ≈ 3 Bytes/Token,
  # gemessen in docs/Performance.md). Liegt der Prompt über `num_ctx`,
  # trunkiert Ollama den Transkript-ANFANG kommentarlos (behält die jüngsten
  # Token) — wir loggen das wenigstens als Warning, statt unbemerkt ein halbes
  # Transkript zu verarbeiten. Echtes Chunking ist die #307-Folge.
  defp guard_prompt_size(prompt, num_ctx, stage) when is_integer(num_ctx) do
    est = div(byte_size(prompt), 3)

    if est > num_ctx do
      Logger.warning(
        "Pipeline: #{stage} Prompt ~#{est} tok > num_ctx=#{num_ctx} — " <>
          "Ollama schneidet den Transkript-Anfang still ab. Lange Session: " <>
          "Chunking nötig (#307-Folge)."
      )
    end

    :ok
  end

  defp guard_prompt_size(_prompt, _num_ctx, _stage), do: :ok

  # Issue #230: drop Einträge die LLM-Sentinel-Strings enthalten (selbst-
  # eingestandene Fabrication wie `in_game_date == "Nicht im Transkript
  # erwähnt"`). Public via @doc false damit der Pipeline-Filter-Test ohne
  # GenServer-Setup direkt callen kann — analog zu `parse_chronik_json/1`.
  @doc false
  def filter_fabricated_chronik(entries) when is_list(entries) do
    {kept, dropped} = Enum.split_with(entries, &(not fabricated_entry?(&1)))

    if dropped != [] do
      sample =
        dropped
        |> List.first()
        |> case do
          %{} = e ->
            Map.get(e, "label") || Map.get(e, "title") || Map.get(e, "in_game_date") || ""

          _ ->
            ""
        end

      Logger.warning(
        "Stage 4: filtered #{length(dropped)} fabricated chronik entries " <>
          "(kept #{length(kept)}). Sample=#{inspect(sample)}"
      )
    end

    kept
  end

  def filter_fabricated_chronik(_), do: []

  defp fabricated_entry?(entry) when is_map(entry) do
    fields = [
      Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
      Map.get(entry, "label") || Map.get(entry, "title") || "",
      Map.get(entry, "summary") || Map.get(entry, "description") || ""
    ]

    Enum.any?(@fabrication_sentinels, fn pattern ->
      Enum.any?(fields, fn field ->
        is_binary(field) and Regex.match?(pattern, field)
      end)
    end)
  end

  defp fabricated_entry?(_), do: true

  defp strip_think_blocks(s) do
    Regex.replace(~r/<think>.*?<\/think>/s, s, "")
  end

  defp strip_code_fence(s) do
    case Regex.run(~r/```(?:json)?\s*\n?(.+?)\n?```/s, s) do
      [_, inner] -> inner
      _ -> s
    end
  end

  # Issue #288: zentraler Sanitize-Helper. Wendet die Strip-Stufen
  # nacheinander an und akkumuliert welche tatsächlich gegriffen haben als
  # pipe-getrennter String (`"think_stripped|fence_unwrapped"`). Wenn keine
  # Stufe greift → `"ok"`. `extract_json_blob` zählt bewusst nicht (Last-
  # Resort-Prose-Extract, kein diagnostisches Signal — Issue #288 spec).
  @doc false
  def strip_and_note(raw) when is_binary(raw) do
    {after_think, notes_after_think} =
      case strip_think_blocks(raw) do
        ^raw -> {raw, []}
        stripped -> {stripped, ["think_stripped"]}
      end

    {after_fence, notes_after_fence} =
      case strip_code_fence(after_think) do
        ^after_think -> {after_think, notes_after_think}
        stripped -> {stripped, notes_after_think ++ ["fence_unwrapped"]}
      end

    cleaned = extract_json_blob(after_fence)
    notes_str = if notes_after_fence == [], do: "ok", else: Enum.join(notes_after_fence, "|")

    {cleaned, notes_str}
  end

  def strip_and_note(_), do: {"", "ok"}

  # Issue #288: kombiniert strip+notes mit dem Parse-Outcome. Wenn
  # Jason.decode scheitert wird `format_notes` zu `"parse_failed"`
  # promoviert (überstimmt die strip-Notes, die ohnehin nicht persistiert
  # werden wenn der Parse fehlschlägt).
  defp parse_with_notes_decode(raw) do
    {cleaned, strip_notes} = strip_and_note(raw)

    case Jason.decode(cleaned) do
      {:ok, decoded} -> {{:ok, decoded}, strip_notes}
      {:error, _} -> {:parse_failed, "parse_failed"}
    end
  end

  defp extract_json_blob(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        trimmed

      true ->
        case Regex.run(~r/(\{.*\}|\[.*\])/s, trimmed) do
          [_, json] -> json
          _ -> trimmed
        end
    end
  end

  # Issue #75: an empty entries list after retry is a stage failure, not a
  # silent OK. Without this branch the LLM can return "" forever and the
  # pipeline still reports `ended` — masking real model-incompatibility.
  defp stage4_publish([], _session_id, _campaign) do
    Logger.warning("Stage 4: LLM returned no usable chronik entries even after retry")
    {:error, :empty_chronik}
  end

  # Issue #227: Re-Run-Cleanup. Vor neuen ChronikEntryChanged-Events räumen
  # wir die bestehenden Chronik-Rows derselben session_id aus — sonst
  # akkumulieren Halluzinationen über jeden Re-Run hinweg, weil die
  # SHA-abgeleiteten IDs auf (date, label) sich ändern und alte Rows nie
  # überschrieben werden.
  defp stage4_publish(entries, session_id, campaign) do
    case Intents.publish(%{
           "kind" => Shared.Events.chronik_cleared_for_session(),
           "campaign_id" => campaign.id,
           "session_id" => session_id,
           "cleared_by" => "llm"
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Stage 4: chronik-clear publish failed (session=#{session_id}): #{inspect(reason)} — " <>
            "proceeding with entry-publish anyway"
        )
    end

    results =
      Enum.map(entries, fn entry ->
        Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_chronik_id(entry),
          "campaign_id" => campaign.id,
          "in_game_date" => Map.get(entry, "in_game_date") || Map.get(entry, "date"),
          "label" => Map.get(entry, "label") || Map.get(entry, "title") || "",
          "summary" => Map.get(entry, "summary") || Map.get(entry, "description"),
          "session_id" => session_id,
          # Issue #114: source_refs pro Eintrag aus dem Stage-4-JSON.
          # Bei alten Modellen die kein refs-Feld liefern: leer (Audit-Spur
          # fehlt, Pipeline läuft normal weiter).
          "source_refs" => normalize_entry_refs(Map.get(entry, "source_refs"))
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _}, &1))

    if failures == [] do
      Logger.info("Stage 4: wrote #{length(entries)} chronik entries (session=#{session_id})")
      :ok
    else
      Logger.warning(
        "Stage 4: #{length(failures)} of #{length(entries)} chronik publishes failed: " <>
          inspect(List.first(failures))
      )

      {:error, {:stage4_publish, List.first(failures)}}
    end
  end

  # Hard-Match auf `{:ok, _seq}` wird vermieden: bei Hub-Outage liefert
  # `Intents.publish` `{:error, :not_connected}` (oder Timeout), was ohne diesen
  # Wrapper einen MatchError in der Stage werfen würde. Stattdessen wird der
  # Fehler geloggt und an den Caller propagiert, der entscheidet ob die Stage
  # damit als fehlgeschlagen gilt (z.B. Stage 2/3) oder ob die Pipeline trotzdem
  # weiterläuft (z.B. Faithfulness, weil optional).
  defp publish_event(payload) do
    case Intents.publish(payload) do
      {:ok, _seq} ->
        :ok

      {:error, reason} ->
        Logger.warning("Pipeline: publish failed (kind=#{payload["kind"]}): #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp derive_chronik_id(entry) do
    seed =
      [
        Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
        Map.get(entry, "label") || Map.get(entry, "title") || ""
      ]
      |> Enum.join("|")

    "chronik-" <>
      (:crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  # ─── Prompt builders ─────────────────────────────────────────────

  defp build_summary_prompt(utterances, speaker_names, flavors, heading) do
    # Issue #307: Kurz-IDs `[u1]…[uN]` statt voller UUID. Eine UUID tokenisiert
    # zu ~30 Token, ein `[uN]`-Marker zu ~3 — gemessen ~60% Prompt-Ersparnis,
    # was das Context-Ceiling von ~1600 auf ~4000 Utterances schiebt (siehe
    # docs/Performance.md). Der Parser (parse_summary_json/2) mappt die Kurz-IDs
    # über dieselbe `Enum.with_index/2`-Reihenfolge zurück auf echte UUIDs.
    transcript =
      utterances
      |> Enum.with_index(1)
      |> Enum.map(fn {u, i} ->
        "[u#{i}] #{Map.get(speaker_names, u.discord_id, u.discord_id)}: #{u.text}"
      end)
      |> Enum.join("\n")

    """
    #{heading}#{flavor_preamble(flavors, "summary")}Verdichte das folgende Transkript zu einem Resümee auf Deutsch
    (3-6 Sätze). Überspringe Out-of-Game-Smalltalk (Pizza, Pausen,
    Regelfragen).

    Antworte in genau diesem JSON-Format (keine Vorrede, kein Code-Fence):
    {
      "content_md": "<Resümee als Markdown-Text>",
      "source_refs": ["u1", "u7", ...]
    }

    `source_refs` ist die Liste der `u…`-Marker (in eckigen Klammern unten),
    auf denen das Resümee fußt. Verwende nur Marker aus dem Transkript; nimm
    die 3-8 wichtigsten Quellen, nicht alle.

    Transkript:
    #{transcript}

    #{fact_fidelity_block("Transkript")}
    """
  end

  defp fact_fidelity_block(source_label) do
    """
    FAKTENTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Verwende NUR Namen, Orte und Ereignisse die explizit im #{source_label} oben stehen.
    - Wenn ein Detail nicht im #{source_label} steht, lass es weg — fülle keine Lücken aus.
    - Wenn das Material nicht für die angefragte Länge reicht, schreibe weniger.
    - Keine inneren Monologe, keine erfundenen Nebenfiguren, keine ausgeschmückten Szenen.
    """
  end

  # Issue #308: Der Epos ist die literarische Ebene — Handlung treu, Erzählweise
  # frei. Bewusst gelockert ggü. fact_fidelity_block/1 (das für Resümee/Chronik
  # gilt): literarische Ausschmückung des WIE ist erwünscht, solange das WAS
  # (Figuren, Ereignisse, Reihenfolge, Ausgang) aus den Resümees stammt.
  defp epos_fidelity_block do
    """
    ERZÄHL-TREUE (Handlung treu, Erzählweise frei — gilt vor allen Stil-Vorgaben):
    - Die Handlung ist bindend: Figuren-Namen, zentrale Ereignisse, deren
      Reihenfolge und Ausgang müssen aus den Session-Resümees oben stammen.
    - Erfinde KEINE neuen Plot-Fakten: keine zusätzlichen benannten Figuren,
      keine Ereignisse oder Wendungen, die nicht in den Resümees vorkommen.
    - Das WIE darfst du literarisch ausmalen: Atmosphäre, Stimmung, Schauplatz-
      Schilderung, Stimmungen und Regungen der Figuren, Übergänge und eine
      durchgängige Erzählstimme sind ausdrücklich erwünscht — solange sie der
      bekannten Handlung nicht widersprechen.
    - Wenn das Material dünn ist, erzähle knapper statt Handlung zu erfinden.
    """
  end

  # Stellt den Stil/Voice der LLM-Antworten als Preamble vorne an. Base
  # (Welt/Setting) und slot-spezifische Voice werden kombiniert. Wenn die
  # Campaign weder Base noch Slot gesetzt hat, kommt nichts — der Prompt
  # bleibt setting-neutral und sachlich.
  defp flavor_preamble(flavors, slot) when is_map(flavors) do
    parts =
      ["base", slot]
      |> Enum.uniq()
      |> Enum.map(&effective_flavor(flavors, &1))
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.trim/1)

    case parts do
      [] ->
        ""

      list ->
        "Stil-Vorgabe für diese Kampagne (oberste Priorität — Wortwahl, Ton, Atmosphäre, NICHT Inhalt oder Format):\n\n" <>
          Enum.join(list, "\n\n") <> "\n\n"
    end
  end

  defp flavor_preamble(_flavors, _slot), do: ""

  # Issue #313: campaign-gesetzter Ton gewinnt; sonst greift der Default-Ton
  # des Slots. Der #308-Literarik-Ton („atmosphärisch, Spannungsbögen …")
  # lebt jetzt hier als editierbarer Default für „epos" — nicht mehr
  # hartcodiert im gesperrten build_epos_prompt-Block. So bleibt der Output
  # out-of-the-box literarisch, ist aber pro Kampagne überschreibbar.
  @default_epos_flavor "Erzähle die Ereignisse als zusammenhängende, atmosphärische Geschichte: Stimmung, Schauplätze, Spannungsbögen und eine durchgängige Erzählstimme. Gib den Abschnitten erzählerische Titel."

  def effective_flavor(flavors, slot) when is_map(flavors) do
    case Map.get(flavors, slot) do
      s when is_binary(s) ->
        if String.trim(s) == "", do: default_flavor(slot), else: s

      _ ->
        default_flavor(slot)
    end
  end

  def default_flavor("epos"), do: @default_epos_flavor
  def default_flavor(_slot), do: nil

  # Issue #320: Überschrift (vorgaben[stage].name) als Prompt-Direktive. Die
  # Überschrift wird als Textsorte/Gattung verstanden — das LLM gestaltet den
  # Output entsprechend und erzeugt einen ZUM INHALT passenden Titel/Schlagzeile,
  # NICHT das Gattungswort selbst (z.B. „Zeitungsartikel" → echte Schlagzeile,
  # „Novelle" → echter Novellen-Titel). Nur wenn ein Name gesetzt ist — sonst ""
  # (Default-Spalten unverändert). Stage-aware: Chronik ist strikte JSON-Liste,
  # da nur Stil-Rahmung statt freier Überschrift.
  @spec heading_directive(String.t() | nil, String.t()) :: String.t()
  def heading_directive(name, stage) when is_binary(name) do
    case String.trim(name) do
      "" -> ""
      n -> format_directive(stage, n)
    end
  end

  def heading_directive(_, _), do: ""

  defp format_directive("chronik", n),
    do:
      "Formuliere die Chronik-Einträge im Stil der Textsorte «#{n}» " <>
        "(das Listen-/JSON-Format unten bleibt unverändert).\n\n"

  defp format_directive(_stage, n),
    do:
      "Gestalte diesen Abschnitt als «#{n}» (Textsorte/Gattung): folge ihren Konventionen und " <>
        "beginne mit einer zum INHALT passenden Überschrift bzw. Schlagzeile im Stil dieser " <>
        "Textsorte. Verwende NICHT das Wort «#{n}» selbst als Titel.\n\n"

  # Eigener Überschrift-Name dieser Stage aus den Campaign-Vorgaben (nil = default).
  @spec stage_heading(map(), String.t()) :: String.t() | nil
  def stage_heading(campaign, stage) when is_map(campaign) do
    case campaign[:vorgaben] do
      %{^stage => %{name: n}} when is_binary(n) -> n
      _ -> nil
    end
  end

  def stage_heading(_, _), do: nil

  # Sampling-Knöpfe pro Stage (Issue #11). Liefert eine Keyword-Liste mit
  # temperature/top_p/num_predict/repeat_penalty; nil-Werte werden vom
  # Backend ignoriert (Worker.LLM.Local.build_options/1).
  defp sampling_opts(stage) when stage in [2, 3, 4] do
    [
      temperature: Worker.Settings.get(:"temperature_stage#{stage}"),
      top_p: Worker.Settings.get(:"top_p_stage#{stage}"),
      num_predict: Worker.Settings.get(:"num_predict_stage#{stage}"),
      repeat_penalty: Worker.Settings.get(:"repeat_penalty_stage#{stage}")
    ]
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  # Build discord_id → preferred-display-name STRING map for the campaign:
  # character_name (Issue #2) wins; else users.display_name; else raw id.
  defp resolve_speaker_names(campaign_id) do
    char_names = Repo.character_names_for(campaign_id)

    # users_for_campaign returns %{did => %{display_name, avatar_url}} after #6;
    # flatten to a string-map before merging with char_names (also strings).
    user_names =
      Repo.users_for_campaign(campaign_id)
      |> Enum.into(%{}, fn
        {did, %{"display_name" => name}} -> {did, name}
        {did, name} when is_binary(name) -> {did, name}
        {did, _} -> {did, did}
      end)

    Map.merge(user_names, char_names)
  end

  # Public so tests können den Prompt-Build über `apply/3` verifizieren
  # (Issue #226). Marker `@doc false` weil interne API — nicht für externe
  # Aufrufer gedacht.
  @doc false
  def build_epos_prompt(
        existing_md,
        summaries,
        flavors,
        force? \\ false,
        darstellungsform \\ "fliesstext",
        heading \\ ""
      )
      when is_list(summaries) do
    # Issue #114: jede Session-Block trägt jetzt die Liste ihrer Source-
    # Utterance-IDs als annotation. Stage 3 LLM kann daraus pro Absatz oder
    # global eine `source_refs`-Liste zurückgeben (Vereinigung der Quellen
    # die einflossen).
    summaries_block =
      summaries
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} ->
        refs = Map.get(s, :source_refs, [])

        refs_line =
          if refs == [],
            do: "",
            else: "Quell-Utterances: #{Enum.join(refs, ", ")}\n"

        "### Session #{i}\n#{refs_line}#{s.content_md}"
      end)
      |> Enum.join("\n\n")

    # Issue #226: bei manuellem Re-Run (force=true) einen expliziten Hinweis
    # in den Prompt einbauen — sonst produziert das LLM bei nahezu-identischem
    # Input einen bit-identischen Output (temp=0.2 + nur subtil geänderte
    # Summaries → deterministisches Verhalten).
    force_hint =
      if force? do
        """

        HINWEIS: Dies ist ein expliziter Re-Run. Integriere insbesondere die
        jüngsten Session-Inhalte sichtbar in den fortlaufenden Epos. Wiederhole
        NICHT den bisherigen Text wortgleich, sondern erweitere ihn um die
        neuen Plot-Punkte aus den zuletzt hinzugekommenen Resümees.
        """
      else
        ""
      end

    """
    #{heading}#{flavor_preamble(flavors, "epos")}#{epos_structure_block(darstellungsform)}

    Antworte in genau diesem JSON-Format (keine Vorrede, kein Code-Fence):
    {
      "content_md": "<vollständiger Markdown-Text>",
      "source_refs": ["<utterance-id-1>", "<utterance-id-2>", ...]
    }

    `source_refs` ist die Vereinigung der wichtigsten Quell-Utterance-IDs
    aus den Session-Resümees (siehe Annotationen). Übernehme die utterance_ids
    aus den Resümees, max. 30 Stück (die wichtigsten).

    Bisheriger Text (NUR als Referenz für bereits etablierte Namen und
    Kontinuität — NICHT den Stil übernehmen; folge dem oben gesetzten Stil):
    #{existing_md}

    Session-Resümees (chronologisch):
    #{summaries_block}

    #{epos_fidelity_block()}
    #{force_hint}
    """
  end

  # Issue #313: genre-neutraler Struktur-Block (gesperrt) — nur die FORM,
  # kein Ton. Fließtext (Prosa) vs. Stichpunkte (Liste). Der literarische
  # Ton kommt aus dem editierbaren Flavor (Default = @default_epos_flavor),
  # nicht mehr von hier — so passt der fixe Teil für jedes Genre.
  def epos_structure_block("stichpunkte") do
    String.trim("""
    Fasse die chronologisch aufgelisteten Session-Resümees unten zu einer
    gegliederten Liste auf Deutsch zusammen: ein Stichpunkt pro Ereignis, in
    zeitlicher Reihenfolge. Gruppiere zusammengehörende Ereignisse über
    Session-Grenzen hinweg unter `##`-Abschnitts-Überschriften (nicht pro
    Session). Keine ausschweifende Prosa.
    """)
  end

  def epos_structure_block(_fliesstext) do
    String.trim("""
    Schreibe aus den chronologisch aufgelisteten Session-Resümees unten einen
    zusammenhängenden Fließtext (Prosa) auf Deutsch — KEINE Aufzählung. Gliedere
    nach HANDLUNGSBÖGEN, nicht pro Session: fasse zusammengehörende Ereignisse
    über Session-Grenzen hinweg unter `##`-Überschriften zusammen. Optional ein
    `#`-Titel für das ganze Dokument.
    """)
  end

  # Issue #320: Marker für die im Vorschau-Prompt gekürzten Quelldaten.
  @preview_more "[… weiteres Material hier gekürzt — die LLM bekommt den vollständigen Inhalt …]"

  @doc """
  Issue #313/#320: liefert den Stage-Prompt als Segment-Liste für die Hub-
  Vorschau. **Byte-genau**: ruft denselben echten Builder auf, den die Pipeline
  benutzt (mit gekürzten Beispiel-Quelldaten), und markiert darin nur die
  editierbaren Werte (Ton `base`/Stage + Überschrift `name`) als `:editable` —
  alles andere bleibt `:locked` und ist wortgleich der echte LLM-Input. Die
  Builder selbst bleiben unverändert → kein Drift zwischen Vorschau und Realität.
  """
  @spec preview_prompt(String.t(), map()) :: [tuple()]
  def preview_prompt(stage, campaign)
      when stage in ["summary", "epos", "chronik"] and is_map(campaign) do
    flavors = campaign[:flavors] || %{}

    form =
      case campaign[:vorgaben] do
        %{^stage => %{darstellungsform: f}} when is_binary(f) and f != "" -> f
        _ -> "fliesstext"
      end

    heading = heading_directive(stage_heading(campaign, stage), stage)
    real = preview_real_prompt(stage, campaign, flavors, heading, form)

    # Editierbare Werte (so wie sie im echten Prompt stehen = getrimmt).
    values =
      [
        {"name", stage_heading(campaign, stage)},
        {"base", effective_flavor(flavors, "base")},
        {stage, effective_flavor(flavors, stage)}
      ]
      |> Enum.map(fn {slot, v} -> {slot, String.trim(to_string(v || ""))} end)
      |> Enum.reject(fn {_slot, v} -> v == "" end)

    tokenize_editables(real, values)
  end

  # Ruft den echten Builder mit gekürzten Beispiel-Quelldaten auf.
  defp preview_real_prompt("summary", campaign, flavors, heading, _form),
    do: build_summary_prompt(sample_utterances(campaign), %{}, flavors, heading)

  defp preview_real_prompt("epos", campaign, flavors, heading, form),
    do: build_epos_prompt("", sample_summaries(campaign), flavors, false, form, heading)

  defp preview_real_prompt("chronik", campaign, flavors, heading, _form),
    do:
      build_chronik_prompt(
        sample_epos(campaign),
        :first_try,
        flavors,
        sample_utterances(campaign),
        heading
      )

  defp sample_utterances(campaign) do
    base =
      with cid when is_binary(cid) <- campaign[:id],
           [session | _] <- Repo.list_sessions(cid),
           [_ | _] = utts <- Repo.list_utterances(session.id) do
        utts
        |> Enum.take(3)
        |> Enum.map(fn u ->
          %{discord_id: u.discord_id, text: String.slice(to_string(u.text), 0, 120), id: u.id}
        end)
      else
        _ -> []
      end

    base ++ [%{discord_id: "—", text: @preview_more, id: "preview-marker"}]
  end

  defp sample_summaries(campaign) do
    base =
      with cid when is_binary(cid) <- campaign[:id],
           [_ | _] = sums <- Repo.list_session_summaries(cid) do
        sums
        |> Enum.take(2)
        |> Enum.map(fn s ->
          %{
            content_md: String.slice(to_string(s.content_md), 0, 200),
            source_refs: Map.get(s, :source_refs, [])
          }
        end)
      else
        _ -> []
      end

    base ++ [%{content_md: @preview_more, source_refs: []}]
  end

  defp sample_epos(campaign) do
    case campaign[:id] && Repo.get_epos_entry(campaign[:id]) do
      %{content_md: md} when is_binary(md) and md != "" ->
        String.slice(md, 0, 240) <> "\n\n" <> @preview_more

      _ ->
        @preview_more
    end
  end

  # Zerlegt den echten Prompt-String in `:locked`-Text + `:editable`-Slots, indem
  # die (getrimmten) Eingabewerte an ihrer ersten Fundstelle markiert werden.
  # Links-nach-rechts, ein Wert je Fundstelle (Rest wird im Resttext gesucht →
  # auch gleiche base/stage-Texte werden korrekt getrennt).
  defp tokenize_editables(text, values) do
    matches =
      values
      |> Enum.flat_map(fn {slot, v} ->
        case :binary.match(text, v) do
          {pos, len} -> [{pos, len, slot, v}]
          :nomatch -> []
        end
      end)

    case Enum.min_by(matches, &elem(&1, 0), fn -> nil end) do
      nil ->
        drop_empty([{:locked, text}])

      {pos, len, slot, v} ->
        before = binary_part(text, 0, pos)
        rest = binary_part(text, pos + len, byte_size(text) - pos - len)

        drop_empty([{:locked, before}, {:editable, slot, v}]) ++
          tokenize_editables(rest, List.delete(values, {slot, v}))
    end
  end

  defp drop_empty(segs) do
    Enum.reject(segs, fn
      {:locked, ""} -> true
      _ -> false
    end)
  end

  defp build_chronik_prompt(epos_md, attempt, flavors, session_utterances, heading) do
    nudge =
      case attempt do
        :retry ->
          """

          HINWEIS: Im ersten Versuch hast du eine leere Liste geliefert.
          Schaue noch einmal nach klaren Plot-Beats (Ankunft, Begegnung,
          Kampf, Entdeckung). Wenn das Material in einem Kapitel keinen
          klaren Plot-Beat hergibt, lass es weg — eine leere Liste ist
          besser als erfundene Einträge.
          """

        _ ->
          ""
      end

    # Issue #114/#307: verfügbare Kurz-IDs als Whitelist für source_refs.
    # `[uN]` statt voller UUID (Token-Diät, siehe build_summary_prompt). Index
    # 1-basiert, deckungsgleich mit der Auflösung in stage4/3 (Enum.take(60)).
    utterance_ids_block =
      session_utterances
      |> Enum.take(60)
      |> Enum.with_index(1)
      |> Enum.map(fn {u, i} ->
        text_preview = u.text |> to_string() |> String.slice(0, 60)
        "  - u#{i}: #{text_preview}"
      end)
      |> Enum.join("\n")

    """
    #{heading}#{flavor_preamble(flavors, "chronik")}Du extrahierst aus dem folgenden Text eine In-Game-Zeitstrahl-Liste.
    Liefere JSON in genau diesem Format:

    {
      "entries": [
        {
          "in_game_date": "<Zeitangabe wie im Text>",
          "label": "<kurze Überschrift>",
          "summary": "<ein Satz auf Deutsch>",
          "source_refs": ["u3", "u14"]
        }
      ]
    }

    Regeln:
    - `in_game_date` ist die In-Game-Zeitangabe wie sie im Text steht.
      Wenn der Text nur narrative Marker hat, verwende diese als Datum.
    - `label` ist eine kurze Überschrift (max 50 Zeichen).
    - `summary` ist ein Satz auf Deutsch.
    - `source_refs` ist die Liste der `u…`-Marker (siehe Whitelist unten)
      die zu diesem Eintrag beigetragen haben — leer wenn keine passt.
    - Antworte NUR mit dem JSON, keine Vorrede.

    ANTI-FABRICATION (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Wenn der Text kein konkretes Datum oder keinen klaren Plot-Beat
      hergibt, lass den Eintrag weg. Eine leere Liste ist eine gültige
      Antwort.
    - Schreibe NIEMALS in `in_game_date` Strings wie "Nicht im Transkript
      erwähnt", "Unbekannt", "Keine Angabe", "N/A" — das sind keine
      gültigen Daten, der Eintrag gehört dann gar nicht in die Liste.
    - Erfinde keine Cliffhanger, keine Atmospheric Filler, keine
      Übergangs-Sätze "Die Gruppe macht sich auf …" wenn dazu nichts
      Konkretes im Transkript steht.
    - source_refs darf nur `u…`-Marker aus der Whitelist unten enthalten —
      keine erfundenen Marker.#{nudge}

    Verfügbare Utterance-Marker der triggernden Session:
    #{utterance_ids_block}

    Text:
    #{epos_md}

    #{fact_fidelity_block("Text")}
    """
  end
end
