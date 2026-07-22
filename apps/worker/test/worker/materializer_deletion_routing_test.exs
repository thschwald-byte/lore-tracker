defmodule Worker.MaterializerDeletionRoutingTest do
  @moduledoc """
  Issue #894 (I7-Bucket-D-Rest): der Durability-Beweis. `CampaignDeleted` muss
  im Global-Store landen (nicht im per-Campaign-Store, der post-tx gedroppt wird)
  — sonst könnte ein Offline-Peer die Löschung nie pullen und würde die Kampagne
  als Zombie halten. Dazu: der PRE-Tx-Store-Guard (`maybe_create_campaign_store`)
  darf keinen Store für eine getombstonte Campaign wiederbeleben, ein Rebirth
  (größere event_id) aber schon.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.DynamicTables
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-route-894"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    if DynamicTables.exists?(@cid), do: DynamicTables.drop_campaign_store!(@cid)
    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
      if DynamicTables.exists?(@cid), do: DynamicTables.drop_campaign_store!(@cid)
    end)

    :ok
  end

  defp created(event_id),
    do:
      event("CampaignCreated", %{"id" => @cid, "name" => "C", "owner_discord_id" => "o"}, 1,
        event_id: event_id
      )

  defp deleted(event_id),
    do:
      event("CampaignDeleted", %{"campaign_id" => @cid, "deleted_by" => "o"}, 2,
        event_id: event_id
      )

  defp global_event_ids,
    do: DynamicTables.global_events_since(nil) |> Enum.map(&elem(&1, 0))

  test "CampaignDeleted landet im Global-Store und bleibt pullbar, obwohl der Campaign-Store gedroppt ist" do
    Materializer.apply_event(created("e01"))
    assert DynamicTables.exists?(@cid), "CampaignCreated legt den per-Campaign-Store an"

    Materializer.apply_event(deleted("e05"))

    # Store weg …
    refute DynamicTables.exists?(@cid)
    # … aber das Lösch-Event liegt im Global-Store → ein Offline-Peer kann es pullen.
    assert "e05" in global_event_ids(),
           "CampaignDeleted MUSS im Global-Store liegen (Durability über den Store-Drop hinweg)"
  end

  test "Pre-Delete-Replay (event_id < Tombstone) belebt weder Store noch Campaign-Row" do
    Materializer.apply_event(created("e01"))
    Materializer.apply_event(deleted("e05"))
    refute DynamicTables.exists?(@cid)

    # Verspäteter alter Create (e01 < Tombstone e05) — darf nichts wiederbeleben.
    Materializer.apply_event(created("e01b"))

    assert :mnesia.dirty_read(S.campaigns(), @cid) == [],
           "alter Create darf die Campaign-Row nicht wiederbeleben (Fold-Gate)"

    refute DynamicTables.exists?(@cid),
           "alter Create darf den Store nicht wiederbeleben (L5-Guard)"
  end

  test "Rebirth (event_id > Tombstone) legt Store + Campaign-Row wieder an" do
    Materializer.apply_event(created("e01"))
    Materializer.apply_event(deleted("e05"))
    refute DynamicTables.exists?(@cid)

    # Rebirth-Create e09 > Tombstone e05 → muss durch.
    Materializer.apply_event(created("e09"))

    assert :mnesia.dirty_read(S.campaigns(), @cid) != [],
           "Rebirth-Create (event_id > Tombstone) muss die Campaign-Row anlegen"

    assert DynamicTables.exists?(@cid), "Rebirth-Create muss den Store wieder anlegen"
  end

  test "gated Event bleibt trotzdem in applied_event_ids vermerkt (Dedup-/Relay-Semantik)" do
    Materializer.apply_event(deleted("e05"))
    # Ein gated Pre-Delete-Event (Session für die getombstonte Campaign).
    ev =
      event("SessionScheduled", %{"id" => "s1", "campaign_id" => @cid, "number" => 1}, 3,
        event_id: "e02"
      )

    Materializer.apply_event(ev)

    assert :mnesia.dirty_read(S.applied_event_ids(), "e02") != [],
           "gated Event muss als applied markiert bleiben (sonst bricht Dedup/Relay)"

    assert :mnesia.dirty_read(S.sessions(), "s1") == [],
           "der Fold selbst ist aber gegated (keine Session-Row)"
  end
end
