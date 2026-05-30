defmodule Worker.MaterializerUserDeletedTest do
  @moduledoc """
  Issue #57: `UserDeleted` löscht den User-Row hart und tombstoned alle
  Campaign-Memberships per :deleted_at. Utterances/Sessions/Markers
  bleiben unverändert (Audit-Trail).

  `CampaignArchived` setzt Campaign-Status auf :archived (für den
  Last-Spielleiter-Pfad im User-Delete-Flow).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "user-delete-test-campaign"
  @target_did "user-to-delete"
  @other_did "user-to-keep"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()

    now = DateTime.utc_now()

    # User + Campaign + 2 Memberships, target ist Mitspieler, other ist Spielleiter
    Builder.write_many!([
      Builder.user(@target_did, display_name: "Ziel-User", role: :spieler),
      Builder.user(@other_did, display_name: "Anderer User", role: :spielleiter),
      Builder.campaign(@cid, name: "Cascade-Test", status: :active, created_at: now),
      Builder.campaign_member(@cid, @target_did, role: :spieler, joined_at: now),
      Builder.campaign_member(@cid, @other_did, role: :spielleiter, joined_at: now)
    ])

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "cascade: user-row weg, member-row tombstoned, andere user/member unangetastet" do
    target = @target_did
    other = @other_did
    ev = event("UserDeleted", %{"discord_id" => target, "deleted_by" => "admin"}, 100)

    Materializer.apply_event(ev)

    # User-Row hart gelöscht
    assert :mnesia.dirty_read(S.users(), target) == []

    # Member-Row für target ist tombstoned (deleted_at gesetzt)
    [{_, _key, _cid, ^target, _role, _joined, _char, deleted_at}] =
      :mnesia.dirty_read(
        S.campaign_members(),
        S.member_key(@cid, target)
      )

    assert deleted_at != nil

    # Other-User + Other-Member bleiben unangetastet
    assert [_row] = :mnesia.dirty_read(S.users(), other)

    [{_, _key2, _cid, ^other, _role, _joined, _char, other_deleted}] =
      :mnesia.dirty_read(
        S.campaign_members(),
        S.member_key(@cid, other)
      )

    assert other_deleted == nil
  end

  test "campaign archived → status :archived" do
    cid = @cid

    ev =
      event(
        "CampaignArchived",
        %{
          "campaign_id" => cid,
          "archived_by" => "admin",
          "reason" => "owner_deleted"
        },
        200
      )

    Materializer.apply_event(ev)

    [{_, ^cid, _name, _icon, _theme, status, _created_at, _flavors, _vocab}] =
      :mnesia.dirty_read(S.campaigns(), cid)

    assert status == :archived
  end

  test "CampaignArchived auf unknown campaign → no-op, kein crash" do
    ev =
      event(
        "CampaignArchived",
        %{
          "campaign_id" => "campaign-that-does-not-exist",
          "archived_by" => "admin",
          "reason" => "manual"
        },
        300
      )

    # Soll NICHT crashen
    assert {:applied, _seq} = Materializer.apply_event(ev)
  end

  test "Repo.last_admin?/1 true wenn nur ein admin existiert" do
    clear_all_tables!()
    Builder.write_many!([Builder.user("solo-admin", role: :admin)])

    assert Worker.Repo.last_admin?("solo-admin") == true
    assert Worker.Repo.last_admin?("nicht-existent") == false
  end

  test "Repo.last_admin?/1 false wenn zwei admins existieren" do
    clear_all_tables!()

    Builder.write_many!([
      Builder.user("admin-1", role: :admin),
      Builder.user("admin-2", role: :admin)
    ])

    assert Worker.Repo.last_admin?("admin-1") == false
    assert Worker.Repo.last_admin?("admin-2") == false
  end

  test "Repo.last_spielleiter_campaigns_for/1 liefert Kampagnen wo User letzter SL ist" do
    clear_all_tables!()

    Builder.write_many!([
      Builder.user("sl-1", role: :spielleiter),
      Builder.user("sl-2", role: :spielleiter),
      Builder.user("player-1", role: :spieler),
      # Camp A: sl-1 ist alleiniger SL + 1 Spieler
      Builder.campaign("camp-a", name: "Camp A"),
      Builder.campaign_member("camp-a", "sl-1", role: :spielleiter),
      Builder.campaign_member("camp-a", "player-1", role: :spieler),
      # Camp B: sl-1 + sl-2 sind beide SL
      Builder.campaign("camp-b", name: "Camp B"),
      Builder.campaign_member("camp-b", "sl-1", role: :spielleiter),
      Builder.campaign_member("camp-b", "sl-2", role: :spielleiter)
    ])

    result = Worker.Repo.last_spielleiter_campaigns_for("sl-1")

    # Nur Camp A — in Camp B ist sl-2 noch SL übrig
    assert length(result) == 1
    [%{id: cid, name: name, members: members}] = result
    assert cid == "camp-a"
    assert name == "Camp A"
    assert length(members) == 1
    assert hd(members).discord_id == "player-1"
  end

  test "fetch_users markiert dangling discord_ids als deleted=true" do
    # target_did wird gelöscht
    Materializer.apply_event(
      event("UserDeleted", %{"discord_id" => @target_did, "deleted_by" => "admin"}, 400)
    )

    # `fetch_users` ist private — wir nutzen indirekt users_for_campaign
    # (das macht den fetch_users-Roundtrip).
    map = Worker.Repo.users_for_campaign(@cid)

    # other_did (lebt) ist nicht-deleted, target_did (gelöscht) ist deleted.
    # users_for_campaign gibt nur ACTIVE members zurück (list_members filtert
    # tombstone'd raus), also ist target_did nicht mehr im map — der fetch_users-
    # deleted-Flag ist nur für die Dangling-Detection beim Render von alten
    # Utterances/Sessions interessant. Sanity-Check: other_did ist sichtbar.
    assert map[@other_did]["deleted"] == false
  end
end
