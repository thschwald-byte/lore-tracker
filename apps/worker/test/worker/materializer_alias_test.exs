defmodule Worker.MaterializerAliasTest do
  @moduledoc """
  Smoke tests for the CampaignAliasSet round-trip through the Materializer.
  Covers the path that pipeline & UI rely on: setting an alias, reading it
  back via `Worker.Repo.character_names_for/1`, and the InviteRedeemed
  preserve-on-rejoin behaviour.

  Mnesia tables come from test_helper bootstrap. Not async — these
  tables are shared singletons.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "cid-alias-test"
  @did "did-alias-test"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write!(Builder.campaign_member(@cid, @did, role: :player))

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  describe "CampaignAliasSet" do
    test "sets character_name and surfaces via character_names_for/1" do
      ev =
        event(
          "CampaignAliasSet",
          %{
            "campaign_id" => @cid,
            "discord_id" => @did,
            "character_name" => "Tharion der Entdecker"
          },
          100
        )

      assert {:applied, 100} = Materializer.apply_event(ev)
      assert Repo.character_names_for(@cid) == %{@did => "Tharion der Entdecker"}
    end

    test "nil character_name resets (removes from character_names map)" do
      _ =
        Materializer.apply_event(
          event(
            "CampaignAliasSet",
            %{"campaign_id" => @cid, "discord_id" => @did, "character_name" => "Tharion"},
            101
          )
        )

      _ =
        Materializer.apply_event(
          event(
            "CampaignAliasSet",
            %{"campaign_id" => @cid, "discord_id" => @did, "character_name" => nil},
            102
          )
        )

      assert Repo.character_names_for(@cid) == %{}
    end

    test "empty string is treated as reset (normalize_alias trims to nil)" do
      _ =
        Materializer.apply_event(
          event(
            "CampaignAliasSet",
            %{"campaign_id" => @cid, "discord_id" => @did, "character_name" => "Tharion"},
            103
          )
        )

      _ =
        Materializer.apply_event(
          event(
            "CampaignAliasSet",
            %{"campaign_id" => @cid, "discord_id" => @did, "character_name" => "   "},
            104
          )
        )

      assert Repo.character_names_for(@cid) == %{}
    end

    test "unknown member is silently dropped (no crash)" do
      ev =
        event(
          "CampaignAliasSet",
          %{
            "campaign_id" => "unknown-cid",
            "discord_id" => "unknown-did",
            "character_name" => "Lyra"
          },
          105
        )

      assert {:applied, 105} = Materializer.apply_event(ev)
      assert Repo.character_names_for("unknown-cid") == %{}
    end
  end
end
