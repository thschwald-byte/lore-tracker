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

  **Zwei Hebel, die nur zusammen wirken.** `fullsweep_after: 0` am Socket
  (`HubWeb.Endpoint`) macht jedes Aufräumen gründlich — ohne das bliebe der
  Müll großer Frames im alten Heap liegen. Ausgelöst wird es hier: nach jedem
  Render einer LiveView bekommt der Verbindungsprozess **eine Sekunde später**
  ein `:garbage_collect` (behandelt `Phoenix.Socket` selbst). Die Verzögerung
  ist Pflicht: `after_render` läuft, BEVOR der Diff an den Verbindungsprozess
  geht — sofort geschickt, räumte er vor dem großen Frame auf statt danach.
  Höchstens eine Bitte je Sekunde und Ansicht: ein weiterer Render innerhalb
  der Sekunde ist mit erfasst, weil sein Frame vor der geplanten Bitte beim
  Verbindungsprozess ankommt.

  Hängt als `on_mount` an der LiveView-Sitzung im Router — alle Ansichten,
  keine Zeile in den LiveViews selbst.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  @verzoegerung_ms 1_000

  @doc "Die Verzögerung zwischen Render und Aufräum-Bitte (für Tests)."
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
        Process.send_after(pid, :garbage_collect, @verzoegerung_ms)
        put_private(socket, :transport_gc_bis, jetzt + @verzoegerung_ms)
    end
  end

  def nach_render(socket, _jetzt), do: socket
end
