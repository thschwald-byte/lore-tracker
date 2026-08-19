defmodule Worker.RepoTimelinePersistenceTest do
  @moduledoc """
  Issue #724 Slice B: Persistenz + Sort-Cutover.

  - `get_campaign_calendar/1` (eigene Tabelle, Default bei Miss),
  - `get_session_anchor_day/1` (eigene Tabelle, nil bei Miss),
  - `list_chronik_entries/1` Sort-Cutover: Familie 0 (echter Tageszähler) NUR bei
    integer `in_game_day`, sonst Familie 1 = bestehendes #650-Verhalten →
    null Regression solange alle Rows nil-day sind.
  - `ChronikEntryChanged`-Apply schreibt in_game_day/precision/source_pos
    (13-Tupel seit #1092).
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
      Builder.write!(
        Builder.session_anchor("sess-x", @cid, in_game_day: 3650, in_game_date_raw: "10. Jahr")
      )

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

  describe "Ordnung innerhalb eines Tages (#1092)" do
    setup do
      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session("s1", @cid, number: 1))
      Builder.write!(Builder.session("s2", @cid, number: 2))
      :ok
    end

    test "gleicher Tag → Quell-Position entscheidet, nicht die Tabellen-Leseordnung" do
      # Der reale Fall: „Real Free Seattle" hatte 543 von 544 Einträgen auf
      # DEMSELBEN Tag. Vor #1092 trugen die alle den Schlüssel `{0, day, ""}`,
      # und weil `Enum.sort_by/2` stabil ist, blieb darunter die Leseordnung
      # einer `:set`-Tabelle stehen — gemessene 0,49 aufsteigende Nachbarpaare.
      for {id, pos} <- [{"c", 30}, {"a", 10}, {"d", 40}, {"b", 20}] do
        Builder.write!(
          Builder.chronik_entry(id, @cid, in_game_day: 100, session_id: "s1", source_pos: pos)
        )
      end

      assert Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) == ["a", "b", "c", "d"]
    end

    test "Tag schlägt Quell-Position — Rückblenden bleiben vorn" do
      # Erzählreihenfolge ist NICHT erzählte Zeit. Ein spät erzählter
      # Flashback gehört trotzdem an seinen Tag.
      Builder.write!(
        Builder.chronik_entry("spaet-erzaehlt", @cid,
          in_game_day: 50,
          session_id: "s1",
          source_pos: 900
        )
      )

      Builder.write!(
        Builder.chronik_entry("frueh-erzaehlt", @cid,
          in_game_day: 100,
          session_id: "s1",
          source_pos: 1
        )
      )

      assert Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) ==
               ["spaet-erzaehlt", "frueh-erzaehlt"]
    end

    test "Session-Nummer ordnet vor der Quell-Position — Positionen sind session-lokal" do
      # `source_pos` ist der Index IM Transkript der jeweiligen Session; über
      # Sessions hinweg ist er nicht vergleichbar. Ohne die Session-Nummer
      # davor würde Session 2 vor Session 1 einsortiert.
      Builder.write!(
        Builder.chronik_entry("s2-frueh", @cid, in_game_day: 100, session_id: "s2", source_pos: 1)
      )

      Builder.write!(
        Builder.chronik_entry("s1-spaet", @cid,
          in_game_day: 100,
          session_id: "s1",
          source_pos: 500
        )
      )

      assert Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) == ["s1-spaet", "s2-frueh"]
    end

    test "Alt-Einträge ohne Quell-Position landen am Ende ihres Tages (Regenerate-Mischfall)" do
      # Nach einem Regenerate mischen sich befüllte und unbefüllte Einträge.
      # Die unbefüllten gehören ans Ende — über ihre Position weiß man am
      # wenigsten. (Elixirs Term-Ordnung täte das auch von selbst; `sort_pos/1`
      # macht es zur Entscheidung statt zur Nebenwirkung.)
      Builder.write!(
        Builder.chronik_entry("alt", @cid, in_game_day: 100, session_id: "s1", source_pos: nil)
      )

      Builder.write!(
        Builder.chronik_entry("neu", @cid, in_game_day: 100, session_id: "s1", source_pos: 7)
      )

      assert Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) == ["neu", "alt"]
    end

    test "Reihenfolge hängt nicht an der Einfüge-Reihenfolge der Tabelle" do
      # Zwei verschieden befüllte Tabellen müssen dieselbe Chronik liefern —
      # sonst zeigen zwei Worker derselben Kampagne verschiedene Reihenfolgen.
      ids = ["e1", "e2", "e3", "e4", "e5"]
      positionen = Map.new(Enum.with_index(ids), fn {id, i} -> {id, i * 10} end)

      write = fn reihenfolge ->
        {:atomic, :ok} = :mnesia.clear_table(S.chronik_entries())

        for id <- reihenfolge do
          Builder.write!(
            Builder.chronik_entry(id, @cid,
              in_game_day: 100,
              session_id: "s1",
              source_pos: positionen[id]
            )
          )
        end

        Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id)
      end

      assert write.(ids) == write.(Enum.reverse(ids))
      assert write.(ids) == ids
    end
  end

  describe "Quell-Position stammt wirklich aus dem Transkript (#1092)" do
    test "Blockpositionen stimmen mit der Zeitachse der Utterances überein" do
      # Der Test gegen die Tautologie: die Chronik nach `source_pos` zu
      # sortieren und dann zu prüfen, dass sie nach `source_pos` sortiert ist,
      # wäre auch bei falscher BEFÜLLUNG grün. Deshalb wird hier gegen eine
      # ANDERE Datenquelle geprüft — die Zeitstempel der Quell-Utterances.
      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session("s-pos", @cid, number: 1))

      basis = ~U[2026-08-19 20:00:00Z]

      # Utterances in echter zeitlicher Reihenfolge.
      for {uid, minute} <- [{"u-a", 0}, {"u-b", 5}, {"u-c", 11}, {"u-d", 17}] do
        Builder.write!(
          Builder.utterance(uid, "s-pos", timestamp: DateTime.add(basis, minute * 60, :second))
        )
      end

      blocks = [
        %{"id" => "b-1", "text" => "erst", "quell_utterance_ids" => ["u-a"]},
        %{"id" => "b-2", "text" => "dann", "quell_utterance_ids" => ["u-b", "u-c"]},
        %{"id" => "b-3", "text" => "zuletzt", "quell_utterance_ids" => ["u-d"]}
      ]

      Builder.write!(
        {S.smoothed_blocks(), "s-pos", @cid,
         Jason.encode!(%{"blocks" => blocks, "rules_version" => 1}), DateTime.utc_now(), "ev-1"}
      )

      positionen = Worker.Recording.Pipeline.block_positions("s-pos")

      # Nach Position sortierte Blöcke → deren früheste Utterance-Zeitstempel
      # müssen aufsteigen. Wäre die Positionsableitung falsch (etwa Map-
      # Reihenfolge statt Listen-Index), bräche genau das.
      zeiten =
        blocks
        |> Enum.sort_by(&Map.fetch!(positionen, &1["id"]))
        |> Enum.map(fn b ->
          b["quell_utterance_ids"]
          |> Enum.map(fn uid ->
            [{_, _, _, _, ts, _, _, _, _}] = :mnesia.dirty_read(S.utterances(), uid)
            ts
          end)
          |> Enum.min(DateTime)
        end)

      assert zeiten == Enum.sort(zeiten, DateTime)
      assert positionen == %{"b-1" => 0, "b-2" => 1, "b-3" => 2}
    end

    test "ein Fakt über mehrere Blöcke zählt ab seinem FRÜHESTEN" do
      # Ein Fakt entsteht dort, wo er im Gespräch zu entstehen beginnt.
      alias Worker.Recording.Pipeline.Render

      assert Render.earliest_source_pos(["b-9", "b-2", "b-7"], %{
               "b-2" => 2,
               "b-7" => 7,
               "b-9" => 9
             }) == 2

      # Unbekannte Referenzen zählen nicht mit …
      assert Render.earliest_source_pos(["b-weg", "b-7"], %{"b-7" => 7}) == 7
      # … und wenn KEINE zuzuordnen ist, gibt es keine Position (statt einer
      # erfundenen 0, die den Eintrag an den Tagesanfang setzen würde).
      assert Render.earliest_source_pos(["b-weg"], %{"b-7" => 7}) == nil
      assert Render.earliest_source_pos([], %{"b-7" => 7}) == nil
    end
  end

  describe "Anker-Präzision (#1092)" do
    test "Jahres-Anker macht keine taggenauen Fakten" do
      # Real: für „Real Free Seattle" wurde „2081" als Anker eingetragen und
      # daraus der 1. Januar 2081 — jeder Fakt daran erschien taggenau.
      cal = Calendar.default()
      day = Calendar.to_day(cal, {2081, 1, 1})

      fakt = %{"claim" => "x", "narration_time" => "present"}

      # Ohne Ankerpräzision (Alt-Anker vor der Migration): Verhalten wie bisher.
      assert %{precision: :day} = Worker.Timeline.Resolver.resolve_one(fakt, cal, day, %{}, nil)

      # Mit Jahres-Anker: der Fakt kann nicht genauer sein als sein Anker.
      assert %{precision: :year} =
               Worker.Timeline.Resolver.resolve_one(fakt, cal, day, %{}, "year")

      assert %{display: "2081"} =
               Worker.Timeline.Resolver.resolve_one(fakt, cal, day, %{}, "year")
    end

    test "der Anker vergröbert nur, er verfeinert nie" do
      cal = Calendar.default()
      day = Calendar.to_day(cal, {2081, 1, 1})

      # Fakt ist selbst nur jahresgenau, Anker ist taggenau → bleibt Jahr.
      fakt = %{"claim" => "x", "narration_time" => "present", "precision" => "year"}

      assert %{precision: :year} =
               Worker.Timeline.Resolver.resolve_one(fakt, cal, day, %{}, "day")
    end
  end

  describe "ChronikEntryChanged-Apply (#724 Trailing-Felder)" do
    test "schreibt in_game_day + precision + source_pos (13-Tupel), BC-nil ohne die Keys" do
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
            "precision" => "day",
            "source_pos" => 17
          },
          1
        )

      assert {:applied, 1} = Materializer.apply_event(with_fields)

      row = :mnesia.dirty_read(S.chronik_entries(), "e-day") |> List.first()
      assert tuple_size(row) == 13
      assert elem(row, 9) == 201_480
      assert elem(row, 10) == "day"
      # Issue #1092: source_pos trailing (Index 12, hinter generation).
      assert elem(row, 12) == 17

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
      assert elem(bc_row, 12) == nil
    end
  end
end
