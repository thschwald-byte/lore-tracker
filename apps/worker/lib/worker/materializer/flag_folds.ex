defmodule Worker.Materializer.FlagFolds do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): die Falsifikations-Flag-Folds — Schwester-Modul
  von `Worker.Materializer.Apply2` (dessen God-Module-Budget), dort nur
  Dünn-Dispatch-Klauseln.

  EINE `worker_flags`-Row pro Objekt (Key `"<campaign_id>:<target_kind>:<target_id>"`),
  EIN geteilter Fold `:flag_status` darauf: `FlagRaised`/`FlagResolved`/
  `FlagDismissed` konkurrieren um DENSELBEN Status-Slot (LWW-by-event_id, exakt
  die `:arc_act`/`:invite_status`-Konvention). Der jüngste Akt gewinnt, egal in
  welcher Sync-Reihenfolge er eintrifft — ein Re-Raise nach Resolve ist ein
  legitimes Wiederaufleben mit höherer event_id.

  **Preserve-Mechanismus** (arc_folds-Muster `current_row/2`): `current_row/4`
  liefert alle Felder (bestehend oder Stub-Basis), jeder Writer überschreibt nur
  seine Gruppe. FlagRaised setzt zusätzlich `raised_by`/`note`; Resolve/Dismiss
  preserven sie (Audit). Trifft ein Resolve/Dismiss VOR dem Raise ein, entsteht
  eine Stub-Row (raised_by/note nil) — ein „Row fehlt → drop" wäre reorder-
  divergent. **Nie `:mnesia.delete`** (#698-Klasse).

  Der effektive Status (inkl. Auto-Resolve verwaister Fakt-Flags) ist reine
  Reader-Ableitung in `Worker.Repo.Flags` — hier wird nur der rohe Akt persistiert.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @target_kinds ~w(session arc fact)
  @note_max_chars 500

  @doc false
  def flag_raised(payload, _ts, meta) do
    write_status(payload, meta, "raised", fn f ->
      %{f | raised_by: payload["set_by"], note: normalize_note(payload["note"])}
    end)
  end

  @doc false
  def flag_resolved(payload, _ts, meta), do: write_status(payload, meta, "resolved", & &1)

  @doc false
  def flag_dismissed(payload, _ts, meta), do: write_status(payload, meta, "dismissed", & &1)

  # ─── intern ──────────────────────────────────────────────────────

  defp write_status(payload, meta, status, field_fn) do
    cid = payload["campaign_id"]
    tk = payload["target_kind"]
    tid = payload["target_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(cid) and tk in @target_kinds and is_binary(tid)) ->
        Logger.warning(
          "Flag(#{status}): bad payload (campaign_id/target_kind/target_id) — dropping"
        )

        :ok

      not fold_supersedes?(S.flags(), flag_key(cid, tk, tid), :flag_status, event_id) ->
        :ok

      true ->
        key = flag_key(cid, tk, tid)

        f =
          current_row(key, cid, tk, tid)
          |> Map.merge(%{status: status, event_id: event_id})
          |> field_fn.()

        write_row!(key, f)
        record_fold_winner!(S.flags(), key, :flag_status, event_id)
    end
  end

  defp flag_key(cid, tk, tid), do: cid <> ":" <> tk <> ":" <> tid

  # DER eine Preserve-Mechanismus: bestehende Row komplett lesen oder Stub-Basis
  # (campaign_id/target aus dem Payload — Cascade-Index + Reader brauchen sie).
  defp current_row(key, cid, tk, tid) do
    case :mnesia.read(S.flags(), key) do
      [{_t, _k, c, k2, i, rb, n, st, ev}] ->
        %{cid: c, target_kind: k2, target_id: i, raised_by: rb, note: n, status: st, event_id: ev}

      [] ->
        %{
          cid: cid,
          target_kind: tk,
          target_id: tid,
          raised_by: nil,
          note: nil,
          status: nil,
          event_id: nil
        }
    end
  end

  defp write_row!(key, f) do
    :ok =
      :mnesia.write(
        {S.flags(), key, f.cid, f.target_kind, f.target_id, f.raised_by, f.note, f.status,
         f.event_id}
      )
  end

  defp normalize_note(n) when is_binary(n), do: String.slice(n, 0, @note_max_chars)
  defp normalize_note(_), do: nil
end
