defmodule HubWeb.CampaignLive.FaktenFenster do
  @moduledoc """
  Issue #1204: die Fakten-Spalte bekommt je Session nur ein Fenster.

  **Warum.** Der Scope `campaign_facts` lieferte alle Fakten aller Sessions,
  und die Spalte zeichnete sie alle — an seattleV4 860 Fakten, je Fakt sechs
  Knöpfe, 1,64 MB Assigns und gemessen 1,45 MB des Render-Diffs beim ersten
  Aufbau im Bearbeiten-Modus (der größte Einzelposten der Seite). Seitdem
  fragt der Hub mit `"fakten_tail"` (50) und den geblätterten Fenstern
  (`"fakten_fenster"`), und der Worker (`Worker.Repo.FaktenFenster`) schickt
  je Session nur diesen Ausschnitt, dazu Gesamtzahl und Startindex. Der Hub
  hält nur UI-Zustand: das Fenster je Session, in das jemand geblättert hat
  (`fakten_windows`), und die Zahlen der letzten Antwort (`fakten_fenster`).

  **Die Anfrage entsteht an EINER Stelle** (`ergaenze/3`, aufgerufen in
  `Snapshot.start_scope_load/3`), nicht bei den Aufrufern: der Scope wird aus
  drei Wegen geladen (Wechsel nach Bearbeiten, Kurations-Event, Blättern), und
  der eine, der das Feld vergisst, holte still wieder alle Fakten (#1153).

  **Mischbetrieb:** ein Worker vor #1204 ignoriert die Felder und liefert die
  volle Liste ohne `fakten_fenster` — dann zeigt die Spalte alles wie bisher,
  ohne Blätterknöpfe.

  **Geblättert wird über den Gesamt-Read**, nicht nur für die eine Session:
  die Antwort ist gefenstert und damit klein, und es gibt keinen zweiten Pfad,
  der die Liste zusammenflicken müsste.
  """

  import Phoenix.Component, only: [assign: 3]

  alias HubWeb.CampaignLive.{Components, Snapshot}

  @scope "campaign_facts"
  @tail 50

  @doc "Fakten je Session im Tail (#1204)."
  @spec tail() :: pos_integer()
  def tail, do: @tail

  @doc """
  Zusatzfelder für einen Scope-Read (pur): für `campaign_facts` der Tail und
  die geblätterten Fenster, für jeden anderen Scope nichts.
  """
  @spec ergaenze(map(), String.t(), map()) :: map()
  def ergaenze(extra, @scope, assigns) do
    fenster =
      Map.new(assigns[:fakten_windows] || %{}, fn {sid, {from, count}} ->
        {sid, %{"from" => from, "count" => count}}
      end)

    Map.merge(extra, %{"fakten_tail" => @tail, "fakten_fenster" => fenster})
  end

  def ergaenze(extra, _kind, _assigns), do: extra

  @doc """
  Wie viele Fakten einer Session vor und nach dem geladenen Ausschnitt liegen
  (pur, für die Blätterknöpfe). Ohne Zahlen vom Worker (Alt-Worker, noch nicht
  geladen) `{0, 0}` — dann gibt es nichts zu blättern.
  """
  @spec verborgen(map() | nil, String.t(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def verborgen(fenster, sid, geladen) do
    case fenster do
      %{^sid => %{"total" => total, "from" => from}}
      when is_integer(total) and is_integer(from) ->
        {from, max(0, total - from - geladen)}

      _ ->
        {0, 0}
    end
  end

  @doc """
  Das Fenster einer Session um einen Schritt verschieben (`:older`/`:newer`)
  und die Spalte neu laden. Dieselbe Schritt-Rechnung wie Protokoll und
  Geglättet (`Components.window_older/2`, `window_newer/2`, Deckel 200).
  """
  @spec schritt(Phoenix.LiveView.Socket.t(), String.t(), :older | :newer) ::
          Phoenix.LiveView.Socket.t()
  def schritt(socket, sid, richtung) do
    case (socket.assigns[:fakten_fenster] || %{})[sid] do
      %{"total" => total, "from" => from} when is_integer(total) and is_integer(from) ->
        geladen = Enum.count(socket.assigns[:facts] || [], &(&1["session_id"] == sid))
        jetzt = {from, geladen}

        naechstes =
          case richtung do
            :older -> Components.window_older(jetzt, total)
            :newer -> Components.window_newer(jetzt, total)
          end

        if naechstes == jetzt do
          socket
        else
          windows = Map.put(socket.assigns[:fakten_windows] || %{}, sid, naechstes)

          socket
          |> assign(:fakten_windows, windows)
          |> Snapshot.start_scope_load(@scope)
        end

      _ ->
        socket
    end
  end
end
