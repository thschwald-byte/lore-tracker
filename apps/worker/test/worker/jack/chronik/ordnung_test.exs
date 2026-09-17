defmodule Worker.Jack.Chronik.OrdnungTest do
  @moduledoc """
  Issue #1211: die Reihenfolge der Chronik rechnet Elixir aus Jacks Bezügen.

  Geprüft wird vor allem, was ein naiver Nachbau falsch machen würde:
  „gleichzeitig mit" ist keine Kante, ein Widerspruch ist ein Befund statt
  eines stillen Rückfalls, und bei Gleichstand entscheidet die ID — nicht die
  Reihenfolge, in der die Einträge ankamen.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Ordnung

  defp e(id, bezug \\ nil) do
    case bezug do
      nil -> %{"id" => id}
      b -> %{"id" => id, "zeit_bezug" => b}
    end
  end

  defp nach(ziel), do: %{"art" => "nach", "ziel" => ziel}
  defp vor(ziel), do: %{"art" => "vor", "ziel" => ziel}
  defp gleichzeitig(ziel), do: %{"art" => "gleichzeitig_mit", "ziel" => ziel}

  describe "die einfache Kette" do
    test "„nach\" reiht hinten an" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([e("auftrag"), e("anfahrt", nach("auftrag"))])

      assert r == [["auftrag"], ["anfahrt"]]
    end

    test "„vor\" reiht davor" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([e("abrechnung"), e("einbruch", vor("abrechnung"))])

      assert r == [["einbruch"], ["abrechnung"]]
    end

    test "eine Kette über drei Stationen" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([
                 e("c", nach("b")),
                 e("a"),
                 e("b", nach("a"))
               ])

      assert r == [["a"], ["b"], ["c"]]
    end
  end

  describe "gleichzeitig ist keine Kante" do
    # Der Fall, an dem ein Nachbau mit zwei gegenläufigen Kanten scheitert:
    # er meldete einen Zyklus, wo Jack etwas völlig Zulässiges gesagt hat.
    test "zwei gleichzeitige Einträge stehen an derselben Stelle, kein Zyklus" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([e("belagerung"), e("seuche", gleichzeitig("belagerung"))])

      assert r == [["belagerung", "seuche"]]
    end

    test "eine Klasse ordnet sich als Ganzes ein" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([
                 e("auftrag"),
                 e("belagerung", nach("auftrag")),
                 e("seuche", gleichzeitig("belagerung"))
               ])

      assert r == [["auftrag"], ["belagerung", "seuche"]]
    end

    test "gleichzeitig UND danach zum selben Ziel ergibt keinen Zyklus" do
      # Jack widerspricht sich hier halb; die Gleichzeitigkeit gewinnt, die
      # Kante innerhalb der Klasse fällt weg. Ein Kreis wäre das falsche
      # Signal — es gibt nichts zu korrigieren, was die Ordnung nicht selbst
      # auflösen kann.
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([
                 e("a"),
                 e("b", gleichzeitig("a")),
                 e("c", nach("b"))
               ])

      assert r == [["a", "b"], ["c"]]
    end

    test "drei gleichzeitige Einträge bilden eine Klasse, auch über Ketten" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([
                 e("a"),
                 e("b", gleichzeitig("a")),
                 e("c", gleichzeitig("b"))
               ])

      assert r == [["a", "b", "c"]]
    end
  end

  describe "Widersprüche werden gemeldet, nicht weggerechnet" do
    test "ein Kreis kommt als Befund zurück" do
      assert {:zyklus, ids} =
               Ordnung.ordne([
                 e("a", nach("b")),
                 e("b", nach("a"))
               ])

      assert ids == ["a", "b"]
    end

    test "der Kreis nennt alle Beteiligten, auch über drei Ecken" do
      assert {:zyklus, ids} =
               Ordnung.ordne([
                 e("a", nach("c")),
                 e("b", nach("a")),
                 e("c", nach("b"))
               ])

      assert ids == ["a", "b", "c"]
    end

    test "was ausserhalb des Kreises liegt, taucht im Befund nicht auf" do
      assert {:zyklus, ids} =
               Ordnung.ordne([
                 e("sauber"),
                 e("a", nach("b")),
                 e("b", nach("a"))
               ])

      refute "sauber" in ids
    end
  end

  describe "Bezüge ins Leere" do
    test "ein unbekanntes Ziel verwirft die Kante und meldet den Eintrag" do
      assert {:ok, %{reihenfolge: r, verwaist: v}} =
               Ordnung.ordne([e("a"), e("b", nach("gibtsnicht"))])

      assert v == ["b"]
      # b steht ohne Bezug in der Reihenfolge — nicht am Ende, nicht verworfen.
      assert Enum.sort(List.flatten(r)) == ["a", "b"]
    end

    test "gleichzeitig mit einem Unbekannten legt nichts zusammen" do
      assert {:ok, %{reihenfolge: r}} = Ordnung.ordne([e("a"), e("b", gleichzeitig("weg"))])
      assert length(r) == 2
    end
  end

  describe "Determinismus" do
    # Zwei Worker derselben Kampagne bauen dieselbe Chronik. Ohne feste
    # Tiebreak-Regel zeigten sie verschiedene Reihenfolgen — dieselbe Klasse,
    # die #1092 für die Fakten-Chronik behoben hat.
    test "bei Gleichstand entscheidet die ID, nicht die Eingabereihenfolge" do
      vorwaerts = Ordnung.ordne([e("zebra"), e("anton"), e("mitte")])
      rueckwaerts = Ordnung.ordne([e("mitte"), e("anton"), e("zebra")])

      assert vorwaerts == rueckwaerts
      assert {:ok, %{reihenfolge: r}} = vorwaerts
      assert r == [["anton"], ["mitte"], ["zebra"]]
    end

    test "auch mit Kanten ist die Ausgabe eingabeunabhängig" do
      a = Ordnung.ordne([e("x", nach("y")), e("y"), e("z")])
      b = Ordnung.ordne([e("z"), e("y"), e("x", nach("y"))])
      assert a == b
    end
  end

  describe "Ränder" do
    test "keine Einträge" do
      assert {:ok, %{reihenfolge: [], verwaist: []}} = Ordnung.ordne([])
    end

    test "ein Eintrag ohne Bezug" do
      assert {:ok, %{reihenfolge: [["allein"]]}} = Ordnung.ordne([e("allein")])
    end

    test "absolut und isoliert tragen keine Kante" do
      assert {:ok, %{reihenfolge: r}} =
               Ordnung.ordne([
                 e("a", %{"art" => "absolut", "zeit" => "3. Wintermond"}),
                 e("b", %{"art" => "isoliert"})
               ])

      assert r == [["a"], ["b"]]
    end
  end
end
