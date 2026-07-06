defmodule HubWeb.CampaignLive.Layout do
  @moduledoc """
  UI-/Panel-Zustand der CampaignLive (Issues #8/#207/#270, ausgelagert in #434
  Cut 4): exklusiver Tab-Toggle, Faithfulness-Aufklappen, Spalten-Collapse/
  -Restore, Protokoll-Session-Toggle. Reiner Anzeige-State, keine Events.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  # Duplikat von HubWeb.CampaignLive.@col_names — col_toggle/col_restore brauchen
  # die Spaltenanzahl. Der col_toggle-Guard (`when col in @col_names`) bleibt als
  # Compile-Literal in CampaignLive. Wert-Sync halten (auch mit Components).
  @col_names ~w(chronik epos summaries protokoll)

  # Issue #270: exklusiver Tab-Toggle. Click auf einen bereits offenen Tab
  # schließt ihn (nil). Sonst neuer Tab open, alter schließt.
  def toggle_tab(socket, tab_str) do
    next_tab =
      case {to_string(socket.assigns.open_tab), tab_str} do
        {same, same} -> nil
        {_, "pipeline"} -> :pipeline
        {_, "flavor"} -> :flavor
        {_, "vocab"} -> :vocab
        _ -> nil
      end

    # Beim Öffnen die jeweiligen Edit-States vorbereiten/zurücksetzen.
    socket =
      case next_tab do
        :flavor ->
          flavors = (socket.assigns.campaign && socket.assigns.campaign["flavors"]) || %{}

          assign(socket,
            open_tab: :flavor,
            flavor_drafts: flavors,
            stil_stage: nil,
            preview_segments: [],
            preview_error: nil
          )

        :vocab ->
          hint = (socket.assigns.campaign || %{})["vocab_hint"] || ""
          assign(socket, open_tab: :vocab, vocab_editing: true, vocab_draft: hint)

        _ ->
          assign(socket, open_tab: next_tab, vocab_editing: false, flavor_editing?: false)
      end

    {:noreply, socket}
  end

  def faithfulness_toggle(socket, sid) do
    expanded = socket.assigns.faithfulness_expanded

    new_expanded =
      if MapSet.member?(expanded, sid),
        do: MapSet.delete(expanded, sid),
        else: MapSet.put(expanded, sid)

    {:noreply, assign(socket, :faithfulness_expanded, new_expanded)}
  end

  # ─── Column collapse/restore (Issue #8) ─────────────────────────

  def col_toggle(socket, col) do
    current = socket.assigns.collapsed_cols

    next =
      if MapSet.member?(current, col) do
        MapSet.delete(current, col)
      else
        candidate = MapSet.put(current, col)
        # Mindestens eine Spalte muss offen bleiben — sonst Toggle ignorieren.
        if MapSet.size(candidate) >= length(@col_names), do: current, else: candidate
      end

    {:noreply,
     socket
     |> assign(:collapsed_cols, next)
     |> push_event("persist_cols", %{collapsed: MapSet.to_list(next)})}
  end

  def col_restore(socket, list) do
    valid = list |> Enum.filter(&(&1 in @col_names)) |> MapSet.new()
    # Falls aus LS alle vier kommen, droppe eine — Invariante „mind. 1 offen".
    valid =
      if MapSet.size(valid) >= length(@col_names),
        do: MapSet.delete(valid, "protokoll"),
        else: valid

    {:noreply, assign(socket, :collapsed_cols, valid)}
  end

  # Issue #207: Protokoll-Sessions kollabier-/aufklappbar. Toggle pro
  # session_id; mehrere parallel offen erlaubt.
  def protokoll_session_toggle(socket, sid) do
    current = socket.assigns.expanded_sessions

    next =
      if MapSet.member?(current, sid),
        do: MapSet.delete(current, sid),
        else: MapSet.put(current, sid)

    {:noreply, assign(socket, :expanded_sessions, next)}
  end

  # Issue #707: "ältere anzeigen" — bumpt das gerenderte Utterance-Fenster
  # dieser Session um einen Schritt. Verhindert, dass eine lange Single-Session
  # (2h-Aufnahme = tausende Utts) beim Aufklappen alle Zeilen in einem Diff
  # rendert (Hub-OOM). Nachladen ist bounded + explizit — kein Silent-Cap.
  def utterance_window_more(socket, sid) do
    windows = socket.assigns.utterance_windows
    step = HubWeb.CampaignLive.Components.utterance_window_size()
    current = Map.get(windows, sid, step)
    next = Map.put(windows, sid, current + step)
    {:noreply, assign(socket, :utterance_windows, next)}
  end
end
