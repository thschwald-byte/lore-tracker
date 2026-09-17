defmodule Worker.Jack.TorTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Stand, Tor}

  defp stand(aussagen) do
    aussagen
    |> Enum.with_index(1)
    |> Enum.reduce(Stand.neu([]), fn {a, i}, s -> Stand.eintragen(s, Map.put(a, "nummer", i)) end)
  end

  defp aussage(claim, refs, beleg \\ "irgendein anderer Beleg"),
    do: %{"claim" => claim, "source_refs" => refs, "beleg" => beleg}

  describe "aehnliche/4 — drei Wege durch das Tor" do
    test "gleiche Fundstellen und gleicher Wortlaut: Rang über 100" do
      s = stand([aussage("Der Balkon ist offen.", [1381, 1382])])
      assert [%{nr: 1, rang: r}] = Tor.aehnliche(s, "Der Balkon ist offen.", [1382, 1381], "x")
      assert r >= 100
    end

    test "gleiche Fundstellen, anderer Wortlaut: 50; gleicher Beleg: 40; Überlappung: 20" do
      s =
        stand([
          aussage("Werbung wird in der Stadt geschaltet", [425]),
          aussage("Ganz etwas anderes steht hier", [7], "4.11."),
          aussage("Die Mauer ist hoch und grau", [42, 43])
        ])

      assert [%{nr: 1, rang: r1}] =
               Tor.aehnliche(s, "AR-Werbung kann man abbestellen", [425], "y")

      assert r1 >= 50 and r1 < 51
      assert [%{nr: 2, rang: r2}] = Tor.aehnliche(s, "Es ist 4:11 Uhr.", [503], "4.11.")
      assert r2 >= 40 and r2 < 41
      assert [%{nr: 3, rang: r3}] = Tor.aehnliche(s, "Eine Leiter lehnt dort", [43], "z")
      assert r3 >= 20 and r3 < 21
    end

    test "ohne gemeinsame Stelle zählt die Wortdeckung ab 0,75, und nur ab drei langen Wörtern" do
      s = stand([aussage("Das Team kämpft gegen ein Rudel Bargaests", [10])])

      assert [%{rang: r}] =
               Tor.aehnliche(s, "Das Team kämpft gegen ein großes Rudel Bargaests", [900], "q")

      assert r >= 30 and r < 31
      assert Tor.aehnliche(s, "Ein Rudel", [900], "q") == []
    end

    test "verworfene Aussagen werden nicht vorgelegt" do
      s = stand([aussage("Der Balkon ist offen.", [5]) |> Map.put("_verworfen", true)])
      assert Tor.aehnliche(s, "Der Balkon ist offen.", [5], "x") == []
    end

    test "sortiert nach Nähe, höchstens acht" do
      s = stand(for i <- 1..10, do: aussage("Aussage Nummer #{i} über den Block", [1]))
      treffer = Tor.aehnliche(s, "Aussage Nummer 3 über den Block", [1], "x")
      assert length(treffer) == 8
      assert hd(treffer).nr == 3
    end
  end

  test "bestaetigung?: gleiche Fundstellen und Wortdeckung ab 0,6" do
    alt = aussage("Kodex hat acht Stimpatches im Rucksack", [160, 162])
    assert Tor.bestaetigung?(alt, "Kodex hat acht Stimpatches dabei", [162, 160])
    refute Tor.bestaetigung?(alt, "Kodex hat acht Stimpatches dabei", [160])
    refute Tor.bestaetigung?(alt, "Lucky trinkt einen Kaffee", [160, 162])
  end

  describe "GUIDs" do
    test "ausgeben, einlösen: danach nicht mehr offen, Schicksal eingelöst" do
      s = Stand.neu([]) |> Tor.ausgeben("g1", %{nr: 1, refs: [3]})
      assert Tor.offen(s, "g1") == %{nr: 1, refs: [3]}
      s = Tor.verbrauchen(s, "g1")
      assert Tor.offen(s, "g1") == nil
      assert Tor.schicksal(s, "g1") == :eingeloest
      assert Tor.schicksal(s, "nie") == nil
    end

    test "was nicht genannt wird, verfällt" do
      s =
        Stand.neu([])
        |> Tor.ausgeben("g1", %{nr: 1, refs: []})
        |> Tor.ausgeben("g2", %{nr: 2, refs: []})
        |> Tor.verfallen_ausser(["g2"])

      assert Tor.schicksal(s, "g1") == :verfallen
      assert Tor.offen(s, "g2")
    end
  end
end
