defmodule Worker.Timeline.VorlaufTest do
  @moduledoc """
  Issue #1069 (E5): der deterministische Zeit-Vorlauf.

  Die Pflichtfälle stammen aus der Implementierungs-Empfehlung im Issue und aus
  echten Messungen an `seattle-bereinigt-1` — nicht aus Vorstellungen davon,
  wie ein Transkript aussieht.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.Vorlauf

  defp block(text, opts \\ []) do
    %{
      "id" => "b_#{:erlang.phash2(text)}",
      "text" => text,
      "asr_unsicher" => Keyword.get(opts, :unsicher, false),
      "hat_luecke" => Keyword.get(opts, :luecke, false),
      "konfidenz" => Keyword.get(opts, :konfidenz, "hoch")
    }
  end

  describe "Negativlisten — Teilstring-Suche ist auf Deutsch unbrauchbar" do
    test "die vier gemessenen Fallen lösen nichts aus" do
      # Aus #1069, dreimal gemessen: „Nacht" trifft Nachteil (4 von 6 Treffern
      # Müll), „Gang" trifft VerGANGenheit (10 von 14), „heiss" trifft heisst,
      # „dunkel" trifft Dunkelzahn — einen Drachennamen.
      fallen = [
        "Kriege ich irgendwelche Nachteile?",
        "Das ist in der Vergangenheit passiert.",
        "Wie heisst der denn?",
        "Dunkelzahn war der erste Drache im Fernsehen.",
        "Er leidet unter Nachtentzug."
      ]

      for text <- fallen do
        assert Vorlauf.finde([block(text)]) == [], "Falscher Treffer in: #{text}"
      end
    end

    test "echte Anker werden davon nicht verschluckt" do
      assert [%{art: :tageszeit}] = Vorlauf.finde([block("Wir treffen uns abends.")])
      assert [%{art: :gruss}] = Vorlauf.finde([block("Guten Abend, die Herren.")])
      assert [%{art: :jahr}] = Vorlauf.finde([block("Das war 2080.")])
    end
  end

  describe "Härte = Form × ASR-Konfidenz (D8/D9/D11)" do
    test "ein sicherer Block trägt einen harten Anker" do
      assert [%{haerte: :hart, degradiert: false}] =
               Vorlauf.finde([block("Am 24. Dezember 2011 erwacht der Drache.")])
    end

    test "Block 37: syntaktisch perfekt, inhaltlich ein ASR-Bruch" do
      # Der reale Fall aus seattle-bereinigt-1. Im Text steht „um 20.10 Uhr",
      # gemeint ist die Jahreszahl 2010 — im selben Satz folgen „Ende 2011" und
      # „24. Dezember 2011". Ohne die Degradierung hätte dieser Anker die ganze
      # Session auf „ein Abend um 20:10" festgenagelt.
      b =
        block("Dann so um die, um 20.10 Uhr, fangen die ersten Menschen an…",
          unsicher: true,
          luecke: true,
          konfidenz: "niedrig"
        )

      funde = Vorlauf.finde([b])
      assert [%{art: :uhrzeit, haerte: :weich, degradiert: true}] = funde
      refute Enum.any?(funde, &(&1.haerte == :hart)), "darf nicht bindend sein"
    end

    test "jedes einzelne Warnsignal degradiert" do
      for opts <- [[unsicher: true], [luecke: true], [konfidenz: "niedrig"]] do
        [f] = Vorlauf.finde([block("Das war 2080.", opts)])
        assert f.haerte == :weich, "#{inspect(opts)} muss degradieren"
      end
    end

    test "fehlende Konfidenz zählt als unsicher, nicht als in Ordnung" do
      # Aufnahmen vor #376/#381 tragen keine Flags. Im Code sieht das aus wie
      # ein einwandfreier Block — das ist die teure Richtung.
      ohne = %{"id" => "b_alt", "text" => "Das war 2080."}
      assert Vorlauf.degradiert?(ohne)
      assert [%{haerte: :weich}] = Vorlauf.finde([ohne])
    end
  end

  describe "Widerspruchsregel — der Truman-Fall" do
    test "vier Tageszeiten in einem Satz ergeben KEINEN Anker" do
      # „Guten Morgen, und falls wir uns nicht mehr sehen, guten Tag, guten
      # Abend und gute Nacht." Nur der erste ist eine Aussage über jetzt; die
      # anderen stehen hinter einem Irrealis. Irrealis auf ASR-Deutsch zu
      # erkennen ist schwer — die billige Regel fängt denselben Fall.
      bloecke = [
        block("Guten Morgen."),
        block("Und falls wir uns nicht mehr sehen, guten Tag."),
        block("Guten Abend und gute Nacht.")
      ]

      bereinigt = bloecke |> Vorlauf.finde() |> Vorlauf.bereinige()
      assert bereinigt == [], "Null Anker sind besser als ein falscher"
    end

    test "dieselbe Tageszeit mehrfach bestätigt sich" do
      # Der reale Fall: „Guten Abend" in den Blöcken 591, 592, 594.
      bloecke = [
        block("Romeo ist ein Mensch mit 40. Guten Abend."),
        block("Guten Abend."),
        block("Zwischentext ohne Anker."),
        block("Schönen guten Abend. Ich bin hoch erfreut.")
      ]

      funde = Vorlauf.finde(bloecke)
      bereinigt = Vorlauf.bereinige(funde)

      assert length(bereinigt) == 3, "übereinstimmende Anker überleben"
      assert Vorlauf.bestaetigte_paare(funde) != []
    end

    test "harte Anker stehen nicht zur Abstimmung" do
      # Ein Datum wird nicht dadurch falsch, dass daneben widersprüchliche
      # Grussformeln stehen.
      bloecke = [
        block("Am 24. Dezember 2011 geschah es."),
        block("Guten Morgen."),
        block("Gute Nacht.")
      ]

      bereinigt = bloecke |> Vorlauf.finde() |> Vorlauf.bereinige()
      assert [%{art: :datum, haerte: :hart}] = bereinigt
    end

    test "weit auseinanderliegende Anker widersprechen sich nicht" do
      # Gemessen: zusammengehörige weiche Anker liegen 1–3 Blöcke auseinander,
      # der nächste unabhängige 93 entfernt. Ein sessionweites Fenster würde
      # jede legitime Tageszeit-Progression als Widerspruch werten — der Abend
      # geht nun mal in die Nacht über.
      fuell = for _ <- 1..(Vorlauf.fenster() + 3), do: block("Nichts Zeitliches hier.")
      bloecke = [block("Guten Morgen.")] ++ fuell ++ [block("Gute Nacht.")]

      bereinigt = bloecke |> Vorlauf.finde() |> Vorlauf.bereinige()
      assert length(bereinigt) == 2, "beide bleiben — sie sind eine Progression"
    end
  end

  describe "Rahmen — was sich belegen lässt" do
    test "bestätigte Tageszeit mit ihren Belegen" do
      bloecke = [
        block("Guten Abend, die Herren."),
        block("Guten Abend."),
        block("Nichts Zeitliches."),
        block("Schönen guten Abend.")
      ]

      r = bloecke |> Vorlauf.finde() |> Vorlauf.rahmen()
      assert r.tageszeit == :abend
      assert length(r.tageszeit_belege) == 3
    end

    test "ein einzelner Gruss begründet keine Tageszeit" do
      # Ein einzelnes „Guten Abend" kann ein Zitat sein, eine Floskel, ein
      # Rollenspiel-Einstieg. Erst die Wiederholung im Fenster trägt.
      r = [block("Guten Abend.")] |> Vorlauf.finde() |> Vorlauf.rahmen()
      assert r.tageszeit == nil
    end

    test "Jahre sind KANDIDATEN mit Häufigkeit, keine Feststellung" do
      # Gemessen an S1: von drei harten Jahres-Ankern gehören zwei zur
      # Handlungszeit (2080) und einer zur erzählten Weltgeschichte (2070).
      # Wer „Jahreszahl gefunden ⇒ Session spielt dann" schliesst, liegt in
      # einem von drei Fällen falsch. Das Signal ist die Wiederholung.
      bloecke = [
        block("2080, die Welt von Shadowrun, wie sieht die aus?"),
        block("Fuji ist in den Konzernkriegen 2070 auseinandergebrochen."),
        block("2080 kann alles sein.")
      ]

      r = bloecke |> Vorlauf.finde() |> Vorlauf.rahmen()
      assert r.jahr_kandidaten == [{2080, 2}, {2070, 1}]
      # KEIN Feld, das ein Jahr behauptet.
      refute Map.has_key?(r, :jahr)
      refute Map.has_key?(r, :session_jahr)
    end

    test "ein degradierter Block begründet keinen Jahres-Kandidaten" do
      # Block 37: „um 20.10 Uhr" für die Jahreszahl 2010. Eine von der ASR
      # verstümmelte Ziffernfolge darf kein Jahr vorschlagen.
      bloecke = [
        block("Um 20.10 Uhr, also 2011, geschah es.",
          unsicher: true,
          luecke: true,
          konfidenz: "niedrig"
        )
      ]

      r = bloecke |> Vorlauf.finde() |> Vorlauf.rahmen()
      assert r.jahr_kandidaten == []
      assert r.degradierte_anker > 0
    end

    test "keine Tagesgrenze heisst: ein Tag" do
      ohne = [block("Guten Abend."), block("Wir gehen in den Club.")]
      assert %{tagesgrenzen: 0} = ohne |> Vorlauf.finde() |> Vorlauf.rahmen()

      mit = [block("Guten Abend."), block("Am nächsten Morgen: es dämmert.")]
      assert %{tagesgrenzen: 1} = mit |> Vorlauf.finde() |> Vorlauf.rahmen()
    end

    test "widersprüchliche Grüsse ergeben keine Tageszeit" do
      # Die Truman-Zeile darf sich auch im Rahmen nicht durchsetzen.
      bloecke = [
        block("Guten Morgen."),
        block("Und falls wir uns nicht mehr sehen, guten Tag."),
        block("Guten Abend und gute Nacht.")
      ]

      assert %{tageszeit: nil} = bloecke |> Vorlauf.finde() |> Vorlauf.rahmen()
    end
  end

  describe "Fundstellen tragen den Wortlaut, nicht die Deutung" do
    test "jeder Fund nennt Position und getroffenen Text" do
      [f] = Vorlauf.finde([block("Wir sehen uns abends im Club.")])
      assert f.block_index == 0
      assert f.wortlaut == "abends"
      assert f.art == :tageszeit
      # Was „abends" bedeutet, entscheidet dieses Modul NICHT — es liefert die
      # Fundstelle. Sobald ein Werkzeug interpretiert, wird es zur Fehlerquelle
      # mit Autorität (s. #1069, „Zeiger, nicht Befund").
      refute Map.has_key?(f, :bedeutung)
      refute Map.has_key?(f, :uhrzeit_von)
    end

    test "Reihenfolge folgt dem Transkript" do
      bloecke = [block("Guten Abend."), block("Nichts."), block("Das war 2080.")]
      indizes = bloecke |> Vorlauf.finde() |> Enum.map(& &1.block_index)
      assert indizes == Enum.sort(indizes)
    end
  end
end
