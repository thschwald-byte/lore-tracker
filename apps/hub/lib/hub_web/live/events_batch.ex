defmodule HubWeb.Live.EventsBatch do
  @moduledoc """
  Gemeinsamer Fold für `{:events_batch, events}`-PubSub-Messages (Issue #702).

  `Hub.Events.broadcast_batch/2` fasst einen Event-Schwall (Transkriptions-
  Backlog nach Session-Ende) in EINE PubSub-Message. LiveViews falten die
  Events durch ihre bestehenden `{:event_appended, …}`-handle_info-Klauseln —
  ein `handle_info` = ein Render, also entsteht genau EIN Diff pro Batch
  statt N (der #702-OOM-Treiber auf Longpoll-Clients).

  Verwendung in einem LiveView (vor etwaigen generischen Catch-alls!):

      def handle_info({:events_batch, events}, socket),
        do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)
  """

  @doc """
  Reduziert `events` in Reihenfolge durch `handler` (die `handle_info/2` des
  aufrufenden LiveViews), jeweils als `{:event_appended, event}`. Hard-Match
  auf `{:noreply, socket}` — eine Clause, die etwas anderes returnt, soll
  laut crashen statt still Events zu verlieren (Silent-Failure-Regel).
  """
  @spec fold([map()], Phoenix.LiveView.Socket.t(), (tuple(), term() -> {:noreply, term()})) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def fold(events, socket, handler) when is_list(events) and is_function(handler, 2) do
    socket =
      Enum.reduce(events, socket, fn event, acc ->
        {:noreply, acc2} = handler.({:event_appended, event}, acc)
        acc2
      end)

    {:noreply, socket}
  end
end
