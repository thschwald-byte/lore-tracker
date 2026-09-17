defmodule Worker.Jack.LesenTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.{Lesen, Stand}

  @texte [
    "Wir fahren los.",
    "Der Monitor piept LAUT.",
    "Kodex flucht.",
    "Ich trinke den Kaffee aus.",
    "Der Wagen hält.",
    "Die Tür ist verschlossen.",
    "Noch ein Kaffee?",
    "Alle steigen aus.",
    "Es regnet.",
    "Ende der Sitzung."
  ]

  defp stand(opts \\ []) do
    bloecke =
      @texte
      |> Enum.with_index()
      |> Enum.map(fn {t, i} -> %{text: t, sprecher: "Figur#{rem(i, 2)}", block_id: "b#{i}"} end)

    Stand.neu(
      Keyword.merge(
        [bloecke: bloecke, cast: ["Kodex", "Wagenlenker"], straenge: ["Der Auftrag"]],
        opts
      )
    )
  end

  test "jede Definition ist ein gültiges Werkzeug; weiter, cast und straenge zählen nicht" do
    defs = Lesen.werkzeuge(stand())

    for d <- defs do
      assert %Werkzeug{} =
               Werkzeug.neu(
                 name: d.name,
                 beschreibung: d.beschreibung,
                 parameter: d.parameter,
                 optional: Map.get(d, :optional, []),
                 wiederholung: Map.get(d, :wiederholung, :zaehlt),
                 ausfuehren: fn _ -> {:ok, ""} end
               )
    end

    assert Enum.map(defs, & &1.name) == ~w(bloecke block suche weiter cast straenge)
    frei = for d <- defs, Map.get(d, :wiederholung) == :frei, do: d.name
    assert frei == ~w(weiter cast straenge)
    assert hd(defs).beschreibung =~ "Der Mitschnitt hat die Bloecke 0 bis 9."
  end

  describe "bloecke/2" do
    test "liefert Nummer, Sprecher und Text und merkt den Bereich" do
      {s, {:ok, text}} = Lesen.bloecke(stand(), %{"von" => 1, "bis" => 2})
      assert text == "1\tFigur1\tDer Monitor piept LAUT.\n2\tFigur0\tKodex flucht."
      assert s.gelesen == [{1, 2}]
      assert s.sammelnd == []
    end

    test "beschneidet auf den Mitschnitt; nach der ersten Aussage zählt es als Sammeln" do
      {s, {:ok, text}} = Lesen.bloecke(%{stand() | lfd: 3}, %{"von" => 8, "bis" => 50})
      assert length(String.split(text, "\n")) == 2
      assert s.gelesen == [{8, 9}]
      assert s.sammelnd == [{8, 9}]
    end

    test "von > bis und ein Bereich hinter dem Mitschnitt sind Fehler und zählen nicht als gelesen" do
      {s, {:error, text}} = Lesen.bloecke(stand(), %{"von" => 9, "bis" => 0})
      assert text =~ "von (9) ist groesser als bis (0)"
      assert s.gelesen == []

      {s, {:error, text}} = Lesen.bloecke(stand(), %{"von" => 10, "bis" => 20})
      assert text =~ "Der Mitschnitt hat die Bloecke 0 bis 9."
      assert s.gelesen == []
    end
  end

  test "block/2: einzeln, und bei unbekannter Nummer je nach Modus mit oder ohne Gesamtzahl" do
    assert {_, {:ok, "3\tFigur1\tIch trinke den Kaffee aus."}} =
             Lesen.block(stand(), %{"nummer" => 3})

    assert {_, {:error, "Block 12 gibt es nicht. Gültig sind 0 bis 9."}} =
             Lesen.block(stand(), %{"nummer" => 12})

    assert {_,
            {:error,
             "Block 12 gibt es nicht. Nimm nur Blocknummern, die dir weiter() gezeigt hat."}} =
             Lesen.block(stand(beppo: true), %{"nummer" => 12})
  end

  describe "suche/2" do
    test "findet ohne Rücksicht auf Groß- und Kleinschreibung, im ganzen oder in einem Bereich" do
      assert {_,
              {:ok,
               "2 Fundstelle(n):\n3\tFigur1\tIch trinke den Kaffee aus.\n6\tFigur0\tNoch ein Kaffee?"}} =
               Lesen.suche(stand(), %{"begriff" => "KAFFEE"})

      assert {_, {:ok, "1 Fundstelle(n):\n6\tFigur0\tNoch ein Kaffee?"}} =
               Lesen.suche(stand(), %{"begriff" => "kaffee", "ab" => 4, "bis" => 9})

      assert {_, {:ok, ~s(Keine Fundstelle fuer "Drache".)}} =
               Lesen.suche(stand(), %{"begriff" => "Drache"})
    end

    test "zu kurzer Begriff ist ein Fehler" do
      assert {_, {:error, "Der Begriff ist zu kurz — nimm mindestens drei Zeichen."}} =
               Lesen.suche(stand(), %{"begriff" => " a "})
    end

    test "höchstens 40 Fundstellen, die Zahl steht im Kopf" do
      s = Stand.neu(bloecke: for(i <- 0..44, do: %{text: "Regen #{i}", sprecher: "X"}))
      {_, {:ok, text}} = Lesen.suche(s, %{"begriff" => "regen"})
      [kopf | zeilen] = String.split(text, "\n")
      assert kopf == "45 Fundstelle(n), die ersten 40:"
      assert length(zeilen) == 40
    end
  end

  describe "weiter/2" do
    test "gibt Portion für Portion, merkt sich die Stelle, und sagt beim letzten Bescheid" do
      s = stand(beppo: true, portion: 4)
      assert s.portion == 5

      {s, {:ok, t1}} = Lesen.weiter(s, %{})

      assert t1 =~
               ~r/^0\t.*\n4\t.*\n\n— Wenn du diesen Abschnitt abgearbeitet hast, ruf weiter\(\)\.$/s

      assert s.beppo_pos == 5

      {s, {:ok, t2}} = Lesen.weiter(s, %{})
      assert t2 =~ "— Das war der letzte Abschnitt."
      assert s.gelesen == [{0, 4}, {5, 9}]
      assert [{"beppo.jsonl", _}, {"beppo.jsonl", %{"letzter" => true}}] = Stand.journal_liste(s)
    end

    test "nach dem Ende: zweimal Fehler, beim dritten Mal Abbruch" do
      s = stand(beppo: true, beppo_pos: 10)

      {s, {:error, a1}} = Lesen.weiter(s, %{})
      assert Jason.encode!(a1) =~ ~s({"nichts_mehr":true,"hinweis":"Der Mitschnitt ist durch)
      assert a1["hinweis"] =~ "wird der Lauf abgebrochen."

      {s, {:error, a2}} = Lesen.weiter(s, %{})
      assert a2["hinweis"] =~ "— das wäre der nächste."

      {s, {:abbruch, a3}} = Lesen.weiter(s, %{})
      assert a3["hinweis"] =~ "Das war dein 3. Aufruf von weiter()"
      assert s.weiter_leer == 3
    end
  end

  test "cast und straenge geben die Listen zeilenweise" do
    assert {_, {:ok, "Kodex\nWagenlenker"}} = Lesen.cast(stand(), %{})
    assert {_, {:ok, "Der Auftrag"}} = Lesen.straenge(stand(), %{})
  end
end
