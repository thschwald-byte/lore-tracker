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

  # Issue #442: Member-Scope == members/campaign/viewer_role des Voll-Snapshots
  # (genau die Sub-Map, die derive_assigns/2 konsumiert), ohne die teuren Bereiche.
  test "campaign_members == members/campaign/viewer_role des Voll-Snapshots", %{full: full} do
    s = scoped("campaign_members")
    assert s["members"] == full["members"]
    assert s["campaign"] == full["campaign"]
    assert s["viewer_role"] == full["viewer_role"]
    refute Map.has_key?(s, "utterances")
    refute Map.has_key?(s, "sessions")
  end

  # Issue #839 (Epic #829 Slice D3): der schmale campaign_threads-Read muss
  # byte-identisch zum campaign_threads-Key des Voll-Snapshots sein (sonst driftet
  # apply_scope gegen apply_snapshot).
  test "campaign_threads == der campaign_threads-Key des Voll-Snapshots", %{full: full} do
    s = scoped("campaign_threads")
    assert s["campaign_threads"] == full["campaign_threads"]
    refute Map.has_key?(s, "chronik")
  end

  test "campaign_threads serialisiert Status-Atome + Keys zu JSON-Strings, strippt facts" do
    Worker.Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{
          "session_id" => "#{@cid}-s1",
          "campaign_id" => @cid,
          "facts" => [
            %{
              "id" => "f1",
              "claim" => "Der König fasst einen Plan.",
              "thread" => "der Plan",
              "character_alias" => "König",
              "verified?" => true,
              "fact_type" => "ereignis"
            }
          ]
        },
        500,
        event_id: "sfe-scope-threads-1"
      )
    )

    full = Repo.snapshot(%{"kind" => "campaign", "id" => @cid, "viewer_discord_id" => @owner})
    assert [t] = full["campaign_threads"]
    assert t["canonical"] == "der Plan"
    assert t["status"] == "offen"
    assert t["entities"] == ["König"]
    assert is_integer(t["fact_count"])
    refute Map.has_key?(t, "facts")
  end

  test "Nicht-Member → forbidden für jeden scoped Read" do
    for kind <-
          ~w(campaign_summaries campaign_chronik campaign_epos campaign_meta campaign_members campaign_threads) do
      assert scoped(kind, @stranger) == %{"forbidden" => true},
             "#{kind} sollte für Nicht-Member forbidden sein"
    end
  end
end
