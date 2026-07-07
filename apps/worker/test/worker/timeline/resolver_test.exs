defmodule Worker.Timeline.ResolverTest do
  @moduledoc "Issue #724 Slice A: Per-Fakt-Auflösung (Anker+Offset+Präzision)."
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Calendar, Resolver}

  defp cal, do: Calendar.default()
  defp anchor_day, do: Calendar.to_day(cal(), {1000, 6, 1})

  defp fact(attrs), do: Map.merge(%{"claim" => "c", "narration_time" => "present"}, attrs)

  describe "session-Anker" do
    test "Präsens-Fakt ohne Datum sitzt exakt am Session-Datum" do
      r = Resolver.resolve_one(fact(%{"time_anchor" => "session"}), cal(), anchor_day())
      assert r.in_game_day == anchor_day()
      assert r.anchor_status == :resolved
      assert r.precision == :day
      assert r.display == "1. Juni 1000"
    end

    test "negativer Jahres-Offset → Vergangenheit (Flashback)" do
      f =
        fact(%{
          "narration_time" => "flashback",
          "time_offset" => %{"value" => -10, "unit" => "year"},
          "precision" => "year"
        })

      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day < anchor_day()
      assert r.in_game_day == Calendar.to_day(cal(), {990, 6, 1})
      assert r.precision == :year
      assert r.display == "990"
    end

    test "positiver Offset (Prophezeiung) → Zukunft" do
      f =
        fact(%{
          "narration_time" => "future",
          "time_offset" => %{"value" => 100, "unit" => "year"}
        })

      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day > anchor_day()
    end

    test "Monatsüberlauf im Offset" do
      # Anker 1000-06-01 + 8 Monate = 1001-02-01
      f = fact(%{"time_anchor" => "session", "time_offset" => %{"value" => 8, "unit" => "month"}})
      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day == Calendar.to_day(cal(), {1001, 2, 1})
    end

    test "ohne Session-Anker → unknown" do
      r = Resolver.resolve_one(fact(%{"time_anchor" => "session"}), cal(), nil)
      assert r.in_game_day == nil
      assert r.anchor_status == :unknown
    end
  end

  describe "absolute Daten" do
    test "im Transkript genanntes Datum" do
      f =
        fact(%{
          "time_anchor" => "absolute",
          "time_absolute" => "20. März 1888",
          "precision" => "day"
        })

      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day == Calendar.to_day(cal(), {1888, 3, 20})
      assert r.display == "20. März 1888"
    end

    test "unparsebares absolutes Datum → unknown" do
      f = fact(%{"time_anchor" => "absolute", "time_absolute" => "irgendwann früher"})
      assert Resolver.resolve_one(f, cal(), anchor_day()).anchor_status == :unknown
    end
  end

  describe "Präzisions-Propagation" do
    test "Jahres-Offset gröbert eine feine Angabe hoch" do
      f =
        fact(%{
          "time_anchor" => "session",
          "time_offset" => %{"value" => -3, "unit" => "year"},
          "precision" => "day"
        })

      # day + year-Offset → effektiv year (nicht day).
      assert Resolver.resolve_one(f, cal(), anchor_day()).precision == :year
    end

    test "decade bleibt decade" do
      f = fact(%{"time_anchor" => "session", "precision" => "decade"})
      assert Resolver.resolve_one(f, cal(), anchor_day()).precision == :decade
    end

    test "nicht angegebene Präzision fällt auf :day (aufgelöst) statt :unknown" do
      f = fact(%{"time_anchor" => "session"})
      assert Resolver.resolve_one(f, cal(), anchor_day()).precision == :day
    end
  end

  describe "Event-Referenz (resolved_days)" do
    test "aufgelöstes Ziel + Offset" do
      target_day = Calendar.to_day(cal(), {1000, 1, 1})
      f = fact(%{"time_anchor" => "event:x", "time_offset" => %{"value" => 3, "unit" => "day"}})
      r = Resolver.resolve_one(f, cal(), anchor_day(), %{"x" => target_day})
      assert r.in_game_day == target_day + 3
    end

    test "unaufgelöstes/fehlendes Ziel → unknown" do
      f = fact(%{"time_anchor" => "event:missing"})
      assert Resolver.resolve_one(f, cal(), anchor_day(), %{}).anchor_status == :unknown
    end
  end

  describe "in_game_date-Fallback (#724 Slice E — Brücke zur #729-Extraktion)" do
    test "in_game_date dient als impliziter absoluter Datums-String" do
      f = fact(%{"in_game_date" => "1888-04-15"})
      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day == Calendar.to_day(cal(), {1888, 4, 15})
      assert r.precision == :day
    end

    test "bare Jahr → precision :year (kein falsches Tages-Rendering)" do
      r = Resolver.resolve_one(fact(%{"in_game_date" => "1850"}), cal(), anchor_day())
      assert r.precision == :year
      assert r.display == "1850"
    end

    test "explizites time_absolute hat Vorrang vor in_game_date" do
      f = fact(%{"time_absolute" => "1700", "in_game_date" => "1888"})
      r = Resolver.resolve_one(f, cal(), anchor_day())
      assert r.in_game_day == Calendar.to_day(cal(), {1700, 1, 1})
    end

    test "unparsebares in_game_date → unknown" do
      assert Resolver.resolve_one(fact(%{"in_game_date" => "Tag 5"}), cal(), anchor_day()).in_game_day ==
               nil
    end
  end

  describe "konservative Fälle" do
    test "vorhandenes aber kaputtes Offset → unknown (kein Anker-exakt-Fallback)" do
      f = fact(%{"time_anchor" => "session", "time_offset" => %{"value" => 5, "unit" => "äon"}})
      assert Resolver.resolve_one(f, cal(), anchor_day()).anchor_status == :unknown
    end

    test "Flashback ohne Anker/Offset → unknown (Sicherheitsventil)" do
      f = fact(%{"narration_time" => "flashback"})
      assert Resolver.resolve_one(f, cal(), anchor_day()).in_game_day == nil
    end
  end
end
