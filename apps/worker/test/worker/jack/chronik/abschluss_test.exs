defmodule Worker.Jack.Chronik.AbschlussTest do
  @moduledoc """
  Issue #1211: wann `fertig` die Chronik durchlässt — und der Trichter, an
  dem „gebündelt" von „verschluckt" unterscheidbar wird (#1111).
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Abschluss
  alias Worker.Jack.Resuemee.Stand

  defp fakt(id, typ \\ "ereignis"), do: %{id: id, typ: typ}

  defp eintrag(id, fakt_ids, wichtigkeit \\ "phase") do
    %{
      id: id,
      titel: "T",
      text: "Text",
      fakt_ids: fakt_ids,
      wichtigkeit: wichtigkeit,
      zeit_bezug: %{"art" => "isoliert"},
      kuratiert?: false,
      kuratierter_text: nil,
      neu?: true
    }
  end

  defp stand(fakten, eintraege, chronik \\ []) do
    %Stand{
      art: :chronik,
      lauf: :schreiben,
      fakten: fakten,
      eintraege: eintraege,
      chronik: chronik
    }
  end

  describe "Hindernisse" do
    test "eine leere Chronik ist kein Ergebnis" do
      assert [m] = Abschluss.hindernisse(stand([fakt("f1")], []))
      assert m =~ "noch keinen Eintrag"
      assert m =~ "EIN Eintrag"
    end

    test "ein Geschehen ohne Eintrag hält den Abschluss auf — und wird benannt" do
      s = stand([fakt("f1"), fakt("f2")], [eintrag("chr-a", ["f1"])])

      assert [m] = Abschluss.hindernisse(s)
      assert m =~ "f2"
      refute m =~ "f1"
      # Der Weg nach vorn steht dabei: bündeln ist erlaubt, weglassen nicht.
      assert m =~ "eintrag_ergaenzen"
    end

    test "Zustände halten nichts auf — sie gehören nicht in den Zeitstrahl (#1119)" do
      s =
        stand(
          [fakt("f1"), fakt("w1", "zustand"), fakt("w2", "zustand")],
          [eintrag("chr-a", ["f1"])]
        )

      assert Abschluss.hindernisse(s) == []
    end

    test "alles zugeordnet → durch" do
      s = stand([fakt("f1"), fakt("f2")], [eintrag("chr-a", ["f1", "f2"])])
      assert Abschluss.hindernisse(s) == []
    end

    test "gebündelt ist erlaubt: viele Fakten in einer Phase" do
      fakten = for i <- 1..40, do: fakt("f#{i}")
      eine_phase = eintrag("chr-insel", Enum.map(1..40, &"f#{&1}"))

      assert Abschluss.hindernisse(stand(fakten, [eine_phase])) == []
    end

    test "die Liste der offenen Fakten wird gekürzt, aber die Zahl bleibt genau" do
      fakten = for i <- 1..30, do: fakt("f#{i}")
      assert [m] = Abschluss.hindernisse(stand(fakten, [eintrag("chr-a", ["f1"])]))
      assert m =~ "29 Fakten"
      assert m =~ "weitere"
    end
  end

  describe "Trichter (#1111)" do
    test "zählt hinein, heraus und was offen blieb" do
      s =
        stand(
          [fakt("f1"), fakt("f2"), fakt("f3"), fakt("w1", "zustand")],
          [eintrag("chr-a", ["f1", "f2"]), eintrag("chr-b", ["f3"], "schluesselszene")]
        )

      t = Abschluss.trichter(s)

      assert t["fakten_gesamt"] == 4
      assert t["fakten_ereignis"] == 3
      assert t["fakten_zustand"] == 1
      assert t["fakten_ohne_eintrag"] == 0
      assert t["eintraege"] == 2
      assert t["phasen"] == 1
      assert t["schluesselszenen"] == 1
      assert t["zyklen"] == 0
      assert t["verwaiste_bezuege"] == 0
    end

    test "macht Verschlucken sichtbar" do
      # Zwanzig Fakten, eine Phase, aber nur zwei darin: die Zahl verrät es.
      fakten = for i <- 1..20, do: fakt("f#{i}")
      t = Abschluss.trichter(stand(fakten, [eintrag("chr-a", ["f1", "f2"])]))

      assert t["fakten_ereignis"] == 20
      assert t["fakten_ohne_eintrag"] == 18
    end

    test "meldet einen Kreis in den Bezügen" do
      a = %{eintrag("chr-a", ["f1"]) | zeit_bezug: %{"art" => "nach", "ziel" => "chr-b"}}
      b = %{eintrag("chr-b", ["f2"]) | zeit_bezug: %{"art" => "nach", "ziel" => "chr-a"}}

      t = Abschluss.trichter(stand([fakt("f1"), fakt("f2")], [a, b]))
      assert t["zyklen"] == 2
    end

    test "kennt den Bestand, gegen den verfeinert wurde" do
      t = Abschluss.trichter(stand([fakt("f1")], [eintrag("chr-a", ["f1"])], [%{id: "alt"}]))
      assert t["bestand_vorher"] == 1
    end
  end

  describe "Ist-Zahlen für den Abgleich" do
    test "nennt Einträge und zugeordnete Geschehen" do
      s = stand([fakt("f1"), fakt("f2"), fakt("w", "zustand")], [eintrag("chr-a", ["f1"])])

      assert Abschluss.ist_schreiben(s) == %{
               "eintraege" => 1,
               "fakten_zugeordnet" => 1
             }
    end
  end
end
