defmodule Worker.MaterializerAdminMemberAddedTest do
  @moduledoc """
  Issue #35: `AdminMemberAdded`-Event legt member-row + upsertet user-row.
  Idempotent (mehrfach hinzufügen überschreibt cleanly).
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-admin-add-test"
  @owner "owner-did"
  @new_did "new-member-did"

  setup do
    Enum.each(
      [S.campaigns(), S.campaign_members(), S.users(), S.worker_state()],
      fn t -> {:atomic, :ok} = :mnesia.clear_table(t) end
    )

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    :mnesia.transaction(fn ->
      :mnesia.write({
        S.campaigns(),
        @cid,
        "Test Campaign",
        nil,
        nil,
        :active,
        DateTime.utc_now(),
        %{}
      })
    end)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", "AdminMemberAdded")
    }
  end

  test "legt member-row + user-row für neuen user" do
    ev =
      event(
        %{
          "campaign_id" => @cid,
          "discord_id" => @new_did,
          "display_name" => "Frischer User",
          "added_by" => "admin-did"
        },
        100
      )

    assert {:applied, 100} = Materializer.apply_event(ev)

    [{_, _, _, did, role, _, _, _}] =
      :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @new_did))

    assert did == @new_did
    # Issue #140: AdminMemberAdded → role :spieler (war vorher :player).
    assert role == :spieler

    [{_, _, name, _, _, user_role}] = :mnesia.dirty_read(S.users(), @new_did)
    assert name == "Frischer User"
    assert user_role == :spieler
  end

  test "idempotent — zweimal anwenden überschreibt cleanly" do
    ev =
      event(
        %{"campaign_id" => @cid, "discord_id" => @new_did, "display_name" => "X"},
        200
      )

    Materializer.apply_event(ev)
    ev2 = event(%{"campaign_id" => @cid, "discord_id" => @new_did, "display_name" => "X"}, 201)
    Materializer.apply_event(ev2)

    rows = :mnesia.dirty_index_read(S.campaign_members(), @cid, :campaign_id)
    assert length(rows) == 1
  end

  test "preserves existing role + character_name auf bestehendem user/member" do
    # Bestehender Admin-User
    :mnesia.transaction(fn ->
      :mnesia.write({
        S.users(),
        @new_did,
        "Existing Admin",
        DateTime.utc_now(),
        "https://avatar/x.png",
        :admin
      })

      :mnesia.write({
        S.campaign_members(),
        S.member_key(@cid, @new_did),
        @cid,
        @new_did,
        :player,
        DateTime.utc_now(),
        "Aragorn",
        nil
      })
    end)

    ev =
      event(
        %{"campaign_id" => @cid, "discord_id" => @new_did, "display_name" => "Existing Admin"},
        300
      )

    Materializer.apply_event(ev)

    [{_, _, _, _, _, role}] = :mnesia.dirty_read(S.users(), @new_did)
    assert role == :admin

    [{_, _, _, _, _, _, char_name, _deleted_at}] =
      :mnesia.dirty_read(S.campaign_members(), S.member_key(@cid, @new_did))

    assert char_name == "Aragorn"
  end

  test "unbekannte campaign_id wird ignoriert" do
    ev =
      event(
        %{"campaign_id" => "ghost-cid", "discord_id" => @new_did, "display_name" => "x"},
        400
      )

    assert {:applied, 400} = Materializer.apply_event(ev)

    assert :mnesia.dirty_read(S.users(), @new_did) == []
  end
end
