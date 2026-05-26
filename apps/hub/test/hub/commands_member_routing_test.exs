defmodule Hub.CommandsMemberRoutingTest do
  @moduledoc """
  Issue #237: Hub.Commands.pick_leader/2 darf nur Worker auswählen, deren
  `subscribed_campaigns`-MapSet (im Phoenix.Tracker-Meta) die Kampagne
  enthält. Bei mehreren Member-Workern wird deterministisch der
  lexikografisch kleinste worker_id gewählt — race-frei, stateless.

  Wir testen über die public-API `request_recording_start/2`, die intern
  pick_leader/2 ruft und das `{:start_recording, did, cid}`-Tuple an den
  channel_pid des gepickten Workers sendet. Der Test-Prozess registriert
  sich selbst als Worker (channel_pid = self()), bekommt also die
  Nachricht via `assert_receive`.
  """

  use ExUnit.Case, async: false

  alias Hub.{Commands, WorkerRegistry}

  setup do
    # Phoenix.Tracker.track ist auf den calling pid keyed — wenn der Test-
    # Prozess endet, geht der Eintrag auch. Trotzdem Cleanup über pids die
    # wir spawnen.
    on_exit(fn -> :ok end)
    :ok
  end

  # Spawne einen Fake-Worker-Prozess, der sich im Tracker registriert + auf
  # Nachrichten wartet. Returnt {pid, ref} — ref dient zur Identifikation
  # in assert_receive.
  defp spawn_fake_worker(worker_id, admin_did, subscribed_to) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, admin_did)

        if subscribed_to != [] do
          {:ok, _} = WorkerRegistry.subscribe(worker_id, subscribed_to)
        end

        send(parent, {:tracked, worker_id})

        receive do
          msg ->
            send(parent, {:received, worker_id, msg})
        after
          5_000 -> :timeout
        end
      end)

    assert_receive {:tracked, ^worker_id}, 2_000
    # Tracker.list ist async — kurz pollen bis der Eintrag sichtbar ist.
    wait_until_visible(worker_id)

    pid
  end

  defp wait_until_visible(worker_id, attempts \\ 50) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_until_visible(worker_id, attempts - 1)

      nil ->
        flunk("Worker #{worker_id} nie im Tracker sichtbar geworden")

      _ ->
        :ok
    end
  end

  test "Member-Worker bekommt das Signal, Non-Member-Worker nicht" do
    cid = "camp-#{System.unique_integer([:positive])}"
    other_cid = "camp-other-#{System.unique_integer([:positive])}"

    _member = spawn_fake_worker("w-member-A", "admin-A", [cid])
    _non_member = spawn_fake_worker("w-other-B", "admin-B", [other_cid])

    # caller-did ist egal beim Member-Routing (kein own-worker-Pfad mehr für
    # campaign-bound Ops).
    assert 1 == Commands.request_recording_start("any-caller", cid)

    assert_receive {:received, "w-member-A", {:start_recording, "any-caller", ^cid}}, 2_000
    refute_received {:received, "w-other-B", _}
  end

  test "Multi-Member: lexikografisch kleinster worker_id gewinnt" do
    cid = "camp-multi-#{System.unique_integer([:positive])}"

    # Bewusst nicht-sortiert spawned, damit klar ist: Auswahl hängt nicht an
    # Spawn-Reihenfolge.
    _zebra = spawn_fake_worker("zebra-worker", "admin-Z", [cid])
    _alpha = spawn_fake_worker("alpha-worker", "admin-A", [cid])
    _middle = spawn_fake_worker("middle-worker", "admin-M", [cid])

    assert 1 == Commands.request_recording_start("any-caller", cid)

    assert_receive {:received, "alpha-worker", {:start_recording, _, ^cid}}, 2_000
    refute_received {:received, "zebra-worker", _}
    refute_received {:received, "middle-worker", _}
  end

  test "Kein Member-Worker connected → returnt 0, kein Worker bekommt was" do
    cid = "camp-empty-#{System.unique_integer([:positive])}"
    other_cid = "camp-other-#{System.unique_integer([:positive])}"

    _non_member = spawn_fake_worker("w-other", "admin-X", [other_cid])

    assert 0 == Commands.request_recording_start("caller", cid)
    refute_received {:received, "w-other", _}
  end

  test "Probelauf (nil-campaign) wählt own-worker des Discord-IDs, kein Member-Filter" do
    other_cid = "camp-irrelevant-#{System.unique_integer([:positive])}"
    own_did = "did-own-#{System.unique_integer([:positive])}"

    # Worker mit passender admin_discord_id, OHNE Campaign-Subscription —
    # für Probelauf trotzdem der richtige Worker, weil Probelauf nicht
    # campaign-bound ist.
    _own = spawn_fake_worker("w-own", own_did, [])
    _stranger = spawn_fake_worker("w-stranger", "did-stranger", [other_cid])

    assert 1 == Commands.request_probelauf_start(own_did)

    assert_receive {:received, "w-own", {:start_probelauf, ^own_did}}, 2_000
    refute_received {:received, "w-stranger", _}
  end
end
