defmodule Worker.Recording.Pipeline do
  @moduledoc """
  Listens for `UtterancesTranscribed` events on the worker-local PubSub and
  runs the per-session Wahrheitsbild-Pipeline (#651; seit #786 der einzige
  Pfad — die Chain Stage 2→3→4 ist entfernt):

      extract               Utterances → strukturierte Fakten (Stages.extract_facts)
      registry              campaign-weites Guise-Merging (best-effort, #714)
      verify                Quell-Grounding + Attribution → verified? (Verify)
      render                Resümee aus verifizierten Fakten (Render.render_summary)
      timeline              deterministischer Zeitstrahl → Chronik (#724)
      render_epos           per-Session-Epos-Kapitel (#752)
      render_arc_progressions  EIN Prosa-Eintrag pro in dieser Session berührtem
                               Handlungsbogen (#838, s. `publish_wahrheitsbild_arc_progressions/3`)

  Jeder Schritt publisht seine Artefakte via `Worker.Intents.publish/1`,
  so other workers and the LiveView see the new content via the regular
  event-sourcing flow. Timeline, Epos-Kapitel und die Bogen-Progressionen
  sind fehler-entkoppelte best-effort-Geschwister aus denselben
  verifizierten Fakten — die Bogen-Progressionen zusätzlich INTERN pro Bogen
  isoliert (ein fehlschlagender Bogen reißt weder andere Bögen noch die
  restliche Pipeline mit, #838 Design J).

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
  alias Worker.Recording.Pipeline.{Parsing, Prompts, Stages, Zeit}

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
        Zeit.publiziere(session, campaign, verified)
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

  # Issue #724 → #866: die SessionFactDateSet-Kante (deterministischer
  # Timeline-Republish) lebt seit Slice F im generischen Dirty-Mechanismus
  # (`Worker.Recording.Pipeline.Dirty.@dependency_graph`) — eine Stelle für
  # alle Kuration-triggert-Neuableitung-Kanten.
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

  # Issue #1122: `run_id` identifiziert EINEN Durchgang über die Stufen. Ohne
  # sie kann die Anzeige zwei Läufe derselben Session nicht trennen — zweimal
  # „neu generieren" genügt dafür schon heute. Sie wird hier geboren, weil hier
  # der Lauf beginnt, und reist durch alle Stufenmeldungen.
  defp run_stages(session, campaign) do
    run_id = UUIDv7.generate()
    # Issue #506: `limit: :all` — die Pipeline braucht die GANZE Session, nicht
    # nur die letzten 200 Utts (Default-Cap). Die Extraktion chunked lange
    # Sessions via Map-Reduce (#683); das Cap hat diesen Pfad bislang
    # ausgehungert → trunkierte Outputs für alles >200 Utts.
    utterances = Repo.list_utterances(session.id, limit: :all)

    if utterances == [] do
      Logger.info("Pipeline: session=#{session.id} has no utterances; skipping LLM stages")
    else
      # Issue #864 (Epic #861 Slice C): Stage 1.1 — deterministische Glättung
      # VOR allem anderen. FAIL-LOUD (K5): scheitert das Smoothing, stoppt die
      # Pipeline mit eigener Fehlerklasse — kein stiller 1-Utterance-Fallback
      # („läuft halt irgendwie weiter" wäre die Datenqualitäts-Rätsel-Klasse).
      # Jeder Lauf glättet mit dem AKTUELLEN Regelwerk (P2: der Regenerate-
      # Button ist damit der on-demand-Re-Smooth-Auslöser; kein Deploy-Trigger).
      case with_status(
             campaign.id,
             "smooth",
             session.id,
             fn -> smooth_transcript(session, campaign, utterances) end,
             run_id
           ) do
        {:ok, %{context: blocks}} ->
          # Issue #651 Phase C / #786: Wahrheitsbild ist der einzige Pfad.
          # #917 (Cut 3): die Klemm-Menge ist entfallen (kein Klemmen mehr).
          run_wahrheitsbild(session, campaign, blocks, %{run_id: run_id})

        {:error, _} = err ->
          err
      end
    end
  end

  # Issue #864: glättet, publisht den TranscriptSmoothed-Whole-Snapshot (#863)
  # und liefert die utterance-förmigen Kontext-Blöcke (Einmal-Resolve, B2) für
  # den restlichen Lauf. Vorschläge/Kurations-Overrides fließen ab Slice D+E in
  # den Adapter ein (bis dahin ist effective_text = Smoothed-Text).
  defp smooth_transcript(session, campaign, utterances) do
    alias Worker.Recording.Pipeline.Smoothing

    gap = Worker.Settings.get(:merge_gap_seconds, 8)
    result = Smoothing.smooth(utterances, merge_gap_seconds: gap)

    {:ok, _seq} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.transcript_smoothed(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "smoothed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "blocks" => result.blocks,
        "ooc_verworfen" => result.ooc_verworfen,
        "praesenz_ping_verworfen" => result.praesenz_ping_verworfen,
        "rules_version" => result.rules_version,
        "merge_gap_seconds" => result.merge_gap_seconds
      })

    # #865: Gap-Fill-Vorschläge + effektive Kurations-Overrides (inkl. Read-
    # Zeit-Re-Attach) fließen in den effective_text ein; unbrauchbar-Blöcke
    # fallen aus der Oberfläche (F5).
    vorschlaege0 = Repo.luecken_vorschlaege_for_session(session.id)
    %{attached: overrides} = Repo.luecken_overrides_effective(session.id, result.blocks)

    # #924: Reihenfolge glätten → Vorschläge → Rest. Der Gapfill läuft SYNCHRON
    # (inline in diesem Pipeline-GpuQueue-Job) für uncurierte Lücken-Blöcke ohne
    # existierenden Vorschlag und speist so schon DIESEN Lauf — vor #924 lief er
    # async und der erste Lauf extrahierte aus dem Roh-Text. Kein Modell/keine
    # Kandidaten → `vorschlaege0` unverändert.
    vorschlaege =
      Worker.Recording.Pipeline.GapFill.generate_now(
        session.id,
        campaign.id,
        result.blocks,
        vorschlaege0,
        overrides
      )

    # Issue #1069 (E7): der deterministische Zeit-Vorlauf. Läuft auf den
    # GEGLÄTTETEN Blöcken, direkt nach der Glättung und vor der Extraktion —
    # kein LLM, Millisekunden.
    #
    # BEST-EFFORT und bewusst nicht fail-loud: der Rahmen ist eine Zugabe. Ein
    # Fehler hier darf die Extraktion nicht aufhalten, denn ohne Rahmen
    # funktioniert die Pipeline genau so wie vor #1069.
    publiziere_zeitrahmen(session, campaign, result.blocks)

    case Smoothing.to_context(result.blocks, vorschlaege, overrides) do
      [] ->
        {:error, {:smooth, :no_blocks}}

      blocks ->
        {:ok, %{context: blocks}}
    end
  rescue
    e -> {:error, {:smooth, e}}
  end

  # Issue #1069 (E7): leitet den Session-Zeitrahmen ab und publisht ihn.
  #
  # Der Rahmen wird bei JEDEM Lauf neu abgeleitet — er hängt an den Blöcken,
  # und die ändern sich mit dem Regelwerk der Glättung. Ein Whole-Snapshot pro
  # Lauf ist damit richtig; ein Merge wäre order-sensitiv.
  defp publiziere_zeitrahmen(session, campaign, blocks) do
    alias Worker.Timeline.Vorlauf

    rahmen = blocks |> Vorlauf.finde() |> Vorlauf.rahmen()

    Logger.info(
      "Vorlauf: session=#{session.id} tageszeit=#{inspect(rahmen.tageszeit)} " <>
        "tagesgrenzen=#{rahmen.tagesgrenzen} jahre=#{inspect(rahmen.jahr_kandidaten)} " <>
        "hart=#{rahmen.harte_anker} degradiert=#{rahmen.degradierte_anker}"
    )

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.session_zeitrahmen_set(),
        "session_id" => session.id,
        "campaign_id" => campaign.id,
        "rahmen" => %{
          "tageszeit" => rahmen.tageszeit && to_string(rahmen.tageszeit),
          "tagesgrenzen" => rahmen.tagesgrenzen,
          # Als Liste von Paaren, nicht als Map: JSON-Keys wären Strings, und
          # eine Jahreszahl als String-Key lädt zu Sortierfehlern ein.
          "jahr_kandidaten" => Enum.map(rahmen.jahr_kandidaten, fn {j, n} -> [j, n] end),
          "harte_anker" => rahmen.harte_anker,
          "degradierte_anker" => rahmen.degradierte_anker,
          # Die Belege reisen mit: ein Rahmen ohne Fundstellen wäre eine
          # Behauptung, die niemand nachprüfen kann.
          "belege" =>
            Enum.map(rahmen.tageszeit_belege, fn f ->
              %{
                "block_index" => f.block_index,
                "block_id" => f.block_id,
                "wortlaut" => f.wortlaut
              }
            end)
        }
      })

    :ok
  rescue
    e ->
      Logger.warning("Vorlauf: session=#{session.id} fehlgeschlagen — #{inspect(e)}")
      :ok
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
    alias Worker.Recording.Pipeline.{
      ArcProgressions,
      EntityRegistry,
      Render,
      ThreadRegistry,
      Verify
    }

    extract =
      Map.get(deps, :extract, fn -> Stages.extract_facts(utterances, session.id, campaign) end)

    resolve =
      Map.get(deps, :resolve, fn -> EntityRegistry.resolve_campaign_entities(campaign.id) end)

    # #832: Handlungsbogen-Clustering — im selben resolve-Schritt wie das Guise-
    # Merging, ebenfalls best-effort (eigene /admin/errors-Klasse "resolve_threads").
    resolve_threads =
      Map.get(deps, :resolve_threads, fn ->
        # #842: inkrementeller Pfad — clustert nur neue Roh-Labels seit dem
        # letzten Lauf. Der Voll-Re-Cluster ist ab jetzt ein expliziter,
        # seltener GM-Trigger (full_recluster_campaign_threads/2).
        ThreadRegistry.resolve_campaign_threads(campaign.id)
      end)

    # #864: der Lauf reicht SEINE Kontext-Blöcke durch (Einmal-Resolve, B2).
    # #917 (Cut 3): keine Klemm-Menge mehr (Gap-Klemme entfernt).
    verify =
      Map.get(deps, :verify, fn ->
        Verify.verify_session(session.id, campaign, utterances)
      end)

    # #787: campaign liefert die Stil-Flavors an die Render-Prompts (Stil wirkt
    # hinter dem Verify-Gate; die deps-Injection der Tests bleibt fn/1).
    # Issue #1122: `deps` trägt neben den injizierbaren Schritten auch den
    # Lauf-Kontext. Ein eigener Parameter wäre sauberer, hätte aber jeden
    # Testaufruf von `run_wahrheitsbild/4` gebrochen; `:run_id` kollidiert mit
    # keinem Schritt-Key. Fehlt er (Tests, Alt-Aufrufer), meldet der Lauf eben
    # ohne Identität — die Anzeige kommt damit klar, sie kann dann nur nicht
    # zwei gleichzeitige Läufe derselben Session trennen.
    run_id = Map.get(deps, :run_id)

    render = Map.get(deps, :render, fn facts -> Render.render_summary(facts, campaign) end)

    render_epos =
      Map.get(deps, :render_epos, fn facts -> Render.render_epos(facts, campaign) end)

    # Issue #838: Prosa-Progression — EIN Call pro (Session × berührter
    # Bogen)-Paar, nicht gebündelt (isolierte Fehlerbehandlung pro Bogen).
    render_arc_progression =
      Map.get(deps, :render_arc_progression, fn canonical, prior_entry, new_facts, gate_facts ->
        Render.render_arc_progression(canonical, prior_entry, new_facts, gate_facts, campaign)
      end)

    result =
      with {:ok, _facts} <- with_status(campaign.id, "extract", session.id, extract, run_id),
           :ok <- resolve_entities_best_effort(campaign.id, session.id, resolve),
           :ok <- resolve_threads_best_effort(campaign.id, session.id, resolve_threads),
           {:ok, verified} <-
             with_status(
               campaign.id,
               "verify",
               session.id,
               fn -> tag_error(verify.(), :verify) end,
               run_id
             ),
           {:ok, rendered} <-
             with_status(
               campaign.id,
               "render",
               session.id,
               fn -> tag_error(render.(verified), :render) end,
               run_id
             ) do
        publish_wahrheitsbild_summary(session, campaign, verified, rendered)

        # #752: Timeline und Epos-Kapitel sind unabhängige Geschwister-Artefakte
        # aus denselben verifizierten Fakten — ein Fehlschlag des einen darf das
        # andere nicht mitreißen (und keiner das schon publizierte Resümee).
        # Fehler landen einzeln klassifiziert in /admin/errors (with_status).
        timeline_entries =
          best_effort_artifact(
            campaign.id,
            "timeline",
            :timeline,
            session.id,
            fn -> Zeit.publiziere(session, campaign, verified) end,
            run_id
          )

        best_effort_artifact(
          campaign.id,
          "render_epos",
          :render_epos,
          session.id,
          fn ->
            publish_wahrheitsbild_epos(
              session,
              campaign,
              verified,
              timeline_entries || [],
              render_epos
            )
          end,
          run_id
        )

        # Issue #838: eigener best-effort-Schritt, PRO-BOGEN-Fehlerisolierung
        # innerhalb (Design J) — der äußere best_effort_artifact-Wrapper
        # allein würde bei einem fehlschlagenden Bogen von dreien den GANZEN
        # Schritt als "failed" markieren; publish_wahrheitsbild_arc_progressions/3
        # fängt jeden Bogen einzeln ab und liefert immer :ok.
        best_effort_artifact(
          campaign.id,
          "render_arc_progressions",
          :render_arc_progressions,
          session.id,
          fn ->
            ArcProgressions.publish(session, campaign, render_arc_progression)
          end,
          run_id
        )

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
  # ohne Guise-Merging weiter (kein Merge ist besser als ein falscher). Der Lauf
  # bleibt also `:ok` — aber #820: ein wiederholt scheiterndes Clustering war
  # davor NUR ein Logger.warning, für den Admin unsichtbar. publish_pipeline_error
  # direkt (statt via with_status, das würde den Stage-Status auf "failed"
  # setzen) macht den Fehler in /admin/errors sichtbar, ohne den Lauf als
  # gescheitert zu markieren.
  defp resolve_entities_best_effort(campaign_id, session_id, resolve_fn) do
    case resolve_fn.() do
      {:ok, _registry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline[wahrheitsbild]: Entity-Registry-Clustering fehlgeschlagen " <>
            "(#{inspect(reason)}) — Fakten bleiben unverändert (kein Merge ist besser als ein falscher)"
        )

        publish_pipeline_error(campaign_id, "resolve", session_id, reason, format_error(reason))

        :ok
    end
  end

  # #832: Handlungsbogen-Clustering-Fehler brechen die Pipeline NICHT (analog
  # #714/#820 beim Guise-Merging) — die Fakten behalten ihr Roh-`thread`-Label,
  # der Reader fällt darauf zurück (kein Cluster ist besser als ein falscher).
  # Eigene /admin/errors-Klasse "resolve_threads", damit ein wiederholt
  # scheiterndes Clustering für den Admin sichtbar wird, ohne den Lauf als
  # gescheitert zu markieren.
  defp resolve_threads_best_effort(campaign_id, session_id, resolve_threads_fn) do
    case resolve_threads_fn.() do
      {:ok, _registry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline[wahrheitsbild]: Thread-Registry-Clustering fehlgeschlagen " <>
            "(#{inspect(reason)}) — Fakten behalten ihr Roh-Label"
        )

        publish_pipeline_error(
          campaign_id,
          "resolve_threads",
          session_id,
          reason,
          format_error(reason)
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
  defp best_effort_artifact(campaign_id, stage, tag, session_id, fun, run_id \\ nil) do
    guarded = fn ->
      try do
        tag_error(fun.(), tag)
      rescue
        e -> {:error, {tag, Exception.message(e)}}
      end
    end

    case with_status(campaign_id, stage, session_id, guarded, run_id) do
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

  # Issue #1092: Block-ID → Position im geglätteten Transkript. Das ist die
  # Ordnung INNERHALB eines In-Game-Tages — die einzige, die deterministisch in
  # den Daten liegt und nicht erfunden werden muss.
  #
  # Bewusst Erzählreihenfolge, nicht erzählte Zeit: bei einer Rückblende fallen
  # beide auseinander, deshalb bleibt `in_game_day` primär und diese Position
  # nur Tiebreak. Die Aussage der Chronik ist damit „an diesem Tag, in dieser
  # Erzählreihenfolge" — zutreffend, statt wie bisher gar keine.
  #
  # Leere Map, wenn eine Session (noch) keinen Glättungs-Snapshot hat: die
  # Einträge bekommen `source_pos: nil` und sortieren ans Ende ihres Tages.
  #
  # Bewusst `def` (@doc false) statt `defp`: der Test prüft die Ableitung gegen
  # die Utterance-Zeitstempel — also gegen eine ANDERE Datenquelle als die, aus
  # der die Positionen stammen. Mit einem Nachbau im Test wäre das kein Beweis.
  @doc false

  # Issue #838: Prosa-Progression pro Bogen — ausgelagert nach
  # Worker.Recording.Pipeline.ArcProgressions (God-Module-Grenze #544).

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

        # Issue #1092: mit Kalender — sonst stünde im Kopf der rohe
        # Epochen-Tageszähler („Tag 734372–759565").
        header =
          Render.chapter_header(
            session,
            timeline_entries,
            Repo.get_campaign_calendar(campaign.id)
          )

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

  def with_status(campaign_id, stage, session_id, fun, run_id \\ nil) do
    ctx = %{session_id: session_id, run_id: run_id}
    notify_status(campaign_id, stage, "started", nil, ctx)
    result = fun.()

    {status, error_msg, error_reason} =
      case result do
        {:ok, _} -> {"ended", nil, nil}
        :ok -> {"ended", nil, nil}
        {:error, reason} -> {"failed", format_error(reason), reason}
        _ -> {"failed", nil, :unknown}
      end

    notify_status(campaign_id, stage, status, error_msg, ctx)
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

  # Issue #1008: die Fehler-TAXONOMIE lebt in `Worker.Recording.ErrorClass` —
  # rund 95 Zeilen reine Musterzuordnung von Reason → Code für /admin/errors.
  # Ausgelagert, weil dieses Modul damit die 1000-Zeilen-Grenze des
  # God-Module-Checks (#544) riss und die Taxonomie der am häufigsten
  # erweiterte Teil davon ist (jede neue Fehlerklasse fügt hier Zeilen hinzu).
  #
  # Die Delegation bleibt: `Pipeline.classify_pipeline_error/1` ist an rund 40
  # Stellen (überwiegend Tests) der eingeführte Name.
  defdelegate classify_pipeline_error(reason), to: Worker.Recording.ErrorClass, as: :classify

  # Issue #1122: `ctx` trägt `session_id` und `run_id` des Laufs. Beide fehlten
  # bislang im Payload, obwohl `with_status/4` die session_id längst übergeben
  # bekam und sie hier wegwarf — für das Laufband ist das der Unterschied
  # zwischen „irgendeine Stufe läuft" und „Session 4 ist bei der Prüfung".
  # Ohne `run_id` lassen sich zwei Läufe derselben Session nicht trennen (schon
  # heute möglich: zweimal auf „neu generieren").
  def notify_status(campaign_id, stage, status, error_msg, ctx \\ %{}) do
    payload =
      %{
        "kind" => "pipeline_stage",
        "campaign_id" => campaign_id,
        "stage" => stage,
        "status" => status,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> put_if("session_id", Map.get(ctx, :session_id))
      |> put_if("run_id", Map.get(ctx, :run_id))
      |> then(fn p -> if error_msg, do: Map.put(p, "error", error_msg), else: p end)

    Worker.HubClient.publish_status(payload)

    # Worker-lokaler Mit-Listener (Issue #74): Probelauf-Engine läuft im
    # selben BEAM und braucht Per-Schritt-Timings ohne den Umweg über Hub.
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
  end

  # Nur setzen, was es gibt — ein `nil`-Feld im Payload wäre eine Behauptung
  # („keine Session"), wo schlicht nichts bekannt ist. Alt-Consumer sehen den
  # Key dann gar nicht, statt auf null prüfen zu müssen.
  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

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

  # #889/#909: der fail-loud Prompt-Größen-Guard der Render-Stages.
  defp format_error({_stage, {:prompt_too_large, est, cap}}),
    do:
      "Render-Prompt zu groß: ~#{est} Tokens > num_ctx=#{cap} (ctx_stage4/5 erhöhen oder Fakten kuratieren)"

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
