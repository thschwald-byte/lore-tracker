defmodule Worker.Jack.AbschlussTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.{Abschluss, Stand}

  @bloecke for i <- 0..29, do: %{text: "t#{i}", sprecher: "X"}

  defp notiz(abschnitt, schluessel),
    do: %{abschnitt: abschnitt, schluessel: schluessel, zeile: "Inhalt", bloecke: []}

  # Phase 1 ohne Hindernis: alles gelesen, Gerüst voll, ABLAUF lückenlos.
  # 11 Einträge, davon 2 ABLAUF.
  defp gelesen_und_notiert do
    register =
      [notiz("ABLAUF", "0-14"), notiz("ABLAUF", "15-29")] ++
        for(a <- ~w(FIGUREN AUFTRAG THEMEN OFFEN), k <- ~w(a b), do: notiz(a, k)) ++
        [notiz("OFFEN", "c")]

    %{Stand.neu(bloecke: @bloecke, register: register) | gelesen: [{0, 29}]}
  end

  test "ein Schema je Phase, alle Felder Pflicht, offen_geblieben darf leer sein" do
    for {phase, zahlen} <- [{1, ~w(bereiche eintraege)}, {2, ~w(aussagen)}] do
      s = Stand.neu(bloecke: @bloecke, phase: phase)
      [d] = Abschluss.werkzeuge(s)

      w =
        Werkzeug.neu(
          name: d.name,
          beschreibung: d.beschreibung,
          parameter: d.parameter,
          wiederholung: d.wiederholung,
          ausfuehren: fn _ -> {:ok, ""} end
        )

      assert Enum.sort(w.parameter["required"]) == Enum.sort(["offen_geblieben" | zahlen])
      assert w.parameter["properties"]["offen_geblieben"]["minLength"] == 0
      assert w.wiederholung == :frei
    end
  end

  describe "Phase 1" do
    test "ohne Lesen: nur dieser eine Punkt, je nach Modus" do
      assert Abschluss.hindernisse(Stand.neu(bloecke: @bloecke)) == [
               "Du hast keinen einzigen Block geholt. bloecke(von, bis) ist der Anfang der Arbeit, nicht eine Formalie."
             ]

      assert [text] = Abschluss.hindernisse(Stand.neu(bloecke: @bloecke, beppo: true))
      assert text =~ "keinen einzigen Abschnitt geholt. weiter()"
    end

    test "Nie gelesen, fehlendes Gerüst und ABLAUF-Lücken" do
      s = %{
        Stand.neu(bloecke: @bloecke, register: [notiz("ABLAUF", "0-9")])
        | gelesen: [{0, 9}, {20, 25}]
      }

      assert [nie, geruest, ablauf] = Abschluss.hindernisse(s)
      assert nie =~ "Nie gelesen: 10-19, 26-29."
      assert geruest == "Im Gedaechtnis fehlt: ## FIGUREN, ## AUFTRAG, ## THEMEN, ## OFFEN"
      assert ablauf == "ABLAUF hat Luecken: 10-29. Jeder Bereich eine Zeile."
    end

    test "offene Arbeit: fertig lehnt ab" do
      {s, {:error, a}} = Abschluss.fertig(Stand.neu(bloecke: @bloecke), %{})
      assert a["hinweis"] == "Noch nicht fertig. Arbeite die Punkte ab und ruf fertig() erneut."
      assert [{"abschluss.jsonl", %{"versuch" => "abgelehnt"}}] = Stand.journal_liste(s)
    end

    test "richtige Zahlen: Abschluss mit Zahlen; der Lauf endet" do
      s = gelesen_und_notiert()
      assert Abschluss.hindernisse(s) == []

      {s, {:halt, a}} =
        Abschluss.fertig(s, %{"bereiche" => 2, "eintraege" => 11, "offen_geblieben" => ""})

      assert Jason.encode!(a) =~
               ~s({"ok":true,"fertig":true,"zahlen":{"bereiche":2,"eintraege":11})

      assert a["hinweis"] == "Abgeschlossen. Du kannst aufhoeren."
      assert [{"abschluss.jsonl", %{"zahlen_stimmten" => "ja"}}] = Stand.journal_liste(s)
    end

    test "falsche Zahlen: zweimal abgelehnt, ohne die richtige zu verraten; der dritte Versuch geht durch" do
      s = gelesen_und_notiert()
      p = %{"bereiche" => 2, "eintraege" => 7, "offen_geblieben" => "x"}

      {s, {:error, a1}} = Abschluss.fertig(s, p)

      assert a1["abweichung"] == [
               "eintraege: du sagst 7 — das stimmt nicht mit der Buchhaltung überein"
             ]

      assert a1["hinweis"] ==
               "Die Arbeit ist durch, aber deine Zahlen stimmen nicht mit der Buchhaltung " <>
                 "überein. Zähl nach und ruf fertig() noch einmal auf."

      refute Jason.encode!(a1) =~ "11"

      {s, {:error, _}} = Abschluss.fertig(s, p)
      {s, {:halt, a3}} = Abschluss.fertig(s, p)
      assert a3["fertig"]

      assert {"abschluss.jsonl", %{"zahlen_stimmten" => "nein", "abweichung" => [journal]}} =
               List.last(Stand.journal_liste(s))

      assert journal == "eintraege: du sagst 7, gezaehlt sind 11"
    end
  end

  describe "Phase 2" do
    test "ohne Aussage und mit ungelesenen Bereichen, höchstens zwölf genannt" do
      gelesen = for i <- 0..13, do: {i * 2, i * 2}
      s = %{Stand.neu(bloecke: @bloecke, phase: 2) | gelesen: gelesen}

      assert [leer, nie] = Abschluss.hindernisse(s)
      assert leer =~ "Es steht keine einzige Aussage im Bestand."

      assert nie =~
               "nicht angesehen: 1-1, 3-3, 5-5, 7-7, 9-9, 11-11, 13-13, 15-15, 17-17, 19-19, 21-21, 23-23 …."
    end

    test "Beppo: solange eine Portion aussteht" do
      s = %{Stand.neu(bloecke: @bloecke, phase: 2, beppo: true, beppo_pos: 20) | lfd: 3}
      assert [text] = Abschluss.hindernisse(s)
      assert text =~ "Es liegt noch ein Abschnitt vor dir."
      assert Abschluss.hindernisse(%{s | beppo_pos: 30}) == []
    end

    test "mehrfach Gefundene stehen im Abschluss" do
      s =
        %{Stand.neu(bloecke: @bloecke, phase: 2) | gelesen: [{0, 29}], lfd: 2}
        |> Stand.eintragen(%{"nummer" => 1, "claim" => "a", "_bestaetigt" => 3})
        |> Stand.eintragen(%{
          "nummer" => 2,
          "claim" => "b",
          "_bestaetigt" => 2,
          "_verworfen" => true
        })

      {_, {:halt, a}} = Abschluss.fertig(s, %{"aussagen" => 2, "offen_geblieben" => ""})
      assert a["mehrfach_gefunden"] == 1
      assert a["hinweis"] =~ "1 Aussage(n) wurden von mehreren Durchgaengen unabhaengig gefunden"
    end
  end
end
