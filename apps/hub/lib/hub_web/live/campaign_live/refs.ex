defmodule HubWeb.CampaignLive.Refs do
  @moduledoc """
  Reine Index-Builder für die source_refs/Spalten-Sync-Domäne der CampaignLive
  (Issues #114/#10, ausgelagert in Issue #434, Cut 3).

  Keine socket-Abhängigkeit: nimmt die Snapshot-Listen (summaries/epos/chronik/
  utterances) und liefert die in `:utterance_refs_index` bzw. `data-sync-index`
  gecachten Maps. `HubWeb.CampaignLive` ruft beide einmal pro Snapshot-Load in
  `apply_snapshot/2`.
  """

  # Issue #114: Backward-Index — pro utterance_id eine Liste der Einträge
  # (kind + entry_id + label), die sie als Quelle ausweisen. Wird einmal pro
  # load_snapshot berechnet und in :utterance_refs_index gecached.
  def build_utterance_refs_index(summaries, epos, chronik) do
    summary_entries =
      summaries
      |> List.wrap()
      |> Enum.flat_map(fn s ->
        refs = Map.get(s, "source_refs", []) || []

        Enum.map(refs, fn uid ->
          {uid, %{kind: "summary", id: s["session_id"], label: "Resümee"}}
        end)
      end)

    epos_entries =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) ->
          Enum.map(refs, fn uid -> {uid, %{kind: "epos", id: id, label: "Epos"}} end)

        _ ->
          []
      end

    chronik_entries =
      chronik
      |> List.wrap()
      |> Enum.flat_map(fn c ->
        refs = Map.get(c, "source_refs", []) || []
        label = c["label"] || "Chronik"
        Enum.map(refs, fn uid -> {uid, %{kind: "chronik", id: c["id"], label: label}} end)
      end)

    (summary_entries ++ epos_entries ++ chronik_entries)
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, entry} -> entry end)
  end

  # Issue #10: Sync-Index für den ColumnSync-JS-Hook. Pro Spalte +
  # Entry-ID die zugeordneten Utterance-IDs und umgekehrt — beide
  # Richtungen, weil der Master beliebig die Spalte sein kann in der
  # gerade gescrollt wird. Wird beim Mount + bei jedem snapshot-Reload
  # als JSON in `data-sync-index` am LV-Root re-rendered; der Hook liest
  # es im `updated()`-Lifecycle neu.
  #
  # Fallback bei fehlenden `source_refs` (alte Pre-#114-Seeds wie Romeo-
  # Schlegel): pro Summary/Chronik mit `session_id` werden ALLE
  # Utterances dieser Session als implizite Refs gemappt. So funktioniert
  # der Sync auch ohne explizite #114-Refs, nur dann session-granular
  # statt utterance-granular.
  def build_sync_index(summaries, epos, chronik, utterances) do
    utts_by_session =
      utterances
      |> List.wrap()
      |> Enum.group_by(&(&1["session_id"] || &1[:session_id]), &(&1["id"] || &1[:id]))

    # Refs pro Entry: vorhandene source_refs ODER Fallback auf alle utts
    # der Session (für Summary + Chronik). Epos ohne refs → leer (keine
    # session_id-Basis).
    summary_refs =
      List.wrap(summaries)
      |> Enum.map(fn s ->
        refs = Map.get(s, "source_refs", []) || []
        refs = if refs == [], do: Map.get(utts_by_session, s["session_id"], []), else: refs
        {{"summaries", s["session_id"]}, refs}
      end)

    epos_refs =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) and refs != [] ->
          [{{"epos", id}, refs}]

        _ ->
          []
      end

    chronik_refs =
      List.wrap(chronik)
      |> Enum.map(fn c ->
        refs = Map.get(c, "source_refs", []) || []
        refs = if refs == [], do: Map.get(utts_by_session, c["session_id"], []), else: refs
        {{"chronik", c["id"]}, refs}
      end)

    all_entries = summary_refs ++ epos_refs ++ chronik_refs

    entries_to_utts =
      all_entries
      |> Enum.into(%{}, fn {{col, id}, refs} -> {"#{col}:#{id}", refs} end)

    # Invertierte Map: utt-id → [{col, id}, ...]
    utts_to_entries =
      all_entries
      |> Enum.flat_map(fn {{col, id}, refs} ->
        Enum.map(refs, fn uid -> {uid, %{"col" => col, "id" => to_string(id)}} end)
      end)
      |> Enum.group_by(fn {uid, _} -> uid end, fn {_, e} -> e end)

    # Issue #370: utt → session-id Mapping. Der Hook nutzt es als Fallback
    # wenn scrollSlaveTo eine collapsed Session trifft → triggert dann
    # protokoll_session_toggle via .click() statt im DOM nichts zu finden.
    utt_to_session =
      utterances
      |> List.wrap()
      |> Enum.into(%{}, fn u ->
        {u["id"] || u[:id], u["session_id"] || u[:session_id]}
      end)

    %{
      "utts_to_entries" => utts_to_entries,
      "entries_to_utts" => entries_to_utts,
      "utt_sessions" => utt_to_session
    }
  end
end
