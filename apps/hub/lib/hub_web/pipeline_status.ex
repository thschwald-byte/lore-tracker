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
  Subscriber lauschen auf `topic/1`. Das Tuple ist `{:pipeline_status, payload}`.

  Routing-Regel (`route/1`), in dieser Reihenfolge:

    * `frage_lauf_id` gesetzt → `frage:<lauf_id>` (Issue #850)
    * `campaign_id` gesetzt → `pipeline_status:<cid>`
    * keins von beidem → `nil`, `broadcast/1` verwirft die Meldung

  **Warum die Frage einen eigenen Topic hat.** Der Kampagnen-Topic ist für
  Stufenmeldungen richtig — sie gehen alle an. Eine **Antwort** nicht: Fragt
  der Spielleiter „was plant der Schurke", läsen sonst alle Spieler mit. Die
  Lauf-ID vergibt der Frager selbst und abonniert damit einen Topic, den nur
  er kennt; der Worker echot sie zurück. Das kommt ohne Hub-Zustand aus — eine
  Karte Lauf-ID → pid wäre Zustand, den der Hub seit #164 nicht hält.

  Bis J4 (#1207) gab es daneben einen Sammel-Topic für den LLM-Probelauf
  (`/admin/probelauf`): kampagnenlose Sweep-Meldungen und die
  `probelauf-<uuid>`-Kampagnen landeten dort. Mit dem Probelauf ist er
  entfallen. Kampagnenlose Meldungen kamen nur von ihm — alle übrigen Absender
  (Pipeline-Stufen, Laufband, Replay, Mikro-/Discord-Präsenz, `mic_level`)
  tragen eine `campaign_id`. Eine Meldung ohne Kampagne hat damit keinen
  Abonnenten, und sie zu verwerfen ist gleichwertig mit dem Senden ins Leere.
  """

  @doc "Per-Campaign-PubSub-Topic für die gegebene campaign_id."
  @spec topic(String.t()) :: String.t()
  def topic(campaign_id) when is_binary(campaign_id), do: "pipeline_status:" <> campaign_id

  @doc """
  Issue #850: der Topic EINES Frage-Laufs. Nur wer die Lauf-ID hat, abonniert
  ihn — und das ist der Frager, der sie erzeugt hat.
  """
  @spec frage_topic(String.t()) :: String.t()
  def frage_topic(lauf_id) when is_binary(lauf_id), do: "frage:" <> lauf_id

  @doc """
  Abonniert den Topic eines Frage-Laufs. **Vor** dem Fragen aufzurufen — sonst
  kann die Antwort vor dem Abonnement eintreffen und ins Leere laufen.
  """
  @spec subscribe_frage(String.t()) :: :ok | {:error, term()}
  def subscribe_frage(lauf_id) when is_binary(lauf_id),
    do: Phoenix.PubSub.subscribe(Hub.PubSub, frage_topic(lauf_id))

  @doc """
  Beendet das Abonnement. Ein Lauf ist einmalig; bliebe der Topic abonniert,
  sammelten sich in einer langen Sitzung beliebig viele.
  """
  @spec unsubscribe_frage(String.t()) :: :ok
  def unsubscribe_frage(lauf_id) when is_binary(lauf_id),
    do: Phoenix.PubSub.unsubscribe(Hub.PubSub, frage_topic(lauf_id))

  @doc """
  Broadcastet ein `pipeline_status`-Payload auf den kampagnen-spezifischen Topic
  (`{:pipeline_status, payload}`). Ohne `campaign_id` wird nichts gesendet.
  """
  @spec broadcast(map()) :: :ok
  def broadcast(payload) when is_map(payload) do
    case route(payload) do
      nil -> :ok
      topic -> Phoenix.PubSub.broadcast(Hub.PubSub, topic, {:pipeline_status, payload})
    end
  end

  @doc """
  Ermittelt den Ziel-Topic für ein Payload, `nil` ohne `campaign_id`. Pure
  Funktion (für Broadcaster mit Sonder-Tuple + Routing-Unit-Test).
  """
  @spec route(map()) :: String.t() | nil
  def route(payload) when is_map(payload) do
    case payload do
      %{"frage_lauf_id" => id} when is_binary(id) -> frage_topic(id)
      %{"campaign_id" => cid} when is_binary(cid) -> topic(cid)
      _ -> nil
    end
  end
end
