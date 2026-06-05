defmodule Worker.HubClient.Bridge do
  @moduledoc """
  Issue #585: Hub-EventBridge-Topic-Bündel aus `Worker.HubClient`.

  Issue #154 (Etappe 4c.1): Hub-Side-Producer (LiveViews/Controllers) rufen
  `Hub.EventBridge.publish/1` statt direkt in events zu schreiben — Hub picked
  uns als Ziel-Worker und pusht den Event-Payload. Wir bauen daraus ein
  normales Worker-Event via `Worker.Intents.publish/1` (Worker-First-Apply
  lokal, dann publish_intent zurück zum Hub → PubSub-Broadcast).
  """

  def on_publish(%{"payload" => payload}, socket) do
    # Issue #430: Intents.publish/1 gibt immer {:ok, …} (kein toter {:error}-Branch).
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      {:ok, _} = Worker.Intents.publish(payload)
    end)

    {:ok, socket}
  end
end
