defmodule Worker.Timeline.CalendarTest do
  @moduledoc "Issue #724 Slice A: reines Kalender-Primitiv."
  use ExUnit.Case, async: true

  alias Worker.Timeline.Calendar

  defp greg, do: Calendar.default()
  # 13 Monate à 28 Tage (Fantasy) — testet Nicht-Gregorian.
  defp fantasy do
    Calendar.from_json(%{
      "epoch_label" => "NZ",
      "months" => for(i <- 1..13, do: %{"name" => "Mond#{i}", "days" => 28})
    })
  end

  describe "year_length / months_per_year" do
    test "gregorian = 365 Tage, 12 Monate" do
      assert Calendar.year_length(greg()) == 365
      assert Calendar.months_per_year(greg()) == 12
    end

    test "fantasy = 364 Tage, 13 Monate" do
      assert Calendar.year_length(fantasy()) == 364
      assert Calendar.months_per_year(fantasy()) == 13
    end
  end

  describe "to_day / from_day Round-Trip" do
    test "bekannte Ankerpunkte" do
      cal = greg()
      assert Calendar.to_day(cal, {0, 1, 1}) == 0
      assert Calendar.to_day(cal, {0, 1, 2}) == 1
      assert Calendar.to_day(cal, {0, 2, 1}) == 31
      assert Calendar.to_day(cal, {1, 1, 1}) == 365
      assert Calendar.to_day(cal, {1888, 4, 15}) == 1888 * 365 + 90 + 14
    end

    test "from_day ist exakte Inverse über Monats- und Jahresgrenzen (auch negativ)" do
      cal = greg()

      # Dichter Scan über Tage inkl. negativer (vor der Epoche = Flashback-Raum).
      for day <- -5000..5000//7 do
        ymd = Calendar.from_day(cal, day)

        assert Calendar.to_day(cal, ymd) == day,
               "Round-Trip brach bei day=#{day} (#{inspect(ymd)})"
      end
    end

    test "Round-Trip auch im Fantasy-Kalender" do
      cal = fantasy()

      for day <- -3000..3000//11 do
        assert Calendar.to_day(cal, Calendar.from_day(cal, day)) == day
      end
    end

    test "negativer Tag liegt vor Jahr 0" do
      cal = greg()
      # -1 = letzter Tag des Jahres -1 = 31. Dezember -1
      assert Calendar.from_day(cal, -1) == {-1, 12, 31}
    end
  end

  describe "shift" do
    test ":day / :week rechnen über den Tageszähler" do
      cal = greg()
      assert Calendar.shift(cal, {1888, 4, 15}, 10, :day) == {1888, 4, 25}
      assert Calendar.shift(cal, {1888, 4, 15}, 1, :week) == {1888, 4, 22}
      assert Calendar.shift(cal, {1888, 1, 1}, -1, :day) == {1887, 12, 31}
    end

    test ":month klemmt den Tag an die Monatslänge (31. Jan + 1 Monat → 28. Feb)" do
      cal = greg()
      assert Calendar.shift(cal, {2020, 1, 31}, 1, :month) == {2020, 2, 28}
    end

    test ":month über Jahresgrenze" do
      cal = greg()
      assert Calendar.shift(cal, {1888, 12, 10}, 2, :month) == {1889, 2, 10}
      assert Calendar.shift(cal, {1888, 2, 10}, -3, :month) == {1887, 11, 10}
    end

    test ":year verschiebt nur das Jahr" do
      cal = greg()
      assert Calendar.shift(cal, {1888, 4, 15}, -10, :year) == {1878, 4, 15}
    end
  end

  describe "format" do
    setup do
      cal = greg()
      %{cal: cal, day: Calendar.to_day(cal, {1888, 4, 15})}
    end

    test "pro Präzision", %{cal: cal, day: day} do
      assert Calendar.format(cal, day, :day) == "15. April 1888"
      assert Calendar.format(cal, day, :month) == "April 1888"
      assert Calendar.format(cal, day, :season) == "Frühling 1888"
      assert Calendar.format(cal, day, :year) == "1888"
      assert Calendar.format(cal, day, :decade) == "1880er"
      assert Calendar.format(cal, day, :unknown) == "unbestimmt"
    end

    test "nil-Tag → unbestimmt", %{cal: cal} do
      assert Calendar.format(cal, nil, :day) == "unbestimmt"
    end

    test "epoch_label wird angehängt" do
      cal =
        Calendar.from_json(%{
          "epoch_label" => "n.Chr.",
          "months" => Calendar.to_json(greg())["months"]
        })

      day = Calendar.to_day(cal, {1888, 4, 15})
      assert Calendar.format(cal, day, :year) == "1888 n.Chr."
      assert Calendar.format(cal, day, :day) == "15. April 1888 n.Chr."
    end

    test "season fällt bei Nicht-12-Monats-Kalender auf Jahr zurück" do
      cal = fantasy()
      day = Calendar.to_day(cal, {500, 3, 1})
      assert Calendar.format(cal, day, :season) == "500 NZ"
    end
  end

  describe "parse" do
    test "ISO / DMY / Monatsname / nur Jahr" do
      cal = greg()
      assert Calendar.parse(cal, "1888-04-15") == {:ok, {1888, 4, 15}}
      assert Calendar.parse(cal, "15.04.1888") == {:ok, {1888, 4, 15}}
      assert Calendar.parse(cal, "15.4.1888") == {:ok, {1888, 4, 15}}
      assert Calendar.parse(cal, "15. Januar 1888") == {:ok, {1888, 1, 15}}
      assert Calendar.parse(cal, "  1888  ") == {:ok, {1888, 1, 1}}
    end

    test "ungültige/leere Eingaben → :error (kein erfundenes Datum)" do
      cal = greg()
      assert Calendar.parse(cal, "irgendwann") == :error
      assert Calendar.parse(cal, "1888-13-01") == :error
      assert Calendar.parse(cal, "1888-02-30") == :error
      assert Calendar.parse(cal, "") == :error
    end

    test "parse → to_day → from_day → parse ist konsistent" do
      cal = greg()
      {:ok, ymd} = Calendar.parse(cal, "1888-04-15")
      assert Calendar.from_day(cal, Calendar.to_day(cal, ymd)) == ymd
    end
  end

  describe "from_json / to_json" do
    test "Round-Trip" do
      cal = fantasy()
      assert Calendar.from_json(Calendar.to_json(cal)) == cal
    end

    test "kaputte/fehlende Struktur → default (Boundary-Defense)" do
      assert Calendar.from_json(nil) == Calendar.default()
      assert Calendar.from_json(%{}) == Calendar.default()
      assert Calendar.from_json(%{"months" => []}) == Calendar.default()

      assert Calendar.from_json(%{"months" => [%{"name" => "X", "days" => 0}]}) ==
               Calendar.default()

      assert Calendar.from_json(%{"months" => [%{"name" => "X"}]}) == Calendar.default()
    end
  end
end
