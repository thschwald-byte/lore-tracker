defmodule Worker.Recording.Pipeline.Dirty do
  @moduledoc """
  Issue #866 (Epic #861 Slice F): der generische Dirty-Mechanismus — Kuration
  triggert die Neuableitung abhängiger :generiert-Artefakte automatisch (bis
  Slice F fiel die ANY-Klemme erst beim nächsten manuellen Regenerate).

  ## Die Text-Identitäts-Weiche (B1)

  Die Weiche keyt auf TEXT-IDENTITÄT, NIE auf das Kurations-Status-Label:
  `hash(effective_text nach Kuration) == extraction_saw[block_id]` → der
  Extraktor hat exakt diesen Text bereits gesehen → **nur Re-Verify**
  (deterministische Klemm-Neuberechnung aus den persistierten `grounded?`/
  `attributed?`-Verdikten — KEIN LLM; Fakt-IDs stabil, Fakt-Overrides
  überleben). Sonst → **Re-Extract mit Carry-over**. Damit ist das
  async-Gemma-Zeitloch geschlossen: lief die Extraktion VOR dem Eintreffen
  des Vorschlags und bestätigt der Member danach, ist `bestaetigt` faktisch
  text-ändernd und routet mechanisch auf Re-Extract.

  **Fail-closed als EXPLIZITE Regel (F1 Runde 6):** fehlender
  `extraction_saw[block_id]`-Eintrag ⇒ text-ändernd ⇒ Re-Extract — benannte
  Klausel in `classify/3`, kein nil-Vergleichs-Nebeneffekt.

  ## Carry-over (F1/F3)

  Re-Extraktion läuft session-scoped (der Prompt braucht Kontext), aber aus
  dem LLM-Lauf werden NUR Fakten übernommen, deren `source_refs` einen
  text-GEÄNDERTEN Block berühren. Fakten ausschließlich unveränderter Blöcke:
  verbatim Carry-over (Verdikte inklusive — gleiche Content-IDs, Overrides
  überleben); LLM-Duplikate dazu werden verworfen (sonst Fakt-Drift bei jeder
  Kuration). **Ausnahme F3: `unbrauchbar`-Blöcke gelten als ENTFERNT** —
  kein verbatim-Übernehmen, ihre Fakten fallen (F5).

  ## Kanten + Nicht-Kanten

  `@dependency_graph` ist die EINE Stelle, an der Events Neuableitungen
  auslösen — `LueckenKurationSet` → Weiche (debounced, Kuration ist ein
  Batch-Vorgang), `SessionFactDateSet` → deterministischer Timeline-Republish
  (aus der Pipeline hierher gezogen, Verhalten identisch). Explizite
  NICHT-Kanten (Negativtests): `LueckenVorschlagGeneriert` (Gemma-Eintreffen
  triggert NIE eine Re-Extraktion), `TranscriptSmoothed` (kein Re-Smoothing-
  Kaskadieren; Re-Smoothing bleibt on-demand via Regenerate, P2),
  `SessionFactsExtracted` (die eigenen Republishes loopen nicht).

  Election: wie die Pipeline (`elected?/2`, #365) — nur der Author-Worker der
  Kuration verarbeitet; sein Fold sieht den neuen Stand garantiert. Stirbt er
  zwischen Fold und Verarbeitung, heilt der nächste Trigger/Regenerate
  (gleiche ehrliche Grenze wie der #724-Republish). Ehrliche Grenze v1: die
  Prosa-Renders (Resümee/Epos) werden NICHT automatisch neu gerendert —
  Fakten + Timeline schon; die Prosa zieht beim nächsten Regenerate nach.
  """

  use GenServer

  require Logger

  alias Worker.Recording.Pipeline
  alias Worker.Recording.Pipeline.Smoothing
  alias Worker.Recording.Pipeline.Stages
  alias Worker.Recording.Pipeline.Verify
  alias Worker.Repo

  @kuration_kind Shared.Events.luecken_kuration_set()
  @fact_date_kind Shared.Events.session_fact_date_set()

  # Die EINE Kanten-Tabelle. Alles andere ist Nicht-Kante (Catch-all).
  @dependency_graph %{
    @kuration_kind => :weiche,
    @fact_date_kind => :timeline
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc false
  def dependency_graph, do: @dependency_graph

  # ── Pure Weiche ────────────────────────────────────────────────────────────

  @doc """
  Die Text-Identitäts-Weiche (pur). `saw_entry` = `extraction_saw[block_id]`
  der aktuellen Fakten-Row (nil, wenn der Block der Extraktion unbekannt ist).
  """
  @spec classify(String.t(), String.t() | nil, String.t() | nil) :: :reextract | :reverify
  def classify(status, bestaetigter_text, saw_entry)

  # unbrauchbar nimmt den Block aus der Oberfläche (F5) — Fakten müssen fallen.
  def classify("unbrauchbar", _text, _saw), do: :reextract

  # FAIL-CLOSED, benannte Regel (F1 Runde 6): Extraktion kennt den Block nicht
  # (Rules-Bump, Pre-Block-Bestand, verwaister Override) → Re-Extract.
  def classify(_status, _text, nil), do: :reextract

  def classify(_status, text, saw_entry) when is_binary(text) do
    if Smoothing.text_hash(text) == saw_entry, do: :reverify, else: :reextract
  end

  def classify(_status, _text, _saw), do: :reextract

  @doc """
  Carry-over-Partition (pur). `changed` = Menge text-geänderter Block-IDs,
  `removed` = Menge der unbrauchbar-Blöcke (F3: gelten als entfernt).
  Returns `{carried, adopted}`: `carried` = Alt-Fakten, deren Refs weder
  geänderte noch entfernte Blöcke berühren (Verdikte bleiben); `adopted` =
  LLM-Fakten, die ≥1 geänderten Block berühren UND nicht schon carried sind.
  """
  @spec partition_carryover([map()], [map()], MapSet.t(), MapSet.t()) :: {[map()], [map()]}
  def partition_carryover(old_facts, llm_facts, %MapSet{} = changed, %MapSet{} = removed) do
    dirty = MapSet.union(changed, removed)

    carried =
      Enum.reject(old_facts, fn f ->
        Enum.any?(f["source_refs"] || [], &MapSet.member?(dirty, &1))
      end)

    carried_ids = MapSet.new(carried, & &1["id"])

    adopted =
      llm_facts
      |> Enum.filter(fn f ->
        Enum.any?(f["source_refs"] || [], &MapSet.member?(changed, &1))
      end)
      |> Enum.reject(&MapSet.member?(carried_ids, &1["id"]))
      |> Enum.uniq_by(& &1["id"])

    {carried, adopted}
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{dirty: %{}, timers: %{}, inflight: MapSet.new()}}
  end

  @impl true
  def handle_info({:applied, %{"payload" => %{"kind" => kind} = payload} = event}, state) do
    case Map.get(@dependency_graph, kind) do
      nil ->
        # NICHT-Kante: LueckenVorschlagGeneriert / TranscriptSmoothed /
        # SessionFactsExtracted / alles andere triggert hier NIE etwas.
        {:noreply, state}

      edge ->
        if Pipeline.elected?(event, Repo.get_state(:worker_id)) do
          handle_edge(edge, payload, state)
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:applied, _}, state), do: {:noreply, state}

  # Debounce abgelaufen → Verarbeitung durch die GpuQueue (hinter laufenden
  # Pipeline-Jobs; Kuration während eines Laufs überholt ihn nicht).
  #
  # KOALESZENZ (Real-Befund 2026-07-17): läuft/wartet bereits ein Dirty-Job
  # dieser Session, wird NICHT erneut enqueued — der Level bleibt gemerkt und
  # der Timer re-armiert; nach {:dirty_done, sid} feuert der Rest. Ohne das
  # stauten sich beim schubweisen Kuratieren (71 Blöcke über 40 min) ZEHN
  # identische Re-Extract-Läufe derselben Session in der GPU-Queue.
  def handle_info({:dirty_fire, session_id}, state) do
    if MapSet.member?(state.inflight, session_id) do
      ref = Process.send_after(self(), {:dirty_fire, session_id}, debounce_ms())
      {:noreply, %{state | timers: Map.put(state.timers, session_id, ref)}}
    else
      {level, dirty} = Map.pop(state.dirty, session_id)
      timers = Map.delete(state.timers, session_id)

      inflight =
        if level do
          me = self()

          Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
            try do
              Worker.GpuQueue.run(
                fn -> process(session_id, level) end,
                label: "dirty:#{session_id}"
              )
            after
              send(me, {:dirty_done, session_id})
            end
          end)

          MapSet.put(state.inflight, session_id)
        else
          state.inflight
        end

      {:noreply, %{state | dirty: dirty, timers: timers, inflight: inflight}}
    end
  end

  # Job fertig → falls währenddessen weiter kuratiert wurde (dirty-Eintrag
  # existiert wieder), nach kurzem Settle erneut feuern.
  def handle_info({:dirty_done, session_id}, state) do
    state = %{state | inflight: MapSet.delete(state.inflight, session_id)}

    if Map.has_key?(state.dirty, session_id) do
      ref = Process.send_after(self(), {:dirty_fire, session_id}, debounce_ms())
      {:noreply, %{state | timers: Map.put(state.timers, session_id, ref)}}
    else
      {:noreply, state}
    end
  end

  # #724-Kante: deterministisch + billig → sofort, ohne Debounce (Verhalten
  # identisch zur früheren Pipeline-handle_info-Klausel).
  defp handle_edge(:timeline, payload, state) do
    session_id = payload["session_id"]

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      Pipeline.republish_timeline_for_session(session_id)
    end)

    {:noreply, state}
  end

  defp handle_edge(:weiche, payload, state) do
    session_id = payload["session_id"]
    level = classify_kuration(payload)

    # :reextract übertrumpft :reverify; jede neue Kuration resettet den Timer
    # (Kuration ist ein Batch-Vorgang — erst wenn Ruhe ist, wird gerechnet).
    merged = merge_level(Map.get(state.dirty, session_id), level)

    if ref = Map.get(state.timers, session_id), do: Process.cancel_timer(ref)
    ref = Process.send_after(self(), {:dirty_fire, session_id}, debounce_ms())

    Logger.info("Dirty: session=#{session_id} → #{merged} (debounce #{debounce_ms()}ms)")

    {:noreply,
     %{
       state
       | dirty: Map.put(state.dirty, session_id, merged),
         timers: Map.put(state.timers, session_id, ref)
     }}
  end

  defp debounce_ms, do: Worker.Settings.get(:dirty_debounce_ms, 15_000)

  defp merge_level(:reextract, _), do: :reextract
  defp merge_level(_, :reextract), do: :reextract
  defp merge_level(_, :reverify), do: :reverify

  defp classify_kuration(payload) do
    saw =
      case Repo.get_session_facts(payload["session_id"]) do
        %{extraction_saw: saw} when is_map(saw) -> saw
        _ -> %{}
      end

    classify(
      payload["status"],
      payload["bestaetigter_text"],
      Map.get(saw, payload["block_id"])
    )
  end

  # ── Verarbeitung (läuft in der GpuQueue) ───────────────────────────────────

  @doc false
  def process(session_id, :reverify) do
    with {:ok, campaign_id} <- campaign_id_for(session_id),
         %{facts: facts, extraction_saw: saw} <- Repo.get_session_facts(session_id) do
      # Deterministische Klemm-Neuberechnung: verified? aus den PERSISTIERTEN
      # Verdikten (der Judge sah exakt diesen Text schon — kein LLM nötig),
      # dann die frische Klemm-Menge (kuratierte Blöcke sind raus) anwenden.
      recomputed =
        facts
        |> Enum.map(fn f ->
          f
          |> Map.put("verified?", f["grounded?"] == true and f["attributed?"] == true)
          |> Map.delete("gap_geklemmt")
        end)
        |> Verify.apply_gap_clamp(Verify.persisted_clamp_ids(session_id))

      {:ok, _seq} =
        Worker.Intents.publish(%{
          "kind" => Shared.Events.session_facts_extracted(),
          "session_id" => session_id,
          "campaign_id" => campaign_id,
          "facts" => recomputed,
          # Feldkonservativ: die Zeit-Adresse bleibt — der Text hat sich ja
          # gerade NICHT geändert (deshalb sind wir im Re-Verify-Zweig).
          # (decode_saw garantiert eine Map — kein nil-Fallback nötig.)
          "extraction_saw" => saw
        })

      Pipeline.republish_timeline_for_session(session_id)

      n = Enum.count(recomputed, & &1["verified?"])
      Logger.info("Dirty[reverify]: session=#{session_id} → #{n}/#{length(recomputed)} verified")
      :ok
    else
      nil -> {:error, :no_facts}
      {:error, reason} -> {:error, reason}
    end
  end

  def process(session_id, :reextract) do
    with {:ok, campaign} <- campaign_for(session_id),
         snap when snap != nil <- Repo.get_smoothed_blocks(session_id),
         %{facts: old_facts, extraction_saw: old_saw} <- Repo.get_session_facts(session_id) do
      blocks = snap.blocks || []
      vorschlaege = Repo.luecken_vorschlaege_for_session(session_id)
      %{attached: overrides} = Repo.luecken_overrides_effective(session_id, blocks)

      # Einmal-Resolve (B2): die effektiven Texte DIESES Laufs.
      ctx = Smoothing.to_context(blocks, vorschlaege, overrides)
      now_saw = Map.new(ctx, fn u -> {u.id, Smoothing.text_hash(u.text || "")} end)

      changed =
        ctx
        |> Enum.filter(fn u -> Map.get(old_saw, u.id) != now_saw[u.id] end)
        |> MapSet.new(& &1.id)

      # F3/F5: unbrauchbar = aus der Oberfläche entfernt (to_context filtert
      # sie schon — die Differenz Blöcke↔ctx ist genau diese Menge).
      removed =
        blocks
        |> MapSet.new(& &1["id"])
        |> MapSet.difference(MapSet.new(ctx, & &1.id))

      with {:ok, llm_facts, _saw} <- Stages.extract_facts_raw(ctx, session_id, campaign) do
        {carried, adopted} = partition_carryover(old_facts, llm_facts, changed, removed)

        # Real-Befund 2026-07-17 (210 stale Klemmen): carried-Fakten reisen
        # verbatim — inkl. ALTER gap_geklemmt/verified?-Flags. apply_gap_clamp
        # setzt Flags nur, nimmt sie nie weg → vor dem Neu-Klemmen wie im
        # Re-Verify-Pfad aus den persistierten Verdikten normalisieren.
        carried =
          Enum.map(carried, fn f ->
            f
            |> Map.put("verified?", f["grounded?"] == true and f["attributed?"] == true)
            |> Map.delete("gap_geklemmt")
          end)

        # Nur die übernommenen (neuen) Fakten durch den LLM-Judge — die
        # carried behalten ihre Verdikte (gleicher Text, gleiche IDs).
        speaker_names = Worker.Recording.Pipeline.Prompts.resolve_speaker_names(campaign.id)
        verified_adopted = Verify.verify_facts(adopted, ctx, speaker_names: speaker_names)

        merged =
          (carried ++ verified_adopted)
          |> Enum.uniq_by(& &1["id"])
          |> Verify.apply_gap_clamp(Smoothing.clamp_block_ids(blocks, overrides))

        {:ok, _seq} =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.session_facts_extracted(),
            "session_id" => session_id,
            "campaign_id" => campaign.id,
            "facts" => merged,
            "extraction_saw" => now_saw
          })

        Pipeline.republish_timeline_for_session(session_id)

        Logger.info(
          "Dirty[reextract]: session=#{session_id} → #{length(carried)} carried, " <>
            "#{length(verified_adopted)} adopted (changed=#{MapSet.size(changed)}, " <>
            "removed=#{MapSet.size(removed)})"
        )

        :ok
      end
    else
      nil -> {:error, :no_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp campaign_for(session_id) do
    with {:ok, campaign_id} <- campaign_id_for(session_id),
         campaign when campaign != nil <- Repo.get_campaign(campaign_id) do
      {:ok, campaign}
    else
      nil -> {:error, :no_campaign}
      {:error, reason} -> {:error, reason}
    end
  end

  defp campaign_id_for(session_id) do
    case Repo.get_session_facts(session_id) do
      %{campaign_id: cid} when is_binary(cid) -> {:ok, cid}
      _ -> {:error, :no_facts}
    end
  end
end
