defmodule Worker.RepoTimelinePersistenceTest do
  @moduledoc """
  Issue #724 Slice B: Persistenz + Sort-Cutover.

  - `get_campaign_calendar/1` (eigene Tabelle, Default bei Miss),
  - `get_session_anchor_day/1` (eigene Tabelle, nil bei Miss),
  - `list_chronik_entries/1` Sort-Cutover: Familie 0 (echter Tageszähler) NUR bei
    integer `in_game_day`, sonst Familie 1 = bestehendes #650-Verhalten →
    null Regression solange alle Rows nil-day sind.
  - `ChronikEntryChanged`-Apply schreibt in_game_day/precision (11-Tupel).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Timeline.Calendar

  @cid "camp-timeline-b"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
    :ok
  end

  describe "get_campaign_calendar/1" do
    test "fehlende Row → Calendar.default/0" do
      assert Repo.get_campaign_calendar("gibt-es-nicht") == Calendar.default()
    end

    test "gespeicherter Kalender wird geparst (Round-Trip)" do
      fantasy =
        Calendar.from_json(%{
          "epoch_label" => "NZ",
          "months" => for(i <- 1..13, do: %{"name" => "Mond#{i}", "days" => 28})
        })

      Builder.write!(
        {S.campaign_calendars(), @cid, Jason.encode!(Calendar.to_json(fantasy)),
         DateTime.utc_now()}
      )

      assert Repo.get_campaign_calendar(@cid) == fantasy
    end

    test "kaputtes JSON → Default (Boundary-Defense, kein Crash)" do
      Builder.write!({S.campaign_calendars(), @cid, "{kaputt", DateTime.utc_now()})
      assert Repo.get_campaign_calendar(@cid) == Calendar.default()
    end
  end

  describe "get_session_anchor_day/1" do
    test "fehlende Row → nil" do
      assert Repo.get_session_anchor_day("keine-session") == nil
    end

    test "gesetzter Anker → Tageszähler" do
      Builder.write!({S.session_anchors(), "sess-x", @cid, 3650, "10. Jahr"})
      assert Repo.get_session_anchor_day("sess-x") == 3650
    end
  end

  describe "list_chronik_entries/1 Sort-Cutover (#724)" do
    setup do
      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session("s1", @cid, number: 1))
      Builder.write!(Builder.session("s2", @cid, number: 2))
      :ok
    end

    test "integer in_game_day (Familie 0) steht global chronologisch vor nil-day (Familie 1)" do
      # Flashback (day 50) < Session-Gegenwart (day 100), beide vor den
      # undatierten :chain-Einträgen.
      Builder.write!(Builder.chronik_entry("day-100", @cid, in_game_day: 100, session_id: "s1"))
      Builder.write!(Builder.chronik_entry("day-50", @cid, in_game_day: 50, session_id: "s2"))

      Builder.write!(
        Builder.chronik_entry("chain-s2", @cid,
          in_game_day: nil,
          session_id: "s2",
          in_game_date: "Tag 1"
        )
      )

      Builder.write!(
        Builder.chronik_entry("chain-s1", @cid,
          in_game_day: nil,
          session_id: "s1",
          in_game_date: "Tag 1"
        )
      )

      ids = @cid |> Repo.list_chronik_entries() |> Enum.map(& &1.id)

      assert ids == ["day-50", "day-100", "chain-s1", "chain-s2"]
    end

    test "alle nil-day → exakt das bestehende #650-Verhalten (Session-Reihenfolge)" do
      # Kein Eintrag hat in_game_day → Familie 1 für alle → Sortierung wie vor
      # #724 (Session-Nummer, dann Freitext-Datum). Null Regression.
      Builder.write!(Builder.chronik_entry("b", @cid, session_id: "s2", in_game_date: "Tag 1"))
      Builder.write!(Builder.chronik_entry("a", @cid, session_id: "s1", in_game_date: "Tag 9"))

      ids = @cid |> Repo.list_chronik_entries() |> Enum.map(& &1.id)

      # s1 (number 1) vor s2 (number 2), unabhängig vom Freitext-Datum.
      assert ids == ["a", "b"]
    end

    test "in_game_day + precision werden im Map-Result durchgereicht" do
      Builder.write!(Builder.chronik_entry("p", @cid, in_game_day: 42, precision: "year"))
      [entry] = Repo.list_chronik_entries(@cid)
      assert entry.in_game_day == 42
      assert entry.precision == "year"
    end
  end

  describe "ChronikEntryChanged-Apply (#724 Trailing-Felder)" do
    test "schreibt in_game_day + precision (11-Tupel), BC-nil ohne die Keys" do
      with_fields =
        event(
          "ChronikEntryChanged",
          %{
            "id" => "e-day",
            "campaign_id" => @cid,
            "in_game_date" => "552 CY",
            "label" => "L",
            "summary" => "S",
            "session_id" => "s1",
            "source_refs" => [],
            "in_game_day" => 201_480,
            "precision" => "day"
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(with_fields)

      row = :mnesia.dirty_read(S.chronik_entries(), "e-day") |> List.first()
      assert tuple_size(row) == 12
      assert elem(row, 9) == 201_480
      assert elem(row, 10) == "day"

      # Event ohne die Keys → nil (Backward-Compat, :chain-Pfad).
      bc =
        event(
          "ChronikEntryChanged",
          %{
            "id" => "e-bc",
            "campaign_id" => @cid,
            "in_game_date" => "Tag 1",
            "label" => "L",
            "summary" => "S",
            "session_id" => "s1",
            "source_refs" => []
          },
          2
        )

      assert {:applied, 2} = Materializer.apply_event(bc)
      bc_row = :mnesia.dirty_read(S.chronik_entries(), "e-bc") |> List.first()
      assert elem(bc_row, 9) == nil
      assert elem(bc_row, 10) == nil
    end
  end
end
