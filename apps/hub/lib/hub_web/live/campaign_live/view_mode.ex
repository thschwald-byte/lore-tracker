defmodule HubWeb.CampaignLive.ViewMode do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): der Lesen|Bearbeiten-Modus der CampaignLive.

  EIN Layout, ein Toggle — der Modus schaltet (1) die Affordances read↔edit
  und (2) die Spalten-Palette (`columns_for_mode/1`). Default = `:lesen` (der
  Erfolgs-Prüfstein „öffnet ein Spieler es freiwillig?"), danach per-Gerät in
  localStorage gemerkt (Round-Trip-Hydration via `view_mode_persist.js`, Muster
  `PersistCols`/`ArchiveTogglePersist`).

  Reiner UI-/Anzeige-State — NIE die Autorisierungs-Schranke: jeder Edit-Command
  prüft sein `can?/3`-Recht serverseitig selbst (der Toggle ist nur Convenience,
  gegated auf `@can_edit_mode?` = „Member mit ≥1 Kurationsrecht").

  **Sofort umschalten, danach füllen (Issue #1200).** Der Wechsel nach
  Bearbeiten brachte an seattleV4 eine Antwort von **2,7 MB** (Kurations-Panels
  ~0,5, Protokoll ~0,7, Fakten ~1,6) — der Knopf sprang erst um, wenn der
  Browser alles eingebaut hatte. Seitdem in drei Schichten:

  1. **Browser, ohne Server:** `view_mode_persist.js` setzt beim Klick
     `data-view-mode` am Wurzel-`div`; Knopf-Zustand und das Ausblenden der
     Bearbeiten-Teile (`.nur-bearbeiten`) hängen per CSS daran.
  2. **Erste Server-Antwort:** nur Modus und Gerüst — Spalten mit Kopf und
     „Wird geladen …". Die Stifte in den Listen hängen am Recht, nicht am
     Modus (CSS blendet sie aus); sonst müsste jede Liste bei jedem Wechsel
     neu gezeichnet werden.
  3. **Danach Stück für Stück:** `@bearbeiten_teile` wächst per
     `{:bearbeiten_fuellen, lauf, rest}` um je einen Teil — jede Stufe eine
     eigene Antwort, damit der Browser dazwischen zeichnet. `lauf` macht eine
     Füllung ungültig, sobald umgeschaltet wurde.

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

  # Issue #1200: die schweren Teile des Bearbeiten-Modus in Füllreihenfolge,
  # kleinster zuerst (an seattleV4 gemessen: Kurations-Panels = Fäden +
  # Review-Queue ~0,5 MB, Protokoll ~0,7 MB, Fakten ~1,6 MB Diff).
  @teile ~w(kuration protokoll fakten)

  @doc "Spalten-Palette (Whitelist) für den Modus."
  @spec columns_for_mode(atom()) :: [String.t()]
  def columns_for_mode(:bearbeiten), do: @bearbeiten_cols
  def columns_for_mode(_lesen), do: @lese_cols

  @doc "Alle bekannten Modi (für den Restore-Guard)."
  def modes, do: @modes

  @doc "Die schweren Bearbeiten-Teile in Füllreihenfolge (#1200)."
  def teile, do: @teile

  @doc """
  Ist dieser schwere Teil schon gefüllt? Für das Template — `nil` (Teil-Socket
  vor dem ersten Mount) heißt nein.
  """
  @spec bereit?(MapSet.t() | nil, String.t()) :: boolean()
  def bereit?(nil, _teil), do: false
  def bereit?(teile, teil), do: MapSet.member?(teile, teil)

  @doc """
  Modus explizit setzen (`mode_str` = "lesen" | "bearbeiten"; unbekannt → :lesen).
  Setzt `@view_mode` + `@active_cols`, persistiert per localStorage, hält den
  zentrierten Session-Anker (der Client meldet die Session-id — palette-
  unabhängig, existiert in beiden Spaltenmengen).
  Idempotent: derselbe Modus re-persistiert nur — ohne neue Füllung.
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

  @doc """
  Eine Füllstufe (#1200): den nächsten schweren Teil freigeben und die
  übernächste Stufe anstoßen. Gehört die Nachricht zu einem überholten Lauf
  (inzwischen umgeschaltet), passiert nichts.
  """
  @spec fuellen(Phoenix.LiveView.Socket.t(), non_neg_integer(), [String.t()]) ::
          Phoenix.LiveView.Socket.t()
  def fuellen(socket, lauf, [teil | rest]) do
    if socket.assigns[:bearbeiten_lauf] == lauf and socket.assigns[:view_mode] == :bearbeiten do
      if rest != [], do: send(self(), {:bearbeiten_fuellen, lauf, rest})
      teile = socket.assigns[:bearbeiten_teile] || MapSet.new()
      assign(socket, :bearbeiten_teile, MapSet.put(teile, teil))
    else
      socket
    end
  end

  def fuellen(socket, _lauf, []), do: socket

  # ─── intern ──────────────────────────────────────────────────────

  # Derselbe Modus noch einmal: nichts neu aufbauen — sonst leerte ein
  # Doppelklick die gefüllten Spalten und schickte die 2,7 MB erneut.
  defp set_mode(%{assigns: %{view_mode: mode}} = socket, mode),
    do: assign(socket, :active_cols, columns_for_mode(mode))

  defp set_mode(socket, mode) do
    lauf = (socket.assigns[:bearbeiten_lauf] || 0) + 1
    if mode == :bearbeiten, do: send(self(), {:bearbeiten_fuellen, lauf, @teile})

    socket
    |> assign(:view_mode, mode)
    |> assign(:active_cols, columns_for_mode(mode))
    |> assign(:bearbeiten_teile, MapSet.new())
    |> assign(:bearbeiten_lauf, lauf)
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
