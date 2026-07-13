defmodule Worker.Recording.Pipeline do
  @moduledoc """
  Listens for `UtterancesTranscribed` events on the worker-local PubSub and
  runs the per-session Wahrheitsbild-Pipeline (#651; seit #786 der einzige
  Pfad — die Chain Stage 2→3→4 ist entfernt):

      extract      Utterances → strukturierte Fakten (Stages.extract_facts)
      registry     campaign-weites Guise-Merging (best-effort, #714)
      verify       Quell-Grounding + Attribution → verified? (Verify)
      render       Resümee aus verifizierten Fakten (Render.render_summary)
      timeline     deterministischer Zeitstrahl → Chronik (#724)
      render_epos  per-Session-Epos-Kapitel (#752)

  Jeder Schritt publisht seine Artefakte via `Worker.Intents.publish/1`,
  so other workers and the LiveView see the new content via the regular
  event-sourcing flow. Timeline + Epos-Kapitel sind fehler-entkoppelte
  best-effort-Geschwister aus denselben verifizierten Fakten.

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
  (`run_for_session/1` via `handle_call`) bleibt ungegated — den routet
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
  @session_fact_date_set_kind Events.session_fact_date_set()

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
    # Synchroner Call: returnt erst nachdem der `running`-Marker gesetzt ist,
    # damit CampaignReplay.wait_pipeline_idle/1 nicht race-conditional gegen
    # einen noch nicht verarbeiteten Cast pollt.
    GenServer.call(__MODULE__, {:run_for_session, session_id}, :infinity)
  end

  @doc """
  Issue #775: läuft gerade mindestens ein Pipeline-Lauf? Leichte Status-API für
  den Self-Update-Idle-Check (`Worker.Updater.idle?/0`) — vorher zählte ein
  laufender `run_for_session`/Regenerate als „idle" und der Update-Halt schoss
  den Lauf mitten im Verify ab (Watchdog-ABRT, 2026-07-09 19:25).
  """
  @spec busy?() :: boolean()
  def busy? do
    GenServer.call(__MODULE__, :busy?)
  end

  @doc """
  Issue #724 Slice F: baut den Zeitstrahl EINER Session deterministisch neu
  auf (kein LLM) — der Trigger nach einer GM-Korrektur in der Review-Queue
  (`SessionFactDateSet`, siehe `handle_info/2`), aber auch direkt aufrufbar
  (Konsole/Tests). Liest die (bereits Override-gemergten, s.
  `Worker.Repo.Artifacts.merge_override/3`) Fakten der Session, filtert
  verifiziert + nicht dauerhaft ausgeblendet, und republisht via denselben
  Pfad wie die reguläre Pipeline (`publish_wahrheitsbild_timeline`,
  #698-Watermark-idempotent).

  `{:error, :no_facts}` OHNE Clear, wenn die Session (noch) keine Extraktion
  hat — ein irrläufiger Trigger auf eine leere/gelöschte Session darf eine
  bestehende Chronik nicht wipen.
  """
  @spec republish_timeline_for_session(String.t()) :: :ok | {:error, term()}
  def republish_timeline_for_session(session_id) when is_binary(session_id) do
    with {:ok, session, campaign} <- session_and_campaign(session_id),
         %{facts: facts} <- Repo.get_session_facts(session_id) do
      verified =
        Enum.filter(facts, fn f ->
          Map.get(f, "verified?") == true and Map.get(f, "review_dismissed") != true
        end)

      best_effort_artifact(campaign.id, "timeline", :timeline, session.id, fn ->
        publish_wahrheitsbild_timeline(session, campaign, verified)
      end)

      :ok
    else
      nil -> {:error, :no_facts}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_call({:run_for_session, session_id}, _from, state) do
    Logger.info("Pipeline: manual re-run requested for session=#{session_id}")

    state = %{state | running: MapSet.delete(state.running, session_id)}

    case maybe_run(session_id, state) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
    end
  end

  @impl true
  # Issue #775: Status für den Updater-Idle-Check.
  def handle_call(:busy?, _from, state) do
    {:reply, MapSet.size(state.running) > 0, state}
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

  # Issue #724 Slice F: eine GM-Korrektur in der Review-Queue triggert einen
  # deterministischen Zeitstrahl-Republish (kein LLM). Race-frei OHNE neues
  # Hub-Command-Plumbing: der Worker, der das SessionFactDateSet-Event selbst
  # appliet hat (`elected?/2` — derselbe Author-Worker-Mechanismus wie oben),
  # ist garantiert derjenige, dessen Fold+Read-Merge bereits den neuen Stand
  # sehen (ein separater Hub→Worker-Push hätte diese Garantie NICHT: die
  # Ziel-Worker-Wahl von EventBridge/Commands kann von der Election abweichen).
  # Läuft NICHT über `state.running`/`maybe_run` — das ist der schwere LLM-Pfad
  # mit De-Dup-Tracking; der Republish ist billig + idempotent (#698-Watermark)
  # und braucht keine eigene Dedup-Buchhaltung. Immer republishen, auch bei
  # `dismissed` (kein Skip) — der Republish-Filter (verified? AND NOT
  # review_dismissed) schließt dismisste Fakten ohnehin aus; ein Skip würde
  # nur einen theoretischen Stale-Eintrag riskieren, wenn ein künftiger Pfad
  # (z.B. `/dev/event`) ein Dismiss auf einen bereits datierten Fakt schickt.
  def handle_info(
        {:applied, %{"payload" => %{"kind" => @session_fact_date_set_kind} = payload} = event},
        state
      ) do
    if elected?(event, Repo.get_state(:worker_id)) do
      session_id = payload["session_id"]

      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        republish_timeline_for_session(session_id)
      end)
    end

    {:noreply, state}
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

  defp maybe_run(session_id, state) do
    case session_and_campaign(session_id) do
      {:ok, session, campaign} ->
        admin = Repo.get_state(:admin_discord_id)

        if Repo.member?(campaign.id, admin) do
          Logger.info(
            "Pipeline: starting stages for session=#{session_id} campaign=#{campaign.id}"
          )

          me = self()

          # Issue #292: LLM-Schritte (lokales Ollama / Cloud-LLM) durch die GPU-
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
              fn -> run_stages(session, campaign) end,
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
      [{_, _, campaign_id, num, _name, _status, _sched, _start, _end}] ->
        case Repo.get_campaign(campaign_id) do
          nil ->
            {:error, :no_campaign}

          campaign ->
            # #752: `number` gehört in die Session-Map — der Epos-Kapitel-Kopf
            # (`Render.chapter_header/2`) braucht sie. Der Nachtlauf-Teststage-
            # Check hat genau diesen fehlenden Key als /admin/errors-Eintrag
            # gefangen (best-effort-Entkopplung funktionierte wie designed).
            {:ok, %{id: session_id, campaign_id: campaign_id, number: num}, campaign}
        end

      [] ->
        {:error, :no_session}
    end
  end

  defp run_stages(session, campaign) do
    # Issue #506: `limit: :all` — die Pipeline braucht die GANZE Session, nicht
    # nur die letzten 200 Utts (Default-Cap). Die Extraktion chunked lange
    # Sessions via Map-Reduce (#683); das Cap hat diesen Pfad bislang
    # ausgehungert → trunkierte Outputs für alles >200 Utts.
    utterances = Repo.list_utterances(session.id, limit: :all)

    if utterances == [] do
      Logger.info("Pipeline: session=#{session.id} has no utterances; skipping LLM stages")
    else
      # Issue #651 Phase C / #786: Wahrheitsbild ist der einzige Pfad — die
      # Chain (Stage 2→3→4) und das `pipeline_mode`-Setting sind entfernt.
      run_wahrheitsbild(session, campaign, utterances)
    end
  end

  # Issue #651 Phase C: der Wahrheitsbild-Pfad. extract_facts (→ Fakten) →
  # EntityRegistry (campaign-weites Guise-Merging, #714) → verify_session
  # (Grounding + Attribution auf kanonischen Entitäten, setzt verified?) →
  # render_summary (aus den verifizierten Fakten, context-faithful + Render-
  # Gating) → publish SessionSummaryGenerated + Geschwister Timeline (#724)
  # und Epos-Kapitel (#752).
  #
  # #714/#716: jeder Schritt läuft in `with_status` (UI-Busy-Badge + /admin/
  # errors-Persistenz mit eigener Fehlerklasse); die Registry ist best-effort
  # (Cluster-Fehler → Fakten unverändert, Pipeline läuft weiter — kein Merge
  # ist besser als ein falscher). `deps` ist für Orchestrator-Tests ohne
  # LLM/Sidecar injizierbar (Muster: Verify/Render-Pur-Kerne).
  @doc false
  def run_wahrheitsbild(session, campaign, utterances, deps \\ %{}) do
    alias Worker.Recording.Pipeline.{EntityRegistry, Render, Verify}

    extract =
      Map.get(deps, :extract, fn -> Stages.extract_facts(utterances, session.id, campaign) end)

    resolve =
      Map.get(deps, :resolve, fn -> EntityRegistry.resolve_campaign_entities(campaign.id) end)

    verify = Map.get(deps, :verify, fn -> Verify.verify_session(session.id, campaign) end)
    # #787: campaign liefert die Stil-Flavors an die Render-Prompts (Stil wirkt
    # hinter dem Verify-Gate; die deps-Injection der Tests bleibt fn/1).
    render = Map.get(deps, :render, fn facts -> Render.render_summary(facts, campaign) end)

    render_epos =
      Map.get(deps, :render_epos, fn facts -> Render.render_epos(facts, campaign) end)

    result =
      with {:ok, _facts} <- with_status(campaign.id, "extract", session.id, extract),
           :ok <- resolve_entities_best_effort(resolve),
           {:ok, verified} <-
             with_status(campaign.id, "verify", session.id, fn ->
               tag_error(verify.(), :verify)
             end),
           {:ok, rendered} <-
             with_status(campaign.id, "render", session.id, fn ->
               tag_error(render.(verified), :render)
             end) do
        publish_wahrheitsbild_summary(session, campaign, verified, rendered)

        # #752: Timeline und Epos-Kapitel sind unabhängige Geschwister-Artefakte
        # aus denselben verifizierten Fakten — ein Fehlschlag des einen darf das
        # andere nicht mitreißen (und keiner das schon publizierte Resümee).
        # Fehler landen einzeln klassifiziert in /admin/errors (with_status).
        timeline_entries =
          best_effort_artifact(campaign.id, "timeline", :timeline, session.id, fn ->
            publish_wahrheitsbild_timeline(session, campaign, verified)
          end)

        best_effort_artifact(campaign.id, "render_epos", :render_epos, session.id, fn ->
          publish_wahrheitsbild_epos(
            session,
            campaign,
            verified,
            timeline_entries || [],
            render_epos
          )
        end)

        :ok
      end

    case result do
      :ok ->
        Logger.info("Pipeline[wahrheitsbild]: completed for session=#{session.id}")

      {:error, reason} ->
        Logger.error(
          "Pipeline[wahrheitsbild]: failed for session=#{session.id}: #{inspect(reason)}"
        )
    end

    result
  end

  # #714: Registry-Fehler brechen die Pipeline NICHT — die Fakten behalten dann
  # ihre per-Oberflächenform-entity_ids (Extraktions-Default), das Verify läuft
  # ohne Guise-Merging weiter. Nur loggen, kein /admin/errors-Eintrag (der
  # Lauf scheitert ja nicht).
  defp resolve_entities_best_effort(resolve_fn) do
    case resolve_fn.() do
      {:ok, _registry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline[wahrheitsbild]: Entity-Registry-Clustering fehlgeschlagen " <>
            "(#{inspect(reason)}) — Fakten bleiben unverändert (kein Merge ist besser als ein falscher)"
        )

        :ok
    end
  end

  # #716: verify/render liefern ungetaggte Fehler (:sidecar_offline, :no_facts,
  # :no_verified_facts, LLM-Reasons) — für die /admin/errors-Klassifikation
  # analog zu den {:stageN, reason}-Wrappern der Kette taggen.
  defp tag_error({:error, reason}, tag), do: {:error, {tag, reason}}
  defp tag_error(other, _tag), do: other

  # #752: unabhängiges Geschwister-Artefakt best-effort ausführen. Fehler (auch
  # Raises) landen via with_status klassifiziert in /admin/errors, brechen aber
  # weder die anderen Artefakte noch den Gesamtlauf. Liefert den {:ok, value}-
  # Wert des Schritts oder nil.
  defp best_effort_artifact(campaign_id, stage, tag, session_id, fun) do
    guarded = fn ->
      try do
        tag_error(fun.(), tag)
      rescue
        e -> {:error, {tag, Exception.message(e)}}
      end
    end

    case with_status(campaign_id, stage, session_id, guarded) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp publish_wahrheitsbild_summary(session, campaign, verified_facts, rendered) do
    # `rendered.flagged` ist per Render-Spec immer eine Liste (kein nil).
    flagged = rendered.flagged

    if flagged != [] do
      Logger.warning(
        "Pipeline[wahrheitsbild]: #{length(flagged)} ungeerdete Render-Claims " <>
          "geflaggt (session=#{session.id}): #{inspect(flagged)}"
      )
    end

    source_refs = verified_facts |> Enum.flat_map(&(&1["source_refs"] || [])) |> Enum.uniq()

    # #783 Phase 2 (Design E, Provenance-Stempel): backend_stage4 ist jetzt
    # frei drehbar — ohne diesen Stempel wäre ein Render-Backend-Wechsel
    # zwischen zwei Sessions unsichtbar. KEIN Pin-Mechanismus (macht Drift nur
    # sichtbar, verhindert ihn nicht — der Pin selbst ist Phase 4 der Multi-
    # Worker-Architektur-Arbeit, nicht Teil dieses PRs).
    render_backend = Worker.Settings.get(:backend_stage4, :local)

    # Issue #715: `flagged_claims` additiv im Event — die Render-Gate-Info war
    # bisher nur Log. Alte Events haben das Feld nicht; Consumer müssen
    # nil-tolerant lesen (`|| []`).
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.session_summary_generated(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "content_md" => rendered.md,
        "source" => "llm",
        "source_refs" => source_refs,
        "flagged_claims" => flagged,
        "render_backend" => Atom.to_string(render_backend),
        "render_model" => Worker.Settings.model_for(4, render_backend)
      })

    :ok
  end

  # Issue #724 Slice E: den deterministischen Zeitstrahl aus den verifizierten
  # Fakten in die Chronik publishen. Auflösung: Graph.resolve datiert jeden Fakt
  # (gegen Campaign-Kalender + Session-Anker) → Render.timeline formt Chronik-
  # Einträge. Idempotenz wie Stage 4 (#227): erst ClearForSession, dann pro
  # Eintrag ChronikEntryChanged. Ein leerer Zeitstrahl clärt trotzdem (Re-Run
  # ohne datierbare Fakten hinterlässt keine Alt-Leichen).
  defp publish_wahrheitsbild_timeline(session, campaign, verified_facts) do
    alias Worker.Recording.Pipeline.Render
    alias Worker.Timeline.Graph

    calendar = Worker.Repo.get_campaign_calendar(campaign.id)
    anchor_day = Worker.Repo.get_session_anchor_day(session.id)

    entries =
      verified_facts
      |> Graph.resolve(calendar, anchor_day)
      |> Render.timeline()

    # Issue #698 (I7): eine Generation pro Run für Clear + alle Entries (s.
    # stage4_publish) — der Clear-Watermark hält den aktuellen Run live und
    # unterdrückt frühere, order-insensitiv.
    generation = UUIDv7.generate()

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.chronik_cleared_for_session(),
        "campaign_id" => campaign.id,
        "session_id" => session.id,
        "cleared_by" => "llm",
        "generation" => generation
      })

    Enum.each(entries, fn e ->
      {:ok, _} =
        Worker.Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_timeline_id(session.id, e),
          "campaign_id" => campaign.id,
          "in_game_date" => e.in_game_date,
          "label" => e.label,
          "summary" => e.summary,
          "session_id" => session.id,
          "source_refs" => e.source_refs,
          "in_game_day" => e.in_game_day,
          "precision" => e.precision,
          "generation" => generation
        })
    end)

    # #752: Entries zurückgeben — der Epos-Kapitel-Kopf leitet seine Tag-Range
    # deterministisch daraus ab (best_effort_artifact reicht sie weiter).
    {:ok, entries}
  end

  # Issue #752: das per-Session-Epos-KAPITEL — gerendert AUSSCHLIESSLICH aus den
  # verifizierten Fakten dieser Session (strikt isoliert, kein Vorkapitel im
  # Prompt: Poisoning-Entscheidung #651-Kommentar 2026-07-08). Kontinuität kommt
  # deterministisch aus dem Kapitel-Kopf (Timeline-Tag-Range). Datenmodell ohne
  # Migration: entry_id = session_id, parent_id = campaign_id (Kapitel-Marker);
  # die Legacy-Single-Row (entry_id = campaign_id) koexistiert unberührt.
  defp publish_wahrheitsbild_epos(session, campaign, verified_facts, timeline_entries, render_fn) do
    alias Worker.Recording.Pipeline.Render

    # Issue #753 (LWW-Guard): ein GM-editiertes Kapitel wird von einem Re-Run
    # derselben Session NICHT überschrieben — der LWW-Fold (apply2) würde den
    # Edit sonst zermahlen. Check VOR dem Render (spart den teuren LLM-Call).
    # Neu generieren trotz Edit = bewusste GM-Aktion → Kapitel-Edit-UI (#753),
    # nicht der Pipeline-Pfad.
    if chapter_user_edited?(session.id) do
      Logger.info(
        "Pipeline[wahrheitsbild]: Kapitel session=#{session.id} hat GM-Edit — Re-Render übersprungen (#753)"
      )

      {:ok, :chapter_skipped_user_edit}
    else
      render_and_publish_chapter(session, campaign, verified_facts, timeline_entries, render_fn)
    end
  end

  # #753: hat dieses Kapitel (entry_id = session_id) jemals einen manuellen
  # GM-Edit? History-Rows mit source :manual sind der persistente Marker.
  defp chapter_user_edited?(entry_id) do
    Repo.list_epos_history(entry_id) |> Enum.any?(&(&1.source == :manual))
  end

  defp render_and_publish_chapter(session, campaign, verified_facts, timeline_entries, render_fn) do
    alias Worker.Recording.Pipeline.Render

    case render_fn.(verified_facts) do
      {:ok, rendered} ->
        if rendered.flagged != [] do
          Logger.warning(
            "Pipeline[wahrheitsbild]: #{length(rendered.flagged)} ungeerdete Epos-Kapitel-" <>
              "Claims geflaggt (session=#{session.id}): #{inspect(rendered.flagged)}"
          )
        end

        header = Render.chapter_header(session, timeline_entries)
        source_refs = verified_facts |> Enum.flat_map(&(&1["source_refs"] || [])) |> Enum.uniq()

        # #783 Phase 2 (Nachtrag, Design E): backend_stage5 ist frei drehbar —
        # ohne Provenance-Stempel wäre ein Epos-Backend-Wechsel zwischen zwei
        # Sessions unsichtbar (analog render_backend/model auf dem Resümee).
        epos_backend = Worker.Settings.get(:backend_stage5, :local)

        {:ok, _} =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => session.id,
            "campaign_id" => campaign.id,
            "parent_id" => campaign.id,
            "new_md" => header <> "\n\n" <> rendered.md,
            "edited_by" => "llm",
            "source" => "llm",
            "source_refs" => source_refs,
            "epos_backend" => Atom.to_string(epos_backend),
            "epos_model" => Worker.Settings.model_for(5, epos_backend)
          })

        {:ok, :chapter_published}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stabile ID pro Timeline-Eintrag. Anders als Stages.derive_chronik_id/2
  # (date|label) nimmt sie den Tageszähler UND die summary auf — sonst
  # kollidieren zwei Fakten derselben Figur am selben Tag zu einer Row. Der
  # ClearForSession davor macht Re-Runs ohnehin sauber.
  defp derive_timeline_id(session_id, entry) do
    seed =
      [session_id, to_string(entry.in_game_day || entry.in_game_date), entry.label, entry.summary]
      |> Enum.join("|")

    "chronik-" <> (:crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  def with_status(campaign_id, stage, session_id, fun) do
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
  # #716: leere Extraktion VOR dem generischen Wrapper-Strip — nach dem Strip
  # wäre `:empty` zu vage für einen gezielten Hint.
  def classify_pipeline_error({:extraction, :empty}), do: "extraction_empty"

  # #716: die Wahrheitsbild-Schritt-Tags (:extraction aus stages.ex,
  # :verify/:render aus run_wahrheitsbild, :timeline/:render_epos aus den
  # #752-Geschwister-Artefakten) strippen — Klassifikation läuft auf dem
  # inneren Reason.
  def classify_pipeline_error({stage, reason})
      when stage in [:extraction, :verify, :render, :timeline, :render_epos],
      do: classify_pipeline_error(reason)

  # #716: Wahrheitsbild-Fehlerklassen (Phase C). Die Atom-Catch-all-Klausel
  # unten würde dieselben Strings liefern — explizit, weil an jede Klasse ein
  # KnownIssues-Hint + type_label im Hub gekoppelt ist (Drift-Schutz).
  def classify_pipeline_error(:sidecar_offline), do: "sidecar_offline"
  def classify_pipeline_error(:no_facts), do: "no_facts"
  def classify_pipeline_error(:no_verified_facts), do: "no_verified_facts"
  def classify_pipeline_error(:all_chunks_failed), do: "all_chunks_failed"

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

    Worker.HubClient.publish_status(payload)

    # Worker-lokaler Mit-Listener (Issue #74): Probelauf-Engine läuft im
    # selben BEAM und braucht Per-Schritt-Timings ohne den Umweg über Hub.
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
  end

  def probelauf_campaign?(campaign_id) when is_binary(campaign_id),
    do: String.starts_with?(campaign_id, "probelauf-")

  def probelauf_campaign?(_), do: false

  # Issue #27: aus dem internen Pipeline-Reason eine UI-lesbare Message machen.
  # Reasons kommen in mehreren Formen rein:
  #   {:extraction, {:upstream, code, status, msg}}  ← Cloud-Backend
  #   {:verify, :sidecar_offline}                    ← NLI-Sidecar weg
  #   {:render, :timeout}                            ← HTTP-Timeout
  #   {tag, atom_or_term}                            ← sonstiges
  defp format_error({_stage, {:upstream, code, status, msg}}) when is_binary(msg),
    do: "Cloud-Backend (#{code} #{status}): #{msg}"

  defp format_error({_stage, {:upstream, code, status, _}}),
    do: "Cloud-Backend (#{code} #{status})"

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

  defdelegate strip_and_note(raw), to: Parsing

  defdelegate preview_prompt(stage, campaign), to: Prompts
  defdelegate effective_flavor(flavors, slot), to: Prompts
  defdelegate default_flavor(slot), to: Prompts
  defdelegate heading_directive(name, stage), to: Prompts
  defdelegate stage_heading(campaign, stage), to: Prompts

  defdelegate stage2_chunking_needed?(utterances, speaker_names, budget), to: Stages
  defdelegate chunk_utterances(utterances, budget, speaker_names), to: Stages
end
