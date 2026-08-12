defmodule Worker.Discord.ConsentStateTest do
  @moduledoc """
  Issue #1005: die Invariante dieses Features, als Test.

  > Kein Frame außerhalb eines Grant-Intervalls darf gespeichert werden.

  Das ist die technische Fassung der Kernentscheidung „die Einwilligung wirkt nur
  nach vorn". Ein früherer Entwurf hatte einen einzelnen `since_ms`-Zeitstempel —
  der verliert beim Grant→Revoke→Re-Grant das erste Intervall. Deshalb rechnet
  das Modul auf der Übergangs-Historie, und deshalb prüfen die Tests unten genau
  diese Fälle.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentState

  defp frames(times), do: Enum.map(times, &%{opus: "f#{&1}", arrival_ms: &1})
  defp times(frames), do: Enum.map(frames, & &1.arrival_ms)

  describe "ohne Einwilligung" do
    test "nichts wird behalten" do
      assert ConsentState.keepable_frames(frames([0, 100, 500]), ConsentState.new()) == []
    end

    test "ein Widerruf ohne vorherige Zustimmung ist ein No-op (nichts war gedeckt)" do
      h = ConsentState.new() |> ConsentState.put(:revoked, 50)
      assert ConsentState.granted_intervals(h) == []
      assert ConsentState.keepable_frames(frames([0, 100]), h) == []
    end
  end

  describe "vorbestehende (persistierte) Einwilligung" do
    test "deckt die ganze Session ab — Aufnahme startet sofort" do
      h = ConsentState.new(true)
      assert ConsentState.granted_intervals(h) == [{0, :infinity}]
      assert times(ConsentState.keepable_frames(frames([0, 100, 9999]), h)) == [0, 100, 9999]
    end

    test "ein Widerruf mitten in der Session schneidet ab dort ab" do
      h = ConsentState.new(true) |> ConsentState.put(:revoked, 500)

      assert ConsentState.granted_intervals(h) == [{0, 500}]
      # Der GEDECKTE Teil bleibt erhalten (das ist die Intervall-Semantik) —
      # der Widerruf vernichtet nicht rückwirkend, was eingewilligt war.
      assert times(ConsentState.keepable_frames(frames([0, 200, 499, 500, 900]), h)) ==
               [0, 200, 499]
    end
  end

  describe "Zustimmung mitten in der Session (der Late-Joiner-Fall)" do
    test "nur ab dem Klick, nichts davor" do
      h = ConsentState.new() |> ConsentState.put(:granted, 300)

      assert ConsentState.granted_intervals(h) == [{300, :infinity}]
      assert times(ConsentState.keepable_frames(frames([0, 299, 300, 301, 5000]), h)) ==
               [300, 301, 5000]
    end

    test "Grenzsemantik: Grant-Beginn inklusiv, Widerruf exklusiv" do
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 100)
        |> ConsentState.put(:revoked, 200)

      kept = times(ConsentState.keepable_frames(frames([99, 100, 199, 200, 201]), h))
      assert kept == [100, 199]
    end
  end

  describe "Grant → Revoke → Re-Grant (der Fall, der eine einzelne Grenze bricht)" do
    test "BEIDE Intervalle bleiben gedeckt, die Lücke dazwischen nicht" do
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 100)
        |> ConsentState.put(:revoked, 200)
        |> ConsentState.put(:granted, 400)

      assert ConsentState.granted_intervals(h) == [{100, 200}, {400, :infinity}]

      kept = times(ConsentState.keepable_frames(frames([50, 100, 150, 250, 399, 400, 500]), h))
      assert kept == [100, 150, 400, 500]
    end

    test "mehrfacher Wechsel bleibt konsistent" do
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 10)
        |> ConsentState.put(:revoked, 20)
        |> ConsentState.put(:granted, 30)
        |> ConsentState.put(:revoked, 40)

      assert ConsentState.granted_intervals(h) == [{10, 20}, {30, 40}]
      assert times(ConsentState.keepable_frames(frames([5, 15, 25, 35, 45]), h)) == [15, 35]
    end
  end

  describe "Robustheit gegen Doppel- und Spät-Zustellung" do
    test "Doppelklick verlängert kein Intervall künstlich und verliert nichts" do
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 100)
        |> ConsentState.put(:granted, 300)

      # Der zweite Grant ist ein No-op — sonst begänne das Intervall erst bei 300
      # und die Frames 100–299 wären trotz gültiger Einwilligung verworfen.
      assert ConsentState.granted_intervals(h) == [{100, :infinity}]
      assert times(ConsentState.keepable_frames(frames([100, 200]), h)) == [100, 200]
    end

    test "doppelter Widerruf ist ebenfalls ein No-op" do
      h =
        ConsentState.new(true)
        |> ConsentState.put(:revoked, 100)
        |> ConsentState.put(:revoked, 300)

      assert ConsentState.granted_intervals(h) == [{0, 100}]
    end

    test "verspätet zugestellter Übergang wird chronologisch einsortiert" do
      # Der Revoke bei 200 trifft NACH dem Grant bei 400 ein.
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 100)
        |> ConsentState.put(:granted, 400)
        |> ConsentState.put(:revoked, 200)

      assert ConsentState.granted_intervals(h) == [{100, 200}, {400, :infinity}]
    end
  end

  describe "Eingabe-Robustheit (fail-closed)" do
    test "Frames ohne arrival_ms fallen raus, statt zu crashen" do
      h = ConsentState.new(true)
      frames = [%{opus: "a"}, %{opus: "b", arrival_ms: 10}, %{opus: "c", arrival_ms: nil}]

      assert times(ConsentState.keepable_frames(frames, h)) == [10]
    end

    test "ungültige Übergänge werden ignoriert" do
      h =
        ConsentState.new()
        |> ConsentState.put(:bogus, 10)
        |> ConsentState.put(:granted, -5)

      assert ConsentState.granted_intervals(h) == []
    end

    test "nicht-Liste als Frames → leer" do
      assert ConsentState.keepable_frames(nil, ConsentState.new(true)) == []
    end
  end

  describe "granted_at?/2 (für Anzeige und Ansage-Logik)" do
    test "spiegelt die Intervalle" do
      h =
        ConsentState.new()
        |> ConsentState.put(:granted, 100)
        |> ConsentState.put(:revoked, 200)

      refute ConsentState.granted_at?(h, 50)
      assert ConsentState.granted_at?(h, 100)
      assert ConsentState.granted_at?(h, 199)
      refute ConsentState.granted_at?(h, 200)
    end
  end
end
