defmodule Worker.MaterializerIdempotencyTest do
  @moduledoc """
  Etappe 2 (Issue #123): id-basierte Idempotenz im Materializer.

  - Worker-First-Apply (apply_local mit event_id, kein seq) trägt event_id
    in `worker_applied_event_ids` ein.
  - Späterer Hub-Broadcast desselben event_id ist :skipped (kein Doppel-Apply
    auf Domain-Tabelle), bumpt aber den last_applied_seq-Cursor.
  - Pre-Migration-Events (kein event_id) laufen über den seq-Cursor-Pfad.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "apply_local + Hub-Broadcast: doppelter Apply wird auf event_id deduplikiert" do
    event_id = "019e1111-1111-7111-8111-111111111111"
    did = "test-user-idempotency-1"

    payload = %{
      "kind" => "UserUpserted",
      "discord_id" => did,
      "display_name" => "Test User"
    }

    local_event =
      event("UserUpserted", payload, 0, event_id: event_id)
      |> Map.delete("seq")

    # 1) Worker-First-Apply
    assert :ok = Materializer.apply_local(local_event)

    # applied_event_ids hat einen Eintrag mit seq=nil
    [{_, ^event_id, nil}] = :mnesia.dirty_read(S.applied_event_ids(), event_id)

    # User existiert
    [_] = :mnesia.dirty_read(S.users(), did)

    # 2) Hub-Broadcast desselben Events (jetzt mit seq=42)
    hub_event = Map.put(local_event, "seq", 42)
    assert :skipped = Materializer.apply_event(hub_event)

    # applied_event_ids hat den seq-Backfill, immer noch nur 1 Eintrag
    [{_, ^event_id, 42}] = :mnesia.dirty_read(S.applied_event_ids(), event_id)

    # User ist immer noch da (kein Doppel-Apply, aber auch nicht weg)
    [_] = :mnesia.dirty_read(S.users(), did)
  end

  test "Pre-Migration-Event (kein event_id) läuft über seq-Cursor-Pfad" do
    payload = %{
      "kind" => "UserUpserted",
      "discord_id" => "test-user-precursor-1",
      "display_name" => "Pre-Migration User"
    }

    # KEIN event_id — wie Events aus der Pre-Etappe-2-Zeit
    pre_migration_event = event("UserUpserted", payload, 100)

    assert {:applied, 100} = Materializer.apply_event(pre_migration_event)

    # applied_event_ids bleibt leer (kein event_id zum Tracking)
    assert :mnesia.dirty_all_keys(S.applied_event_ids()) == []

    # last_applied_seq-Cursor wurde gebumpt
    assert Materializer.last_applied_seq() == 100

    # Wiederholtes Apply ist :skipped via seq-Cursor
    assert :skipped = Materializer.apply_event(pre_migration_event)
  end
end
