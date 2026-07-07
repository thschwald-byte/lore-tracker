defmodule Worker.MaterializerTimelineConfigTest do
  @moduledoc """
  Issue #724 Slice C: Config-Events CampaignCalendarSet + SessionInGameAnchorSet.
  Der Worker validiert/normalisiert den Kalender und löst den Session-Anker-Roh-
  String DETERMINISTISCH gegen den Campaign-Kalender auf.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Timeline.Calendar

  @cid "camp-tl-cfg"
  @sid "sess-tl-cfg"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
    :ok
  end

  defp anchor_ev(raw, seq),
    do:
      event(
        "SessionInGameAnchorSet",
        %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => raw},
        seq
      )

  describe "CampaignCalendarSet" do
    test "speichert kanonisch + Repo.get_campaign_calendar liest zurück" do
      fantasy =
        Calendar.from_json(%{
          "epoch_label" => "NZ",
          "months" => for(i <- 1..13, do: %{"name" => "Mond#{i}", "days" => 28})
        })

      ev =
        event(
          "CampaignCalendarSet",
          %{"campaign_id" => @cid, "calendar" => Calendar.to_json(fantasy), "set_by" => "gm"},
          1
        )

      assert {:applied, 1} = Materializer.apply_event(ev)
      assert Repo.get_campaign_calendar(@cid) == fantasy
    end

    test "kaputte Kalender-Struktur → Default gespeichert (Boundary-Defense)" do
      ev =
        event(
          "CampaignCalendarSet",
          %{"campaign_id" => @cid, "calendar" => %{"months" => []}},
          2
        )

      assert {:applied, 2} = Materializer.apply_event(ev)
      assert Repo.get_campaign_calendar(@cid) == Calendar.default()
    end
  end

  describe "SessionInGameAnchorSet" do
    test "parsebarer Roh-String → Tageszähler gegen den Default-Kalender aufgelöst" do
      assert {:applied, 1} = Materializer.apply_event(anchor_ev("15. Januar 1888", 1))

      expected = Calendar.to_day(Calendar.default(), {1888, 1, 15})
      assert Repo.get_session_anchor_day(@sid) == expected
    end

    test "gegen einen zuvor gesetzten Campaign-Kalender aufgelöst" do
      # Fantasy-Kalender (13×28) → Tag anders als gregorianisch.
      fantasy =
        Calendar.from_json(%{
          "months" => for(i <- 1..13, do: %{"name" => "Mond#{i}", "days" => 28})
        })

      Materializer.apply_event(
        event(
          "CampaignCalendarSet",
          %{"campaign_id" => @cid, "calendar" => Calendar.to_json(fantasy)},
          1
        )
      )

      assert {:applied, 2} = Materializer.apply_event(anchor_ev("500-03-01", 2))
      assert Repo.get_session_anchor_day(@sid) == Calendar.to_day(fantasy, {500, 3, 1})
    end

    test "unparsebarer Roh-String → day nil, Roh-String bewahrt" do
      assert {:applied, 1} = Materializer.apply_event(anchor_ev("irgendwann damals", 1))

      assert Repo.get_session_anchor_day(@sid) == nil
      row = :mnesia.dirty_read(S.session_anchors(), @sid) |> List.first()
      # {tbl, session_id, campaign_id, in_game_day, in_game_date_raw}
      assert elem(row, 3) == nil
      assert elem(row, 4) == "irgendwann damals"
    end

    test "leerer Roh-String → Anker gelöscht (unset)" do
      Materializer.apply_event(anchor_ev("1500-01-01", 1))
      assert Repo.get_session_anchor_day(@sid) != nil

      assert {:applied, 2} = Materializer.apply_event(anchor_ev("  ", 2))
      assert Repo.get_session_anchor_day(@sid) == nil
      assert :mnesia.dirty_read(S.session_anchors(), @sid) == []
    end
  end
end
