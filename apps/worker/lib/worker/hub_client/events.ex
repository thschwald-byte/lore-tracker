defmodule Worker.HubClient.Events do
  @moduledoc """
  Issue #585: Events-Topic-Bündel aus `Worker.HubClient`.

  Behandelt die Event-Replication-Klauseln, die der Hub auf dem `worker:<id>`-
  Channel pusht:

  - `event_appended` — neuer kanonischer Event vom Hub → Materializer.apply_event/1, ack
  - `pull_request` / `pull_request_global` — anderer Worker fragt nach Events (Issue #131/#141)
  - `pull_batch` / `pull_batch_global` — Antwort eines anderen Workers auf unseren pull_since
  - `catch_up_batch` — Hub schickt nach Join verpasste Events; nach erfolgreichem Apply
    läuft `maybe_bootstrap_admin/0` (Issue #34, Auto-Admin auf frischer Instance)

  Frame-Bau läuft über `Worker.HubClient.{ack/2, push_event/3}` — siehe Channel-Helpers
  in HubClient.
  """

  require Logger

  alias Worker.HubClient
  alias Worker.Materializer
  alias Worker.Schema.DynamicTables

  def on_event_appended(payload, socket) do
    case Materializer.apply_event(payload) do
      {:applied, seq} -> HubClient.ack(socket, seq)
      :skipped -> :ok
    end

    {:ok, socket}
  end

  # Issue #131 (Etappe 3c): Hub fragt uns nach Events einer Campaign seit
  # `last_event_id`. Wir lesen aus dem lokalen per-Campaign-Store, schicken
  # pull_response zurück mit dem Anfrager-worker_id (Hub forwarded an ihn).
  def on_pull_request(
        %{
          "campaign_id" => cid,
          "last_event_id" => last_event_id,
          "requesting_worker_id" => requester
        },
        socket
      ) do
    events =
      cid
      |> DynamicTables.events_since(last_event_id)
      |> Enum.map(fn {event_id, hub_seq, payload, ts} ->
        %{
          event_id: event_id,
          hub_seq: hub_seq,
          payload: payload,
          ts: DateTime.to_iso8601(ts)
        }
      end)

    if events != [] do
      Logger.info(
        "HubClient: pull_request for campaign=#{cid} since=#{inspect(last_event_id)} → #{length(events)} events to worker=#{requester}"
      )
    end

    HubClient.push_event(socket, "pull_response", %{
      campaign_id: cid,
      requesting_worker_id: requester,
      events: events
    })

    {:ok, socket}
  end

  # Hub forwarded Events von einem anderen Worker zu uns — durch Materializer
  # schicken, Idempotenz auf event_id verhindert Doppel-Apply.
  def on_pull_batch(%{"campaign_id" => cid, "events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch campaign=#{cid} → #{length(events)} events")
    end

    Enum.each(events, fn ev ->
      Materializer.apply_local(%{
        "event_id" => ev["event_id"],
        "payload" => ev["payload"],
        "ts" => ev["ts"],
        "author_worker_id" => nil
      })
    end)

    {:ok, socket}
  end

  # Issue #141 (Etappe 4a): Global-Events-Pull. Hub fragt uns nach campaign-
  # losen Events im worker_events_global ab last_event_id.
  def on_pull_request_global(
        %{"last_event_id" => last_event_id, "requesting_worker_id" => requester},
        socket
      ) do
    events =
      last_event_id
      |> DynamicTables.global_events_since()
      |> Enum.map(fn {event_id, hub_seq, payload, ts} ->
        %{
          event_id: event_id,
          hub_seq: hub_seq,
          payload: payload,
          ts: DateTime.to_iso8601(ts)
        }
      end)

    if events != [] do
      Logger.info(
        "HubClient: pull_request_global since=#{inspect(last_event_id)} → #{length(events)} events to worker=#{requester}"
      )
    end

    HubClient.push_event(socket, "pull_response_global", %{
      requesting_worker_id: requester,
      events: events
    })

    {:ok, socket}
  end

  def on_pull_batch_global(%{"events" => events}, socket) do
    if events != [] do
      Logger.info("HubClient: pull_batch_global → #{length(events)} events")
    end

    Enum.each(events, fn ev ->
      Materializer.apply_local(%{
        "event_id" => ev["event_id"],
        "payload" => ev["payload"],
        "ts" => ev["ts"],
        "author_worker_id" => nil
      })
    end)

    {:ok, socket}
  end

  def on_catch_up_batch(%{"events" => events, "head_seq" => head}, socket) do
    Logger.info("HubClient: catch_up_batch (#{length(events)} events, hub head=#{head})")
    last = Materializer.apply_batch(events)

    if last > 0 do
      HubClient.ack(socket, last)
    end

    # Auto-Admin-Bootstrap (Issue #34): wenn nach komplettem Catch-Up
    # KEIN Admin existiert + wir selbst sind als User registriert, machen
    # wir uns zum Admin. Per-Instance einmaliger Bootstrap.
    maybe_bootstrap_admin()

    {:ok, socket}
  end

  defp maybe_bootstrap_admin do
    me = Worker.Repo.get_state(:admin_discord_id)

    cond do
      is_nil(me) ->
        :ok

      Worker.Repo.admin_exists?() ->
        :ok

      true ->
        Logger.info(
          "HubClient: Auto-Admin-Bootstrap — keine Admin auf dieser Instance, promoviere self=#{me}"
        )

        # Publish in eigenem Task — wir sind IM handle_message des HubClient-
        # GenServers, und Intents.publish ist ein GenServer.call AUF diese
        # Instance. Synchron würde das deadlocken.
        # Issue #571: Return matchen — Auto-Admin-Bootstrap ist genau der
        # Silent-Failure-Pfad, der einen Worker headless lassen würde.
        Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
          {:ok, _} =
            Worker.Intents.publish(%{
              "kind" => Shared.Events.user_role_set(),
              "discord_id" => me,
              "role" => "admin",
              "set_by" => "auto-bootstrap"
            })
        end)

        :ok
    end
  end
end
