defmodule Worker.Jack.OrdnenTest do
  # Phase 3 als Ablauf: a ordnet, b prüft und rollt zurück, c bessert nach.
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.{Abschluss, Ordnung, Pruefung, Redaktion, Stand, Werkzeuge}

  @texte %{
    7 => "Der Uhrmacher ist seit drei Wochen verschwunden.",
    8 => "Seit drei Wochen fehlt vom Uhrmacher jede Spur.",
    250 => "Die Mine liegt im Norden."
  }

  defp stand(opts \\ []) do
    bloecke =
      for i <- 0..400, do: %{text: Map.get(@texte, i, "Fuellsatz Nummer #{i}."), sprecher: "SL"}

    [
      {1, "Der Uhrmacher ist seit drei Wochen verschwunden.", [7],
       "seit drei Wochen verschwunden"},
      {2, "Seit drei Wochen ist der Uhrmacher verschwunden.", [8],
       "fehlt vom Uhrmacher jede Spur"},
      {3, "Die Mine liegt im Norden.", [250], "Die Mine liegt im Norden"}
    ]
    |> Enum.reduce(Stand.neu([bloecke: bloecke, phase: 3] ++ opts), fn {nr, claim, refs, beleg},
                                                                       s ->
      Stand.eintragen(s, %{
        "nummer" => nr,
        "claim" => claim,
        "source_refs" => refs,
        "beleg" => beleg
      })
    end)
    |> Map.put(:lfd, 3)
  end

  defp rolle(s, rolle, runde \\ 1),
    do: %{s | ordnung: %{s.ordnung | rolle: rolle, runde: runde}, abschluss_zahlversuche: 0}

  test "Raster, Stufen, Kennungen" do
    assert Ordnung.raster(400) == [{0, 200}, {150, 350}, {300, 400}]
    assert Ordnung.raster(-1) == []
    assert Ordnung.stufen_der_runde(1) == Ordnung.stufen()
    assert Ordnung.stufen_der_runde(5) == ["kritisch"]
    assert Ordnung.stufen_der_runde(6) == []
    assert Ordnung.id_nummer("r12") > Ordnung.id_nummer("r7")
  end

  test "die Werkzeuge je Rolle, und nur dort, wo sie hingehören" do
    assert Werkzeuge.namen(stand(rolle: "a")) |> Enum.take(-5) ==
             ~w(aussagen kandidat_getrennt aussage_berichtigen aussage_verwerfen aussage_zusammenfuehren)

    assert Werkzeuge.namen(stand(rolle: "b")) |> Enum.take(-4) ==
             ~w(aussagen aenderungen aenderung_annehmen aenderung_ablehnen)

    c = Werkzeuge.namen(stand(rolle: "c"))
    assert "ablehnung_erledigt" in c and "aussage_zusammenfuehren" in c
    refute "aussage" in c

    for d <- Redaktion.werkzeuge(stand()) ++ Pruefung.werkzeuge(stand()) do
      w =
        Werkzeug.neu(
          name: d.name,
          beschreibung: d.beschreibung,
          parameter: d.parameter,
          wiederholung: Map.get(d, :wiederholung, :zaehlt),
          aendert_bestand: Map.get(d, :aendert_bestand, false),
          ausfuehren: fn _ -> {:ok, ""} end
        )

      if d.name in ~w(aussagen aenderungen ablehnungen),
        do: assert(w.wiederholung == :bis_aenderung and not w.aendert_bestand),
        else: assert(w.aendert_bestand)
    end
  end

  describe "Rolle a — ordnen" do
    test "aussagen: der Bereich, die Kandidaten, der nächste Bereich, die offene Arbeit" do
      {s, {:ok, a}} = Redaktion.aussagen(stand(), %{"von" => 0, "bis" => 200})

      assert Jason.encode!(a) =~ ~s({"bereich":"0-200","anzahl":2,"aussagen":[{"nummer":1,)
      assert [%{} = k] = a["dubletten_kandidaten"] |> Enum.map(&Map.new(&1.values))
      assert k == %{"paar" => [1, 2], "deckung" => 1.0, "gemeinsamer_block" => false}
      assert a["portion"] == "1 von 3"
      assert a["naechster_bereich"] == "150-350"
      assert a["offene_arbeit"]["kandidaten_offen"] == [[1, 2]]
      assert a["nicht_fertig"] =~ "Noch offen: 2 Bereich(e), 1 Kandidatenpaar(e)."

      assert Enum.map(Stand.journal_liste(s), &elem(&1, 0)) == [
               "kandidaten.jsonl",
               "bereiche.jsonl"
             ]
    end

    test "kandidat_getrennt: erledigt ein Paar, einmal" do
      {s, _} = Redaktion.aussagen(stand(), %{"von" => 0, "bis" => 200})
      {s, {:ok, a}} = Redaktion.kandidat_getrennt(s, %{"nummern" => [2, 1], "grund" => "anders"})
      assert a["offene_kandidaten"] == 0
      assert s.ordnung.getrennt_neu == 1

      assert {_, {:error, e}} =
               Redaktion.kandidat_getrennt(s, %{"nummern" => [1, 2], "grund" => "x"})

      assert e["fehler"] == ["1/2 ist schon getrennt."]

      assert {_, {:error, e}} =
               Redaktion.kandidat_getrennt(s, %{"nummern" => [1, 99], "grund" => "x"})

      assert e["fehler"] == ["Gibt es nicht: [99]"]
    end

    test "zusammenführen, verwerfen, berichtigen — mit Beleg, mit Verlauf" do
      s = stand()

      assert {_, {:error, e}} =
               Redaktion.aussage_zusammenfuehren(s, %{
                 "behalten" => 1,
                 "aufgeben" => 2,
                 "claim" => "x",
                 "beleg" => "seit drei Wochen verschwunden",
                 "source_refs" => [7, 999],
                 "grund" => "dasselbe"
               })

      assert e["fehler"] == ["source_refs nennt Bloecke, die es nicht gibt: [999]"]

      {s, {:ok, z}} =
        Redaktion.aussage_zusammenfuehren(s, %{
          "behalten" => 1,
          "aufgeben" => 2,
          "claim" => "Der Uhrmacher ist seit drei Wochen verschwunden, ohne Spur.",
          "beleg" => "seit drei Wochen verschwunden … fehlt vom Uhrmacher jede Spur",
          "source_refs" => [7, 8, 7],
          "grund" => "dieselbe Sache, zwei Belege"
        })

      assert Map.new(z.values) == %{"ok" => true, "nummer" => 1, "verworfen" => 2, "id" => "r1"}

      assert %{"_verworfen" => true, "_grund" => "zusammengefuehrt in Nr. 1"} =
               Stand.bestand_von(s, 2)

      assert %{"source_refs" => [7, 8], "_zusammengefuehrt" => [2]} = Stand.bestand_von(s, 1)

      {s, {:ok, _}} =
        Redaktion.aussage_verwerfen(s, %{"nummer" => 3, "grund" => "keine Weltaussage"})

      assert {_, {:error, e}} = Redaktion.aussage_verwerfen(s, %{"nummer" => 3, "grund" => "x"})
      assert e["fehler"] == ["Nr. 3 ist schon verworfen."]

      assert {_, {:error, e}} =
               Redaktion.aussage_berichtigen(s, %{
                 "nummer" => 1,
                 "claim" => "neu",
                 "beleg" => "Die Tür ist zu",
                 "source_refs" => [7],
                 "grund" => "genauer"
               })

      # zwei Befunde: das Stück steht nicht im Block, und Block 7 ist nicht zitiert
      assert [text, _refs] = e["fehler"]
      assert text =~ "stehen in keinem der genannten Blöcke"

      {s, {:ok, _}} =
        Redaktion.aussage_berichtigen(s, %{
          "nummer" => 1,
          "claim" => "Der Uhrmacher ist seit drei Wochen verschwunden.",
          "beleg" => "seit drei Wochen verschwunden",
          "source_refs" => [7],
          "grund" => "Block 8 trägt nichts Eigenes"
        })

      assert %{"_berichtigt" => 1, "source_refs" => [7]} = Stand.bestand_von(s, 1)
      assert Enum.map(s.ordnung.verlauf, & &1["was"]) == ~w(zusammengefuehrt verworfen berichtigt)

      assert Abschluss.ist_zahlen(s) ==
               %{"zusammengefuehrt" => 1, "berichtigt" => 1, "verworfen" => 1, "getrennt" => 0}
    end

    test "fertig: erst alle Bereiche, dann ist nichts mehr offen" do
      s = stand()
      assert [nie] = Abschluss.hindernisse(s)

      assert nie ==
               "Nie angesehen: 0-200, 150-350, 300-400 (durch: 0 von 3). Jeder Bereich gehoert geholt."

      s =
        Enum.reduce([{0, 200}, {150, 350}, {300, 400}], s, fn {v, b}, s ->
          s |> Redaktion.aussagen(%{"von" => v, "bis" => b}) |> elem(0)
        end)

      assert [kand] = Abschluss.hindernisse(s)

      assert kand =~
               "1 Kandidatenpaar(e) unentschieden: 1/2. Zusammenfuehren oder kandidat_getrennt()"

      {s, _} = Redaktion.kandidat_getrennt(s, %{"nummern" => [1, 2], "grund" => "anders"})
      assert Abschluss.hindernisse(s) == []

      assert Abschluss.werkzeuge(s) |> hd() |> Map.get(:beschreibung) =~
               "zusammengefuehrt, berichtigt, verworfen, getrennt"

      p = %{
        "zusammengefuehrt" => 0,
        "berichtigt" => 0,
        "verworfen" => 0,
        "getrennt" => 1,
        "offen_geblieben" => ""
      }

      assert {s, {:halt, _}} = Abschluss.fertig(s, p)

      assert {"abschluss.jsonl", %{"rolle" => "a", "zahlen_stimmten" => "ja"}} =
               List.last(Stand.journal_liste(s))
    end
  end

  # a hat zusammengeführt (r1), verworfen (r2) und berichtigt (r3).
  defp nach_a do
    s = stand()

    {s, _} =
      Redaktion.aussage_zusammenfuehren(s, %{
        "behalten" => 1,
        "aufgeben" => 2,
        "claim" => "Der Uhrmacher ist seit drei Wochen verschwunden, ohne Spur.",
        "beleg" => "seit drei Wochen verschwunden … fehlt vom Uhrmacher jede Spur",
        "source_refs" => [7, 8],
        "grund" => "dieselbe Sache"
      })

    {s, _} = Redaktion.aussage_verwerfen(s, %{"nummer" => 3, "grund" => "keine Weltaussage"})

    {s, _} =
      Redaktion.aussage_berichtigen(s, %{
        "nummer" => 1,
        "claim" => "Der Uhrmacher fehlt.",
        "beleg" => "seit drei Wochen verschwunden",
        "source_refs" => [7],
        "grund" => "kürzer"
      })

    s
  end

  describe "Rolle b — prüfen" do
    test "aenderungen zeigt die offenen Schritte eines Bereichs, mit Vorher und Jetzt" do
      s = rolle(nach_a(), "b")
      {s, {:ok, a}} = Pruefung.aenderungen(s, %{"von" => 0, "bis" => 200})

      assert a["anzahl"] == 2
      assert Enum.map(a["aenderungen"], & &1["id"]) == ["r1", "r3"]
      # r1 ergab die zusammengeführte Fassung, jetzt steht dort die berichtigte
      assert hd(a["aenderungen"])["jetzt"]["claim"] == "Der Uhrmacher fehlt."
      assert a["wirksame_stufen"] == Ordnung.stufen()
      assert MapSet.member?(s.ordnung.gesehen, "p0-200")
    end

    test "zurückrollen: der spätere Schritt zuerst, dann steht der alte Stand wieder da" do
      s = rolle(nach_a(), "b")

      assert {_, {:error, e}} =
               Pruefung.aenderung_ablehnen(s, %{"id" => "r1", "stufe" => "schwer", "grund" => "x"})

      assert e["fehler"] == [
               ~s(Auf r1 bauen spaetere Schritte auf: ["r3"]. Lehne den spaetesten zuerst ab.)
             ]

      {s, {:ok, a}} =
        Pruefung.aenderung_ablehnen(s, %{
          "id" => "r3",
          "stufe" => "schwer",
          "grund" => "Block 7 sagt mehr"
        })

      assert a["zurueckgerollt"] == 1

      assert Stand.bestand_von(s, 1)["claim"] ==
               "Der Uhrmacher ist seit drei Wochen verschwunden, ohne Spur."

      assert [%{abschnitt: "ABLEHNUNGEN", schluessel: "zurueck-r3", bloecke: [7, 8]} = n] =
               s.register

      assert n.zeile == "berichtigt an #1 zurueckgerollt (schwer, Runde 1): Block 7 sagt mehr"

      assert {_, {:error, e}} =
               Pruefung.aenderung_ablehnen(s, %{"id" => "r3", "stufe" => "schwer", "grund" => "x"})

      assert e["fehler"] == ["r3 ist schon abgelehnt."]

      {s, {:ok, an}} =
        Pruefung.aenderung_annehmen(s, %{"ids" => ["r1", "r2", "r99"], "anmerkung" => ""})

      assert an["angenommen"] == ["r1", "r2"]
      assert an["hinweise"] == [~s|Kennung(en) gibt es nicht: ["r99"]|]
      assert an["noch_offen"] == 0

      assert Abschluss.ist_zahlen(s) == %{"angenommen" => 2, "abgelehnt" => 1}
      assert [nie] = Abschluss.hindernisse(s)
      assert nie =~ "Nie angesehen: 0-200, 150-350, 300-400"
    end

    test "eine Stufe, die in dieser Runde nicht mehr zählt, rollt nichts zurück" do
      s = rolle(nach_a(), "b", 3)

      assert {_, {:error, e}} =
               Pruefung.aenderung_ablehnen(s, %{"id" => "r3", "stufe" => "leicht", "grund" => "x"})

      assert hd(e["fehler"]) =~
               "In Runde 3 zaehlt die Stufe „leicht“ nicht mehr — noch wirksam: kritisch, schwer, mittel."
    end

    test "offene Schritte halten den Abschluss auf" do
      s = rolle(nach_a(), "b")

      s =
        Enum.reduce([{0, 200}, {150, 350}, {300, 400}], s, fn {v, b}, s ->
          s |> Pruefung.aenderungen(%{"von" => v, "bis" => b}) |> elem(0)
        end)

      assert [offen] = Abschluss.hindernisse(s)

      assert offen ==
               "3 Aenderung(en) sind weder angenommen noch abgelehnt: r1, r2, r3. Jede Aenderung braucht eine Entscheidung."
    end
  end

  describe "Rolle c — nachbessern" do
    defp nach_b do
      s = rolle(nach_a(), "b")

      {s, _} =
        Pruefung.aenderung_ablehnen(s, %{"id" => "r3", "stufe" => "schwer", "grund" => "zu knapp"})

      {s, _} = Pruefung.aenderung_annehmen(s, %{"ids" => ["r1", "r2"], "anmerkung" => "hält"})
      rolle(s, "c")
    end

    test "ablehnungen: die Arbeitsliste mit beiden Begründungen und dem Stand jetzt" do
      {_, {:ok, a}} = Pruefung.ablehnungen(nach_b(), %{"alle" => false})
      assert a["offen"] == 1
      assert [l] = a["ablehnungen"]

      assert %{"id" => "r3", "grund_a" => "kürzer", "grund_b" => "zu knapp", "stufe" => "schwer"} =
               l

      assert [%{"nummer" => 1, "verworfen" => false}] = l["stand_jetzt"]
    end

    test "nachgebessert verlangt einen neuen Schritt — eine Annahme durch b zählt nicht" do
      s = nach_b()

      assert {_, {:error, e}} =
               Pruefung.ablehnung_erledigt(s, %{
                 "id" => "r3",
                 "entscheidung" => "nachgebessert",
                 "begruendung" => "x"
               })

      assert hd(e["fehler"]) =~ "Du hast an #1 seit der Ablehnung nichts geaendert."

      {s, _} =
        Redaktion.aussage_berichtigen(s, %{
          "nummer" => 1,
          "claim" => "Der Uhrmacher ist seit drei Wochen verschwunden.",
          "beleg" => "seit drei Wochen verschwunden",
          "source_refs" => [7],
          "grund" => "vollständig, aber nur Block 7"
        })

      {s, {:ok, a}} =
        Pruefung.ablehnung_erledigt(s, %{
          "id" => "r3",
          "entscheidung" => "nachgebessert",
          "begruendung" => "neu gefasst"
        })

      assert a["noch_offen"] == 0

      assert [
               %{
                 schluessel: "zurueck-r3",
                 zeile: "nachgebessert (Runde 1): neu gefasst",
                 bloecke: [7, 8]
               }
             ] = s.register

      assert {_, {:error, e}} =
               Pruefung.ablehnung_erledigt(s, %{
                 "id" => "r3",
                 "entscheidung" => "angenommen",
                 "begruendung" => "x"
               })

      assert e["fehler"] == ["r3 ist schon abgehakt."]
    end

    test "eine nicht abgehakte Ablehnung hält den Abschluss auf" do
      s =
        Enum.reduce([{0, 200}, {150, 350}, {300, 400}], nach_b(), fn {v, b}, s ->
          s |> Redaktion.aussagen(%{"von" => v, "bis" => b}) |> elem(0)
        end)

      assert Abschluss.hindernisse(s) == [
               "1 Ablehnung(en) sind nicht abgehakt. Nach dem Handeln jeweils ablehnung_erledigt()."
             ]
    end
  end
end
