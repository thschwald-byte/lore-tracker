defmodule Worker.Jack.BeispieleTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Beispiele, Halter, Stand, Werkzeuge}

  # Erfundener Minimalsatz im Format der echten Datei (Festlegung eve, 11.09.).
  @text """
  # Beispiele (Test)

  Grundregel: im Zweifel aufnehmen.

  ---

  ### Beispiel 1 · Regel · Probe erklärt
  ohne System · Tisch · synthetisch
  Mitschnitt:
    [SL] Du würfelst gegen deinen Wert.
  Entscheidung: keine Aussage.

  ### Beispiel 2 · entfallen
  Grund: doppelt zu 1.

  ### Beispiel 3 · Handlung · Die Tür
  ohne System · synthetisch
  Mitschnitt:
    [SL] Hinter dem Regal ist eine Tür.
  Entscheidung: Aussage: „Hinter dem Regal liegt eine Tür.“

  """

  defp satz do
    {:ok, b} = Beispiele.lesen(@text)
    b
  end

  # Wie die Antwort beim Modell ankommt: kompaktes JSON (Lauf.als_text).
  defp json({:ok, antwort}), do: Jason.encode!(antwort)

  describe "Lesen" do
    test "Regeln ohne abschließendes ---, Abschnitte samt Kopfzeile, ohne Leerraum am Ende" do
      b = satz()
      assert b.regeln == "# Beispiele (Test)\n\nGrundregel: im Zweifel aufnehmen."

      assert [
               %{nummer: 1, klasse: "Regel", stichwort: "Probe erklärt"},
               %{nummer: 2, klasse: "entfallen", stichwort: nil},
               %{nummer: 3, klasse: "Handlung", stichwort: "Die Tür"}
             ] = b.eintraege

      assert Beispiele.eintrag(b, 1).text ==
               "### Beispiel 1 · Regel · Probe erklärt\nohne System · Tisch · synthetisch\n" <>
                 "Mitschnitt:\n  [SL] Du würfelst gegen deinen Wert.\nEntscheidung: keine Aussage."

      assert String.ends_with?(Beispiele.eintrag(b, 3).text, "liegt eine Tür.“")
      assert b.sha256 == :crypto.hash(:sha256, @text) |> Base.encode16(case: :lower)
      assert Beispiele.max(b) == 3
    end

    test "unlesbare Kopfzeile und doppelte Nummer sind Fehler beim Laden" do
      unsinn = String.replace(@text, "### Beispiel 3 · Handlung", "### Beispiel 3 · Unsinn")

      assert {:error, {:unlesbare_kopfzeile, "### Beispiel 3 · Unsinn · Die Tür"}} =
               Beispiele.lesen(unsinn)

      doppelt = String.replace(@text, "### Beispiel 3 ·", "### Beispiel 1 ·")
      assert {:error, {:doppelte_nummer, [1]}} = Beispiele.lesen(doppelt)

      assert {:error, :keine_beispiele} = Beispiele.lesen("# nur Regeln\n")
    end

    test "Kopfzeilen-Kandidat ist nur „### Beispiel “ mit Leerzeichen; Lücken sind kein Fehler" do
      mit_zeilen =
        String.replace(
          @text,
          "Grund: doppelt zu 1.",
          "Grund: doppelt zu 1.\n### Beispiele sind keine Kopfzeile\n### Beispiel"
        )

      assert {:ok, b} = Beispiele.lesen(mit_zeilen)
      assert Beispiele.eintrag(b, 2).text =~ "### Beispiele sind keine Kopfzeile\n### Beispiel"

      luecke = String.replace(@text, "### Beispiel 3 ·", "### Beispiel 5 ·")
      assert {:ok, b} = Beispiele.lesen(luecke)
      assert Beispiele.max(b) == 5

      assert Jason.encode!(elem(Beispiele.beispiel(b, 3), 1)) ==
               ~s|{"fehler":"Beispiel 3 gibt es nicht, vorhanden sind 1–5."}|

      assert Jason.encode!(elem(Beispiele.beispiele(b, %{"suche" => "", "alle" => true}), 1)) ==
               ~s|{"fehler":"Entweder suche oder alle, nicht beides."}|
    end

    @tag :tmp_dir
    test "laden/1 merkt sich den Pfad; eine fehlende Datei ist ein Fehler", %{tmp_dir: dir} do
      pfad = Path.join(dir, "beispiele.md")
      File.write!(pfad, @text)
      assert {:ok, %Beispiele{pfad: ^pfad, eintraege: [_, _, _]}} = Beispiele.laden(pfad)

      assert {:error, {:beispiele_datei, _, :enoent}} =
               Beispiele.laden(Path.join(dir, "fehlt.md"))
    end
  end

  describe "beispiele — kompaktes JSON in fester Reihenfolge" do
    test "ohne Angabe und mit alle: false: Regeln, Übersicht mit Entfallenen, Hinweis" do
      erwartet =
        ~s|{"regeln":"# Beispiele (Test)\\n\\nGrundregel: im Zweifel aufnehmen.",| <>
          ~s|"beispiele":[{"nummer":1,"klasse":"Regel","stichwort":"Probe erklärt"},| <>
          ~s|{"nummer":2,"klasse":"entfallen","stichwort":""},| <>
          ~s|{"nummer":3,"klasse":"Handlung","stichwort":"Die Tür"}],| <>
          ~s|"hinweis":"beispiel(n) zeigt ein Beispiel vollständig, beispiele(alle: true) alle."}|

      assert json(Beispiele.beispiele(satz(), %{})) == erwartet
      assert json(Beispiele.beispiele(satz(), %{"alle" => false})) == erwartet
    end

    test "suche: jedes Wort als Teilzeichenkette, ohne Groß/klein, Entfallene treffen nie" do
      assert json(Beispiele.beispiele(satz(), %{"suche" => "REGAL tü"})) ==
               ~s|{"suche":"REGAL tü","treffer":[{"nummer":3,"klasse":"Handlung","stichwort":"Die Tür"}],| <>
                 ~s|"hinweis":"beispiel(n) zeigt ein Beispiel vollständig."}|

      assert json(Beispiele.beispiele(satz(), %{"suche" => "Tür Drache"})) ==
               ~s|{"suche":"Tür Drache","treffer":[],| <>
                 ~s|"hinweis":"Kein Beispiel enthält „Tür Drache“. beispiele() zeigt die Übersicht."}|

      # "doppelt" steht nur im entfallenen Beispiel 2.
      assert json(Beispiele.beispiele(satz(), %{"suche" => "doppelt"})) =~ ~s|"treffer":[]|
    end

    test "alle: true: Regeln und alle nicht entfallenen Abschnitte" do
      a = Beispiele.eintrag(satz(), 1).text
      c = Beispiele.eintrag(satz(), 3).text

      assert json(Beispiele.beispiele(satz(), %{"alle" => true})) ==
               Jason.encode!(
                 Jason.OrderedObject.new([
                   {"regeln", satz().regeln},
                   {"beispiele",
                    [
                      Jason.OrderedObject.new([{"nummer", 1}, {"text", a}]),
                      Jason.OrderedObject.new([{"nummer", 3}, {"text", c}])
                    ]}
                 ])
               )
    end

    test "Fehler sind normale Ergebnisse" do
      assert json(Beispiele.beispiele(satz(), %{"suche" => "Tür", "alle" => true})) ==
               ~s|{"fehler":"Entweder suche oder alle, nicht beides."}|

      assert json(Beispiele.beispiele(satz(), %{"suche" => "  "})) ==
               ~s|{"fehler":"suche ist leer."}|
    end
  end

  describe "beispiel" do
    test "genau eines; unbekannte Nummer nennt den Bereich; entfallen" do
      assert json(Beispiele.beispiel(satz(), 3)) ==
               Jason.encode!(
                 Jason.OrderedObject.new([
                   {"nummer", 3},
                   {"text", Beispiele.eintrag(satz(), 3).text}
                 ])
               )

      assert json(Beispiele.beispiel(satz(), 9)) ==
               ~s|{"fehler":"Beispiel 9 gibt es nicht, vorhanden sind 1–3."}|

      assert json(Beispiele.beispiel(satz(), 2)) == ~s|{"fehler":"Beispiel 2 ist entfallen."}|
    end
  end

  test "über Werkzeuge.fuer: nur mit beispiele: und nur in Phase 2, frei von der Sperre" do
    b = satz()

    werkzeuge = fn phase, opts ->
      s = Stand.neu(bloecke: [%{text: "x", sprecher: "SL", block_id: "b0"}], phase: phase)
      {:ok, halter} = Halter.start_link(s)
      halter |> Werkzeuge.fuer(opts) |> Map.new(&{&1.name, &1})
    end

    mit = werkzeuge.(2, beispiele: b)
    assert %{wiederholung: :frei} = mit["beispiele"]
    assert %{wiederholung: :frei} = mit["beispiel"]
    assert mit["beispiele"].parameter["required"] in [nil, []]
    assert mit["beispiel"].parameter["required"] == ["nummer"]
    assert mit["beispiele"].beschreibung =~ "Beispiele dafür, was eine Aussage ist"

    assert {:ok, antwort} = mit["beispiel"].ausfuehren.(%{"nummer" => 3})
    assert Jason.encode!(antwort) =~ ~s|{"nummer":3,"text":"### Beispiel 3|

    refute Map.has_key?(werkzeuge.(1, beispiele: b), "beispiele")
    refute Map.has_key?(werkzeuge.(2, []), "beispiele")
  end
end
