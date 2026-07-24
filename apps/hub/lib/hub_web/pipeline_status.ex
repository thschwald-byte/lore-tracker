defmodule HubWeb.PipelineStatus do
  @moduledoc """
  Zentrales Routing für den `pipeline_status`-PubSub-Kanal (Issue #401).

  Früher lief der gesamte Stage-/`mic_level`-Status über EINEN globalen Topic
  `"pipeline_status"` — jede CampaignLive im System wachte bei jedem Event jeder
  Kampagne auf und filterte lokal per campaign_id. Bei `mic_level` (#391, 5 Hz ×
  N aktive Streamer × M CampaignLive-Subscriber) war das die dominante PubSub-Last.

  Seit #401 bekommt jede Kampagne einen eigenen Topic (`pipeline_status:<cid>`),
  sodass das Filtering auf der PubSub-Ebene passiert statt in jeder LiveView.
  Broadcaster rufen `broadcast/1` (routet nach `payload["campaign_id"]`),
  Subscriber lauschen auf `topic/1` (eine Kampagne) bzw. `probelauf_topic/0`.

  Routing-Regel (`route/1`):

    * `campaign_id` gesetzt und KEIN `probelauf-`-Präfix → `pipeline_status:<cid>`
    * `campaign_id` mit `probelauf-`-Präfix ODER fehlend (admin-globaler
      Sweep-Progress ohne cid) → `probelauf_topic/0`

  Damit sehen echte Kampagnen-Topics nie Probelauf-Rauschen, und die
  `/admin/probelauf`-LiveView bekommt alle Probelauf-Events (Sweep-Progress +
  die `probelauf-<uuid>`-Kampagnen) über einen einzigen Topic. Das Tuple bleibt
  `{:pipeline_status, payload}` — nur der Topic-String ändert sich, die
  handle_info-Clauses der Subscriber sind unangetastet.
  """

  @probelauf_topic "pipeline_status:probelauf"

  @doc "Per-Campaign-PubSub-Topic für die gegebene campaign_id."
  @spec topic(String.t()) :: String.t()
  def topic(campaign_id) when is_binary(campaign_id), do: "pipeline_status:" <> campaign_id

  @doc """
  Sammel-Topic für admin-globale Probelauf-Events (Sweep-Progress ohne
  campaign_id + die `probelauf-<uuid>`-Kampagnen). Von `/admin/probelauf`
  abonniert.
  """
  @spec probelauf_topic() :: String.t()
  def probelauf_topic, do: @probelauf_topic

  @doc """
  Broadcastet ein `pipeline_status`-Payload auf den kampagnen-spezifischen Topic
  (`{:pipeline_status, payload}`). campaign_id-lose oder `probelauf-`-präfigierte
  Payloads landen auf `probelauf_topic/0`.
  """
  @spec broadcast(map()) :: :ok
  def broadcast(payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(Hub.PubSub, route(payload), {:pipeline_status, payload})
  end

  @doc """
  Ermittelt den Ziel-Topic für ein Payload. Pure Funktion (für Broadcaster mit
  Sonder-Tuple + Routing-Unit-Test).
  """
  @spec route(map()) :: String.t()
  def route(payload) when is_map(payload) do
    case payload["campaign_id"] do
      "probelauf-" <> _ -> @probelauf_topic
      cid when is_binary(cid) -> "pipeline_status:" <> cid
      _ -> @probelauf_topic
    end
  end
end
