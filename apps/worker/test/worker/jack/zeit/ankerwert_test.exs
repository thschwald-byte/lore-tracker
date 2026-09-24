defmodule Worker.Jack.Zeit.AnkerwertTest do
  @moduledoc """
  #1247: die **zehn echten Ankerwerte** aus dem Lauf vom 24.09.2026 — und
  warum keiner von ihnen eine Minute ergab.

  Der Lauf war erfolgreich: 27 Glieder, alle 2168 Zeilen entschieden, ein
  einziger Befund. Und trotzdem unbrauchbar für die Zeitrechnung, denn die
  zehn gesetzten Anker waren durchweg undatiert. Drei verschiedene Ursachen
  steckten dahinter:

    * **Erläuterung im Wert** (fünfmal): „2070 (Konzernkriege, Fuji
      zerbricht)". Ohne den Klammerzusatz lesbar.
    * **Zwei Ausdrücke mit Schrägstrich** (zweimal): „Ende 2011 / am
      24. Dezember 2011". Jeder für sich lesbar.
    * **Dauer als Zeitpunkt** (dreimal): „60 Jahre her", „sechs Jahre". Das
      lehnt der Parser zu Recht ab — eine Dauer ist kein Datum.

  Dazu ein echter Mangel im Parser: „um 2010" war nicht lesbar, obwohl
  „2010", „im Jahr 2010" und „am 2010" es sind. Das Füllwort stand in keiner
  Liste.

  **Die Werte stehen hier wörtlich**, weil sie aus einem echten Lauf stammen
  und die Regeln an ihnen gemessen wurden — nicht an ausgedachten Beispielen,
  die dieselbe Annahme tragen wie der Code (die #1149-Lehre).
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Ausdruck, Calendar}

  defp minute(wert, art \\ :zeitpunkt) do
    Ausdruck.aufloesen(%{art: art, wert: wert, utterance_ids: []}, Calendar.default())[:minute]
  end

  describe "der Parser-Mangel, der den Lauf mit betroffen hat" do
    test "um 2010 ist ein Jahr" do
      assert minute("um 2010") == minute("2010")
      assert is_integer(minute("um 2080"))
    end

    test "aber um sieben bleibt eine Uhrzeit, keine Jahreszahl" do
      # Die Schranke ist dieselbe wie bei „kurz vor 2080": Das Füllwort
      # fällt nur vor einer drei- bis fünfstelligen Zahl. Ohne sie würde aus
      # „um sieben" der Wert 7 — ein Jahr im ersten Jahrhundert.
      refute is_integer(minute("um sieben"))
      refute is_integer(minute("um halb acht"))
    end
  end

  describe "die zehn Werte des echten Laufs" do
    @klammer [
      "um 2010 (erste Metamenschen)",
      "2070 (Konzernkriege, Fuji zerbricht)",
      "Mitte der 2060er (zweiter Crash)",
      "in den frühen 2000ern (Vitas-Plage)",
      "2055 bis 2065 (Vorgeschichte)"
    ]

    test "mit Erläuterung in Klammern: nicht lesbar" do
      for w <- @klammer do
        refute is_integer(minute(w)), "#{w} dürfte keine Minute ergeben"
      end
    end

    test "ohne den Zusatz: lesbar — das ist der Vorschlag, den die Antwort nennt" do
      for w <- @klammer do
        ohne = w |> String.replace(~r/\s*\([^)]*\)\s*$/u, "") |> String.trim()

        assert is_integer(minute(ohne)),
               "#{ohne} müsste lesbar sein, sonst trägt der Vorschlag nicht"
      end
    end

    test "zwei Ausdrücke mit Schrägstrich: erst der vordere allein trägt" do
      voll = "Ende 2011 / am 24. Dezember 2011"
      refute is_integer(minute(voll))
      assert is_integer(minute("Ende 2011"))
      assert is_integer(minute("am 24. Dezember 2011"))
    end

    test "eine Dauer als Zeitpunkt bleibt abgelehnt — das ist richtig so" do
      # „60 Jahre her" ist kein Datum. Hier darf kein Vorschlag greifen:
      # Wer das zurechtschneidet, erfindet ein Jahr.
      for w <- ["60 Jahre her (relativ zur Gegenwart)", "sechs Jahre (KI-Experimente)"] do
        refute is_integer(minute(w))
        ohne = w |> String.replace(~r/\s*\([^)]*\)\s*$/u, "") |> String.trim()
        refute is_integer(minute(ohne)), "#{ohne} ist eine Dauer, kein Zeitpunkt"
      end
    end
  end

  describe "die Werkzeugbeschreibung sagt es" do
    test "das Wert-Feld verbietet Erläuterung und Schrägstrich ausdrücklich" do
      beschreibung =
        Worker.Jack.Zeit.Anker.werkzeuge()
        |> Enum.find(&(&1.name == "setz_zeitpunkt"))
        |> get_in([:parameter, "properties", "wert", "description"])

      assert beschreibung =~ "KEINE Erläuterung"
      assert beschreibung =~ "Schrägstrich"
      assert beschreibung =~ "beleg"
    end
  end
end
