defmodule Worker.Intents do
  @moduledoc """
  Worker-Side Event-Publisher mit Worker-First-Apply (Issue #123, Etappe 2).

  Jeder Aufruf:
  1. Generiert `event_id` (UUIDv7) wenn keiner im Payload ist
  2. Appliest den Event **lokal sofort** via `Worker.Materializer.apply_local/1`
     — Owner-Worker sieht den Output unabhängig vom Hub
  3. Sendet den Event zum Hub via `Worker.HubClient.publish/1` (best-effort)

  Returns:
  - `{:ok, seq}` wenn Hub-Sync erfolgreich
  - `{:ok, :pending}` wenn Hub-Sync gescheitert (Event ist lokal sichtbar,
    aber andere Worker sehen ihn erst nach Etappe-3-Sync)

  Aufrufer matchen nicht hart auf `{:ok, _seq}` — Etappe 1 hat den Crash-Schutz
  schon eingebaut, alle Stage-Publishes laufen über `Pipeline.publish_event/1`
  oder ähnliche Wrapper.
  """

  require Logger

  # Issue #430: gibt IMMER {:ok, …} zurück — Hub-Sync-Fehler werden zu
  # {:ok, :pending} (local-apply ist schon passiert, Issue #215), local-apply
  # selbst ist `:ok =`-asserted. Kein {:error}-Pfad (war toter Branch bei Callern).
  @spec publish(map()) :: {:ok, pos_integer() | :pending}
  def publish(payload) when is_map(payload) do
    event_id = Map.get(payload, "event_id") || UUIDv7.generate()

    local_event = %{
      "event_id" => event_id,
      "payload" => payload,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "author_worker_id" => Worker.Repo.get_state(:worker_id)
    }

    :ok = Worker.Materializer.apply_local(local_event)

    case Worker.HubClient.publish(event_id, payload) do
      {:ok, seq} ->
        {:ok, seq}

      {:error, reason} ->
        Logger.warning(
          "Intents.publish: Hub-Sync failed (kind=#{payload["kind"]} event_id=#{event_id}): " <>
            inspect(reason)
        )

        {:ok, :pending}
    end
  end
end
