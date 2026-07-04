defmodule Worker.MaterializerBackfillBelowMaxTest do
  @moduledoc """
  Issue #693: das `.48`-Szenario im Kleinen. Ein Worker hat bereits jüngere
  Events im Global-Store (per Live-`event_appended` angekommen), der
  Cold-Start-Backfill liefert danach die ÄLTERE Historie nach — Events mit
  event_ids UNTERHALB des Tabellen-MAX. Die müssen (a) vollständig in den
  Store geschrieben werden (ordered_set schluckt beliebige Keys, kein
  Nur-Anhängen) und (b) Membership-Events bootstrappen dabei den
  per-Campaign-Store.
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

  test "Backfill-Events unterhalb des Global-MAX werden gespeichert (kein Nur-Anhängen)" do
    # 1) Live-Event an der Spitze (jüngere UUIDv7) ist schon da.
    live_id = "019f9999-0000-7000-8000-000000000001"

    live =
      event("UserUpserted", %{"kind" => "UserUpserted", "discord_id" => "live-user"}, 0,
        event_id: live_id
      )
      |> Map.delete("seq")

    assert :ok = Materializer.apply_local(live)

    # MAX der Tabelle ist jetzt das Live-Event.
    assert Worker.Schema.DynamicTables.last_global_event_id() == live_id

    # 2) Backfill liefert ein ÄLTERES Event (event_id < MAX) nach.
    old_id = "019e1111-0000-7000-8000-000000000001"

    old =
      event("UserUpserted", %{"kind" => "UserUpserted", "discord_id" => "old-user"}, 0,
        event_id: old_id
      )
      |> Map.delete("seq")

    assert :ok = Materializer.apply_local(old)

    # Beide liegen im Global-Store — das ältere wurde NICHT verworfen.
    assert [_] = :mnesia.dirty_read(S.events_global(), old_id)
    assert [_] = :mnesia.dirty_read(S.events_global(), live_id)

    # MAX bleibt das Live-Event (ordered_set, Reihenfolge = event_id).
    assert Worker.Schema.DynamicTables.last_global_event_id() == live_id
  end

  test "CampaignCreated aus dem Backfill bootstrappt den per-Campaign-Store" do
    cid = "backfill-boot-campaign"
    # Dynamische Tabellen sind disc_copies und überleben frühere Testläufe —
    # explizit droppen, damit der Bootstrap-Pfad wirklich von Null startet.
    Worker.Schema.DynamicTables.drop_campaign_store!(cid)
    refute Worker.Schema.DynamicTables.exists?(cid)

    created =
      event(
        "CampaignCreated",
        %{"kind" => "CampaignCreated", "id" => cid, "name" => "Backfill-Boot"},
        0,
        event_id: "019e2222-0000-7000-8000-000000000001"
      )
      |> Map.delete("seq")

    assert :ok = Materializer.apply_local(created)

    # Store existiert → der subscribe_campaigns-Handler im HubClient pullt
    # die Campaign-Historie ab Wasserlinie (dort getestet ist hier nur der
    # Bootstrap-Pfad Store-Anlage).
    assert Worker.Schema.DynamicTables.exists?(cid)
  end
end
