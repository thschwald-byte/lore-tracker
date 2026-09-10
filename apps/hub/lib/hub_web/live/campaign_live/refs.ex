defmodule HubWeb.CampaignLive.Refs do
  @moduledoc """
  source_refs-/Spalten-Sync-Domäne der CampaignLive (Issues #114/#10,
  ausgelagert in Issue #434, Cut 3 + Cut 4).

  Zwei Teile:

  - Reine Index-Builder (`build_utterance_refs_index/3`, `build_sync_index/6`):
    keine socket-Abhängigkeit, gebaut beim Snapshot-Apply und nach jedem
    Scope, der eine ihrer Eingaben ändert.
  - Refs-Popover-/Navigations-Handler (Cut 4): `show_refs`, `show_utterance_refs`,
    `hide_refs`, `goto_utterance`, `goto_entry` — Delegations-Pattern, nehmen den
    Socket und liefern `{:noreply, socket}`. Laufen im LiveView-Prozess.

  **Seit #1198 löst der Worker die Quellen auf.** `source_refs` zitieren seit
  #864 Block-IDs. Die Auflösung zu Utterance-IDs brauchte die Block-Karte aller
  geglätteten Blöcke der Kampagne (`block_source_map/1`, #1094), und die lebte
  hier im Hub — samt dem Skelett, das am 10.09.2026 einen einzelnen Tab zum
  Hub-Killer gemacht hat. Jetzt tragen Resümee, Chronik, Epos und Epos-Kapitel
  `quell_utterance_ids`, im Worker aufgelöst (`Worker.Repo.GlattQuellen`,
  dieselbe Semantik: Unbekanntes und Altdaten durchreichen, `uniq`). `quell/1`
  ist die EINE Lesestelle dafür.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @doc """
  Issue #1198: die Utterance-IDs, auf denen ein Resümee-, Chronik- oder
  Epos-Eintrag beruht.

  Der Worker liefert sie aufgelöst als `quell_utterance_ids` (angefragt mit
  `"refs" => "aufgeloest"`). **Fehlt das Feld** — ein Worker vor #1198 —, fällt
  die Funktion auf die rohen `source_refs` zurück. Für Altdaten (Utterance-IDs
  vor #864) ist das richtig; für Block-IDs ist es eine benannte
  Verschlechterung: Popover und Scroll-Sync finden dann bis zum Worker-Update
  keine Zeilen. Die Alternative wäre wieder eine Block-Karte im Hub — genau die
  ist mit #1198 weggefallen.
  """
  @spec quell(map() | nil) :: [String.t()]
  def quell(%{} = eintrag), do: eintrag["quell_utterance_ids"] || source_refs(eintrag)
  def quell(_), do: []

  @doc """
  Issue #114: Backward-Index — pro Utterance-ID die Einträge (kind + id +
  label), die sie als Quelle nennen. Speist den 📎-Zähler an jeder
  Protokollzeile und das Rückwärts-Popover.

  Issue #1094: der Index keyte bis dahin auf den ROHEN `source_refs` — seit
  #864 also auf Block-IDs — und wurde mit Utterance-IDs abgefragt; der Zähler
  stand dauerhaft auf 0. Seit #1198 kommen die Utterance-IDs fertig vom
  Worker (`quell/1`).
  """
  def build_utterance_refs_index(summaries, epos, chronik) do
    summary_entries =
      summaries
      |> List.wrap()
      |> Enum.flat_map(fn s ->
        Enum.map(quell(s), fn uid ->
          {uid, %{kind: "summary", id: s["session_id"], label: "Resümee"}}
        end)
      end)

    epos_entries =
      case epos do
        %{"id" => id} = e ->
          Enum.map(quell(e), fn uid -> {uid, %{kind: "epos", id: id, label: "Epos"}} end)

        _ ->
          []
      end

    chronik_entries =
      chronik
      |> List.wrap()
      |> Enum.flat_map(fn c ->
        label = c["label"] || "Chronik"

        Enum.map(quell(c), fn uid ->
          {uid, %{kind: "chronik", id: c["id"], label: label}}
        end)
      end)

    (summary_entries ++ epos_entries ++ chronik_entries)
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, entry} -> entry end)
  end

  @doc """
  Issue #10: Sync-Index für den ColumnSync-JS-Hook. Pro Spalte + Entry-ID die
  zugeordneten Utterance-IDs und umgekehrt — beide Richtungen, weil der Master
  beliebig die Spalte sein kann, in der gerade gescrollt wird. Geht als
  `"sync_index"`-Ereignis an den Hook (#1187).

  Fallback bei fehlenden Quellen (alte Pre-#114-Seeds wie Romeo-Schlegel): pro
  Resümee/Chronik mit `session_id` werden ALLE geladenen Utterances dieser
  Session als implizite Refs gemappt — session-granular statt
  utterance-granular.

  **Seit #1198 nur noch, was angezeigt wird.** `glatt_ansicht` ist die Liste
  aus `campaign_glatt_ansicht`; ihre Blöcke sind genau die gerenderten. Vorher
  trug der Index einen Eintrag für jeden der 5.317 Blöcke der Seattle-Kampagne,
  ob im DOM oder nicht (2,5 MB je Push). Ein Block außerhalb des Fensters kann
  ohnehin kein Scroll-Ziel sein — der Hook fände ihn nicht.

  **`utt_sessions` ist entfallen.** Der Hook brauchte es nur als Sperre in
  `tryAutoExpand`; der Server findet die Session selbst (`focus_utterance/3` →
  `request_absent_utterance/3`), und die Karte kam zum größten Teil aus eben
  dem Block-Skelett.
  """
  def build_sync_index(summaries, epos, chronik, utterances, glatt_ansicht, facts) do
    utts_by_session =
      utterances
      |> List.wrap()
      |> Enum.group_by(&(&1["session_id"] || &1[:session_id]), &(&1["id"] || &1[:id]))

    summary_refs =
      List.wrap(summaries)
      |> Enum.map(fn s ->
        refs = quell(s)
        refs = if refs == [], do: Map.get(utts_by_session, s["session_id"], []), else: refs
        {{"summaries", s["session_id"]}, refs}
      end)

    epos_refs =
      case epos do
        %{"id" => id} = e ->
          case quell(e) do
            [] -> []
            refs -> [{{"epos", id}, refs}]
          end

        _ ->
          []
      end

    chronik_refs =
      List.wrap(chronik)
      |> Enum.map(fn c ->
        refs = quell(c)
        refs = if refs == [], do: Map.get(utts_by_session, c["session_id"], []), else: refs
        {{"chronik", c["id"]}, refs}
      end)

    glatt_refs =
      glatt_ansicht
      |> List.wrap()
      |> Enum.flat_map(fn sm -> sm["blocks"] || [] end)
      |> Enum.map(fn b -> {{"glatt", b["block_id"]}, b["quell_utterance_ids"] || []} end)
      |> Enum.reject(fn {_, refs} -> refs == [] end)

    # Issue #1095: Fakten brauchen keine Auflösung — `quell_utterance_ids` sind
    # bereits Utterance-IDs (die Fakt-Kuration aus #916 ankert darauf).
    # Ausgeblendete Fakten bleiben drin: sie sind in der Spalte sichtbar.
    fakten_refs =
      facts
      |> List.wrap()
      |> Enum.map(fn f -> {{"fakten", f["id"]}, f["quell_utterance_ids"] || []} end)
      |> Enum.reject(fn {_, refs} -> refs == [] end)

    all_entries = summary_refs ++ epos_refs ++ chronik_refs ++ glatt_refs ++ fakten_refs

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

    %{"utts_to_entries" => utts_to_entries, "entries_to_utts" => entries_to_utts}
  end

  # ─── Refs-Popover + Navigation (Issue #114, Cut 4) ──────────────

  def show_refs(socket, kind, id) do
    eintrag = lookup_entry(socket, kind, id)
    refs = quell(eintrag)

    # Issue #1087: nachgeladen werden muss trotzdem — die aufgelösten
    # Utterances liegen bei älteren Sessions außerhalb des Ladefensters.
    socket = HubWeb.CampaignLive.Snapshot.start_utterance_ids_load(socket, refs)

    {:noreply,
     assign(socket, :refs_popover, %{
       kind: kind,
       entry_id: id,
       refs: refs,
       # Wie viele Blöcke hinter den aufgelösten Zeilen stehen — der
       # Popover-Titel zählte bisher Refs und nannte sie „Utterances".
       block_count: length(source_refs(eintrag || %{}))
     })}
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
        # Issue #1087: Ziel außerhalb des geladenen Fensters. Vorher war das
        # ein stilles Nichts — der Klick tat einfach gar nichts. Jetzt wird
        # nachgeladen und der Sprung danach wiederholt.
        {:noreply, request_absent_utterance(socket, uid, collapse_others?)}

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

  defp lookup_entry(socket, "summary", session_id),
    do: Enum.find(socket.assigns.summaries, &(&1["session_id"] == session_id))

  defp lookup_entry(socket, "epos", _entry_id), do: socket.assigns.epos

  defp lookup_entry(socket, "chronik", entry_id),
    do: Enum.find(socket.assigns.chronik, &(&1["id"] == entry_id))

  defp lookup_entry(_, _, _), do: nil

  # Issue #545: `source_refs` robust lesen — Schlüssel fehlt ODER ist `nil`
  # (alte Seeds / LLM-Output ohne Refs) → `[]`.
  defp source_refs(map), do: Map.get(map, "source_refs", []) || []

  # ─── Issue #1087: Sprung auf noch nicht geladene Zeilen ─────────

  # Zwei Stufen, weil erst der ID-Abruf verrät, in welcher Session die Zeile
  # steht und an welcher Position: (1) Zeile per ID holen → (2) den Bereich
  # zwischen ihr und dem geladenen Anfang nachladen. Danach greift der normale
  # Pfad. `pending_focus` wird in JEDEM Zweig gesetzt oder gelöscht — ein
  # unauflösbares Ziel darf nicht in eine Nachlade-Schleife laufen.
  defp request_absent_utterance(socket, uid, collapse_others?) do
    alias HubWeb.CampaignLive.Snapshot

    pending = %{uid: uid, collapse?: collapse_others?}

    case Map.get(socket.assigns.utterance_lookup, uid) do
      nil ->
        socket
        |> assign(:pending_focus, pending)
        |> Snapshot.start_utterance_ids_load([uid])

      utt ->
        sid = utt["session_id"] || utt[:session_id]
        idx = Map.get(socket.assigns.utterance_indices, uid)
        from = Map.get(socket.assigns.utterance_from, sid, 0)

        if is_integer(idx) and idx < from do
          socket
          |> assign(:pending_focus, pending)
          |> Snapshot.start_utterance_load(sid, idx, from - idx)
        else
          # Alles geladen, was zu laden war, und die Zeile ist trotzdem nicht
          # in der Liste. Aufgeben statt erneut zu laden.
          assign(socket, :pending_focus, nil)
        end
    end
  end

  @doc """
  Issue #1087: nach einem Nachlade-Ergebnis den aufgeschobenen Sprung erneut
  versuchen. Ohne offenes Ziel eine reine Durchreiche.
  """
  def retry_pending_focus(%{assigns: %{pending_focus: nil}} = socket), do: socket

  def retry_pending_focus(%{assigns: %{pending_focus: %{uid: uid, collapse?: c}}} = socket) do
    {:noreply, socket} =
      socket
      |> assign(:pending_focus, nil)
      |> focus_utterance(uid, c)

    socket
  end
end
