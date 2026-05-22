defmodule Worker.RepoChronikSortTest do
  @moduledoc """
  Issue #135: Chronik-Sort wird am Read-Path aus `in_game_date` abgeleitet.
  Diese Tests fixieren das Klassifizierungs-Verhalten der einzelnen
  Pattern-Familien und ihre relative Ordnung.
  """

  use ExUnit.Case, async: true

  alias Worker.Repo

  describe "derive_chronik_sort_tuple/1 — leere/nil Werte" do
    test "nil sortiert ans Ende (Familie 9)" do
      assert {9, 0, ""} = Repo.derive_chronik_sort_tuple(nil)
    end

    test "leerer String sortiert ans Ende (Familie 9)" do
      assert {9, 0, ""} = Repo.derive_chronik_sort_tuple("")
    end
  end

  describe "derive_chronik_sort_tuple/1 — Unit + Zahl (Familie 0)" do
    test "\"Session N\" extrahiert N" do
      assert {0, 13, "Session 13"} = Repo.derive_chronik_sort_tuple("Session 13")
      assert {0, 1, "Session 1"} = Repo.derive_chronik_sort_tuple("Session 1")
    end

    test "\"Tag N\" extrahiert N" do
      assert {0, 38, "Tag 38"} = Repo.derive_chronik_sort_tuple("Tag 38")
    end

    test "\"Day N\", \"Akt N\", \"Szene N\", \"Scene N\" funktionieren analog" do
      assert {0, 14, _} = Repo.derive_chronik_sort_tuple("Day 14")
      assert {0, 2, _} = Repo.derive_chronik_sort_tuple("Akt 2")
      assert {0, 5, _} = Repo.derive_chronik_sort_tuple("Szene 5")
      assert {0, 7, _} = Repo.derive_chronik_sort_tuple("Scene 7")
    end

    test "case-insensitive + tolerant gegen Leerzeichen" do
      assert {0, 3, _} = Repo.derive_chronik_sort_tuple("session 3")
      assert {0, 3, _} = Repo.derive_chronik_sort_tuple("SESSION 3")
      assert {0, 3, _} = Repo.derive_chronik_sort_tuple("  Tag   3")
    end
  end

  describe "derive_chronik_sort_tuple/1 — \"NNN CY [+ Season]\" (Familie 1)" do
    test "reines Jahr → year * 10" do
      assert {1, 5500, _} = Repo.derive_chronik_sort_tuple("550 CY")
    end

    test "Jahr + Season → year * 10 + season_bump (Spring=1 … Winter=4)" do
      assert {1, 5521, _} = Repo.derive_chronik_sort_tuple("552 CY - Spring")
      assert {1, 5522, _} = Repo.derive_chronik_sort_tuple("552 CY - Summer")
      assert {1, 5523, _} = Repo.derive_chronik_sort_tuple("552 CY - Autumn")
      assert {1, 5523, _} = Repo.derive_chronik_sort_tuple("552 CY - Fall")
      assert {1, 5524, _} = Repo.derive_chronik_sort_tuple("552 CY - Winter")
    end
  end

  describe "derive_chronik_sort_tuple/1 — narrative Marker (Familie 2)" do
    test "\"Aufbruch\" / \"Erste Begegnung\" landen in Familie 2 mit String-Tiebreak" do
      assert {2, 0, "Aufbruch"} = Repo.derive_chronik_sort_tuple("Aufbruch")
      assert {2, 0, "Erste Begegnung"} = Repo.derive_chronik_sort_tuple("Erste Begegnung")
    end
  end

  describe "derive_chronik_sort_tuple/1 — Gesamtordnung" do
    test "Mix aus allen Familien sortiert in der erwarteten Reihenfolge" do
      input = [
        "Aufbruch",
        "Session 13",
        nil,
        "550 CY",
        "Tag 5",
        "552 CY - Winter",
        "",
        "Erste Begegnung",
        "Session 2"
      ]

      sorted = Enum.sort_by(input, &Repo.derive_chronik_sort_tuple/1)

      assert sorted == [
               # Familie 0 — Unit + Zahl, aufsteigend
               "Session 2",
               "Tag 5",
               "Session 13",
               # Familie 1 — Jahr * 10 + Season
               "550 CY",
               "552 CY - Winter",
               # Familie 2 — narrative Marker, String-Tiebreak
               "Aufbruch",
               "Erste Begegnung",
               # Familie 9 — nil/leer ans Ende
               nil,
               ""
             ]
    end

    test "Folger-R&J-Symptom: \"Session N\" gemischt sortiert linear nach N" do
      # Genau die Reihenfolge aus dem Bug-Screenshot. Erwartung: numerisch
      # nach Session-Nummer, dedup nicht nötig (verschiedene Labels pro N).
      input = [
        "Session 13",
        "Session 21",
        "Session 13",
        "Session 18",
        "Session 28",
        "Session 12",
        "Session 5",
        "Session 22",
        "Session 24",
        "Session 22",
        "Session 21",
        "Session 17"
      ]

      sorted = Enum.sort_by(input, &Repo.derive_chronik_sort_tuple/1)

      assert sorted == [
               "Session 5",
               "Session 12",
               "Session 13",
               "Session 13",
               "Session 17",
               "Session 18",
               "Session 21",
               "Session 21",
               "Session 22",
               "Session 22",
               "Session 24",
               "Session 28"
             ]
    end
  end
end
