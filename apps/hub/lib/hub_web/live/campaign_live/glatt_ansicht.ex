defmodule HubWeb.CampaignLive.GlattAnsicht do
  @moduledoc """
  Issue #1198: die Geglättet-Spalte, so wie der Worker sie anzeigefertig
  liefert (Scope `campaign_glatt_ansicht`, `Worker.Repo.GlattAnsicht`).

  **Warum.** Bis #1198 holte der Hub über `campaign_luecken` das Skelett aller
  Blöcke (an seattleV4 5.317, davon ≤ 600 sichtbar) und rechnete Ansicht,
  Filter, Zähler, Fenster und fehlende Texte selbst — im LiveView-Heap 10 →
  36 MB pro Tab. Am 10.09.2026 hat ein einziger Tab den Prod-Hub damit dreimal
  umgebracht. Jetzt schickt der Worker pro Session nur das Fenster, mit Text,
  und die Zahlen, die angezeigt werden. Der Hub hält nur UI-Zustand: die
  gewählte Ansicht (`glatt_view`) und das Fenster (`glatt_windows`) je Session.

  **Drei Regeln, jede mit einem Anlass:**

  1. **Ein Fehler löst NIE einen Voll-Reload aus.** `campaign_live.ex` macht
     bei einem gescheiterten Scope-Read `schedule_reload` — für diesen Scope
     wäre das eine Schleife mit lebendem Worker: im Deploy-Fenster (neuer Hub,
     Worker noch alt) antwortet der Worker `unknown_scope`, der Voll-Read
     gelingt, fragt wieder diesen Scope, und so fort. Deshalb ein eigener
     Async-Name (`:glatt_ansicht`) mit eigenem Ergebnis-Zweig: alter Worker →
     Hinweis in der Spalte, Fehler → alter Stand bleibt. Der Ausweg ist
     `workers_changed` nach dem Worker-Update.
  2. **Höchstens ein Read je LiveView.** `start_async/3` bricht einen laufenden
     Task gleichen Namens ab (#1122) — ein Fensterschritt mitten im Voll-Read
     verwürfe sonst die Vollantwort. Was während eines Reads angefragt wird,
     sammelt sich als Nachlauf (Muster #321) und startet danach als EIN Read.
  3. **Die Ansicht wird nur geschickt, wenn jemand sie gewählt hat.** Ohne Wahl
     geht `nil`, und der Worker schlägt `kuratieren` vor, solange es
     Kuratierbares gibt, sonst `einfach`. Schickte der Hub den Vorschlag als
     Wunsch zurück, bliebe die Spalte auf „kuratieren" stehen, auch wenn dort
     nichts mehr ist.

  **Die Closure trägt nur die Scope-Map.** Alles, was in `start_async/3`
  gebunden wird, kopiert der BEAM in den Task-Prozess (#1181).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  require Logger

  alias Hub.Reader
  alias HubWeb.CampaignLive.{Components, GapMarker, Updates}

  @scope "campaign_glatt_ansicht"

  @doc "Der Scope-Name (für den Reader und die Messzeilen)."
  @spec scope_kind() :: String.t()
  def scope_kind, do: @scope

  @doc """
  Die Ansicht laden — alle Sessions (`:alle`) oder nur diese.

  Läuft schon ein Read, wird der Wunsch vorgemerkt und nach dessen Antwort
  nachgeholt. Ohne Kampagnen-Kontext (Teil-Socket in Tests, Fehlerzweig) ist
  das ein No-op: ein fehlender Text ist ein Schönheitsfehler, ein `KeyError`
  im Render-Pfad kostet die ganze Seite.
  """
  @spec lade(Phoenix.LiveView.Socket.t(), :alle | [String.t()]) :: Phoenix.LiveView.Socket.t()
  def lade(socket, ziel) do
    cond do
      not ladbar?(socket.assigns) -> socket
      socket.assigns[:glatt_laedt] != nil -> vormerken(socket, ziel)
      true -> starte(socket, ziel)
    end
  end

  defp ladbar?(assigns),
    do: is_binary(assigns[:campaign_id]) and is_map(assigns[:current_user])

  defp vormerken(socket, ziel),
    do: assign(socket, :glatt_nachlauf, vereinige(socket.assigns[:glatt_nachlauf], ziel))

  defp starte(socket, ziel) do
    scope = scope_fuer(socket.assigns, ziel)
    # `self()` VOR der Closure — darin wäre es die Pid des Tasks (#1149).
    lv = self()

    # Messzeile nur für die Vollform — sie ist die, die durch die
    # Warteschlange läuft und im Mount die Spitze trägt (#1169).
    if ziel == :alle do
      Hub.MemoryReporter.marke("voll_read_start",
        kind: @scope,
        anlass: socket.assigns[:voll_read_anlass]
      )
    end

    socket
    |> assign(:glatt_laedt, ziel)
    |> assign(:glatt_nachlauf, nil)
    |> start_async(:glatt_ansicht, fn -> Reader.read(scope, notify: lv) end)
  end

  @doc """
  Die Anfrage an den Worker, aus dem UI-Zustand gebaut (pur). Nur Sessions mit
  gewählter Ansicht oder verschobenem Fenster tragen einen Wunsch; alle
  anderen bekommen beim Worker Auto-Ansicht und Tail.
  """
  @spec scope_fuer(map(), :alle | [String.t()]) :: map()
  def scope_fuer(assigns, ziel) do
    views = assigns[:glatt_view] || %{}
    windows = assigns[:glatt_windows] || %{}

    sitzungen =
      (Map.keys(views) ++ Map.keys(windows))
      |> Enum.uniq()
      |> Enum.filter(&(ziel == :alle or &1 in ziel))
      |> Map.new(fn sid ->
        {sid, %{"ansicht" => Map.get(views, sid), "fenster" => fenster(Map.get(windows, sid))}}
      end)

    %{
      "kind" => @scope,
      "id" => assigns.campaign_id,
      "viewer_discord_id" => assigns.current_user.discord_id,
      "nur" => if(ziel == :alle, do: nil, else: ziel),
      "sitzungen" => sitzungen
    }
  end

  @doc "UI-Fenster → Worker-Fenster. Ohne Eintrag: Tail (folgt neuen Blöcken)."
  @spec fenster({non_neg_integer(), non_neg_integer()} | nil) :: map()
  def fenster(nil), do: %{"tail" => Components.window_default()}
  def fenster({from, count}), do: %{"from" => from, "count" => count}

  @doc "Zwei Lade-Wünsche zusammenlegen (pur). `:alle` schluckt alles."
  @spec vereinige(nil | :alle | [String.t()], :alle | [String.t()]) :: :alle | [String.t()]
  def vereinige(nil, ziel), do: ziel
  def vereinige(:alle, _), do: :alle
  def vereinige(_, :alle), do: :alle
  def vereinige(a, b), do: Enum.uniq(a ++ b)

  @doc """
  Das Ergebnis des Async-Reads anwenden. Stößt NIE einen Voll-Reload an
  (Regel 1 oben); ein vorgemerkter Nachlauf startet danach.
  """
  @spec apply_ergebnis(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def apply_ergebnis(socket, ergebnis) do
    angefragt = socket.assigns[:glatt_laedt]

    socket
    |> assign(:glatt_laedt, nil)
    |> uebernehme(ergebnis, angefragt)
    |> nachlauf()
  end

  defp uebernehme(socket, {:ok, {:ok, %{"glatt_ansicht" => liste} = snap}}, angefragt)
       when is_list(liste) do
    # Issue #1169: Marke nach dem Render — die Nachricht wird erst danach
    # verarbeitet. Nur für die Vollform; ein Fensterschritt ist keine Spitze.
    if angefragt == :alle, do: send(self(), {:voll_read_rendered, @scope})

    socket
    |> assign(
      :glatt_ansicht,
      einsortieren(socket.assigns[:glatt_ansicht] || [], liste, snap["nur"])
    )
    |> assign(:glatt_status, :ok)
    |> GapMarker.uebernehmen(snap)
    |> Updates.rebuild_refs()
  end

  defp uebernehme(socket, {:ok, {:ok, %{"error" => "unknown_scope"}}}, _angefragt) do
    Logger.warning(
      "CampaignLive: der Worker kennt #{@scope} noch nicht (älterer Stand) — die Geglättet-Spalte wartet auf sein Update"
    )

    assign(socket, :glatt_status, :worker_veraltet)
  end

  defp uebernehme(socket, anderes, _angefragt) do
    Logger.warning("CampaignLive: Geglättet-Ansicht nicht ladbar (#{inspect(anderes, limit: 5)})")
    assign(socket, :glatt_status, :fehler)
  end

  defp nachlauf(socket) do
    case socket.assigns[:glatt_nachlauf] do
      nil -> socket
      ziel -> socket |> assign(:glatt_nachlauf, nil) |> lade(ziel)
    end
  end

  @doc """
  Eine (Teil-)Antwort in die Liste einsortieren (pur). Vollform ersetzt alles;
  eine Teilantwort ersetzt genau die angefragten Sessions — eine angefragte,
  die nicht mehr kommt (gelöscht, keine Glättung), fällt heraus. Sortiert nach
  Sessionnummer, damit eine frisch geglättete Session an ihrem Platz landet.
  """
  @spec einsortieren([map()], [map()], nil | [String.t()]) :: [map()]
  def einsortieren(_alt, neu, nil), do: neu

  def einsortieren(alt, neu, nur) when is_list(nur) do
    alt
    |> Enum.reject(&(&1["session_id"] in nur))
    |> Kernel.++(neu)
    |> Enum.sort_by(&(&1["session_number"] || 0))
  end

  @doc "Ansicht einer Session wählen: Fenster zurück auf den Tail, diese Session neu laden."
  @spec ansicht_setzen(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def ansicht_setzen(socket, sid, ansicht) do
    socket
    |> assign(:glatt_view, Map.put(socket.assigns.glatt_view, sid, ansicht))
    |> assign(:glatt_windows, Map.delete(socket.assigns.glatt_windows, sid))
    |> lade([sid])
  end

  @doc """
  Das Fenster einer Session um einen Schritt verschieben (`:older`/`:newer`)
  und nur diese Session neu laden. Gerechnet über die **gefilterte** Liste —
  deren Länge (`gefiltert_total`) und die aktuelle Lage (`from` + gelieferte
  Blöcke) kommen aus der letzten Antwort.
  """
  @spec fenster_schritt(Phoenix.LiveView.Socket.t(), String.t(), :older | :newer) ::
          Phoenix.LiveView.Socket.t()
  def fenster_schritt(socket, sid, richtung) do
    case Enum.find(socket.assigns[:glatt_ansicht] || [], &(&1["session_id"] == sid)) do
      nil ->
        socket

      sm ->
        total = sm["gefiltert_total"] || 0
        jetzt = {sm["from"] || 0, length(sm["blocks"] || [])}

        naechstes =
          case richtung do
            :older -> Components.window_older(jetzt, total)
            :newer -> Components.window_newer(jetzt, total)
          end

        if naechstes == jetzt do
          socket
        else
          socket
          |> assign(:glatt_windows, Map.put(socket.assigns.glatt_windows, sid, naechstes))
          |> lade([sid])
        end
    end
  end
end
