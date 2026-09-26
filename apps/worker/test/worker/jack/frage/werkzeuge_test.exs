defmodule Worker.Jack.Frage.WerkzeugeTest do
  @moduledoc """
  Issue #850: die Werkzeuge des Frage-Jack — und der Wächter gegen die
  #1211-Klasse.

  Die Lesebasis ist die des Resümee-Jack. Wo sie dem Modell etwas über „das
  Resümee", „die Gliederung" oder `fertig(ausgelassen)` sagt, richtet sie sich
  nach `art` — und wo eine Klausel fehlt, fällt sie **still** auf den
  Resümee-Text zurück. Genau das kostete den Chronik-Jack einen ganzen Lauf
  (#1211): `bloecke` sagte ihm „Im Resümee dient der Mitschnitt …", `boegen`
  nannte ein `fertig(ausgelassen)`, das er nicht hat.

  Der Fehler erzeugt keine Ausnahme und keinen roten Test — nur ein Modell,
  das nach Regeln arbeitet, die für es nicht gelten. Deshalb liest dieser Test
  die **gerenderten** Beschreibungen und Schemata, nicht den Quelltext.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Frage.Werkzeuge
  alias Worker.Jack.Resuemee.Stand

  # Wendungen, die dem Frage-Jack eine **Rolle** zuweisen, die er nicht hat.
  #
  # Bewusst nicht der blosse Begriff: `vorige_resuemees` heisst „Die Resümees
  # früherer Sitzungen", `vorige_kapitel` nennt Epos-Kapitel, `suche_bisher`
  # zählt beide als durchsuchte Quellen auf — das ist ihr **Gegenstand** und
  # völlig richtig. Falsch ist erst, wo eine Beschreibung sagt, wofür der Jack
  # das Gelesene braucht („Grundlage deiner Gliederung", „Im Resümee dient der
  # Mitschnitt …"). Ein Wächter auf den blossen Begriff zwänge dazu, korrekte
  # Texte zu verstümmeln.
  @fremde_rolle [
    "deiner Gliederung",
    "deine Gliederung",
    "Im Resümee dient",
    "Im Epos-Kapitel dient",
    "In der Chronik dient",
    "fertig(ausgelassen)",
    "deiner Szenen",
    "deine Szenen",
    "Grundlage deiner",
    "dein Kapitel",
    "deinem Kapitel",
    "NICHT_ZEITLEISTE",
    "die Fakten dieser Sitzung"
  ]

  defp stand do
    %Stand{
      art: :frage,
      lauf: :antworten,
      frage: "Wer ist Kodex?",
      sitzung: %{id: "s2", nummer: 2, name: "Zweite"},
      fakten: [
        %{
          id: "S1-F1",
          fakt_id: "f_eins",
          sitzung: 1,
          typ: "ereignis",
          aussage: "Kodex betritt die Villa",
          figur: "Kodex",
          boegen: [],
          datum: nil,
          erzaehlzeit: "present",
          bloecke: [3],
          ohne_block: 0
        },
        %{
          id: "S2-F1",
          fakt_id: "f_zwei",
          sitzung: 2,
          typ: "zustand",
          aussage: "Kodex ist Magier",
          figur: "Kodex",
          boegen: [],
          datum: nil,
          erzaehlzeit: "present",
          bloecke: [1],
          ohne_block: 0
        }
      ],
      fruehere: [%{nummer: 1, name: "Erste", fakten: []}],
      boegen: [],
      notizen: [],
      gelesen: MapSet.new(),
      mitschnitt: %Worker.Jack.Stand{bloecke: %{}, max_block: -1, cast: [], straenge: []}
    }
  end

  describe "Werkzeugliste" do
    test "die Lesebasis plus antworte, kein Name doppelt" do
      namen = Enum.map(Werkzeuge.definitionen(stand()), & &1.name)

      assert "antworte" in namen
      assert "fakten" in namen
      assert "suche_bisher" in namen
      refute "notiz" in namen, "der Frage-Jack macht keine Notizen"
      refute "fertig" in namen, "antworte IST sein Abschluss"
      assert namen -- Enum.uniq(namen) == []
    end

    test "jeder Name aus namen/1 hat eine Definition" do
      # Sonst bricht `Resuemee.Werkzeuge.aus/3` mit KeyError.
      defs = MapSet.new(Werkzeuge.definitionen(stand()), & &1.name)

      for name <- Werkzeuge.namen(stand()) do
        assert MapSet.member?(defs, name), "#{name} hat keine Definition"
      end
    end
  end

  describe "keine fremden Begriffe in den Beschreibungen (#1211-Klasse)" do
    test "kein Werkzeug weist dem Frage-Jack eine fremde Rolle zu" do
      treffer =
        for d <- Werkzeuge.definitionen(stand()),
            text = gerendert(d),
            wort <- @fremde_rolle,
            String.contains?(text, wort),
            do: {d.name, wort}

      assert treffer == [],
             "Diese Werkzeuge sagen dem Frage-Jack, wofür er das Gelesene braucht — und\n" <>
               "nennen dabei eine Aufgabe, die er nicht hat:\n" <>
               Enum.map_join(treffer, "\n", fn {n, w} -> "  #{n}: #{inspect(w)}" end) <>
               "\n\nEine `art: :frage`-Klausel fehlt (die #1211-Klasse)."
    end

    test "fakten meint die ganze Kampagne, nicht eine Sitzung" do
      d = Enum.find(Werkzeuge.definitionen(stand()), &(&1.name == "fakten"))

      assert d.beschreibung =~ "Kampagne",
             "fakten() muss beim Frage-Jack kampagnenweit lesen — die Lesebasis ist " <>
               "sonst sitzungsbezogen, und eine Kampagnenfrage bekäme einen Bruchteil, " <>
               "den das Modell für alles hielte."
    end
  end

  # Beschreibung samt Parameter-Beschreibungen: Die Regeln stehen in beidem,
  # und beides geht als `tools` an das Modell.
  defp gerendert(d) do
    Enum.join([d.beschreibung, inspect(Map.get(d, :parameter, %{}))], " ")
  end
end
