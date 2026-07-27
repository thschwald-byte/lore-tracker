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

  # Palette pro Modus. Lese = read-only Konsum (Nachlese-Band + Prosa-Spalten);
  # Bearbeiten = zusätzlich das Kurations-Substrat Protokoll. Die dedizierte
  # (read-only) Fakten-Spalte ist bewusst Cut 2 (#916) — dort wird sie editierbar,
  # ein Wegwerf-Read-Only-Rendering jetzt wäre verschwendet (ehrliche Grenze).
  @lese_cols ~w(chronik epos summaries glatt)
  @bearbeiten_cols ~w(protokoll glatt summaries epos chronik)

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
  unabhängig, existiert in beiden Spaltenmengen) und lädt im Lesemodus lazy den
  schmalen Nachlese-Scope (`campaign_nachlese`), sofern noch nicht geladen.
  Idempotent: derselbe Modus re-persistiert nur (kein Schaden).
  """
  def set_view_mode(socket, mode_str, anchor_session_id) do
    next = parse_mode(mode_str)

    socket =
      socket
      |> set_mode(next)
      |> push_event("persist_view_mode", %{mode: Atom.to_string(next)})
      |> maybe_scroll_anchor(anchor_session_id)
      |> maybe_load_nachlese(next)

    {:noreply, socket}
  end

  @doc """
  Modus aus dem localStorage-Wert setzen (Mount-Hydration). Unbekannter Wert →
  Default `:lesen`. Lädt bei `:lesen` lazy die Nachlese.
  """
  def view_mode_restore(socket, mode_str) do
    mode = parse_mode(mode_str)

    socket =
      socket
      |> set_mode(mode)
      |> maybe_load_nachlese(mode)

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

  # Nachlese nur im Lesemodus + nur einmal laden (lazy). `nachlese_loaded?`
  # markiert den erfolgten Load — ein Toggle-Ping-Pong zieht keinen Reload.
  defp maybe_load_nachlese(socket, :lesen) do
    if socket.assigns[:nachlese_loaded?] do
      socket
    else
      Snapshot.start_scope_load(socket, "campaign_nachlese")
    end
  end

  defp maybe_load_nachlese(socket, _bearbeiten), do: socket
end
