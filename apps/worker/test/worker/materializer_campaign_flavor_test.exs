defmodule Worker.MaterializerCampaignFlavorTest do
  @moduledoc """
  Smoke-Tests für `CampaignFlavorSet` mit slot-aware Map-Schema:
  - Backward-Compat (slot fehlt → "base")
  - mehrere Slots koexistieren
  - flavor=nil entfernt den Slot
  - unbekannter slot wird ignoriert
  - unbekannte campaign_id wird ignoriert
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-flavor-test"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write!(Builder.campaign(@cid, name: "Test Campaign"))

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp current_flavors do
    [{_, _, _, _, _, _, _, flavors, _, _}] = :mnesia.dirty_read(S.campaigns(), @cid)
    flavors
  end

  test "backward-compat: ohne slot landet flavor in base" do
    ev =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "flavor" => "Düster", "edited_by" => "x"},
        400
      )

    assert {:applied, 400} = Materializer.apply_event(ev)

    assert current_flavors() == %{"base" => "Düster"}
  end

  test "setzt mehrere Slots, lässt unangetastete unverändert" do
    ev1 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "base", "flavor" => "Tatooine", "edited_by" => "x"},
        500
      )

    ev2 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "epos", "flavor" => "Skalde", "edited_by" => "x"},
        501
      )

    assert {:applied, 500} = Materializer.apply_event(ev1)
    assert {:applied, 501} = Materializer.apply_event(ev2)

    assert current_flavors() == %{"base" => "Tatooine", "epos" => "Skalde"}
  end

  test "slot=nil entfernt den Key aus der Map" do
    ev1 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "summary", "flavor" => "Reporter", "edited_by" => "x"},
        600
      )

    ev2 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "summary", "flavor" => nil, "edited_by" => "x"},
        601
      )

    assert {:applied, 600} = Materializer.apply_event(ev1)
    assert current_flavors() == %{"summary" => "Reporter"}

    assert {:applied, 601} = Materializer.apply_event(ev2)
    assert current_flavors() == %{}
  end

  test "leerer string entfernt den Slot (gleich wie nil)" do
    ev1 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "chronik", "flavor" => "X", "edited_by" => "x"},
        700
      )

    ev2 =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "chronik", "flavor" => "   ", "edited_by" => "x"},
        701
      )

    assert {:applied, 700} = Materializer.apply_event(ev1)
    assert {:applied, 701} = Materializer.apply_event(ev2)
    assert current_flavors() == %{}
  end

  test "unbekannter slot wird ignoriert, keine Mutation" do
    ev =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => @cid, "slot" => "bogus", "flavor" => "x", "edited_by" => "y"},
        800
      )

    assert {:applied, 800} = Materializer.apply_event(ev)
    assert current_flavors() == %{}
  end

  test "unbekannte campaign_id wird ignoriert" do
    ev =
      event(
        "CampaignFlavorSet",
        %{"campaign_id" => "unknown", "slot" => "base", "flavor" => "x", "edited_by" => "y"},
        900
      )

    assert {:applied, 900} = Materializer.apply_event(ev)
  end
end
