defmodule Worker.Jack.GedaechtnisTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.{Gedaechtnis, Stand}

  defp stand(opts \\ []) do
    Stand.neu(
      Keyword.merge([bloecke: for(i <- 0..199, do: %{text: "t#{i}", sprecher: "X"})], opts)
    )
  end

  defp e(abschnitt, schluessel, zeile, bloecke \\ []),
    do: %{
      "abschnitt" => abschnitt,
      "schluessel" => schluessel,
      "zeile" => zeile,
      "bloecke" => bloecke
    }

  defp notiz(s, eintraege), do: Gedaechtnis.notiz(s, %{"eintraege" => eintraege})

  test "jede Definition ist ein gültiges Werkzeug; notizen_lesen zählt nicht" do
    for d <- Gedaechtnis.werkzeuge(stand()) do
      assert %Werkzeug{} =
               Werkzeug.neu(
                 name: d.name,
                 beschreibung: d.beschreibung,
                 parameter: d.parameter,
                 wiederholung: Map.get(d, :wiederholung, :zaehlt),
                 ausfuehren: fn _ -> {:ok, ""} end
               )
    end

    assert [%{name: "notiz"}, %{name: "notizen_lesen", wiederholung: :frei}] =
             Gedaechtnis.werkzeuge(stand())
  end

  describe "notiz/2" do
    test "anlegen, ersetzen, streichen — und die Antwort in der Reihenfolge des Spikes" do
      {s, {:ok, a}} =
        notiz(stand(), [e("FIGUREN", "Kodex", "Decker", [3]), e("ABLAUF", "0-50", "Anfahrt")])

      assert Jason.encode!(a) =~ ~s({"neu":2,"ersetzt":0,"gestrichen":0,"eintraege_gesamt":2,)
      assert a["geruest_unvollstaendig"] == ["## AUFTRAG", "## THEMEN", "## OFFEN"]

      {s, {:ok, a}} =
        notiz(s, [e("FIGUREN", " Kodex ", "Decker der Gruppe", [3]), e("ABLAUF", "0-50", nil)])

      assert {a["ersetzt"], a["gestrichen"], a["eintraege_gesamt"]} == {1, 1, 1}
      assert [%{schluessel: "Kodex", zeile: "Decker der Gruppe"}] = s.register

      assert Enum.map(Stand.journal_liste(s), fn {"notizen_verlauf.txt", j} -> j["art"] end) ==
               ["+", "+", "~", "-"]
    end

    test "ein unveränderter Eintrag wird nicht quittiert; beim dritten Versuch ist er ein Fehler" do
      {s, _} = notiz(stand(), [e("OFFEN", "Uhrzeit", "unklar")])
      {s, {:error, a1}} = notiz(s, [e("OFFEN", "Uhrzeit", "unklar")])
      assert a1["unveraendert"] == 1
      assert a1["hinweis_unveraendert"] =~ "NICHT neu"
      refute a1["fehler"]

      {s, {:error, _}} = notiz(s, [e("OFFEN", "Uhrzeit", "unklar")])
      {_, {:error, a3}} = notiz(s, [e("OFFEN", "Uhrzeit", "unklar")])
      assert [text] = a3["fehler"]

      assert text =~
               "OFFEN/Uhrzeit steht bereits genau so — das war der 3. gleichlautende Versuch."
    end

    test "leere Zeile, leerer Schlüssel und unbekannte Blöcke sind Fehler" do
      {s, {:error, a}} =
        notiz(stand(), [
          e("FIGUREN", "A", "  "),
          e("FIGUREN", "   ", "x"),
          e("FIGUREN", "B", "x", [3, 500])
        ])

      assert [leer, schluessel, bloecke] = a["fehler"]
      assert leer =~ "FIGUREN/A: die Zeile ist leer."

      assert schluessel ==
               "`schluessel` fehlt — ohne ihn ist der Eintrag spaeter nicht zu finden."

      assert bloecke == "Bloecke gibt es nicht: [500]."
      assert s.register == []
    end

    test "ABLAUF: der Schlüssel ist ein Bereich, und ein neuer Bereich darf keinen bestehenden schneiden" do
      {s, _} = notiz(stand(), [e("ABLAUF", "0-100", "Anfahrt")])

      {_, {:error, a}} = notiz(s, [e("ABLAUF", "Fortschritt", "fertig")])
      assert hd(a["fehler"]) =~ "ABLAUF/Fortschritt: der Schluessel muss ein Blockbereich sein"

      {_, {:error, a}} = notiz(s, [e("ABLAUF", "90-150", "Ankunft")])
      assert hd(a["fehler"]) =~ ~s|ABLAUF/90-150 ueberschneidet sich mit ABLAUF/0-100 ("Anfahrt")|

      # vertauschte Grenzen gelten als richtig herum
      {_, {:error, a}} = notiz(s, [e("ABLAUF", "150-90", "Ankunft")])
      assert hd(a["fehler"]) =~ "ueberschneidet sich mit ABLAUF/0-100"

      # unter demselben Schlüssel weiterschreiben ist erlaubt, anschließen auch
      assert {_, {:ok, _}} = notiz(s, [e("ABLAUF", "0-100", "Anfahrt und Ankunft")])
      assert {_, {:ok, _}} = notiz(s, [e("ABLAUF", "101-150", "Ankunft")])
    end
  end

  test "notizen_lesen: Stand, Einträge mit Schlüsseln, Text" do
    {_, {:ok, leer}} = Gedaechtnis.notizen_lesen(stand(), %{})
    assert leer["notizen"] == "(noch keine Notizen)"
    assert leer["stand"] =~ "Du liest noch. Gelesen: noch nichts"

    {s, _} =
      notiz(stand(), [e("FIGUREN", "Kodex", "Decker", [3, 4]), e("OFFEN", "Uhrzeit", "unklar")])

    {_, {:ok, a}} = Gedaechtnis.notizen_lesen(s, %{})

    assert Jason.encode!(hd(a["eintraege"])) ==
             ~s({"abschnitt":"FIGUREN","schluessel":"Kodex","zeile":"Decker","bloecke":[3,4]})

    assert a["notizen"] == "## FIGUREN\nKodex — Decker  [3, 4]\n\n## OFFEN\nUhrzeit — unklar"
  end

  describe "stand_text/1" do
    test "lesend: was gelesen wurde; sammelnd: bis wohin, und die größte Lücke ohne Aussage" do
      s = %{stand() | gelesen: [{0, 49}, {50, 99}]}
      assert Gedaechtnis.stand_text(s) =~ "Du liest noch. Gelesen: 0-49, 50-99"

      s =
        %{stand() | lfd: 4, sammelnd: [{0, 80}, {81, 160}]} |> Stand.belegte_merken([2, 10, 170])

      text = Gedaechtnis.stand_text(s)
      assert text =~ "Eingetragene Aussagen: 4"
      assert text =~ "Beim Sammeln durchgearbeitet bis Block 160 von 199."
      assert text =~ "Groesster Bereich ohne Aussage: 10-170 — sieh dort nach."
    end

    test "Beppo: keine Angabe zur Größe des Mitschnitts" do
      text = Gedaechtnis.stand_text(stand(beppo: true, beppo_pos: 40))

      assert text ==
               "Eingetragene Aussagen: 0\nZuletzt bearbeitet bis Block 39. Der naechste Abschnitt kommt mit weiter()."

      refute text =~ "199"
    end
  end

  test "ablauf_luecken: leer, Lücken, und Alt-Schlüssel wie „0 bis 49“" do
    assert Gedaechtnis.ablauf_luecken(stand()) == ["ABLAUF ist leer"]

    s =
      stand(
        register: [
          %{abschnitt: "ABLAUF", schluessel: "0 bis 49", zeile: "a", bloecke: []},
          %{abschnitt: "ABLAUF", schluessel: "80-120", zeile: "b", bloecke: []},
          %{abschnitt: "ABLAUF", schluessel: "121-150", zeile: "  ", bloecke: []}
        ]
      )

    assert Gedaechtnis.ablauf_luecken(s) == ["50-79", "121-199"]
  end
end
