defmodule Worker.Materializer.ArcFolds do
  @moduledoc """
  Issues #903/#905 (Epic #900 S2+S3): die Arc-Folds — Schwester-Modul von
  `Worker.Materializer.Apply2` (dessen God-Module-Budget), dort nur
  Dünn-Dispatch-Klauseln.

  EINE `worker_arcs`-Row pro Arc, VIER unabhängige Fold-Gruppen darauf
  (fold_meta-Sidecar, Muster `member_join_apply`):

    * `:arc_created`   — Existenz + Seeds + Leitfrage-Draft (ArcCreated).
    * `:arc_act`       — GETEILT für ArcClosed + ArcReopened (konkurrieren um
      dasselbe Feld-Tripel act_kind/act_grund/act_wasserlinie; LWW-by-event_id,
      `:invite_status`-Konvention). Whole-Snapshot pro Gruppe: Reopened nil-t
      grund + wasserlinie EXPLIZIT (Partial-Payload wäre reorder-divergent).
    * `:arc_leitfrage` — kuratierter Leitfragen-Text (LeitfrageSet; leerer
      Text = Undo-Row, NIE ein Delete).
    * `:arc_merge` (#905) — Merge-Redirect-Zeiger `merged_into` (ArcMergeSet;
      "" = Undo-Row). Self-Merge wird am Fold gedroppt; die Redirect-
      Wirksamkeit (Ziel existiert + un-gemerged, Ein-Level) entscheidet
      der READER, nie der Fold (order-sensitiv wäre falsch).

  **EIN Preserve-Mechanismus für alle Writer** (#905-Fund F1): `current_row/2`
  liefert ALLE Felder (bestehend oder Stub-Basis), jeder Writer überschreibt
  NUR seine Gruppe via `write_row!/2`. Die frühere Drei-Mechanismen-Lage
  (eigener Read / existing_or_stub / Zweit-Read) hätte beim Anwachsen der
  Spalten einen vergessenen Preserve-Pfad = order-sensitives Clobbern
  riskiert (A1-Klasse).

  Reorder-Invariante (Stub-Upsert): trifft ein Akt/eine Leitfrage/ein Merge
  VOR dem ArcCreated ein, wird eine Stub-Row angelegt — ein „Row fehlt →
  drop" wäre order-sensitiv divergent.

  Dazu (#905): `fact_arc_set/3` — der Fakt→Arc-Override als eigene LWW-Row
  in `worker_fact_arc_overrides` (thread_overrides-Muster, Undo = ""-Row).

  Der Arc-STATUS ist bewusst kein Feld — Reader-Ableitung (`Worker.Repo.Threads`).
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @grunde ~w(geloest versandet)

  @doc false
  def arc_created(payload, _ts, meta) do
    arc_id = payload["arc_id"]
    cid = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(arc_id) and is_binary(cid)) ->
        Logger.warning("ArcCreated: bad payload (arc_id/campaign_id) — dropping")
        :ok

      not fold_supersedes?(S.arcs(), arc_id, :arc_created, event_id) ->
        :ok

      true ->
        seeds = payload["seed_raw_labels"] |> List.wrap() |> Enum.filter(&is_binary/1)
        f = current_row(arc_id, cid)
        write_row!(arc_id, %{f | cid: cid, seeds: seeds, draft: payload["leitfrage_draft"]})
        record_fold_winner!(S.arcs(), arc_id, :arc_created, event_id)
    end
  end

  @doc false
  def arc_closed(payload, _ts, meta) do
    grund = payload["grund"]

    if grund in @grunde do
      # Wasserlinie kommt ZUR SCHREIBZEIT aus dem Hub-LV-Payload (#900-Fund A4);
      # nicht-integer Werte defensiv auf nil — der Reader behandelt nil als 0
      # (fail-open Richtung „offen/sichtbar").
      wl = payload["wasserlinie_session"]
      wl = if is_integer(wl), do: wl, else: nil
      write_act(payload, meta, "closed", grund, wl)
    else
      Logger.warning("ArcClosed: unbekannter grund #{inspect(grund)} — dropping")
      :ok
    end
  end

  @doc false
  # Whole-Snapshot der :arc_act-Gruppe: grund + wasserlinie explizit nil.
  def arc_reopened(payload, _ts, meta), do: write_act(payload, meta, "reopened", nil, nil)

  @doc false
  def leitfrage_set(payload, _ts, meta) do
    arc_id = payload["arc_id"]
    cid = payload["campaign_id"]
    text = payload["text"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(arc_id) and is_binary(cid) and is_binary(text)) ->
        Logger.warning("LeitfrageSet: bad payload (arc_id/campaign_id/text) — dropping")
        :ok

      not fold_supersedes?(S.arcs(), arc_id, :arc_leitfrage, event_id) ->
        :ok

      true ->
        write_row!(arc_id, %{current_row(arc_id, cid) | kuratiert: text})
        record_fold_winner!(S.arcs(), arc_id, :arc_leitfrage, event_id)
    end
  end

  @doc false
  # #905: Merge-Redirect-Zeiger. "" = Undo (reguläre Row); Self-Merge = Drop.
  def arc_merge_set(payload, _ts, meta) do
    arc_id = payload["arc_id"]
    cid = payload["campaign_id"]
    target = payload["merge_into"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(arc_id) and is_binary(cid) and is_binary(target)) ->
        Logger.warning("ArcMergeSet: bad payload (arc_id/campaign_id/merge_into) — dropping")
        :ok

      target == arc_id ->
        Logger.warning("ArcMergeSet: Self-Merge #{arc_id} — dropping")
        :ok

      not fold_supersedes?(S.arcs(), arc_id, :arc_merge, event_id) ->
        :ok

      true ->
        write_row!(arc_id, %{current_row(arc_id, cid) | merged_into: target})
        record_fold_winner!(S.arcs(), arc_id, :arc_merge, event_id)
    end
  end

  @doc false
  # #905: Fakt→Arc-Override (v1: EIN Override pro Fakt; "" = Undo → Label-
  # Kette gilt). Eigene LWW-Row, Key "cid:fact_id" (fact_id content-adressiert
  # #864 → re-key-immun). Wirksamkeit (Ziel-Arc existiert/sichtbar) prüft
  # der Reader.
  def fact_arc_set(payload, _ts, meta) do
    cid = payload["campaign_id"]
    fact_id = payload["fact_id"]
    arc_id = payload["arc_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(cid) and is_binary(fact_id) and is_binary(arc_id)) ->
        Logger.warning("FactArcSet: bad payload (campaign_id/fact_id/arc_id) — dropping")
        :ok

      true ->
        key = cid <> ":" <> fact_id

        if fold_supersedes?(S.fact_arc_overrides(), key, :fact_arc_set, event_id) do
          :ok = :mnesia.write({S.fact_arc_overrides(), key, cid, fact_id, arc_id, event_id})
          record_fold_winner!(S.fact_arc_overrides(), key, :fact_arc_set, event_id)
        else
          :ok
        end
    end
  end

  # Issue #838: Prosa-Progression pro (Bogen × Session) — eigene, EIN Row
  # pro (arc_id, session_id)-Paar-Tabelle (worker_arc_progressions), Key
  # "cid:arc_id:session_id" (fact_arc_set/3-Muster). LWW pro Key — konkurriert
  # NIE mit dem Eintrag einer anderen Session desselben Bogens (die
  # strukturelle Replay-Sicherheit: ein Regenerate von Session 3 trifft
  # ausschließlich den Session-3-Eintrag).
  def arc_progression_generated(payload, ts, meta) do
    cid = payload["campaign_id"]
    arc_id = payload["arc_id"]
    session_id = payload["session_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(cid) and is_binary(arc_id) and is_binary(session_id)) ->
        Logger.warning(
          "ArcProgressionGenerated: bad payload (campaign_id/arc_id/session_id) — dropping"
        )

        :ok

      true ->
        key = cid <> ":" <> arc_id <> ":" <> session_id

        if fold_supersedes?(S.arc_progressions(), key, :arc_progression_generated, event_id) do
          :ok =
            :mnesia.write({
              S.arc_progressions(),
              key,
              arc_id,
              cid,
              session_id,
              payload["session_number"],
              payload["content_md"] || "",
              Jason.encode!(payload["flagged_claims"] || []),
              payload["render_backend"],
              payload["render_model"],
              ts
            })

          record_fold_winner!(S.arc_progressions(), key, :arc_progression_generated, event_id)
        else
          :ok
        end
    end
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp write_act(payload, meta, act_kind, grund, wasserlinie) do
    arc_id = payload["arc_id"]
    cid = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(arc_id) and is_binary(cid)) ->
        Logger.warning("Arc-Akt: bad payload (arc_id/campaign_id) — dropping")
        :ok

      not fold_supersedes?(S.arcs(), arc_id, :arc_act, event_id) ->
        :ok

      true ->
        f = current_row(arc_id, cid)
        write_row!(arc_id, %{f | act_kind: act_kind, act_grund: grund, act_wl: wasserlinie})
        record_fold_winner!(S.arcs(), arc_id, :arc_act, event_id)
    end
  end

  # DER eine Preserve-Mechanismus: bestehende Row komplett lesen oder
  # Stub-Basis liefern (campaign_id aus dem Payload — Cascade-Index braucht
  # sie). Jeder Writer merged nur seine Gruppe darüber.
  defp current_row(arc_id, payload_cid) do
    case :mnesia.read(S.arcs(), arc_id) do
      [{_t, _id, cid, seeds, draft, ak, ag, aw, lk, mi}] ->
        %{
          cid: cid,
          seeds: seeds,
          draft: draft,
          act_kind: ak,
          act_grund: ag,
          act_wl: aw,
          kuratiert: lk,
          merged_into: mi
        }

      [] ->
        %{
          cid: payload_cid,
          seeds: [],
          draft: nil,
          act_kind: nil,
          act_grund: nil,
          act_wl: nil,
          kuratiert: nil,
          merged_into: nil
        }
    end
  end

  defp write_row!(arc_id, f) do
    :ok =
      :mnesia.write(
        {S.arcs(), arc_id, f.cid, f.seeds, f.draft, f.act_kind, f.act_grund, f.act_wl,
         f.kuratiert, f.merged_into}
      )
  end
end
