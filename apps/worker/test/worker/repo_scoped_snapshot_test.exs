defmodule Worker.RepoScopedSnapshotTest do
  @moduledoc """
  Issue #442 Stage 2: die schmalen scoped Reads (campaign_summaries/_chronik/
  _epos/_meta) müssen byte-identische Sub-Maps zur "campaign"-Voll-Klausel
  liefern — sonst driftet apply_scope/3 gegen apply_snapshot/2. Plus
  member?-Gating (Nicht-Member → forbidden), analog zur campaign-Klausel.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo

  @cid "repo-scope-camp"
  @owner "did-owner-scope"
  @member "did-member-scope"
  @stranger "did-stranger-scope"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      name: "Scope-Kampagne",
      owner_did: @owner,
      owner_name: "Owner Scope",
      members: [@member],
      sessions: [2, 3],
      include_summaries?: true,
      apply: true
    )

    full = Repo.snapshot(%{"kind" => "campaign", "id" => @cid, "viewer_discord_id" => @owner})
    {:ok, full: full}
  end

  defp scoped(kind, viewer \\ @owner),
    do: Repo.snapshot(%{"kind" => kind, "id" => @cid, "viewer_discord_id" => viewer})

  test "campaign_summaries == die summaries/faithfulness-Keys des Voll-Snapshots", %{full: full} do
    s = scoped("campaign_summaries")
    assert s["summaries"] == full["summaries"]
    assert s["faithfulness"] == full["faithfulness"]
    # NUR der betroffene Bereich — keine teuren Utterances/Sessions.
    refute Map.has_key?(s, "utterances")
    refute Map.has_key?(s, "sessions")
  end

  test "campaign_chronik == der chronik-Key des Voll-Snapshots", %{full: full} do
    assert scoped("campaign_chronik")["chronik"] == full["chronik"]
  end

  test "campaign_epos == die epos/epos_history-Keys des Voll-Snapshots", %{full: full} do
    s = scoped("campaign_epos")
    assert s["epos"] == full["epos"]
    assert s["epos_history"] == full["epos_history"]
  end

  test "campaign_meta == der campaign-Key des Voll-Snapshots", %{full: full} do
    assert scoped("campaign_meta")["campaign"] == full["campaign"]
  end

  test "Nicht-Member → forbidden für jeden scoped Read" do
    for kind <- ~w(campaign_summaries campaign_chronik campaign_epos campaign_meta) do
      assert scoped(kind, @stranger) == %{"forbidden" => true},
             "#{kind} sollte für Nicht-Member forbidden sein"
    end
  end
end
