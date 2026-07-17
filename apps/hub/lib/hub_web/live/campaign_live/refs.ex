defmodule HubWeb.CampaignLive.Refs do
  @moduledoc """
  source_refs-/Spalten-Sync-Domäne der CampaignLive (Issues #114/#10,
  ausgelagert in Issue #434, Cut 3 + Cut 4).

  Zwei Teile:

  - Reine Index-Builder (`build_utterance_refs_index/3`, `build_sync_index/4`):
    keine socket-Abhängigkeit, einmal pro Snapshot-Load in `apply_snapshot/2`.
  - Refs-Popover-/Navigations-Handler (Cut 4): `show_refs`, `show_utterance_refs`,
    `hide_refs`, `goto_utterance`, `goto_entry` — Delegations-Pattern, nehmen den
    Socket und liefern `{:noreply, socket}`. Laufen im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  # Issue #114: Backward-Index — pro utterance_id eine Liste der Einträge
  # (kind + entry_id + label), die sie als Quelle ausweisen. Wird einmal pro
  # Snapshot-Apply berechnet und in :utterance_refs_index gecached.
  def build_utterance_refs_index(summaries, epos, chronik) do
    summary_entries =
      summaries
      |> List.wrap()
      |> Enum.flat_map(fn s ->
        refs = source_refs(s)

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
        refs = source_refs(c)
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
  def build_sync_index(summaries, epos, chronik, utterances, smoothed \\ []) do
    utts_by_session =
      utterances
      |> List.wrap()
      |> Enum.group_by(&(&1["session_id"] || &1[:session_id]), &(&1["id"] || &1[:id]))

    # Issue #871 (Fix des stillen Slice-C-Bruchs): source_refs zitieren seit
    # #864 BLOCK-IDs — für den Sync (der auf Utterance-Anker im Protokoll
    # mappt) werden sie hier über die quell_utterance_ids der Blöcke
    # expandiert. Gleichzeitig wird jeder Block selbst ein Sync-Eintrag der
    # Spalte "glatt" (Anker = Block-ID).
    block_to_utts =
      smoothed
      |> List.wrap()
      |> Enum.flat_map(fn sm -> sm["blocks"] || [] end)
      |> Enum.into(%{}, fn b -> {b["block_id"], b["quell_utterance_ids"] || []} end)

    expand_refs = fn refs ->
      Enum.flat_map(refs, fn ref ->
        case Map.get(block_to_utts, ref) do
          nil -> [ref]
          quell -> quell
        end
      end)
    end

    # Refs pro Entry: vorhandene source_refs ODER Fallback auf alle utts
    # der Session (für Summary + Chronik). Epos ohne refs → leer (keine
    # session_id-Basis).
    summary_refs =
      List.wrap(summaries)
      |> Enum.map(fn s ->
        refs = expand_refs.(source_refs(s))
        refs = if refs == [], do: Map.get(utts_by_session, s["session_id"], []), else: refs
        {{"summaries", s["session_id"]}, refs}
      end)

    epos_refs =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) and refs != [] ->
          [{{"epos", id}, expand_refs.(refs)}]

        _ ->
          []
      end

    chronik_refs =
      List.wrap(chronik)
      |> Enum.map(fn c ->
        refs = expand_refs.(source_refs(c))
        refs = if refs == [], do: Map.get(utts_by_session, c["session_id"], []), else: refs
        {{"chronik", c["id"]}, refs}
      end)

    glatt_refs =
      smoothed
      |> List.wrap()
      |> Enum.flat_map(fn sm -> sm["blocks"] || [] end)
      |> Enum.map(fn b -> {{"glatt", b["block_id"]}, b["quell_utterance_ids"] || []} end)
      |> Enum.reject(fn {_, refs} -> refs == [] end)

    all_entries = summary_refs ++ epos_refs ++ chronik_refs ++ glatt_refs

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

  # ─── Refs-Popover + Navigation (Issue #114, Cut 4) ──────────────

  def show_refs(socket, kind, id) do
    refs = lookup_entry_refs(socket, kind, id)
    {:noreply, assign(socket, :refs_popover, %{kind: kind, entry_id: id, refs: refs})}
  end

  # Klick auf den Backward-Badge an einer Utterance: zeige Liste der
  # Einträge die diese Utterance referenzieren.
  def show_utterance_refs(socket, uid) do
    citing = Map.get(socket.assigns.utterance_refs_index, uid, [])
    {:noreply, assign(socket, :refs_popover, %{kind: "utterance", entry_id: uid, refs: citing})}
  end

  def hide_refs(socket), do: {:noreply, assign(socket, :refs_popover, nil)}

  # Klick auf einen Eintrag im Refs-Popover: scroll-to-utterance via JS-Hook.
  # Issue #709: geht durch focus_utterance/3 — expandiert die Ziel-Session UND
  # setzt das Fenster um die Utterance (window_around), sonst ist die Zeile bei
  # langen Sessions evincd und der Scroll liefe ins Leere. collapse_others?=true
  # erhält das bisherige Verhalten (andere Sessions zuklappen).
  def goto_utterance(socket, uid), do: focus_utterance(socket, uid, true)

  @doc """
  Issue #709: sorgt dafür, dass Utterance `uid` gerendert ist (Session
  expandiert + Fenster um ihren Index zentriert), dann push_event
  scroll_to_utterance. Genutzt vom Refs-Popover-Jump (collapse_others?=true)
  und von ColumnSync (collapse_others?=false → Ziel-Session nur additiv öffnen).
  Der Push passiert im selben Diff, der das Fenster setzt → die Zeile existiert
  im DOM, wenn der Client das Event dispatched.
  """
  def focus_utterance(socket, uid, collapse_others? \\ false) do
    utts = socket.assigns.utterances

    case Enum.find(utts, &(Map.get(&1, "id") == uid or Map.get(&1, :id) == uid)) do
      nil ->
        {:noreply, socket}

      u ->
        sid = u["session_id"] || u[:session_id]
        group = Enum.filter(utts, &((&1["session_id"] || &1[:session_id]) == sid))
        i = Enum.find_index(group, &((&1["id"] || &1[:id]) == uid)) || 0
        win = HubWeb.CampaignLive.Components.window_around(i, length(group))

        expanded =
          if collapse_others?,
            do: MapSet.new([sid]),
            else: MapSet.put(socket.assigns.expanded_sessions, sid)

        {:noreply,
         socket
         |> assign(:expanded_sessions, expanded)
         |> assign(:utterance_windows, Map.put(socket.assigns.utterance_windows, sid, win))
         |> assign(:refs_popover, nil)
         |> push_event("scroll_to_utterance", %{id: uid})}
    end
  end

  # Direkt-Sprung zu einem Eintrag der eine Utterance referenziert (aus
  # dem Backward-Popover).
  def goto_entry(socket, kind, id) do
    {:noreply,
     socket
     |> assign(:refs_popover, nil)
     |> push_event("scroll_to_utterance", %{id: "#{kind}-#{id}"})}
  end

  defp lookup_entry_refs(socket, "summary", session_id) do
    case Enum.find(socket.assigns.summaries, &(&1["session_id"] == session_id)) do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(socket, "epos", _entry_id) do
    case socket.assigns.epos do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(socket, "chronik", entry_id) do
    case Enum.find(socket.assigns.chronik, &(&1["id"] == entry_id)) do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(_, _, _), do: []

  # Issue #545: `source_refs` robust lesen — Schlüssel fehlt ODER ist `nil`
  # (alte Seeds / LLM-Output ohne Refs) → `[]`. War 4× inline dupliziert.
  defp source_refs(map), do: Map.get(map, "source_refs", []) || []
end
