defmodule Worker.Recording.Pipeline do
  @moduledoc """
  Listens for `UtterancesTranscribed` events on the worker-local PubSub and
  runs the per-session Wahrheitsbild-Pipeline (#651; seit #786 der einzige
  Pfad — die Chain Stage 2→3→4 ist entfernt):

      jack_gedaechtnis      Jack (J4 #1207, `Worker.Jack.Pipeline.extract_facts/4`):
      extract               Blöcke → geprüfte Fakten in drei Stufen, die Jack
      jack_verifikation     selbst meldet (`stufen_melder/3`)
      registry              campaign-weites Guise-Merging (best-effort, #714)
      (Bestand)             nach den Registries zurückgelesen (`Worker.Jack.
                            Pipeline.geprueft/1`), keine Stufe — ein zweites
                            Modell (Stufe 3, „verify“) gibt es nicht mehr
      resuemee_ueberblick   Resümee-Jack (J5 #1209, `Worker.Jack.Resuemee.Pipeline`):
      render                Überblick → Schreiben → Durchsicht, drei Stufen, die er
      resuemee_durchsicht   selbst meldet; danach SessionSummaryGenerated
      timeline              deterministischer Zeitstrahl → Chronik (#724)
      epos_ueberblick       Epos-Jack (J6 #1210, `Worker.Jack.Epos.Pipeline`):
      render_epos           Überblick → Schreiben → Durchsicht, drei Stufen, alle
      epos_durchsicht       best-effort; danach EposEntryEdited (Kapitel #752)
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
  `Hub.Commands` ohnehin gezielt an einen Worker (CampaignReplay /
  UI-Regenerate).
  """

  use GenServer

  require Logger

  alias Shared.Events
  alias Worker.{Intents, Repo}
  # Issue #583: God-Module-Split — Stage-Impl/Prompt-Bau/Output-Parse ausgelagert.
  alias Worker.Recording.Pipeline.{Fortschritt, Prompts}

  # Issue #571: Modul-Attribute für event-kind-Match im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard/Pattern). Hier wirkt das
  # Attribut wie ein bedingter Pattern-Constant; die Aliasing über
  # Shared.Events.x() macht den Hardcoded-String-Drift unmöglich.
  @utterances_transcribed_kind Events.utterances_transcribed()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Manueller Pipeline-Trigger für eine Session — direkt aufgerufen aus
  `CampaignReplay` und dem UI-Pfad (`Worker.HubClient`
  beim `start_session_regenerate`-Push). Kein Event-Roundtrip durch
  den Hub.

  Räumt eine etwaige stuck/finished prior-run Markierung aus dem
  `running`-Set, damit ein hängengebliebener Vorlauf den Retry nicht
  blockiert.

  `jack_weiter: n` (J4, #1207, „noch N Iterationen“): statt des ganzen Laufs
  n Folgedurchgänge auf Jacks abgelegtem Stand — ohne neue Glättung, danach
  wie jeder Lauf Registries, Resümee, Zeitstrahl und Epos.
  """
  @spec run_for_session(String.t(), keyword()) :: :ok
  def run_for_session(session_id, opts \\ []) when is_binary(session_id) do
    # Synchroner Call: returnt erst nachdem der `running`-Marker gesetzt ist,
    # damit CampaignReplay.wait_pipeline_idle/1 nicht race-conditional gegen
    # einen noch nicht verarbeiteten Cast pollt.
    GenServer.call(__MODULE__, {:run_for_session, session_id, opts}, :infinity)
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
  @spec republish_timeline_for_session(String.t()) :: :ok
  def republish_timeline_for_session(session_id) when is_binary(session_id) do
    # J7 (#1211): Es gibt keinen deterministischen Weg zurück in die Chronik
    # mehr. Der alte Pfad rechnete aus jedem verifizierten Fakt einen
    # datierten Eintrag; jetzt schreibt sie der Chronik-Jack, und ein
    # Modelllauf ist nichts, was man als Nebenwirkung einer Kuration startet
    # — der Resümee-Jack brauchte auf der Teststage 10 bis 72 Minuten, und
    # eine Kuration ist ein Batch-Vorgang.
    #
    # EHRLICHE FOLGE, die hier stehen bleibt, statt still zu verschwinden:
    # Nach einer Lücken-Kuration oder einer Neu-Extraktion ziehen die Fakten
    # sofort nach, die CHRONIK aber erst beim nächsten regulären
    # Pipeline-Lauf dieser Sitzung. Bis dahin kann sie Fakten zitieren, die
    # inzwischen anders lauten. Das ist der Preis dafür, dass die Chronik
    # gebündelt und über Sitzungsgrenzen hinweg entsteht.
    Logger.debug(
      "Chronik: kein deterministischer Republish mehr (#1211) — session=#{session_id} " <>
        "zieht beim nächsten Pipeline-Lauf nach."
    )

    :ok
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

    case maybe_run(session_id, state, opts) do
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

  defp maybe_run(session_id, state, opts \\ []) do
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
  defp run_stages(session, campaign, opts) do
    run_id = UUIDv7.generate()

    Fortschritt.lauf_start(%{
      run_id: run_id,
      session_id: session.id,
      campaign_id: campaign.id
    })

    case Keyword.fetch(opts, :jack_weiter) do
      {:ok, n} -> jack_weiter(session, campaign, n, run_id)
      :error -> ganzer_lauf(session, campaign, run_id)
    end
  end

  defp ganzer_lauf(session, campaign, run_id) do
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

  # J4 (#1207): „noch N Iterationen“ — Jack setzt auf seinem abgelegten Stand
  # auf. Bewusst OHNE neue Glättung: Jacks Blocknummern gelten nur für die
  # Blockliste, auf der er gelaufen ist (`Worker.Jack.Pipeline.abgelegter_stand/2`
  # prüft das). Danach wie jeder Lauf. Fehlt die Glättung, wird das als
  # Extraktions-Fehler sichtbar statt still zu enden.
  defp jack_weiter(session, campaign, n, run_id) do
    case Worker.Jack.Pipeline.gespeicherter_kontext(session.id) do
      {:ok, blocks} ->
        run_wahrheitsbild(session, campaign, blocks, %{run_id: run_id, jack: [weiter: n]})

      {:error, _} = err ->
        with_status(campaign.id, "extract", session.id, fn -> err end, run_id)
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

    case Smoothing.to_context(result.blocks, vorschlaege, overrides) do
      [] ->
        {:error, {:smooth, :no_blocks}}

      blocks ->
        {:ok, %{context: blocks}}
    end
  rescue
    e -> {:error, {:smooth, e}}
  end

  # Issue #651 Phase C: der Wahrheitsbild-Pfad. Jack-Extraktion (→ geprüfte
  # Fakten, J4 #1207) → EntityRegistry (campaign-weites Guise-Merging, #714) →
  # Bestand nach den Registries zurücklesen (`bestand_lesen/3`, keine Stufe,
  # kein eigenes Modell mehr) → Resümee durch den Resümee-Jack (J5 #1209) →
  # publish SessionSummaryGenerated + Geschwister Timeline (#724) und
  # Epos-Kapitel (#752).
  #
  # #714/#716: jeder Schritt läuft in `with_status` (UI-Busy-Badge + /admin/
  # errors-Persistenz mit eigener Fehlerklasse) — außer Jack und dem
  # Resümee-Jack, die ihre je drei Stufen selbst melden (`stufen_melder/3`),
  # und dem Epos-Jack (J6 #1210), der es ebenso tut, best-effort.
  # Scheitert das Resümee (Überblick oder Schreiben), endet der Lauf dort wie
  # früher beim Render: Chronik, Epos und Bogen-Progressionen laufen dann
  # NICHT. Die Registry ist best-effort
  # (Cluster-Fehler → Fakten unverändert, Pipeline läuft weiter — kein Merge
  # ist besser als ein falscher). `deps` ist für Orchestrator-Tests ohne
  # LLM injizierbar.
  @doc false
  def run_wahrheitsbild(session, campaign, utterances, deps \\ %{}) do
    alias Worker.Recording.Pipeline.{
      ArcProgressions,
      EntityRegistry,
      Render,
      ThreadRegistry
    }

    # #787: campaign liefert die Stil-Flavors an die Render-Prompts (Stil wirkt
    # hinter der Belegprüfung; die deps-Injection der Tests bleibt fn/1).
    # Issue #1122: `deps` trägt neben den injizierbaren Schritten auch den
    # Lauf-Kontext. Ein eigener Parameter wäre sauberer, hätte aber jeden
    # Testaufruf von `run_wahrheitsbild/4` gebrochen; `:run_id` kollidiert mit
    # keinem Schritt-Key. Fehlt er (Tests, Alt-Aufrufer), meldet der Lauf eben
    # ohne Identität — die Anzeige kommt damit klar, sie kann dann nur nicht
    # zwei gleichzeitige Läufe derselben Session trennen.
    run_id = Map.get(deps, :run_id)

    # J4 (#1207): Stufe 2 ist Jack — es gibt keine andere Extraktion mehr
    # (Tom, 11.09.2026). `deps.jack` trägt Jacks Optionen (`weiter: n`). Kein
    # `with_status` darum: Jack meldet Gedächtnis, Extraktion und Verifikation
    # selbst, samt Fehlern (`stufen_melder/3`).
    extract =
      Map.get(deps, :extract, fn ->
        Worker.Jack.Pipeline.extract_facts(
          utterances,
          session.id,
          campaign,
          Keyword.put(
            Map.get(deps, :jack, []),
            :melde_stufe,
            stufen_melder(campaign.id, session.id, run_id)
          )
        )
      end)

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

    # J4 (#1207): Stufe 3 entfällt — Jacks Fakten tragen ihre Belegprüfung
    # schon; hier kommt nur der Bestand nach den Registries zurück, kein
    # zweites Modell (Tom, 11.09.2026).
    verify = Map.get(deps, :verify, fn -> Worker.Jack.Pipeline.geprueft(session.id) end)

    # J5 (#1209, B4): das Resümee schreibt der Resümee-Jack — kein Rückfall auf
    # den früheren Render. Er liest die Sitzung selbst aus dem Repo und meldet
    # Überblick, Schreiben und Durchsicht selbst (`stufen_melder/3`), samt
    # Fehlern. `deps.resuemee` trägt seine Optionen (Tests: Modell, Fenster).
    render =
      Map.get(deps, :render, fn _facts ->
        Worker.Jack.Resuemee.Pipeline.schreiben(
          session,
          campaign,
          Keyword.put(
            Map.get(deps, :resuemee, []),
            :melde_stufe,
            stufen_melder(campaign.id, session.id, run_id)
          )
        )
      end)

    # J6 (#1210, E4): das Epos-Kapitel schreibt der Epos-Jack — kein Rückfall
    # auf den früheren Render (`Render.render_epos` ist entfernt). Er liest die
    # Sitzung selbst aus dem Repo, samt dem eben abgelegten Stand des
    # Resümee-Jack (daraus kommt der Weg), und meldet Überblick, Schreiben und
    # Durchsicht selbst (`stufen_melder/3`), samt Fehlern. `deps.epos` trägt
    # seine Optionen (Tests: Modell, Fenster); `deps.render_epos` ersetzt ihn
    # ganz, dann meldet niemand die drei Stufen.
    render_epos =
      Map.get(deps, :render_epos, fn _facts ->
        Worker.Jack.Epos.Pipeline.schreiben(
          session,
          campaign,
          Keyword.put(
            Map.get(deps, :epos, []),
            :melde_stufe,
            stufen_melder(campaign.id, session.id, run_id)
          )
        )
      end)

    # Issue #838: Prosa-Progression — EIN Call pro (Session × berührter
    # Bogen)-Paar, nicht gebündelt (isolierte Fehlerbehandlung pro Bogen).
    render_arc_progression =
      Map.get(deps, :render_arc_progression, fn canonical, prior_entry, new_facts ->
        Render.render_arc_progression(canonical, prior_entry, new_facts, campaign)
      end)

    result =
      with {:ok, _facts} <- extract.(),
           :ok <- resolve_entities_best_effort(campaign.id, session.id, resolve),
           :ok <- resolve_threads_best_effort(campaign.id, session.id, resolve_threads),
           {:ok, verified} <- bestand_lesen(campaign.id, session.id, verify),
           {:ok, rendered} <- tag_error(render.(verified), :render) do
        Worker.Jack.Resuemee.Pipeline.veroeffentlichen(session, campaign, verified, rendered)

        # #752: Timeline und Epos-Kapitel sind unabhängige Geschwister-Artefakte
        # aus denselben verifizierten Fakten — ein Fehlschlag des einen darf das
        # andere nicht mitreißen (und keiner das schon publizierte Resümee).
        # Fehler landen einzeln klassifiziert in /admin/errors (with_status).
        # J7 (#1211): die Chronik schreibt der Chronik-Jack. Der frühere
        # deterministische Pfad (`Zeit.publiziere/3`) rechnete aus jedem
        # verifizierten Fakt einen datierten Eintrag — 543 von 544 Einträgen
        # einer echten Kampagne lagen dabei auf demselben Tag (#1092). Jetzt
        # urteilt Jack (was gehört zusammen, was kam wovor), und Elixir
        # rechnet die Reihenfolge.
        #
        # Best-effort wie bisher, aber ohne `with_status` — der Chronik-Jack
        # meldet seine Stufen selbst. Ein Fehlschlag (auch ein Raise) reisst
        # den Lauf nicht mit; die bestehende Chronik bleibt stehen, weil
        # nichts mehr geleert wird.
        timeline_entries = chronik_jack(session, campaign, run_id, deps)

        # J6 (#1210, E4): best-effort wie bisher, aber ohne `with_status` — der
        # Epos-Jack meldet seine drei Stufen selbst. Ein Fehlschlag (auch ein
        # Raise) reißt den Lauf nicht mit, das bisherige Kapitel bleibt stehen.
        Worker.Jack.Epos.Pipeline.kapitel(
          session,
          campaign,
          verified,
          timeline_entries || [],
          render_epos,
          stufen_melder(campaign.id, session.id, run_id)
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

  # J4 (#1207): der Bestand nach den Registries — keine Stufe mehr (Stufe 3
  # entfällt, `Worker.Jack.Pipeline.geprueft/1`). Ein Fehler bleibt in
  # /admin/errors sichtbar, unter "verify" wie bisher; getaggt `:verify`, damit
  # er klassifiziert wird wie die Alteinträge.
  defp bestand_lesen(campaign_id, session_id, verify) do
    case tag_error(verify.(), :verify) do
      {:error, reason} = fehler ->
        publish_pipeline_error(campaign_id, "verify", session_id, reason, format_error(reason))
        fehler

      ok ->
        ok
    end
  end

  # #752: unabhängiges Geschwister-Artefakt best-effort ausführen. Fehler (auch
  # Raises) landen via with_status klassifiziert in /admin/errors, brechen aber
  # weder die anderen Artefakte noch den Gesamtlauf. Liefert den {:ok, value}-
  # Wert des Schritts oder nil.
  # J7 (#1211): der Chronik-Jack. Wie der Epos-Jack ohne `with_status` — er
  # meldet seine Stufen selbst (`chronik_ueberblick`, `timeline`,
  # `chronik_durchsicht`). Ein Fehlschlag reisst den Lauf nicht mit und lässt
  # die bestehende Chronik stehen; ein Raise ebenso, deshalb der Rettungszweig.
  #
  # Zurück kommen die veröffentlichten Einträge — der Kapitelkopf des Epos
  # leitet daraus seine Tagesspanne ab (#752). Bei einem Fehlschlag ist das
  # `nil`, und der Kopf bleibt ohne Datum; das war schon vorher so.
  defp chronik_jack(session, campaign, run_id, deps) do
    # `deps.chronik_jack` ersetzt den Lauf ganz (Tests: kein Modell in der
    # Umgebung) — dasselbe Muster wie `deps.render_epos`. `deps.chronik`
    # trägt nur seine Optionen.
    lauf =
      Map.get(deps, :chronik_jack, fn ->
        Worker.Jack.Chronik.Pipeline.schreiben(
          session,
          campaign,
          Keyword.put(
            Map.get(deps, :chronik, []),
            :melde_stufe,
            stufen_melder(campaign.id, session.id, run_id)
          )
        )
      end)

    case lauf.() do
      {:ok, eintraege} ->
        eintraege

      {:error, grund} ->
        Logger.warning(
          "Pipeline[wahrheitsbild]: Chronik-Jack gescheitert für session=#{session.id}: " <>
            "#{inspect(grund, limit: 20)} — die bestehende Chronik bleibt stehen."
        )

        nil
    end
  rescue
    e ->
      Logger.error(
        "Pipeline[wahrheitsbild]: Chronik-Jack ist abgestürzt für session=#{session.id}: " <>
          "#{Exception.message(e)}"
      )

      nil
  end

  defp best_effort_artifact(campaign_id, stage, tag, session_id, fun, run_id) do
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

  # J5 (#1209, B4): das Veröffentlichen des Resümees lebt in
  # `Worker.Jack.Resuemee.Pipeline.veroeffentlichen/4` — mit genauen
  # `source_refs` (nur die zitierten Fakten), Satzquellen und Zählwerten;
  # `render_backend: "jack"` statt des früheren Stage-4-Stempels (#783).

  # J6 (#1210, E4): das Epos-Kapitel schreibt der Epos-Jack; der #753-Schutz
  # (GM-Edit), der Kapitelkopf (#752/#1092) und das Veröffentlichen leben in
  # `Worker.Jack.Epos.Pipeline.kapitel/6`. Die Blockpositionen der Chronik
  # (#1092) liegen in `Worker.Recording.Pipeline.Zeit.block_positions/1`, die
  # Bogen-Progressionen (#838) in `Worker.Recording.Pipeline.ArcProgressions`.

  def with_status(campaign_id, stage, session_id, fun, run_id \\ nil) do
    ctx = %{session_id: session_id, run_id: run_id, campaign_id: campaign_id}
    stufe_beginnt(ctx, stage)
    result = fun.()
    stufe_endet(ctx, stage, result)
    result
  end

  @doc false
  # J4 (#1207): der Rückruf `:melde_stufe` für Jack (`Worker.Jack.Pipeline`).
  # Jacks Stufen entsprechen keiner einzelnen Funktion, die `with_status/5`
  # umschließen könnte — Gedächtnis, Extraktion und Verifikation beginnen und
  # enden mitten in seinem Lauf. Deshalb dieselben zwei Bausteine wie dort,
  # nur getrennt aufgerufen; dazu die Zählung je Stufe (die Verifikation je
  # Durchgang neu) an `Fortschritt`.
  def stufen_melder(campaign_id, session_id, run_id) do
    ctx = %{session_id: session_id, run_id: run_id, campaign_id: campaign_id}

    fn
      stage, :beginn -> stufe_beginnt(ctx, stage)
      stage, {:ende, ergebnis} -> stufe_endet(ctx, stage, ergebnis)
      stage, {:zaehlung, gesamt, nr} -> Fortschritt.abschnitt(ctx, stage, gesamt, nr)
      stage, {:gelesen, block, nr} -> Fortschritt.fertig(ctx, stage, block, nr)
    end
  end

  defp stufe_beginnt(ctx, stage) do
    notify_status(ctx.campaign_id, stage, "started", nil, ctx)
    Fortschritt.stufe(ctx, stage, "started")
  end

  defp stufe_endet(ctx, stage, result) do
    {status, error_msg, error_reason} =
      case result do
        {:ok, _} -> {"ended", nil, nil}
        :ok -> {"ended", nil, nil}
        {:error, reason} -> {"failed", format_error(reason), reason}
        _ -> {"failed", nil, :unknown}
      end

    notify_status(ctx.campaign_id, stage, status, error_msg, ctx)
    Fortschritt.stufe(ctx, stage, status)
    # Issue #68 (Phase 1): persistierter Fehler-Log für /admin/errors.
    if status == "failed",
      do: publish_pipeline_error(ctx.campaign_id, stage, ctx.session_id, error_reason, error_msg)

    :ok
  end

  # Issue #68 (Phase 1): publisht ein `PipelineErrorLogged`-Event. Best-effort,
  # Publish-Fehler werden geloggt aber nicht propagiert — sonst würde der
  # ursprüngliche Stage-Fehler durch einen Hub-Sync-Fehler maskiert.
  def publish_pipeline_error(campaign_id, stage, session_id, reason, message) do
    # Issue #542: die Häufung zählen, den Einzelfall nicht wiederholen — der
    # steht gleich als Eintrag in `/admin/errors`. Als Quelle die Stufe, damit
    # „fünf Fehler" nicht bedeutungslos bleibt.
    Worker.Telemetry.zaehle(:pipeline_fehler, quelle: to_string(stage))

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

    # Worker-lokaler Mit-Listener: `Worker.Recording.CampaignReplay` läuft im
    # selben BEAM und braucht die Stufenmeldungen ohne den Umweg über den Hub —
    # jede Meldung setzt seine Stille-Frist zurück (#1062). Eingeführt wurde
    # der Broadcast für den inzwischen entfernten Probelauf (#74).
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
  end

  # Nur setzen, was es gibt — ein `nil`-Feld im Payload wäre eine Behauptung
  # („keine Session"), wo schlicht nichts bekannt ist. Alt-Consumer sehen den
  # Key dann gar nicht, statt auf null prüfen zu müssen.
  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # Issue #27: aus dem internen Pipeline-Reason eine UI-lesbare Message machen.
  # Reasons kommen in mehreren Formen rein:
  #   {:extraction, {:upstream, code, status, msg}}  ← Cloud-Backend
  #   {:verify, :no_facts}                           ← kein Fakten-Bestand
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

  defdelegate preview_prompt(stage, campaign), to: Prompts
  defdelegate effective_flavor(flavors, slot), to: Prompts
  defdelegate default_flavor(slot), to: Prompts
  defdelegate heading_directive(name, stage), to: Prompts
  defdelegate stage_heading(campaign, stage), to: Prompts
end
