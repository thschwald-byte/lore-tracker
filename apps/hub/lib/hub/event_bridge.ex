defmodule Hub.EventBridge do
  @moduledoc """
  Hub-Side Event-Producer-Bridge (Issue #154, Etappe 4c.1).

  Hub-Side-Producer (LiveViews, Controllers, Mix-Tasks) erzeugen Events
  nicht mehr selbst via `Hub.EventLog.append/3`, sondern delegieren das
  Event-Generieren an einen online Worker. Der Worker macht
  Worker-First-Apply (lokale Materialisierung) und broadcastet via
  `publish_intent` zurück — Hub-LV bekommt das Event danach automatisch
  über die `EventLog.broadcast/3`-PubSub-Schiene (Etappe 4b).

  Verantwortung:
  - Worker-Selection: für Campaign-Events ein Subscriber dieser Campaign,
    für campaign-lose Events beliebiger Worker. Tie-Break: höchster
    `applied_seq` (der mit aktuellster Replik).
  - Channel-Push: `bridge_publish`-Frame zum gewählten Worker.

  Returns:
  - `:ok` wenn der Push abgesetzt wurde (fire-and-forget — der Worker ist
    nach dem Push verantwortlich; Crashes sind dort Bugs)
  - `{:error, :no_worker_online}` wenn kein passender Worker gefunden

  Hub-LV-Aufrufer reagieren auf den `{:error, :no_worker_online}`-Fall mit
  Flash-Error oder graceful skip; das eigentliche Event-Sichtbarwerden im
  LV passiert async über das PubSub-Broadcast nach dem Worker-Roundtrip.
  """

  alias Hub.WorkerRegistry

  @spec publish(map()) :: :ok | {:error, :no_worker_online}
  def publish(payload) when is_map(payload) do
    publish(payload["campaign_id"], payload)
  end

  @doc """
  Variante mit expliziter `campaign_id` — nützlich wenn der Payload
  selbst keine `campaign_id` führt (z.B. `MarkerAdded` trägt nur eine
  `session_id`) aber das Worker-Routing über die zugehörige Campaign
  laufen soll. `nil` für Global-Events.
  """
  @spec publish(String.t() | nil, map()) :: :ok | {:error, :no_worker_online}
  def publish(campaign_id, payload)
      when (is_binary(campaign_id) or is_nil(campaign_id)) and is_map(payload) do
    case pick_target_worker(campaign_id) do
      nil ->
        {:error, :no_worker_online}

      pid ->
        send(pid, {:bridge_publish, payload})
        :ok
    end
  end

  defp pick_target_worker(nil) do
    # Globale Events (UserRoleSet, UserUpserted, Probelauf-Marker) — beliebiger
    # online Worker mit höchstem applied_seq als Tie-Breaker.
    WorkerRegistry.list()
    |> Enum.sort_by(fn {_id, meta} -> -Map.get(meta, :applied_seq, 0) end)
    |> case do
      [{_id, %{channel_pid: pid}} | _] -> pid
      _ -> nil
    end
  end

  defp pick_target_worker(campaign_id) when is_binary(campaign_id) do
    # Campaign-Events — nur Worker mit Subscription auf die Campaign
    # (Member oder Owner), höchster applied_seq als Tie-Breaker.
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} ->
      MapSet.member?(Map.get(meta, :subscribed_campaigns, MapSet.new()), campaign_id)
    end)
    |> Enum.sort_by(fn {_id, meta} -> -Map.get(meta, :applied_seq, 0) end)
    |> case do
      [{_id, %{channel_pid: pid}} | _] -> pid
      _ -> nil
    end
  end
end
