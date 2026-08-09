defmodule HubWeb.DashboardCampaignsMergeTest do
  @moduledoc """
  Issue #981: reine Merge-Logik für die Multi-Worker-Kampagnenliste — Dedupe
  nach Campaign-ID, Users-Merge, viewer_role-Auswahl. Keine Worker/Reader
  nötig (pure Funktion).
  """

  use ExUnit.Case, async: true

  alias HubWeb.DashboardLive

  test "campaigns aus mehreren Snapshots werden vereinigt" do
    snaps = [
      %{"campaigns" => [%{"id" => "c1"}], "users" => %{}, "viewer_role" => "spieler"},
      %{"campaigns" => [%{"id" => "c2"}], "users" => %{}, "viewer_role" => "spieler"}
    ]

    merged = DashboardLive.merge_campaign_snapshots(snaps)
    assert Enum.map(merged["campaigns"], & &1["id"]) |> Enum.sort() == ["c1", "c2"]
  end

  test "dieselbe Campaign-ID von zwei Workern -> dedupe, erstes Vorkommen gewinnt" do
    snaps = [
      %{"campaigns" => [%{"id" => "c1", "name" => "A"}], "users" => %{}, "viewer_role" => "spieler"},
      %{"campaigns" => [%{"id" => "c1", "name" => "A (Kopie)"}], "users" => %{}, "viewer_role" => "spieler"}
    ]

    merged = DashboardLive.merge_campaign_snapshots(snaps)
    assert [%{"id" => "c1", "name" => "A"}] = merged["campaigns"]
  end

  test "users-Maps werden über alle Snapshots gemergt" do
    snaps = [
      %{"campaigns" => [], "users" => %{"did-1" => %{"name" => "A"}}, "viewer_role" => "spieler"},
      %{"campaigns" => [], "users" => %{"did-2" => %{"name" => "B"}}, "viewer_role" => "spieler"}
    ]

    merged = DashboardLive.merge_campaign_snapshots(snaps)
    assert merged["users"] == %{"did-1" => %{"name" => "A"}, "did-2" => %{"name" => "B"}}
  end

  test "viewer_role: erstes nicht-leeres Vorkommen gewinnt (globale Rolle, sollte ohnehin identisch sein)" do
    snaps = [
      %{"campaigns" => [], "users" => %{}, "viewer_role" => nil},
      %{"campaigns" => [], "users" => %{}, "viewer_role" => "admin"}
    ]

    assert DashboardLive.merge_campaign_snapshots(snaps)["viewer_role"] == "admin"
  end

  test "leere Snapshot-Liste -> leeres Ergebnis, kein Crash" do
    assert DashboardLive.merge_campaign_snapshots([]) == %{
             "campaigns" => [],
             "users" => %{},
             "viewer_role" => nil
           }
  end
end
