defmodule Worker.Jack.StandTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.Stand

  defp notiz(abschnitt, zeile),
    do: %{abschnitt: abschnitt, schluessel: "k", zeile: zeile, bloecke: []}

  test "neu nummeriert die Blöcke ab 0 und kennt den letzten" do
    s = Stand.neu(bloecke: [%{text: "a"}, %{text: "b"}])
    assert Stand.block(s, 1) == %{text: "b"}
    assert s.max_block == 1
  end

  describe "geruest_fehlt/1" do
    test "nennt die fehlenden Abschnitte" do
      s = Stand.neu(register: [notiz("FIGUREN", "Kodex")])
      assert Stand.geruest_fehlt(s) == ["## ABLAUF", "## AUFTRAG", "## THEMEN", "## OFFEN"]
    end

    test "zählt nur Einträge mit Inhalt und verlangt zehn" do
      voll = for a <- Stand.abschnitte(), do: notiz(a, "Inhalt")
      leer = for a <- Stand.abschnitte(), do: notiz(a, "  ")

      assert Stand.geruest_fehlt(Stand.neu(register: voll ++ leer)) == [
               "(zu duenn: 5 Eintraege mit Inhalt, mindestens 10)"
             ]

      assert Stand.geruest_fehlt(Stand.neu(register: voll ++ voll)) == []
    end
  end

  test "guid zählt über die Quelle des Stands" do
    s = Stand.neu(guid_quelle: fn n -> "g#{n}" end)
    {g1, s} = Stand.guid(s)
    {g2, _} = Stand.guid(s)
    assert {g1, g2} == {"g1", "g2"}
  end

  test "die zufällige GUID hat das Format 8-4-4-4-12" do
    assert Stand.zufalls_guid(1) =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  end

  test "Themen in der Reihenfolge ihres ersten Auftretens, ohne Doppel" do
    s = Stand.neu([]) |> Stand.themen_merken(["b", "a"]) |> Stand.themen_merken(["a", "c"])
    assert s.themen == ["b", "a", "c"]
  end

  test "ersetzen ersetzt an Ort und Stelle, das Journal hält die Reihenfolge" do
    s =
      Stand.neu([])
      |> Stand.eintragen(%{"nummer" => 1, "claim" => "alt"})
      |> Stand.eintragen(%{"nummer" => 2, "claim" => "zwei"})
      |> Stand.ersetzen(1, %{"nummer" => 1, "claim" => "neu"})
      |> Stand.journal("a.jsonl", %{"n" => 1})
      |> Stand.journal("b.jsonl", %{"n" => 2})

    assert Enum.map(s.eingetragen, & &1.voll["claim"]) == ["neu", "zwei"]
    assert Stand.journal_liste(s) == [{"a.jsonl", %{"n" => 1}}, {"b.jsonl", %{"n" => 2}}]
  end

  test "belegte Blöcke und der höchste davon" do
    s = Stand.neu([]) |> Stand.belegte_merken([4, 9]) |> Stand.belegte_merken([2])
    assert s.hoechster_belegter_block == 9
    assert MapSet.equal?(s.belegte_bloecke, MapSet.new([2, 4, 9]))
  end
end
