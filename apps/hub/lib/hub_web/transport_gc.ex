defmodule HubWeb.TransportGc do
  @moduledoc """
  Issue #1198 (OOM): der Verbindungsprozess eines Browser-Tabs räumt nach
  großen Antworten auf.

  **Befund (Teststage, seattleV4, 10.09.2026).** Der Prozess, der die
  Websocket-Verbindung eines Tabs hält (`Bandit.DelegatingHandler`), trug nach
  dem Laden einer Kampagne 29–32 MB, mit dem alten Weg der Geglättet-Spalte
  50 MB. Ein erzwungenes Aufräumen brachte ihn jeweils auf praktisch null — es
  war nur Müll: jeder Diff wird in diesen Prozess kopiert und dort zu JSON
  kodiert, und ein Prozess, der danach ruht, räumt von selbst nicht auf. Auf
  dem Prod-Hub (381 MiB) sind das rund 30 MB je offenem Tab.

  **Wie.** Nach jedem Render einer LiveView wird der Verbindungsprozess
  **eine Sekunde später** aufgeräumt — per `:erlang.garbage_collect/1` aus
  einem Timer (`aufraeumen/2`), gedrosselt auf höchstens einmal je Sekunde und
  Ansicht. Die Verzögerung ist Pflicht: `after_render` läuft, BEVOR der Diff an
  den Verbindungsprozess geht; sofort aufgeräumt, wäre der große Frame noch gar
  nicht da. Ein weiterer Render innerhalb der Sekunde ist mit erfasst, weil
  sein Frame vor dem geplanten Aufräumen verschickt ist. `fullsweep_after: 0`
  am Socket (`HubWeb.Endpoint`) sorgt zusätzlich dafür, dass auch die GCs, die
  der Prozess von selbst macht, den alten Heap mitnehmen.

  **Bewusst KEINE Nachricht an den Verbindungsprozess.** Die erste Fassung
  schickte ihm `:garbage_collect` — `Phoenix.Socket` kennt das, der Test-Client
  von LiveView (`Phoenix.LiveViewTest.ClientProxy`) nicht und stürzte ab
  (PR #1201, CI-Lauf 1026: ein Test, der länger als eine Sekunde lebte).
  `:erlang.garbage_collect/1` wirkt auf jeden Prozess, ohne dass er etwas davon
  in seinem Posteingang sieht.

  Hängt als `on_mount` an der LiveView-Sitzung im Router — alle Ansichten,
  keine Zeile in den LiveViews selbst.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  @verzoegerung_ms 1_000

  @doc "Die Verzögerung zwischen Render und Aufräumen (für Tests)."
  def verzoegerung_ms, do: @verzoegerung_ms

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      {:cont, attach_hook(socket, :transport_gc, :after_render, &nach_render/1)}
    else
      {:cont, socket}
    end
  end

  @doc false
  def nach_render(socket), do: nach_render(socket, System.monotonic_time(:millisecond))

  @doc false
  def nach_render(%{transport_pid: pid} = socket, jetzt) when is_pid(pid) do
    case socket.private[:transport_gc_bis] do
      bis when is_integer(bis) and jetzt < bis ->
        socket

      _ ->
        aufraeumen(pid, @verzoegerung_ms)
        put_private(socket, :transport_gc_bis, jetzt + @verzoegerung_ms)
    end
  end

  def nach_render(socket, _jetzt), do: socket

  @doc """
  Lässt `pid` in `ms` Millisekunden vollständig aufräumen — aus einem
  Timer-Prozess, ohne Nachricht an `pid`. Ist `pid` bis dahin tot, passiert
  nichts.
  """
  @spec aufraeumen(pid(), non_neg_integer()) :: :ok
  def aufraeumen(pid, ms) when is_pid(pid) do
    {:ok, _} = :timer.apply_after(ms, :erlang, :garbage_collect, [pid])
    :ok
  end
end
