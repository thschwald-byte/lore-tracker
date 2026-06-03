defmodule HubWeb.CampaignLive.Publisher do
  @moduledoc """
  Gemeinsamer Event-Publish-Pfad der CampaignLive-Domänen (Issue #434, Cut 4).

  Kapselt `Hub.EventBridge.publish/2` plus den #215-Fehlerpfad (Self-Message
  `{:bridge_publish_failed, kind}` → Parent-`handle_info` zeigt Flash). Wird vom
  `HubWeb.CampaignLive` (via dünnem `bridge_publish/2`-Delegate) und von den
  Domänen-Kontext-Modulen (`Members`, …) genutzt.

  `send(self(), …)` adressiert immer den LiveView-Prozess — die Domänen-Module
  laufen im selben Prozess wie die LiveView (Funktions-Delegation, keine
  separaten Tasks/Components).
  """
  require Logger

  alias Hub.EventBridge

  @doc """
  Publisht `payload` für die Kampagne (campaign_id aus dem Payload oder den
  socket-assigns). Liefert immer `:ok`; bei fehlendem Worker wird `{:error,
  :no_worker_online}` zu einer Self-Message für die Flash-Anzeige (kein Crash,
  kein silent fail).
  """
  def publish(socket, payload) do
    cid = payload["campaign_id"] || socket.assigns[:campaign_id]

    case EventBridge.publish(cid, payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        Logger.warning(
          "CampaignLive.bridge_publish: kein Worker online (kind=#{payload["kind"]} campaign=#{cid})"
        )

        # Issue #215: Self-Message für Flash-Anzeige; vor #215 silent fail.
        send(self(), {:bridge_publish_failed, payload["kind"]})
        :ok
    end
  end
end
