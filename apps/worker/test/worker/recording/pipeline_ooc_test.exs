defmodule Worker.Recording.Pipeline.OocTest do
  @moduledoc """
  Issue #680: konservative OOC-Heuristik für die Fakt-Extraktion. Wichtig ist
  beides: klare Würfel-/Wert-Turns fangen UND Narration in Ruhe lassen (ein zu
  aggressiver Filter verlöre echten Inhalt).
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Ooc

  describe "ooc?/1 — fängt klare Würfel-/Wert-Turns" do
    test "numerische Probe (X gegen/auf Y)" do
      assert Ooc.ooc?("Verborgenes Erkennen — 38 gegen 55. Geschafft.")
      assert Ooc.ooc?("Bibliotheksnutzung — 22 auf 60. Sitzt.")
    end

    test "Würfel-Notation + würfeln" do
      assert Ooc.ooc?("W4 drauf, ne?")
      assert Ooc.ooc?("Mein Würfel ist runtergefallen.")
      assert Ooc.ooc?("Glück: ich würfle 29.")
    end

    test "Wert-/Schadens-Marker" do
      assert Ooc.ooc?("mein Wert steht auf 75")
      assert Ooc.ooc?("Einen Schadenspunkt, alles klar.")
    end
  end

  describe "ooc?/1 — lässt Narration in Ruhe (kein False-Positive)" do
    test "Erzähl-Turns werden NICHT geflaggt" do
      refute Ooc.ooc?("Der König von Böhmen bittet Holmes um Hilfe.")
      refute Ooc.ooc?("Irene Adler heiratet Godfrey Norton in der Sankt-Monika-Kirche.")
      # „geschafft" allein (ohne Würfel/Zahlen) ist Narration, nicht OOC:
      refute Ooc.ooc?("Holmes hat es geschafft, unbemerkt zu entkommen.")
      # „Probe" allein (mehrdeutig) löst bewusst NICHT aus:
      refute Ooc.ooc?("Sie nahmen eine Probe des Papiers.")
    end

    test "nil / leer → false" do
      refute Ooc.ooc?(nil)
      refute Ooc.ooc?("")
    end
  end

  describe "filter/1" do
    test "entfernt OOC, behält Narration + Reihenfolge" do
      utts = [
        %{id: "u1", text: "Holmes empfängt den König."},
        %{id: "u2", text: "Bibliotheksnutzung — 22 auf 60. Sitzt."},
        %{id: "u3", text: "Der König bittet um Hilfe."},
        %{id: "u4", text: "W4 drauf, ne?"}
      ]

      assert ["u1", "u3"] = Ooc.filter(utts) |> Enum.map(& &1.id)
    end

    test "string-keys werden auch akzeptiert" do
      assert [%{"id" => "u1"}] =
               Ooc.filter([
                 %{"id" => "u1", "text" => "Narration."},
                 %{"id" => "u2", "text" => "W20!"}
               ])
    end
  end
end
