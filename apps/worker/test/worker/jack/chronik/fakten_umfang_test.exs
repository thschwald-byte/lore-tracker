defmodule Worker.Jack.Chronik.FaktenUmfangTest do
  @moduledoc """
  #1247: **beim Chronik-Jack ist der Gegenstand die Kampagne** — und die
  Antwort muss das sagen.

  Maintainer, 25.09.2026: „chronik ist die ganze kampagne → das Etikett muss
  weg." Anlass war der Chronik-Lauf auf seattleV5: `fakten(sitzung: 2)` lieferte
  alle 208 Fakten der Kampagne, und der Kopf behauptete „Sitzung 2, Fakten 1 bis
  208" — im Bereich 1..40 standen Fakten aus S1. Jack hat es sofort bemerkt:
  „the IDs are labeled as S1-F1 through S1-F40, which suggests these might be
  from a different session than expected."

  Die Ursache war eine Klausel aus der Resümee-Welt: „die Nummer ist meine
  eigene → gib `s.fakten`". Dort IST `s.fakten` die eigene Sitzung, beim
  Chronik-Jack ist es `alle_fakten/1` über alle Sitzungen.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Aufruf
  alias Worker.Jack.Chronik.Werkzeuge
  alias Worker.Jack.Resuemee.{Halter, Stand}

  defp fakt(nr, i),
    do: %{
      id: "S#{nr}-F#{i}",
      fakt_id: "f_#{nr}_#{i}",
      sitzung: nr,
      typ: "ereignis",
      aussage: "Geschehen #{nr}/#{i}",
      figur: nil,
      datum: nil,
      erzaehlzeit: "present",
      bloecke: [],
      ohne_block: [],
      refs: [],
      boegen: []
    }

  # Zwei Sitzungen, wie sie der Chronik-Jack sieht: alles in EINER Liste,
  # vorn die früheren (`Chronik.Eingabe.alle_fakten/1`).
  defp stand do
    %Stand{
      art: :chronik,
      lauf: :schreiben,
      sitzung: %{id: "s2", nummer: 2, name: "Zweite"},
      fakten: Enum.map(1..3, &fakt(1, &1)) ++ Enum.map(1..2, &fakt(2, &1)),
      eintraege: [],
      chronik: [],
      notizen: [],
      boegen: [],
      gelesen: MapSet.new(),
      mitschnitt: %Worker.Jack.Stand{bloecke: %{}, max_block: -1, cast: [], straenge: []}
    }
  end

  defp ruf(felder) do
    {:ok, h} = Halter.start_link(stand())
    werkzeuge = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: "fakten", argumente: {:ok, felder}}, werkzeuge)
  end

  describe "ohne sitzung" do
    test "liest die ganze Kampagne — und sagt das, statt eine Sitzung zu behaupten" do
      assert {:ok, t} = ruf(%{"von" => 1, "bis" => 5})

      assert t =~ "Alle Fakten der Kampagne, Fakten 1 bis 5 von 5"
      refute t =~ "Sitzung 2, Fakten", "das war die Falschaussage"

      # Die IDs nennen die Sitzung — das war immer richtig und bleibt.
      assert t =~ "S1-F1"
      assert t =~ "S2-F1"
    end
  end

  describe "mit sitzung" do
    test "filtert wirklich auf diese Sitzung — auch auf die eigene" do
      # Der Kern des Defekts: `sitzung: 2` ist beim Chronik-Jack die eigene
      # Nummer, und die alte Klausel gab dafür alles zurück.
      assert {:ok, t} = ruf(%{"sitzung" => 2, "von" => 1, "bis" => 5})

      assert t =~ "Sitzung 2, Fakten 1 bis 2 von 2"
      assert t =~ "S2-F1"
      refute t =~ "S1-F", "Fakten aus Sitzung 1 gehören nicht in diese Antwort"
    end

    test "und auf eine frühere" do
      assert {:ok, t} = ruf(%{"sitzung" => 1, "von" => 1, "bis" => 3})

      assert t =~ "Sitzung 1, Fakten 1 bis 3 von 3"
      refute t =~ "S2-F"
    end

    test "eine Sitzung ohne Fakten wird benannt, samt denen, die welche haben" do
      # Beim Chronik-Jack gibt es kein „früher" — er sieht alle, also nennt
      # die Absage die vorhandenen.
      assert {:error, t} = ruf(%{"sitzung" => 7, "von" => 1, "bis" => 3})

      assert t =~ "Zu Sitzung 7 gibt es keine Fakten"
      assert t =~ "1, 2"
      assert t =~ "Ohne sitzung liest du alle Fakten der Kampagne"
    end
  end

  describe "die Grenzmeldungen lesen sich in beiden Fällen" do
    test "der Bereich hinter dem Ende nennt die Kampagne" do
      assert {:error, t} = ruf(%{"von" => 9, "bis" => 12})
      assert t =~ "Die Kampagne hat die Fakten 1 bis 5"
    end

    test "und bei gesetzter Sitzung die Sitzung" do
      assert {:error, t} = ruf(%{"sitzung" => 2, "von" => 9, "bis" => 12})
      assert t =~ "Sitzung 2 hat die Fakten 1 bis 2"
    end
  end
end
