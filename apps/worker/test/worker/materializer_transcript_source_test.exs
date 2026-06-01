defmodule Worker.MaterializerTranscriptSourceTest do
  @moduledoc """
  Issue #394: `CampaignTranscriptSourceUpdated` setzt die per-Kampagne
  Pipeline-Quelle (:confirmed | :live). Default ist :confirmed.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Builder

  @cid "camp-transcript-source-test"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    mat_pid = ensure_materializer!()
    Builder.write_many!([Builder.campaign(@cid, name: "Quelle-Test")])

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "Default ist :confirmed" do
    assert Repo.get_campaign(@cid).transcript_source == :confirmed
  end

  test "auf :live setzen" do
    ev =
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => @cid, "transcript_source" => "live"},
        100
      )

    assert {:applied, 100} = Materializer.apply_event(ev)
    assert Repo.get_campaign(@cid).transcript_source == :live
  end

  test "zurück auf :confirmed" do
    Materializer.apply_event(
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => @cid, "transcript_source" => "live"},
        110
      )
    )

    Materializer.apply_event(
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => @cid, "transcript_source" => "confirmed"},
        111
      )
    )

    assert Repo.get_campaign(@cid).transcript_source == :confirmed
  end

  test "invalider Wert → :confirmed" do
    Materializer.apply_event(
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => @cid, "transcript_source" => "junk"},
        120
      )
    )

    assert Repo.get_campaign(@cid).transcript_source == :confirmed
  end

  test "andere Campaign-Felder bleiben unverändert" do
    Materializer.apply_event(
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => @cid, "transcript_source" => "live"},
        130
      )
    )

    c = Repo.get_campaign(@cid)
    assert c.name == "Quelle-Test"
    assert c.transcript_source == :live
  end

  test "unbekannte Campaign wird ignoriert" do
    ev =
      event(
        "CampaignTranscriptSourceUpdated",
        %{"campaign_id" => "ghost", "transcript_source" => "live"},
        140
      )

    assert {:applied, 140} = Materializer.apply_event(ev)
    assert Repo.get_campaign("ghost") == nil
  end
end
