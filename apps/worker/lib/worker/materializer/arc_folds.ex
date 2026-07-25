defmodule Worker.Materializer.ArcFolds do
  @moduledoc """
  Issue #903 (Epic #900 S2): die Arc-Folds — Schwester-Modul von
  `Worker.Materializer.Apply2` (dessen God-Module-Budget), dort nur
  Dünn-Dispatch-Klauseln.

  EINE `worker_arcs`-Row pro Arc, DREI unabhängige Fold-Gruppen darauf
  (fold_meta-Sidecar, Muster `member_join_apply`):

    * `:arc_created`   — Existenz + Seeds + Leitfrage-Draft (ArcCreated).
      Fasst act-/leitfrage-Felder NIE an (getrennte Gruppen).
    * `:arc_act`       — GETEILT für ArcClosed + ArcReopened (konkurrieren um
      dasselbe Feld-Tripel act_kind/act_grund/act_wasserlinie; LWW-by-event_id,
      `:invite_status`-Konvention). Whole-Snapshot pro Gruppe: Reopened nil-t
      grund + wasserlinie EXPLIZIT (Partial-Payload wäre reorder-divergent).
    * `:arc_leitfrage` — kuratierter Leitfragen-Text (LeitfrageSet; leerer
      Text = Undo-Row, NIE ein Delete).

  Reorder-Invariante (Stub-Upsert): trifft ein Akt/eine Leitfrage VOR dem
  ArcCreated ein, wird eine Stub-Row angelegt (eigene Feld-Gruppe schreiben,
  fremde preserven bzw. nil) — ein „Row fehlt → drop" wäre order-sensitiv
  divergent (#900-Plan, Fund A1.2).

  Der Arc-STATUS ist bewusst kein Feld dieser Row — er wird am Reader
  abgeleitet (`Worker.Repo.Threads`, Modell in Epic #900).
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
        # Fremde Fold-Gruppen (Akt + kuratierte Leitfrage) preserven — ein
        # späteres/re-emittiertes ArcCreated darf sie nie clobbern.
        {act_kind, act_grund, act_wl, kuratiert} =
          case :mnesia.read(S.arcs(), arc_id) do
            [{_t, _id, _cid, _seeds, _draft, ak, ag, aw, lk}] -> {ak, ag, aw, lk}
            [] -> {nil, nil, nil, nil}
          end

        seeds = payload["seed_raw_labels"] |> List.wrap() |> Enum.filter(&is_binary/1)

        :ok =
          :mnesia.write(
            {S.arcs(), arc_id, cid, seeds, payload["leitfrage_draft"], act_kind, act_grund,
             act_wl, kuratiert}
          )

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
        {ex_cid, seeds, draft, act_kind, act_grund, act_wl} = existing_or_stub(arc_id, cid)

        :ok =
          :mnesia.write(
            {S.arcs(), arc_id, ex_cid, seeds, draft, act_kind, act_grund, act_wl, text}
          )

        record_fold_winner!(S.arcs(), arc_id, :arc_leitfrage, event_id)
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
        {ex_cid, seeds, draft, _ak, _ag, _aw} = existing_or_stub(arc_id, cid)

        kuratiert =
          case :mnesia.read(S.arcs(), arc_id) do
            [{_t, _id, _c, _s, _d, _a1, _a2, _a3, lk}] -> lk
            [] -> nil
          end

        :ok =
          :mnesia.write(
            {S.arcs(), arc_id, ex_cid, seeds, draft, act_kind, grund, wasserlinie, kuratiert}
          )

        record_fold_winner!(S.arcs(), arc_id, :arc_act, event_id)
    end
  end

  # Bestehende Row lesen (fremde Gruppen preserven) oder Stub-Basis liefern —
  # campaign_id kommt beim Stub aus dem Payload (Cascade-Index braucht sie).
  defp existing_or_stub(arc_id, payload_cid) do
    case :mnesia.read(S.arcs(), arc_id) do
      [{_t, _id, ecid, seeds, draft, ak, ag, aw, _lk}] -> {ecid, seeds, draft, ak, ag, aw}
      [] -> {payload_cid, [], nil, nil, nil, nil}
    end
  end
end
