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

  ## Single-Worker-Election (Issue #365)

  Der Member-Check ist nur das **Eligibility-/Privacy-Gate** (ein Nicht-Member-
  Worker darf keine Kampagnen-Daten durch ein LLM jagen). Er reicht NICHT als
  Election: bei mehreren connected Member-Workern wird `UtterancesTranscribed`
  via Hub an ALLE geforwarded, jeder appliest lokal + broadcastet `{:applied, …}`
  auf `"applied_events"`, und ohne weiteren Filter würde JEDER Member-Worker die
  Stages 2-4 starten → doppelte LLM-Calls + doppelte Stage-Output-Events
  (unterschiedliche Event-UUIDs, der Materializer-Dedup greift nicht).

  Election-Mechanik ohne neue Hub-Koordination:

    - `Worker.Intents.publish/1` stempelt `author_worker_id` (= eigene
      `worker_id`) ins Event-Envelope.
    - `HubWeb.WorkerChannel` setzt beim `publish_intent` die author-ID auf die
      publizierende Worker-ID (`Hub.Events.broadcast(event_id, payload,
      socket.assigns.worker_id)`) und forwarded sie via `event_to_wire` an alle
      Member-Worker — Producer wie Empfänger sehen dieselbe ID.
    - Der transkribierende Worker ist per Konstruktion genau einer:
      `Hub.Commands.pick_leader/2` routet alle Audio-Chunks einer Session an
      einen einzigen Member-Worker, der buffert + transkribiert +
      `UtterancesTranscribed` publisht.

  Daher feuert die Pipeline im event-getriggerten Pfad nur auf dem Worker, der
  das Event selbst produziert hat (`author_worker_id == worker_id`, siehe
  `elected?/2`). Catch-up/Pull-Events tragen `author_worker_id == nil`
  (`Worker.HubClient`) → werden übersprungen, ein nachträglich syncender Worker
  re-runt also keine bereits fertige Session. Der manuelle Trigger
  (`run_for_session/2` via `handle_call`) bleibt ungegated — den routet
  `Hub.Commands` ohnehin gezielt an einen Worker (CampaignReplay / Probelauf /
  UI-Regenerate).
  """

  use GenServer

  require Logger

  alias Shared.Events
  alias Worker.{Intents, Repo}
  # Issue #583: God-Module-Split — Stage-Impl/Prompt-Bau/Output-Parse ausgelagert.
  alias Worker.Recording.Pipeline.{Parsing, Prompts, Stages}

  # Issue #571: Modul-Attribute für event-kind-Match im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard/Pattern). Hier wirkt das
  # Attribut wie ein bedingter Pattern-Constant; die Aliasing über
  # Shared.Events.x() macht den Hardcoded-String-Drift unmöglich.
  @utterances_transcribed_kind Events.utterances_transcribed()

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
  # Issue #355: triggert jetzt auf `UtterancesTranscribed` (firet nach
  # Transcribe-Ende). SessionEnded firet bereits beim Recording-Stop in
  # `AudioBuffer.finalize`, BEVOR die Transkription läuft — die Utterances
  # existieren zu dem Zeitpunkt noch nicht, daher hier nicht mehr als
  # Trigger geeignet.
  #
  # Issue #365: Single-Worker-Election. Das Event wird via Hub an ALLE Member-
  # Worker geforwarded; ohne Filter würde jeder die Stages starten (doppelte
  # LLM-Calls + Doppel-Events). Nur der Worker, der das Event selbst produziert
  # hat (`author_worker_id == eigene worker_id`), fährt die Pipeline — siehe
  # `elected?/2` + Moduledoc.
  def handle_info(
        {:applied, %{"payload" => %{"kind" => @utterances_transcribed_kind} = payload} = event},
        state
      ) do
    session_id = payload["session_id"]

    cond do
      not elected?(event, Repo.get_state(:worker_id)) ->
        {:noreply, state}

      MapSet.member?(state.running, session_id) ->
        {:noreply, state}

      true ->
        maybe_run(session_id, state)
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

  # Issue #365: Election-Prädikat. `true` gdw. dieser Worker das Event selbst
  # produziert hat. Der Hub stempelt `author_worker_id` auf die publizierende
  # Worker-ID und forwarded sie an alle Member-Worker, daher reicht der
  # Gleichheits-Vergleich mit der eigenen `worker_id`.
  #
  # Edge-Cases:
  #   - Catch-up/Pull-Events tragen `author_worker_id == nil` (Worker.HubClient)
  #     → `nil != worker_id` → skip (paired Worker re-runt keine fertige Session).
  #   - Ungepairter Single-Worker-Dev: `worker_id == nil` und author ebenfalls
  #     `nil` → `nil == nil` → läuft (kein Multi-Worker-Race möglich; der
  #     Member-Check in `maybe_run/3` bleibt als zweites Gate).
  @doc false
  @spec elected?(map(), term()) :: boolean()
  def elected?(event, my_worker_id) when is_map(event) do
    Map.get(event, "author_worker_id") == my_worker_id
  end

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
          #
          # Issue #571: Worker.TaskSupervisor statt bare Task.start — Stage-
          # Pipeline-Crashes (z.B. Mnesia-Race, GpuQueue weg) sollen im
          # Supervisor-Log auftauchen. Caveat: bei Crash bleibt session_id in
          # `state.running` hängen, keine :stage_done-Signal → eigener
          # Folge-Cut für Process.monitor/DOWN-Cleanup.
          Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
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

  defp run_stages(session, campaign, opts) do
    # Issue #506: `limit: :all` — die Pipeline braucht die GANZE Session, nicht
    # nur die letzten 200 Utts (Default-Cap). Stage 2 chunked lange Sessions
    # via stage2_map_reduce (#417); das Cap hat diesen Pfad bislang ausgehungert
    # → trunkierte Resümees für alles >200 Utts (lange Aufnahmen, Importe, Seeds).
    utterances = Repo.list_utterances(session.id, limit: :all)

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
      Stages.stage2(utterances, session.id, campaign)
    end)
  end

  defp run_or_load_stage2(only_stages, utterances, session, campaign) do
    if 2 in only_stages do
      with_status(campaign.id, "stage2", session.id, fn ->
        Stages.stage2(utterances, session.id, campaign)
      end)
    else
      load_summary_from_repo(session.id)
    end
  end

  defp run_or_load_stage3(nil, summary_md, _session, campaign, opts) do
    with_status(campaign.id, "stage3", fn -> Stages.stage3(summary_md, campaign, opts) end)
  end

  defp run_or_load_stage3(only_stages, summary_md, _session, campaign, opts) do
    if 3 in only_stages do
      with_status(campaign.id, "stage3", fn -> Stages.stage3(summary_md, campaign, opts) end)
    else
      load_epos_from_repo(campaign.id)
    end
  end

  defp maybe_stage4(nil, epos_md, session, campaign) do
    with_status(campaign.id, "stage4", session.id, fn ->
      Stages.stage4(epos_md, session.id, campaign)
    end)
  end

  defp maybe_stage4(only_stages, epos_md, session, campaign) do
    if 4 in only_stages do
      with_status(campaign.id, "stage4", session.id, fn ->
        Stages.stage4(epos_md, session.id, campaign)
      end)
    else
      :ok
    end
  end

  defp maybe_faithfulness(nil, summary, utterances, session, campaign) do
    Stages.stage_faithfulness(summary, utterances, session.id, campaign.id)
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

  def with_status(campaign_id, stage, fun), do: with_status(campaign_id, stage, nil, fun)

  def with_status(campaign_id, stage, session_id, fun) do
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
  def publish_pipeline_error(campaign_id, stage, session_id, reason, message) do
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

    # Issue #430: Intents.publish/1 gibt immer {:ok, …} (kein toter {:error}-Branch).
    {:ok, _seq} = Intents.publish(payload)
    :ok
  end

  # Issue #589 (Cut 3): Stage-Bodies wrappen ihren inneren Fehler als
  # `{:error, {:stageN, inner_reason}}` (stages.ex, Z. 101/475/525/712).
  # `with_status` reicht den *gewrappten* Reason hier rein — ohne diese
  # Unwrap-Klausel matchte keine der spezifischen Klauseln unten (die alle den
  # INNEREN Reason erwarten: :no_key_configured, :timeout, {:network_error,_} …),
  # sodass JEDER Pipeline-Fehler auf den `_ -> "other"`-Fallback fiel. Die ganze
  # #68-Error-Taxonomie für /admin/errors war damit tot (jeder Fehler "other",
  # ohne den gezielten Recovery-Hint). Fix: Wrapper strippen + auf den inneren
  # Reason rekursieren → korrekte Klassifikation.
  def classify_pipeline_error({stage, reason})
      when stage in [:stage2, :stage3, :stage4, :stage4_publish],
      do: classify_pipeline_error(reason)

  def classify_pipeline_error(:empty_chronik), do: "empty_chronik"
  def classify_pipeline_error(:no_key_configured), do: "no_key_configured"
  def classify_pipeline_error(:upstream_auth), do: "upstream_auth"
  def classify_pipeline_error(:upstream_rate_limit), do: "upstream_rate_limit"

  # Issue #68 Phase 3: Ollama-Connection-Refused → eigener Code für
  # gezielten "ollama serve"-Recovery-Hint.
  def classify_pipeline_error({:network_error, :econnrefused}), do: "ollama_unreachable"
  def classify_pipeline_error({:network_error, :nxdomain}), do: "ollama_unreachable"
  def classify_pipeline_error({:network_error, _}), do: "network_error"

  # Issue #68 Phase 3: Ollama-Model-Not-Found → "ollama pull"-Hint.
  # Local-Backend wrapped Ollama-404 als {:http, 404, body}, body kann String
  # oder geparste Map sein je nach Pfad.
  def classify_pipeline_error({:http, 404, body}) when is_binary(body) do
    if String.contains?(body, "model") and String.contains?(body, "not found") do
      "model_not_found"
    else
      "http_error"
    end
  end

  def classify_pipeline_error({:http, 404, %{"error" => msg}}) when is_binary(msg) do
    if String.contains?(msg, "not found"), do: "model_not_found", else: "http_error"
  end

  def classify_pipeline_error({:upstream_error, _, _}), do: "upstream_error"
  def classify_pipeline_error({:http, _, _}), do: "http_error"
  def classify_pipeline_error(:timeout), do: "timeout"
  def classify_pipeline_error(:no_summary), do: "no_summary"
  def classify_pipeline_error(:no_epos), do: "no_epos"
  def classify_pipeline_error(:no_campaign), do: "no_campaign"
  def classify_pipeline_error(:no_session), do: "no_session"

  # Issue #178: Cap-Limit für Cloud-LLM-Calls.
  def classify_pipeline_error(:spend_cap_exceeded), do: "spend_cap_exceeded"

  # Issue #68 Phase 3 — Stage-1-Whisper-Codes (falls je aus Pipeline bubbled).
  def classify_pipeline_error(:whisper_binary_missing), do: "whisper_binary_missing"
  def classify_pipeline_error(:whisper_model_missing), do: "whisper_model_missing"
  def classify_pipeline_error(:whisper_failed), do: "whisper_failed"
  def classify_pipeline_error({:whisper_failed, _}), do: "whisper_failed"
  def classify_pipeline_error(:whisper_empty), do: "whisper_empty"

  def classify_pipeline_error(atom) when is_atom(atom), do: Atom.to_string(atom)
  def classify_pipeline_error(_), do: "other"

  # Issue #288: Stage-Body merkt sich die Format-Notes via Process-Dict;
  # notify_status liest sie beim "ended"/"failed"-Event ins Payload.
  # Process-Dict ist hier safe weil Stage-Run + notify_status im selben
  # Prozess laufen (vgl. Logger.metadata-Pattern).
  def put_format_notes(notes) when is_binary(notes), do: Process.put(:format_notes, notes)
  def put_format_notes(_), do: :ok

  def notify_status(campaign_id, stage, status, error_msg) do
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

  def probelauf_campaign?(campaign_id) when is_binary(campaign_id),
    do: String.starts_with?(campaign_id, "probelauf-")

  def probelauf_campaign?(_), do: false

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

  # ─── Issue #583: Façade-Delegation an die ausgelagerten Submodule ─────────
  # Test- + extern-erreichbare Publics bleiben über `Worker.Recording.Pipeline.x()`
  # erreichbar (Call-Sites + Tests unverändert); die Impl lebt im Submodul.

  defdelegate parse_chronik_json(raw), to: Parsing
  defdelegate parse_summary_json(raw, utterances), to: Parsing
  defdelegate parse_epos_json(raw, fallback_refs), to: Parsing
  defdelegate filter_fabricated_chronik(entries), to: Parsing
  defdelegate strip_and_note(raw), to: Parsing

  defdelegate preview_prompt(stage, campaign), to: Prompts
  defdelegate effective_flavor(flavors, slot), to: Prompts
  defdelegate default_flavor(slot), to: Prompts
  defdelegate heading_directive(name, stage), to: Prompts
  defdelegate stage_heading(campaign, stage), to: Prompts
  defdelegate epos_structure_block(form), to: Prompts
  defdelegate build_epos_prompt(a, b, c), to: Prompts
  defdelegate build_epos_prompt(a, b, c, d), to: Prompts
  defdelegate build_epos_prompt(a, b, c, d, e), to: Prompts
  defdelegate build_epos_prompt(a, b, c, d, e, f), to: Prompts

  defdelegate stage2_chunking_needed?(utterances, speaker_names, budget), to: Stages
  defdelegate group_for_reduce(partials, budget), to: Stages
  defdelegate chunk_utterances(utterances, budget, speaker_names), to: Stages
  defdelegate stage4_source_text(session_id, epos_md), to: Stages
end
