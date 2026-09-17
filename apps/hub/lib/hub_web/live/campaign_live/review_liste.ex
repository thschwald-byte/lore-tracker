defmodule HubWeb.CampaignLive.ReviewListe do
  @moduledoc """
  Issue #1204: die Review-Liste (Fakten ohne Zeitstrahl-Datum, #724/#746) lädt
  erst, wenn jemand sie aufklappt.

  **Warum.** Sie reiste bis hierhin im Haupt-Snapshot zu **jedem** Betrachter
  — an seattleV4 567 Einträge, 1,15 MB im LiveView-Heap, auch im Lesen-Modus
  und bei Mitgliedern, denen sie nie gezeigt wird. Gezeichnet wurde sie in
  einem zugeklappten `<details>` trotzdem vollständig: gemessen 0,67 MB des
  Render-Diffs beim ersten Aufbau im Bearbeiten-Modus, für eine Liste, die zu
  war. Seitdem schickt der Worker im Haupt-Snapshot nur die **Zahl**
  (`"review_facts" => "anzahl"`, `Worker.Repo.FaktenFenster.review/4`), und die
  Liste kommt über den schmalen Scope `campaign_review_facts`, sobald der
  Betrachter aufklappt. Zugeklappt wird sie wieder verworfen.

  **Server-verwaltet statt `<details>`**, aus zwei Gründen: nur so weiß der
  Hub, wann er laden muss, und ein natives `<details>` schnappt bei jeder
  Kurations-Aktion per morphdom zu (#836 — dasselbe Muster wie das
  Fäden-Panel).

  **Mischbetrieb:** ein Worker vor #1204 ignoriert das Flag und liefert die
  Liste weiterhin mit — dann wird die Zahl aus ihr gezählt, gerendert wird sie
  trotzdem erst nach dem Aufklappen.
  """

  import Phoenix.Component, only: [assign: 3]

  alias HubWeb.CampaignLive.Snapshot

  @scope "campaign_review_facts"

  @doc """
  Aus dem Haupt-Snapshot: nur die Zahl. Ist die Liste gerade offen, wird sie
  neu geholt (ein Voll-Reload kann sie verändert haben); bis dahin bleibt der
  bisherige Stand stehen, statt die offene Liste leer zu räumen.
  """
  @spec aus_haupt_snapshot(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def aus_haupt_snapshot(socket, snap) do
    anzahl = snap["review_facts_count"] || length(snap["review_facts"] || [])
    socket = assign(socket, :review_facts_count, anzahl)

    cond do
      anzahl == 0 -> assign(socket, :review_facts, [])
      socket.assigns[:review_offen?] == true -> Snapshot.start_scope_load(socket, @scope)
      true -> assign(socket, :review_facts, [])
    end
  end

  @doc """
  Antwort von `campaign_review_facts` (Aufklappen oder Event-Reload nach
  `SessionFactDateSet`): die Zahl immer, die Liste nur, solange das Panel
  offen ist.
  """
  @spec aus_scope(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def aus_scope(socket, snap) do
    liste = snap["review_facts"] || []

    socket
    |> assign(:review_facts_count, length(liste))
    |> assign(:review_facts, if(socket.assigns[:review_offen?] == true, do: liste, else: []))
  end

  @doc "Auf- oder zuklappen. Auf lädt die Liste, zu verwirft sie."
  @spec umschalten(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def umschalten(socket) do
    if socket.assigns[:review_offen?] == true do
      socket
      |> assign(:review_offen?, false)
      |> assign(:review_facts, [])
    else
      socket
      |> assign(:review_offen?, true)
      |> Snapshot.start_scope_load(@scope)
    end
  end
end
