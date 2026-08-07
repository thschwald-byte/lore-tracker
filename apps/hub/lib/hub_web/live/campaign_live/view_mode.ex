defmodule HubWeb.CampaignLive.ViewMode do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): der Lesen|Bearbeiten-Modus der CampaignLive.

  EIN Layout, ein Toggle — der Modus schaltet (1) die Affordances read↔edit
  (das Template UND-verknüpft die `can_*`-Gates mit `@view_mode == :bearbeiten`)
  und (2) die Spalten-Palette (`columns_for_mode/1`). Default = `:lesen` (der
  Erfolgs-Prüfstein „öffnet ein Spieler es freiwillig?"), danach per-Gerät in
  localStorage gemerkt (Round-Trip-Hydration via `view_mode_persist.js`, Muster
  `PersistCols`/`ArchiveTogglePersist`).

  Reiner UI-/Anzeige-State — NIE die Autorisierungs-Schranke: jeder Edit-Command
  prüft sein `can?/3`-Recht serverseitig selbst (der Toggle ist nur Convenience,
  gegated auf `@can_edit_mode?` = „Member mit ≥1 Kurationsrecht").

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias HubWeb.CampaignLive.Snapshot

  @modes [:lesen, :bearbeiten]

  # Palette pro Modus. Lese = read-only Konsum (Prosa-Spalten);
  # Bearbeiten = zusätzlich das Kurations-Substrat Protokoll + die editierbare
  # Fakten-Spalte (#916, Cut 2 — direkte L1-Wahrheitsbasis-Kuration).
  @lese_cols ~w(chronik epos summaries glatt)
  @bearbeiten_cols ~w(protokoll glatt fakten summaries epos chronik)

  @doc "Spalten-Palette (Whitelist) für den Modus."
  @spec columns_for_mode(atom()) :: [String.t()]
  def columns_for_mode(:bearbeiten), do: @bearbeiten_cols
  def columns_for_mode(_lesen), do: @lese_cols

  @doc "Alle bekannten Modi (für den Restore-Guard)."
  def modes, do: @modes

  @doc """
  Modus explizit setzen (`mode_str` = "lesen" | "bearbeiten"; unbekannt → :lesen).
  Setzt `@view_mode` + `@active_cols`, persistiert per localStorage, hält den
  zentrierten Session-Anker (der Client meldet die Session-id — palette-
  unabhängig, existiert in beiden Spaltenmengen).
  Idempotent: derselbe Modus re-persistiert nur (kein Schaden).
  """
  def set_view_mode(socket, mode_str, anchor_session_id) do
    next = parse_mode(mode_str)

    socket =
      socket
      |> set_mode(next)
      |> push_event("persist_view_mode", %{mode: Atom.to_string(next)})
      |> maybe_scroll_anchor(anchor_session_id)
      |> maybe_load_facts(next)

    {:noreply, socket}
  end

  @doc """
  Modus aus dem localStorage-Wert setzen (Mount-Hydration). Unbekannter Wert →
  Default `:lesen`.
  """
  def view_mode_restore(socket, mode_str) do
    mode = parse_mode(mode_str)

    socket =
      socket
      |> set_mode(mode)
      |> maybe_load_facts(mode)

    {:noreply, socket}
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp set_mode(socket, mode) do
    socket
    |> assign(:view_mode, mode)
    |> assign(:active_cols, columns_for_mode(mode))
  end

  defp parse_mode("bearbeiten"), do: :bearbeiten
  defp parse_mode("lesen"), do: :lesen
  defp parse_mode(_), do: :lesen

  defp maybe_scroll_anchor(socket, sid) when is_binary(sid) and sid != "" do
    push_event(socket, "scroll_to_session", %{session_id: sid})
  end

  defp maybe_scroll_anchor(socket, _), do: socket

  # #916 (Cut 2): die editierbare Fakten-Spalte lebt im Bearbeiten-Modus — lazy
  # laden (Fakten-Liste kann groß sein), einmal (facts_loaded?).
  defp maybe_load_facts(socket, :bearbeiten) do
    if socket.assigns[:facts_loaded?] do
      socket
    else
      socket
      |> assign(:facts_loaded?, true)
      |> Snapshot.start_scope_load("campaign_facts")
    end
  end

  defp maybe_load_facts(socket, _lesen), do: socket
end
