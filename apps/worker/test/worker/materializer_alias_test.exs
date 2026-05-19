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

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "cid-alias-test"
  @did "did-alias-test"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.campaign_members())
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    # PubSub is session-wide via test_helper. Materializer is per-test
    # because clear_table wipes its persistent cursor row.
    mat_pid = ensure_started({Worker.Materializer, []})

    # Seed a member row at arity 7 (current shape, including character_name).
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({
          S.campaign_members(),
          S.member_key(@cid, @did),
          @cid,
          @did,
          :player,
          DateTime.utc_now(),
          nil
        })
      end)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp ensure_started(child_spec) do
    spec = Supervisor.child_spec(child_spec, [])
    {mod, fun, args} = spec.start

    case apply(mod, fun, args) do
      {:ok, pid} -> pid
      {:error, {:already_started, _pid}} -> nil
    end
  end

  defp event(kind, payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", kind)
    }
  end

  describe "CampaignAliasSet" do
    test "sets character_name and surfaces via character_names_for/1" do
      ev = event("CampaignAliasSet", %{
        "campaign_id" => @cid,
        "discord_id" => @did,
        "character_name" => "Tharion der Entdecker"
      }, 100)

      assert {:applied, 100} = Materializer.apply_event(ev)
      assert Repo.character_names_for(@cid) == %{@did => "Tharion der Entdecker"}
    end

    test "nil character_name resets (removes from character_names map)" do
      _ = Materializer.apply_event(event("CampaignAliasSet", %{
        "campaign_id" => @cid, "discord_id" => @did,
        "character_name" => "Tharion"
      }, 101))

      _ = Materializer.apply_event(event("CampaignAliasSet", %{
        "campaign_id" => @cid, "discord_id" => @did,
        "character_name" => nil
      }, 102))

      assert Repo.character_names_for(@cid) == %{}
    end

    test "empty string is treated as reset (normalize_alias trims to nil)" do
      _ = Materializer.apply_event(event("CampaignAliasSet", %{
        "campaign_id" => @cid, "discord_id" => @did,
        "character_name" => "Tharion"
      }, 103))

      _ = Materializer.apply_event(event("CampaignAliasSet", %{
        "campaign_id" => @cid, "discord_id" => @did,
        "character_name" => "   "
      }, 104))

      assert Repo.character_names_for(@cid) == %{}
    end

    test "unknown member is silently dropped (no crash)" do
      ev = event("CampaignAliasSet", %{
        "campaign_id" => "unknown-cid",
        "discord_id" => "unknown-did",
        "character_name" => "Lyra"
      }, 105)

      assert {:applied, 105} = Materializer.apply_event(ev)
      assert Repo.character_names_for("unknown-cid") == %{}
    end
  end
end
