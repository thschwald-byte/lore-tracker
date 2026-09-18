defmodule Worker.Jack.Epos.WerkzeugeTest do
  # J6 (#1210, E1): die Werkzeuge des Epos-Überblicks, rein auf dem Stand —
  # kein Mnesia, kein Modell. Beispiele aus der Demo-Welt (Werkstatt am Hafen).
  use ExUnit.Case, async: true

  alias Worker.Jack.Epos.{Abschluss, Notizen, Weg, Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.{Eingabe, Halter, Lesen, Stand, Suche}

  @uhrmacher "Der verschwundene Uhrmacher"
  @arnheim "Die Familie von Arnheim"
  @brief "Der Brief des Uhrmachers"

  @bloecke [
    %{
      text: "Ihr steht im Regen vor der alten Werkstatt am Hafen.",
      sprecher: "SL",
      block_id: "b0"
    },
    %{text: "Ich klopfe zweimal an die Tür und warte.", sprecher: "Mira", block_id: "b1"},
    %{
      text: "Der Alte zeigt euch eine Spieldose mit einem Wappen.",
      sprecher: "SL",
      block_id: "b2"
    },
    %{
      text: "Das Wappen kenne ich, das gehört der Familie von Arnheim.",
      sprecher: "Mira",
      block_id: "b3"
    },
    %{
      text: "Nach zwei Tagen erreicht ihr das Dorf am Rand der Salzminen.",
      sprecher: "SL",
      block_id: "b4"
    }
  ]

  defp roh(id, claim, refs),
    do: %{
      "id" => id,
      "claim" => claim,
      "source_refs" => refs,
      "fact_type" => "ereignis",
      "narration_time" => "present",
      "verified?" => true
    }

  defp zuordnung do
    arc = [%{titel: @uhrmacher, kind: "arc"}]

    %{
      "f_a" => arc,
      "f_c" => arc,
      "f_d" => [%{titel: @arnheim, kind: "context"}],
      "f_e" => arc,
      "f_frueh" => [%{titel: @brief, kind: "arc"}]
    }
  end

  defp station(k, zeile, fakten), do: %{schluessel: k, zeile: zeile, fakten: fakten, boegen: []}

  defp weg do
    [
      station("1", "Ankunft an der Werkstatt", ["S2-F1", "S2-F2"]),
      station("2", "die Spieldose und das Wappen", ["S2-F3", "S2-F4"]),
      station("3", "Ankunft im Dorf an den Salzminen", ["S2-F5"]),
      station("Vorgeschichte", "der Auftrag aus der ersten Sitzung", ["S1-F1"])
    ]
  end

  defp eingabe(opts) do
    positionen = Map.new(Enum.with_index(@bloecke), fn {b, i} -> {b.block_id, i} end)

    diese = [
      roh("f_a", "Die Gruppe steht vor der Werkstatt am Hafen.", ["b0"]),
      roh("f_b", "Mira klopft an die Tür.", ["b1"]),
      roh("f_c", "Der Alte zeigt eine Spieldose mit einem Wappen.", ["b2"]),
      roh("f_d", "Mira erkennt das Wappen der Familie von Arnheim.", ["b3"]),
      roh("f_e", "Die Gruppe erreicht das Dorf an den Salzminen.", ["b4"])
    ]

    fakten = Eingabe.fakten(diese, 2, zuordnung(), positionen)

    fruehe =
      Eingabe.fakten(
        [roh("f_frueh", "Tess nimmt den Brief des Uhrmachers an.", ["x"])],
        1,
        zuordnung(),
        nil
      )

    %{
      art: :epos,
      sitzung: %{id: "s2", nummer: 2, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [%{nummer: 1, name: "Die Werkstatt", fakten: fruehe}],
      boegen: Eingabe.boegen(fakten, []),
      boegen_kampagne: Eingabe.boegen(fruehe ++ fakten, []),
      bloecke: @bloecke,
      cast: ["Mira", "Brann", "Tess"],
      straenge: [@uhrmacher, @arnheim],
      ueberschrift: "Heldenlied",
      flavor: %{base: "Düster", epos: "Nah an der Gruppe."},
      resuemee_diese:
        Keyword.get(
          opts,
          :resuemee,
          "Die Gruppe erreicht im Regen die Werkstatt.\n\nMira erkennt das Wappen der Familie " <>
            "von Arnheim."
        ),
      resuemee_weg: Keyword.get(opts, :weg, weg()),
      kapitel: [
        %{
          nummer: 1,
          name: "Die Werkstatt",
          text: "## Kapitel 1\n\nDer Regen fiel auf den Brief."
        },
        %{
          nummer: 2,
          name: "Nach Norden",
          text: "## Kapitel 2\n\nDas alte Kapitel mit dem Wappen."
        }
      ]
    }
  end

  defp stand(opts \\ []), do: Stand.neu(eingabe(opts))

  defp j(o), do: o |> Jason.encode!() |> Jason.decode!()

  defp gelesen(s), do: s |> Lesen.fakten(%{"von" => 1, "bis" => 5}) |> elem(0)

  defp e(a, k, zeile, fakten \\ [], boegen \\ []),
    do: %{
      "abschnitt" => a,
      "schluessel" => k,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => boegen
    }

  defp notiz(s, eintraege), do: Notizen.notiz(s, %{"eintraege" => eintraege})

  defp form(s),
    do: s |> notiz([e("FORM", "Form", "Heldenlied in Szenen; nah an der Gruppe")]) |> elem(0)

  defp fertig(s, fakten, szenen),
    do: Abschluss.fertig(s, %{"fakten" => fakten, "szenen" => szenen, "offen_geblieben" => ""})

  # Alles gelesen, FORM, drei Szenen, die die drei Pflicht-Stationen tragen.
  defp bereit do
    s = stand() |> gelesen() |> form()

    {s, {:ok, _}} =
      notiz(s, [
        e("SZENEN", "Regen am Hafen", "Nacht, Regen", ["S2-F1"]),
        e("SZENEN", "Die Spieldose", "in der Werkstatt", ["S2-F3"]),
        e("SZENEN", "Das Dorf", "zwei Tage später", ["S2-F5"])
      ])

    s
  end

  describe "Werkzeuge" do
    test "der Überblick: die Lesebasis, resuemee, notiz, notizen_lesen, fertig — streng" do
      s = stand()

      assert Werkzeuge.namen(s) ==
               Worker.Jack.Resuemee.Werkzeuge.lesend() ++ ~w(resuemee notiz notizen_lesen fertig)

      {:ok, h} = Halter.start_link(s)
      w = Map.new(Werkzeuge.fuer(h), &{&1.name, &1})
      # `hilfe` kommt aus `Resuemee.Werkzeuge.aus/3` und gilt für jeden Jack.
      assert Enum.sort(Map.keys(w)) == Enum.sort(["hilfe" | Werkzeuge.namen(s)])

      assert w["notiz"].parameter["required"] == ["eintraege"]
      items = w["notiz"].parameter["properties"]["eintraege"]["items"]
      assert Enum.sort(items["required"]) == ~w(abschnitt boegen fakten schluessel zeile)
      assert items["properties"]["abschnitt"]["enum"] == ~w(FORM SZENEN ABWEICHUNG OFFEN)
      assert Enum.sort(w["fertig"].parameter["required"]) == ~w(fakten offen_geblieben szenen)
      assert w["resuemee"].wiederholung == :frei
      assert w["notizen_lesen"].wiederholung == :frei

      # Die gemeinsamen Lesewerkzeuge sprechen vom Epos.
      assert w["suche_sitzung"].beschreibung =~ "ihren Bögen (Titel, Leitfrage) und ihrem Resümee"
      assert w["bloecke"].beschreibung =~ "Im Epos-Kapitel dient der Mitschnitt"
      assert w["boegen"].beschreibung =~ "Grundlage deiner Szenen"
      assert w["notiz"].beschreibung =~ "„Heldenlied“"

      assert {:ok, t} = w["resuemee"].ausfuehren.(%{})
      assert t =~ "## Das Resümee von Sitzung 2"
      Agent.stop(h)
    end

    test "boegen() spricht von Szenen, der Resümee-Jack weiter von der Gliederung" do
      {_s, {:ok, t}} = Lesen.boegen(stand(), %{})
      assert t =~ "Deine Szenen nennen diese Titel"
      refute t =~ "Gliederung"

      {_s, {:ok, r}} = Lesen.boegen(Stand.neu(%{eingabe([]) | art: :resuemee}), %{})
      assert r =~ "Die Stationen deiner Gliederung"
    end
  end

  describe "notiz" do
    test "erst die FORM, dann SZENEN; die FORM ist genau eine" do
      s = gelesen(stand())

      {s, {:error, a}} = notiz(s, [e("SZENEN", "Regen", "im Regen", ["S2-F1"])])
      assert hd(j(a)["fehler"]) =~ "SZENEN/Regen: erst die FORM"
      assert hd(j(a)["fehler"]) =~ "aus dem Epos-Ton seine Erzählhaltung"
      assert j(a)["es_fehlt"] == ["FORM", "SZENEN"]

      s = form(s)
      {_s, {:error, a}} = notiz(s, [e("FORM", "Andere", "Chronik")])
      assert hd(j(a)["fehler"]) =~ "FORM hat schon einen Eintrag unter „Form“"

      {s, {:ok, a}} =
        notiz(s, [e("SZENEN", "Regen am Hafen", "Nacht, Regen", ["s2-f1", "S2-F2"], [@uhrmacher])])

      assert j(a)["neu"] == 1
      assert j(a)["weg"] =~ "Die Fakten deiner SZENEN reichen von Block 0 bis 1"
      assert [%{fakten: ["S2-F1", "S2-F2"], boegen: [@uhrmacher]}] = Stand.abschnitt(s, "SZENEN")
    end

    test "eine Szene nennt Fakten dieser Sitzung; Unbekanntes wird abgelehnt" do
      s = stand() |> gelesen() |> form()

      for {eintrag, erwartet} <- [
            {e("SZENEN", "a", "x", []), "die Szene nennt keinen Fakt."},
            {e("SZENEN", "b", "x", ["S1-F1"]), "nennt keinen Fakt dieser Sitzung"},
            {e("SZENEN", "c", "x", ["S2-F99"]), "Fakten gibt es nicht: [\"S2-F99\"]"},
            {e("SZENEN", "d", "x", ["S2-F1"], ["Erfunden"]), "Bögen gibt es nicht"}
          ] do
        {_s, {:error, a}} = notiz(s, [eintrag])
        assert hd(j(a)["fehler"]) =~ erwartet
      end

      # Ein Bogen, den nur boegen_kampagne() kennt (aus Sitzung 1), ist bekannt;
      # frühere Fakten dürfen zu einem Fakt dieser Sitzung dazukommen.
      {s, {:ok, _}} = notiz(s, [e("SZENEN", "e", "x", ["S2-F1", "S1-F1"], [@brief])])
      assert [%{boegen: [@brief], fakten: ["S2-F1", "S1-F1"]}] = Stand.abschnitt(s, "SZENEN")
    end

    test "keine Obergrenze für die Zahl der Szenen" do
      s = stand() |> gelesen() |> form()

      eintraege =
        for i <- 1..25, do: e("SZENEN", "Szene #{i}", "Moment #{i}", ["S2-F#{rem(i, 5) + 1}"])

      {s, {:ok, a}} = notiz(s, eintraege)
      assert j(a)["neu"] == 25
      assert length(Stand.abschnitt(s, "SZENEN")) == 25
    end

    test "ABWEICHUNG: der Schlüssel einer Station, Schreibweise egal; unbekannt abgelehnt" do
      s = stand() |> gelesen() |> form()

      {_s, {:error, a}} = notiz(s, [e("ABWEICHUNG", "7", "gibt es nicht")])
      fehler = hd(j(a)["fehler"])
      assert fehler =~ "eine Station „7“ gibt es im Weg aus dem Resümee nicht"
      assert fehler =~ "„1“, „2“, „3“, „Vorgeschichte“"

      {s, {:ok, _}} = notiz(s, [e("ABWEICHUNG", " vorgeschichte ", "steht im vorigen Kapitel")])
      assert [%{schluessel: "Vorgeschichte"}] = Stand.abschnitt(s, "ABWEICHUNG")

      # Andere Schreibweise: derselbe Eintrag wird ersetzt, dann gestrichen.
      {s, {:ok, a}} = notiz(s, [e("ABWEICHUNG", "VORGESCHICHTE", "anders begründet")])
      assert j(a)["ersetzt"] == 1
      {s, {:ok, a}} = notiz(s, [e("ABWEICHUNG", "vorgeschichte", nil)])
      assert j(a)["gestrichen"] == 1
      assert Stand.abschnitt(s, "ABWEICHUNG") == []
    end

    test "ohne Weg aus dem Resümee gibt es keine ABWEICHUNG" do
      s = stand(weg: []) |> gelesen() |> form()
      {_s, {:error, a}} = notiz(s, [e("ABWEICHUNG", "1", "x")])
      assert hd(j(a)["fehler"]) =~ "aus dem Resümee liegt kein Weg vor"
    end
  end

  describe "resuemee()" do
    test "der Text, darunter je Station Zeile, Fakten und wo sie steht" do
      s = stand() |> gelesen() |> form()

      {s, {:ok, _}} =
        notiz(s, [
          e("SZENEN", "Regen am Hafen", "Nacht", ["S2-F1"]),
          e("ABWEICHUNG", "2", "im Kapitel später")
        ])

      {_s, {:ok, t}} = Weg.resuemee(s, %{})

      assert t =~ "## Das Resümee von Sitzung 2\n\nDie Gruppe erreicht im Regen die Werkstatt."
      assert t =~ "## Der Weg der Gruppe aus dem Resümee — 4 Stationen"
      assert t =~ "Station „1“ — Ankunft an der Werkstatt  (in Szene „Regen am Hafen“)"
      assert t =~ "  S2-F1 · Die Gruppe steht vor der Werkstatt am Hafen."
      assert t =~ "Station „2“ — die Spieldose und das Wappen  (unter ABWEICHUNG)"
      assert t =~ "Station „3“ — Ankunft im Dorf an den Salzminen  (noch offen)"

      assert t =~
               "Station „Vorgeschichte“ — der Auftrag aus der ersten Sitzung  (nennt keinen " <>
                 "Fakt dieser Sitzung)"

      assert t =~ "  S1-F1 · (Sitzung 1) Tess nimmt den Brief des Uhrmachers an."
    end

    test "ohne Weg und ohne Resümee: klare Sätze" do
      {_s, {:ok, t}} = Weg.resuemee(stand(weg: [], resuemee: nil), %{})
      assert t =~ "Zu Sitzung 2 liegt kein Resümee vor."
      assert t =~ "Aus dem Resümee liegt kein Weg der Gruppe vor. Du stellst ihn selbst auf"
    end
  end

  describe "Suche" do
    test "suche_sitzung findet im Resümee dieser Sitzung — beim Resümee-Jack nicht" do
      {_s, {:ok, t}} = Suche.suche_sitzung(stand(), %{"begriff" => "Regen"})
      assert t =~ "in Sitzung 2 (ihre Fakten, ihr Mitschnitt, ihre Bögen, ihr Resümee)"
      assert t =~ "## Resümees — 1 Treffer"
      assert t =~ "Resümee S2, Absatz 1 · Die Gruppe erreicht im Regen die Werkstatt."
      refute t =~ "bisherige Fassung"

      resuemee_jack = Stand.neu(%{eingabe([]) | art: :resuemee})
      {_s, {:ok, r}} = Suche.suche_sitzung(resuemee_jack, %{"begriff" => "Regen"})
      assert r =~ "in Sitzung 2 (ihre Fakten, ihr Mitschnitt, ihre Bögen)."
      refute r =~ "Resümee S2"
    end

    test "suche_bisher: Resümee dieser Sitzung als Vorlage, Kapitel als bisherige Fassung, Notizen" do
      s = stand() |> gelesen() |> form()
      {s, {:ok, _}} = notiz(s, [e("SZENEN", "Wappen", "Mira und das Wappen", ["S2-F4"])])

      {_s, {:ok, t}} = Suche.suche_bisher(s, %{"begriff" => "Wappen"})
      assert t =~ "Resümee S2, Absatz 2 · Mira erkennt das Wappen"
      assert t =~ "Kapitel S2 (bisherige Fassung), Absatz 2 · Das alte Kapitel mit dem Wappen."
      assert t =~ "S2 Resümee-Notiz GLIEDERUNG / 2 · die Spieldose und das Wappen"
      assert t =~ "S2 Epos-Notiz SZENEN / Wappen · Mira und das Wappen"
    end
  end

  describe "notizen_lesen" do
    test "Notizen und wo du stehst: Lesestand, FORM, Szenen, offene Stationen, Spanne" do
      s = stand() |> gelesen() |> form()
      {s, {:ok, _}} = notiz(s, [e("SZENEN", "Regen am Hafen", "Nacht", ["S2-F1", "S2-F2"])])

      {_s, {:ok, a}} = Notizen.notizen_lesen(s, %{})
      a = j(a)

      assert a["stand"] =~ "Sitzung 2. Die Epos-Spalte heißt „Heldenlied“.\n"
      refute a["stand"] =~ "mindestens"

      assert a["stand"] =~ "Fakten dieser Sitzung: 5 von 5 gelesen."
      assert a["stand"] =~ "FORM: Heldenlied in Szenen; nah an der Gruppe"
      assert a["stand"] =~ "SZENEN: 1; sie nennen 2 von 5 Fakten dieser Sitzung."

      assert a["stand"] =~
               "Weg aus dem Resümee: 1 von 3 Stationen stehen in einer Szene oder unter " <>
                 "ABWEICHUNG. Noch in keiner Szene und nicht unter ABWEICHUNG: „2“ — die " <>
                 "Spieldose und das Wappen; „3“ — Ankunft im Dorf an den Salzminen."

      assert a["stand"] =~
               "Die Fakten deiner SZENEN reichen von Block 0 bis 1, die Fakten dieser Sitzung " <>
                 "von Block 0 bis 4. Nach Block 1 liegen Fakten, die keine Szene nennt"

      assert a["notizen"] =~
               "## FORM\nForm — Heldenlied in Szenen; nah an der Gruppe\n\n## SZENEN\n" <>
                 "Regen am Hafen — Nacht  [Fakten: S2-F1, S2-F2]"

      assert [%{"abschnitt" => "FORM"}, %{"abschnitt" => "SZENEN"}] = a["eintraege"]
    end

    test "Szenen gegen die Blockreihenfolge: ein Hinweis, keine Ablehnung" do
      s = stand() |> gelesen() |> form()

      {s, {:ok, a}} =
        notiz(s, [
          e("SZENEN", "Das Dorf", "zuerst das Ende", ["S2-F5"]),
          e("SZENEN", "Regen am Hafen", "dann der Anfang", ["S2-F1"])
        ])

      assert j(a)["weg"] =~
               "Die Szenen stehen nicht in Blockreihenfolge: „Regen am Hafen“ beginnt bei " <>
                 "Block 0, vor „Das Dorf“ (Block 4), steht aber dahinter."

      assert length(Stand.abschnitt(s, "SZENEN")) == 2
    end
  end

  describe "fertig" do
    test "Hindernisse: ungelesen, FORM, SZENEN, offene Stationen — einzeln abgearbeitet" do
      s = stand()
      {_s, {:error, a}} = fertig(s, 0, 0)
      offen = j(a)["offen"]

      assert Enum.any?(offen, &(&1 =~ "noch nicht gelesen: 1-5."))
      assert Enum.any?(offen, &(&1 =~ "Die FORM fehlt."))
      assert Enum.any?(offen, &(&1 =~ "Die SZENEN fehlen."))

      assert Enum.any?(
               offen,
               &(&1 =~
                   "weder in einer Szene noch unter ABWEICHUNG: „1“ — Ankunft an der Werkstatt")
             )

      # Eine Station ohne Fakt dieser Sitzung ist keine Pflicht.
      refute Enum.any?(offen, &(&1 =~ "Vorgeschichte"))

      s = s |> gelesen() |> form()

      {s, {:ok, _}} =
        notiz(s, [e("SZENEN", "Regen", "x", ["S2-F1"]), e("SZENEN", "Dorf", "y", ["S2-F5"])])

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "„2“ — die Spieldose und das Wappen"
      refute h =~ "„1“"

      {s, {:ok, _}} = notiz(s, [e("ABWEICHUNG", "2", "im Kapitel Teil der Szene im Regen")])
      assert Abschluss.hindernisse(s) == []
    end

    test "Zahlenabgleich: welche Zahl nicht stimmt und wie sie gezählt ist; der dritte geht durch" do
      s = bereit()

      {s, {:error, a}} = fertig(s, 4, 3)
      a = j(a)

      assert a["abweichung"] == [
               "fakten: du sagst 4 — gezählt sind 5"
             ]

      # Seit 18.09.2026 nennt die Ablehnung die gezählte Zahl: die Arbeit ist
      # durch, nur der Zähler stimmt nicht — sie zu verschweigen kostete nur
      # Runden (an einem echten Chronik-Lauf gesehen).
      assert Jason.encode!(a) =~ "gezählt sind 5"

      {s, {:error, _}} = fertig(s, 4, 3)
      {s, {:halt, a}} = fertig(s, 4, 3)
      assert j(a)["zahlen"] == %{"fakten" => 5, "szenen" => 3}

      [eintrag] =
        for {"abschluss.jsonl", %{"abschluss" => true} = x} <- Stand.journal_liste(s), do: x

      assert eintrag["zahlen_stimmten"] == "nein"
      assert eintrag["abweichung"] == ["fakten: du sagst 4, gezaehlt sind 5"]
      assert eintrag["jack"] == "epos"
      assert eintrag["stationen"] == 3
    end

    test "richtig gemeldet: der Überblick ist abgeschlossen" do
      {_s, {:halt, a}} = fertig(bereit(), 5, 3)
      a = j(a)
      assert a["fertig"] == true
      assert a["zahlen"] == %{"fakten" => 5, "szenen" => 3}
      assert a["weg"] =~ "Die Szenen stehen in Blockreihenfolge."
    end

    test "ohne Weg aus dem Resümee genügen Fakten, FORM und Szenen" do
      s = stand(weg: []) |> gelesen() |> form()
      {s, {:ok, _}} = notiz(s, [e("SZENEN", "Regen", "x", ["S2-F1"])])
      assert {_s, {:halt, _}} = fertig(s, 5, 1)
    end
  end

  describe "Abbild, Ablage, Zusammenfassung" do
    test "das Abbild trägt jack: epos; die Ablage liest das Schreiben zurück" do
      s = bereit()
      a = Notizen.abbild(s)

      assert %{
               "jack" => "epos",
               "lauf" => "ueberblick",
               "gelesen" => 5,
               "fakten" => 5,
               "szenen" => 3,
               "abweichungen" => 0,
               "stationen" => 3,
               "stationen_offen" => []
             } = a

      refute Map.has_key?(a, "mindest_woerter")
      assert is_binary(Jason.encode!(a))

      ablage = Stand.ablage(s)
      assert Enum.map(ablage["notizen"], & &1["abschnitt"]) == ~w(FORM SZENEN SZENEN SZENEN)
      assert length(Stand.fuer_schreiben(eingabe([]), ablage).notizen) == 4
    end

    test "die Zusammenfassung trägt Stil, Stand, Notizen und den nächsten Schritt" do
      t = Zusammenfassung.text(bereit())
      assert t =~ "## Stil\nÜberschrift der Epos-Spalte: „Heldenlied“"
      assert t =~ "**Grundton der Kampagne:** Düster\n\n**Ton des Epos:** Nah an der Gruppe."
      assert t =~ "## Deine Notizen\n## FORM"

      assert t =~
               "## Nächster Schritt\nPrüf deine Szenen mit notizen_lesen() und schließ mit " <>
                 "fertig() ab."

      s = stand() |> gelesen() |> form()
      {s, {:ok, _}} = notiz(s, [e("SZENEN", "Regen", "x", ["S2-F1"])])
      assert Zusammenfassung.text(s) =~ "Diese Stationen aus dem Weg des Resümees stehen noch"

      assert Zusammenfassung.text(stand()) =~ "Lies weiter: fakten(von, bis) ab Fakt 1."
    end

    test "der Ton: beim Resümee-Jack wie bisher, beim Epos-Jack mit dem Epos-Ton" do
      assert Stand.ton(%{base: "a", summary: "b"}) ==
               "**Grundton der Kampagne:** a\n\n**Ton des Resümees:** b"

      assert Stand.ton(%{base: nil, epos: "c"}, :epos) == "**Ton des Epos:** c"
      assert Stand.ton(%{base: nil, epos: nil}, :epos) =~ "kein Ton vorgegeben"
    end
  end
end
