defmodule Hub.EventBridgeTest do
  @moduledoc """
  Issue #66 (Coverage-Followup): Routing-Coverage für `Hub.EventBridge`.

  `EventBridge.publish/1,2` wählt über `Hub.WorkerRegistry.list()` einen
  Ziel-Worker (Campaign-Subscriber bzw. — für Global-Events — beliebigen
  Worker, Tie-Break: höchster `applied_seq`) und pusht ihm das
  `{:bridge_publish, payload}`-Frame. Cold-Fail (kein passender Worker) →
  `{:error, :no_worker_online}`.

  Da `WorkerRegistry` ein `Phoenix.Tracker` ist und der getrackte Prozess
  selbst als `channel_pid` im Meta landet, spawnen wir pro Worker einen
  Prozess, der trackt/subscribt und das gepushte Frame an den Test-Parent
  weiterreicht. Tracker-Updates sind async → vor jedem `publish` pollen wir
  `list()`, bis der erwartete State sichtbar ist.
  """

  use ExUnit.Case, async: false

  alias Hub.EventBridge
  alias Hub.WorkerRegistry

  # ── Worker-Spawn-Harness ──────────────────────────────────────────

  defp spawn_worker(worker_id, opts) do
    parent = self()
    campaigns = Keyword.get(opts, :campaigns, [])
    applied_seq = Keyword.get(opts, :applied_seq, 0)

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-#{worker_id}")
        if campaigns != [], do: {:ok, _} = WorkerRegistry.subscribe(worker_id, campaigns)

        if applied_seq > 0,
          do: {:ok, _} = WorkerRegistry.update_applied_seq(worker_id, applied_seq)

        send(parent, {:tracked, worker_id})
        worker_loop(parent)
      end)

    assert_receive {:tracked, ^worker_id}, 2_000
    wait_until(worker_id, campaigns, applied_seq)
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp worker_loop(parent) do
    receive do
      {:bridge_publish, payload} ->
        send(parent, {:got_publish, self(), payload})
        worker_loop(parent)

      :stop ->
        :ok
    end
  end

  # Tracker.update ist async → pollen, bis der Worker mit erwarteter
  # Subscription + applied_seq in list() auftaucht.
  defp wait_until(worker_id, campaigns, applied_seq) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
        {_id, meta} ->
          subs = Map.get(meta, :subscribed_campaigns, MapSet.new())

          ready? =
            Enum.all?(campaigns, &MapSet.member?(subs, &1)) and
              Map.get(meta, :applied_seq, 0) >= applied_seq

          if ready?, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}

        nil ->
          Process.sleep(10)
          {:cont, nil}
      end
    end)
  end

  # ── Cold-Fail ─────────────────────────────────────────────────────

  describe "kein passender Worker online" do
    test "Campaign-Event ohne Subscriber → {:error, :no_worker_online}" do
      cid = "eb-no-worker-#{System.unique_integer([:positive])}"

      assert EventBridge.publish(%{"campaign_id" => cid, "kind" => "MarkerAdded"}) ==
               {:error, :no_worker_online}
    end

    test "Campaign-Event: Worker nur auf ANDERE Campaign subscribed → no_worker_online" do
      other = "eb-other-#{System.unique_integer([:positive])}"
      target = "eb-target-#{System.unique_integer([:positive])}"
      spawn_worker("w-#{System.unique_integer([:positive])}", campaigns: [other])

      assert EventBridge.publish(target, %{"kind" => "SomethingHappened"}) ==
               {:error, :no_worker_online}
    end
  end

  # ── Erfolgs-Routing ───────────────────────────────────────────────

  describe "Push an passenden Worker" do
    test "publish/2 pusht das Frame an einen subscribed Worker" do
      cid = "eb-camp-#{System.unique_integer([:positive])}"
      wid = "w-#{System.unique_integer([:positive])}"
      worker = spawn_worker(wid, campaigns: [cid])

      payload = %{"campaign_id" => cid, "kind" => "UtteranceAppended", "id" => "u1"}
      assert EventBridge.publish(cid, payload) == :ok

      assert_receive {:got_publish, ^worker, ^payload}, 2_000
    end

    test "publish/1 zieht die campaign_id aus dem Payload" do
      cid = "eb-camp1-#{System.unique_integer([:positive])}"
      wid = "w-#{System.unique_integer([:positive])}"
      worker = spawn_worker(wid, campaigns: [cid])

      payload = %{"campaign_id" => cid, "kind" => "SessionStarted"}
      assert EventBridge.publish(payload) == :ok
      assert_receive {:got_publish, ^worker, ^payload}, 2_000
    end

    test "Global-Event (campaign_id=nil) pickt einen beliebigen online Worker" do
      wid = "w-global-#{System.unique_integer([:positive])}"
      worker = spawn_worker(wid, applied_seq: 5)

      payload = %{"campaign_id" => nil, "kind" => "UserRoleSet"}
      assert EventBridge.publish(payload) == :ok
      assert_receive {:got_publish, ^worker, ^payload}, 2_000
    end
  end

  # ── Tie-Break ─────────────────────────────────────────────────────

  describe "Tie-Break über applied_seq" do
    test "Campaign-Event geht an den Worker mit dem höchsten applied_seq" do
      cid = "eb-tie-#{System.unique_integer([:positive])}"

      _low =
        spawn_worker("w-low-#{System.unique_integer([:positive])}",
          campaigns: [cid],
          applied_seq: 1
        )

      high =
        spawn_worker("w-high-#{System.unique_integer([:positive])}",
          campaigns: [cid],
          applied_seq: 99
        )

      payload = %{"campaign_id" => cid, "kind" => "UtteranceAppended"}
      assert EventBridge.publish(cid, payload) == :ok

      assert_receive {:got_publish, got_pid, ^payload}, 2_000
      assert got_pid == high, "Frame muss an den Worker mit höchstem applied_seq gehen"
    end
  end
end
