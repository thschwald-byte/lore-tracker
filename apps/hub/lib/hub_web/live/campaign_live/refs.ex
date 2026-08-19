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
  @doc """
  Issue #1094: die EINE Auflösung von `source_refs` zu Utterance-IDs.

  `source_refs` zitieren seit #864 **Block-IDs** (`b_…`), nicht mehr
  Utterance-IDs. Von den vier Stellen, die sie lasen, war das nur einer bekannt
  — die anderen suchten Block-IDs in der Utterance-Liste, fanden nichts und
  zeigten das als Datenverlust an („Quelle nicht mehr verfügbar"). Eine
  Typ-Verwechslung, als Datenlage getarnt.

  Diese Karte ist deshalb die einzige Stelle, die den Unterschied kennt. Sie
  trägt pro Block **zwei** Dinge:

  - `utts` — die Quell-Utterances des Blocks.
  - `session_id` — die Session, in der der Block liegt. Die steht **nicht** am
    Block, sondern am umschließenden `smoothed`-Eintrag (einer pro Session);
    beim Bauen ist sie ohnehin in der Hand. Ohne sie bricht der Scroll-Sync
    still ab: `column_sync.js` verlässt `tryAutoExpand` ohne Session-ID
    (`if (!sid) return`), und expandierte Utterances alter Sessions sind seit
    dem #1087-Ladefenster gar nicht geladen — stünden sie nicht in
    `utt_sessions`, wäre das Popover repariert und der Sprung trotzdem stumm.
  """
  @spec block_source_map([map()] | nil) :: %{optional(String.t()) => map()}
  def block_source_map(smoothed) do
    smoothed
    |> List.wrap()
    |> Enum.flat_map(fn sm ->
      sid = sm["session_id"] || sm[:session_id]

      (sm["blocks"] || [])
      |> Enum.map(fn b ->
        {b["block_id"], %{utts: b["quell_utterance_ids"] || [], session_id: sid}}
      end)
    end)
    |> Enum.into(%{})
  end

  @doc """
  Issue #1094: `source_refs` → Utterance-IDs.

  Ein Ref, der in der Karte **nicht** vorkommt, wird unverändert
  durchgereicht. Das ist kein Nachlässigkeits-Fallback, sondern nötig: vor #864
  waren `source_refs` echte Utterance-IDs, und Bestandskampagnen ohne Glättung
  haben gar keine Blöcke. Ein Filtern statt Durchreichen würde deren Refs
  löschen.

  **Zwei benannte Unterschiede zum vorher inline in `build_sync_index/6`
  liegenden `expand_refs`**, beide bewusst:

  - Ein Block, der die Karte **kennt**, aber keine `quell_utterance_ids` hat,
    wird ebenfalls durchgereicht statt verworfen. Für das Popover ist das die
    richtige Wahl (eine unauflösbare Quelle sichtbar lassen statt lautlos
    schlucken). Im Sync-Index kann es in einem Grenzfall die Session-Rückfall-
    Logik unterdrücken — aber nur, wenn **alle** Refs eines Eintrags solche
    entarteten Blöcke sind; ein einziger echter Ref genügt, damit der Rückfall
    ohnehin nicht greift.
  - Das Ergebnis ist `uniq`. Zwei Blöcke desselben Eintrags können dieselbe
    Quell-Utterance nennen; vorher stand sie doppelt in den Maps.
  """
  @spec resolve_source_refs([String.t()] | nil, map()) :: [String.t()]
  def resolve_source_refs(refs, block_map) do
    refs
    |> List.wrap()
    |> Enum.flat_map(fn ref ->
      case Map.get(block_map, ref) do
        %{utts: utts} when utts != [] -> utts
        _ -> [ref]
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Issue #1094: `%{utterance_id => session_id}` für alles, was über Blöcke
  erreichbar ist — auch für Utterances, die gar nicht geladen sind.

  Speist `utt_sessions` im Sync-Index. Ohne diesen Beitrag kennt der Index nur
  die geladenen Zeilen (#1087), und ein Sprung auf eine alte Quelle bricht im
  JS-Hook stumm ab.
  """
  @spec block_utterance_sessions(map()) :: %{optional(String.t()) => String.t()}
  def block_utterance_sessions(block_map) do
    Enum.reduce(block_map, %{}, fn {_bid, %{utts: utts, session_id: sid}}, acc ->
      if is_nil(sid) do
        acc
      else
        Enum.reduce(utts, acc, fn uid, inner -> Map.put_new(inner, uid, sid) end)
      end
    end)
  end

  def build_utterance_refs_index(summaries, epos, chronik, smoothed \\ []) do
    # Issue #1094: dieser Index keyte auf die ROHEN `source_refs` — seit #864
    # also auf Block-IDs — wurde aber mit Utterance-IDs abgefragt. Der 📎-Zähler
    # an jeder Protokollzeile stand damit dauerhaft auf 0 und das
    # Rückwärts-Popover war immer leer. Beides sah nach „wird nirgends zitiert"
    # aus und fiel deshalb nie auf.
    block_map = block_source_map(smoothed)
    expand = &resolve_source_refs(&1, block_map)

    summary_entries =
      summaries
      |> List.wrap()
      |> Enum.flat_map(fn s ->
        Enum.map(expand.(source_refs(s)), fn uid ->
          {uid, %{kind: "summary", id: s["session_id"], label: "Resümee"}}
        end)
      end)

    epos_entries =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) ->
          Enum.map(expand.(refs), fn uid -> {uid, %{kind: "epos", id: id, label: "Epos"}} end)

        _ ->
          []
      end

    chronik_entries =
      chronik
      |> List.wrap()
      |> Enum.flat_map(fn c ->
        label = c["label"] || "Chronik"

        Enum.map(expand.(source_refs(c)), fn uid ->
          {uid, %{kind: "chronik", id: c["id"], label: label}}
        end)
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
  def build_sync_index(summaries, epos, chronik, utterances, smoothed \\ [], facts \\ []) do
    utts_by_session =
      utterances
      |> List.wrap()
      |> Enum.group_by(&(&1["session_id"] || &1[:session_id]), &(&1["id"] || &1[:id]))

    # Issue #871 (Fix des stillen Slice-C-Bruchs): source_refs zitieren seit
    # #864 BLOCK-IDs — für den Sync (der auf Utterance-Anker im Protokoll
    # mappt) werden sie über die quell_utterance_ids der Blöcke expandiert.
    # Gleichzeitig wird jeder Block selbst ein Sync-Eintrag der Spalte "glatt"
    # (Anker = Block-ID).
    #
    # Issue #1094: die Auflösung lag hier inline und war damit die EINZIGE
    # Stelle, die den #864-Bedeutungswechsel kannte — drei andere Konsumenten
    # suchten Block-IDs in der Utterance-Liste. Sie wohnt jetzt in
    # `block_source_map/1` + `resolve_source_refs/2`, dieselbe Karte für alle.
    block_map = block_source_map(smoothed)
    expand_refs = &resolve_source_refs(&1, block_map)

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

    # Issue #1095: die Fakten-Spalte lief beim Scroll-Sync nicht mit — sie stand
    # in keiner der beiden Richtungsmaps. Die Fakten sind die Wahrheitsbasis, aus
    # der Resümee, Chronik und Epos entstehen; ausgerechnet dort den Bezug zum
    # Protokoll von Hand suchen zu müssen, war die unpassendste Stelle.
    #
    # Fakten brauchen KEIN `expand_refs`: `quell_utterance_ids` sind bereits
    # Utterance-IDs (die Fakt-Kuration aus #916 ankert darauf). Bei Resümee,
    # Epos und Chronik müssen die Block-IDs erst zurückgerechnet werden.
    #
    # Ausgeblendete Fakten (`curation_dismissed`) bleiben drin: sie sind in der
    # Spalte sichtbar (durchgestrichen, für den Un-Dismiss), und ein stummer
    # Eintrag in einer sonst mitlaufenden Spalte verwirrt mehr als einer, der
    # mitzieht.
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

    # Issue #370: utt → session-id Mapping. Der Hook nutzt es als Fallback
    # wenn scrollSlaveTo eine collapsed Session trifft → triggert dann
    # protokoll_session_toggle via .click() statt im DOM nichts zu finden.
    # Issue #1095 (im Zusammenspiel mit dem Ladefenster aus #1087): diese Map ist
    # die Bedingung dafür, dass ein Sprung auf eine NICHT geladene Zeile
    # überhaupt ankommt. `column_sync.js` bricht in `tryAutoExpand` ohne
    # Session-ID ab (`if (!sid) return`) — der Klick tut dann schlicht nichts.
    #
    # Seit #1087 liefert der Snapshot nur die jüngsten Utterances je Session,
    # `utterances` ist also eine Teilliste. Ein Fakt aus einer alten Session
    # zeigt damit regelmäßig auf Zeilen, die hier fehlen würden.
    #
    # Fakten tragen ihre `session_id` selbst, also wird sie für die eigenen
    # Quell-Zeilen mitgeliefert. Die geladenen Utterances gewinnen bei einem
    # Konflikt — sie sind die unmittelbare Quelle, die Fakt-Angabe die
    # abgeleitete.
    #
    # Issue #1094: #1095 hat die Fakten-Hälfte gelöst — für Resümee, Epos und
    # Chronik blieb dasselbe Loch offen, denn deren Refs zeigen nach der
    # Auflösung ebenfalls auf Zeilen, die nicht geladen sind. Die Block-Karte
    # kennt die Session jedes Blocks und liefert sie hier als BASIS mit.
    # Reihenfolge der drei Schichten (später gewinnt): Blöcke → Fakten →
    # geladene Utterances. Die geladene Zeile ist die unmittelbare Quelle, die
    # beiden anderen sind abgeleitet; zwischen Block und Fakt gibt es keinen
    # echten Widerspruch (beide nennen die Session, in der die Zeile liegt).
    utt_to_session =
      block_map
      |> block_utterance_sessions()
      |> Map.merge(
        facts
        |> List.wrap()
        |> Enum.flat_map(fn f ->
          sid = f["session_id"]
          if sid, do: Enum.map(f["quell_utterance_ids"] || [], &{&1, sid}), else: []
        end)
        |> Enum.into(%{})
      )
      |> Map.merge(
        utterances
        |> List.wrap()
        |> Enum.into(%{}, fn u ->
          {u["id"] || u[:id], u["session_id"] || u[:session_id]}
        end)
      )

    %{
      "utts_to_entries" => utts_to_entries,
      "entries_to_utts" => entries_to_utts,
      "utt_sessions" => utt_to_session
    }
  end

  # ─── Refs-Popover + Navigation (Issue #114, Cut 4) ──────────────

  def show_refs(socket, kind, id) do
    roh = lookup_entry_refs(socket, kind, id)
    block_map = block_source_map(socket.assigns[:smoothed])
    refs = resolve_source_refs(roh, block_map)

    # Issue #1094: erst auflösen, DANN laden. Vorher gingen die rohen Refs in
    # den Abruf — seit #864 also Block-IDs, die der Worker in der
    # Utterance-Tabelle nie findet. Der Read kam garantiert leer zurück und
    # kostete dabei einen Voll-Scan über alle Utterances der Kampagne
    # (`utterances_by_ids/2` liest jede Session mit `limit: :all`; an echten
    # Prod-Daten 5.553 Zeilen pro Popover-Klick).
    #
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
       block_count: length(roh)
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
