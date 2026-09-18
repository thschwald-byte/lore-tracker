defmodule Worker.Jack.Chronik.EntwurfTest do
  @moduledoc """
  Issue #1211: die Regeln beim Schreiben der Chronik.

  Geprüft wird nicht nur, DASS abgelehnt wird, sondern auch, **was in der
  Ablehnung steht** — sie ist das, was Jack liest, und eine Ablehnung ohne
  Weg nach vorn kostet eine Modellrunde ohne Fortschritt.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Entwurf

  # Die Karte kurze ID -> echte ID. In den Tests sind beide gleich, damit die
  # Erwartungen lesbar bleiben; die Übersetzung selbst prüft `notizen_test`.
  defp fakten(ids), do: Map.new(ids, &{&1, &1})

  defp anlegen!(e, p, bekannt \\ ["f1", "f2", "f3"]) do
    assert {:ok, neu, _} = Entwurf.anlegen(e, p, fakten(bekannt))
    neu
  end

  defp phase(titel, fakt_ids, bezug \\ %{"art" => "isoliert"}) do
    %{
      "titel" => titel,
      "text" => "Was geschah: #{titel}.",
      "fakt_ids" => fakt_ids,
      "wichtigkeit" => "phase",
      "zeit_bezug" => bezug
    }
  end

  describe "kurze ID hinein, echte ID gespeichert" do
    # Der Eintrag trägt die inhaltsadressierte ID — sonst zeigte er nach dem
    # nächsten Regenerate stumm auf andere Fakten (Review vom 18.09.2026: bis
    # dahin wurde die kurze Positions-ID gespeichert, entgegen der Doku).
    test "der Eintrag speichert die echte ID, die Antwort nennt die kurze" do
      karte = %{"S1-F1" => "f_9c1e", "S1-F2" => "f_77ab"}
      assert {:ok, [e], _} = Entwurf.anlegen([], phase("Auftrag", ["S1-F1", "S1-F2"]), karte)
      assert e.fakt_ids == ["f_9c1e", "f_77ab"]
      refute "S1-F1" in e.fakt_ids
    end

    test "die Eintrags-ID hängt an den echten Fakten — dieselben Fakten, dieselbe ID" do
      a = %{"S1-F1" => "f_9c1e"}
      b = %{"S3-F7" => "f_9c1e"}
      assert {:ok, [ea], _} = Entwurf.anlegen([], phase("A", ["S1-F1"]), a)
      assert {:ok, [eb], _} = Entwurf.anlegen([], phase("B", ["S3-F7"]), b)
      assert ea.id == eb.id
    end

    test "„liegt schon in“ nennt die kurze ID, die das Modell kennt" do
      karte = %{"S1-F1" => "f_9c1e"}
      {:ok, vorher, _} = Entwurf.anlegen([], phase("A", ["S1-F1"]), karte)
      assert {:error, m} = Entwurf.anlegen(vorher, phase("B", ["S1-F1"]), karte)
      assert m =~ "S1-F1 (liegt in"
      refute m =~ "f_9c1e"
    end
  end

  describe "zeit_bezug ist eine Liste (18.09.2026)" do
    test "gleichzeitig mit A und nach B in einem Eintrag" do
      {:ok, vorher, _} = Entwurf.anlegen([], phase("A", ["f1"]), fakten(["f1"]))
      {:ok, vorher, _} = Entwurf.anlegen(vorher, phase("B", ["f2"]), fakten(["f2"]))
      [a, b] = vorher

      bezuege = [
        %{"art" => "gleichzeitig_mit", "ziel" => a.id},
        %{"art" => "nach", "ziel" => b.id}
      ]

      assert {:ok, [_, _, x], _} =
               Entwurf.anlegen(vorher, phase("X", ["f3"], bezuege), fakten(["f3"]))

      assert x.zeit_bezug == bezuege
    end

    test "isoliert wird zur leeren Liste, eine einzelne Map wird angenommen" do
      assert {:ok, [e], _} =
               Entwurf.anlegen([], phase("A", ["f1"], %{"art" => "isoliert"}), fakten(["f1"]))

      assert e.zeit_bezug == []

      assert {:ok, [e2], _} = Entwurf.anlegen([], phase("A", ["f1"], []), fakten(["f1"]))
      assert e2.zeit_bezug == []
    end

    test "ein falsches Element lehnt die ganze Liste ab — mit dem Grund" do
      {:ok, vorher, _} = Entwurf.anlegen([], phase("A", ["f1"]), fakten(["f1"]))
      [a] = vorher

      bezuege = [
        %{"art" => "nach", "ziel" => a.id},
        %{"art" => "vor", "ziel" => "chr-gibts-nicht"}
      ]

      assert {:error, m} = Entwurf.anlegen(vorher, phase("X", ["f2"], bezuege), fakten(["f2"]))
      assert m =~ "chr-gibts-nicht"
      assert m =~ "leere Liste"
    end

    test "streichen scheitert, wenn ein Bezug in einer Liste auf den Eintrag zeigt" do
      {:ok, vorher, _} = Entwurf.anlegen([], phase("A", ["f1"]), fakten(["f1"]))
      [a] = vorher
      bezuege = [%{"art" => "gleichzeitig_mit", "ziel" => a.id}]
      {:ok, beide, _} = Entwurf.anlegen(vorher, phase("X", ["f2"], bezuege), fakten(["f2"]))
      assert {:error, m} = Entwurf.streichen(beide, %{"id" => a.id, "grund" => "test"})
      assert m =~ "bezieh"
    end
  end

  describe "anlegen" do
    test "eine Phase mit Fakten" do
      assert {:ok, [e], meldung} =
               Entwurf.anlegen([], phase("Der Auftrag", ["f1"]), fakten(["f1"]))

      assert e.titel == "Der Auftrag"
      assert e.fakt_ids == ["f1"]
      assert e.wichtigkeit == "phase"
      assert e.neu?
      refute e.kuratiert?
      assert meldung =~ "angelegt"
    end

    test "erfundene Fakt-IDs werden abgelehnt, mit Nennung" do
      assert {:error, m} = Entwurf.anlegen([], phase("X", ["f1", "erfunden"]), fakten(["f1"]))
      assert m =~ "erfunden"
      assert m =~ "gibt es nicht"
    end

    test "ein Fakt liegt in höchstens einer Phase" do
      vorher = anlegen!([], phase("Erste", ["f1", "f2"]))

      assert {:error, m} = Entwurf.anlegen(vorher, phase("Zweite", ["f2"]), fakten(["f1", "f2"]))
      assert m =~ "f2"
      assert m =~ "genau eine Phase"
      # Die Ablehnung sagt, wo der Fakt liegt — sonst muss Jack suchen.
      assert m =~ hd(vorher).id
    end

    test "unbekannte wichtigkeit wird abgelehnt und erklärt" do
      p = %{phase("X", ["f1"]) | "wichtigkeit" => "wichtig"}
      assert {:error, m} = Entwurf.anlegen([], p, fakten(["f1"]))
      assert m =~ "phase"
      assert m =~ "schluesselszene"
    end

    test "ein Bezug auf einen unbekannten Eintrag wird abgelehnt" do
      p = phase("X", ["f1"], %{"art" => "nach", "ziel" => "gibtsnicht"})
      assert {:error, m} = Entwurf.anlegen([], p, fakten(["f1"]))
      assert m =~ "gibtsnicht"
      assert m =~ "leere Liste"
    end

    test "absolut braucht eine Zeitangabe und verlangt keine Umrechnung" do
      p = phase("X", ["f1"], %{"art" => "absolut"})
      assert {:error, m} = Entwurf.anlegen([], p, fakten(["f1"]))
      assert m =~ "Rechne nichts um"
    end

    test "die ID hängt an den Fakten, nicht am Text" do
      [a] = anlegen!([], phase("Der Auftrag auf der Insel", ["f1", "f2"]))
      [b] = anlegen!([], phase("Ganz anders benannt", ["f2", "f1"]))
      # Umformuliert und umsortiert — derselbe Eintrag. Sonst verwaisen
      # Kuration und Bezüge bei jedem Lauf (#916-Muster).
      assert a.id == b.id
    end
  end

  describe "ergaenzen" do
    test "hängt an, statt zu ersetzen" do
      [e] = anlegen!([], phase("Der Auftrag", ["f1"]))

      assert {:ok, [neu], m} =
               Entwurf.ergaenzen(
                 [e],
                 %{"id" => e.id, "text" => "Und dann die Abrechnung.", "fakt_ids" => ["f2"]},
                 fakten(["f1", "f2"])
               )

      assert neu.text =~ "Was geschah"
      assert neu.text =~ "Abrechnung"
      assert neu.fakt_ids == ["f1", "f2"]
      assert m =~ "fortgeschrieben"
    end

    test "beim kuratierten Eintrag bleibt der Text des Spielleiters stehen" do
      kuratiert = %{
        id: "chr-kuratiert",
        titel: "Vom Spielleiter",
        text: "Der Spielleiter hat das hier geschrieben.",
        fakt_ids: ["f1"],
        wichtigkeit: "phase",
        zeit_bezug: %{"art" => "isoliert"},
        kuratiert?: true,
        kuratierter_text: "Der Spielleiter hat das hier geschrieben.",
        neu?: false
      }

      assert {:ok, [neu], m} =
               Entwurf.ergaenzen(
                 [kuratiert],
                 %{"id" => "chr-kuratiert", "text" => "Danach ging es weiter.", "fakt_ids" => []},
                 fakten(["f1"])
               )

      assert neu.text =~ "Der Spielleiter hat das hier geschrieben."
      assert neu.text =~ "Danach ging es weiter."
      assert neu.kuratierter_text == "Der Spielleiter hat das hier geschrieben."
      assert m =~ "Spielleiter"
    end

    test "auch beim Ergänzen bleibt ein Fakt in höchstens einer Phase" do
      [a] = anlegen!([], phase("Erste", ["f1"]))
      [_, b] = anlegen!([a], phase("Zweite", ["f2"]))

      assert {:error, m} =
               Entwurf.ergaenzen(
                 [a, b],
                 %{"id" => b.id, "text" => "mehr", "fakt_ids" => ["f1"]},
                 fakten(["f1", "f2"])
               )

      assert m =~ "f1"
    end
  end

  describe "einordnen" do
    test "ändert nur die Stellung" do
      [a] = anlegen!([], phase("Erste", ["f1"]))
      [_, b] = anlegen!([a], phase("Zweite", ["f2"]))

      assert {:ok, neu, m} =
               Entwurf.einordnen([a, b], %{
                 "id" => b.id,
                 "zeit_bezug" => %{"art" => "nach", "ziel" => a.id}
               })

      geaendert = Enum.find(neu, &(&1.id == b.id))
      assert geaendert.zeit_bezug == [%{"art" => "nach", "ziel" => a.id}]
      assert geaendert.text == b.text
      assert m =~ "eingeordnet"
    end

    test "auch ein kuratierter Eintrag darf eingeordnet werden — der Text bleibt seins" do
      kuratiert = %{
        id: "chr-k",
        titel: "T",
        text: "Text",
        fakt_ids: [],
        wichtigkeit: "phase",
        zeit_bezug: %{"art" => "isoliert"},
        kuratiert?: true,
        kuratierter_text: "Text",
        neu?: false
      }

      [a] = anlegen!([], phase("Erste", ["f1"]))

      assert {:ok, neu, _} =
               Entwurf.einordnen([a, kuratiert], %{
                 "id" => "chr-k",
                 "zeit_bezug" => %{"art" => "nach", "ziel" => a.id}
               })

      k = Enum.find(neu, &(&1.id == "chr-k"))
      assert [%{"ziel" => ziel}] = k.zeit_bezug
      assert ziel == a.id
      assert k.text == "Text"
    end

    test "ein Eintrag kann sich nicht auf sich selbst beziehen" do
      [a] = anlegen!([], phase("Erste", ["f1"]))

      assert {:error, m} =
               Entwurf.einordnen([a], %{
                 "id" => a.id,
                 "zeit_bezug" => %{"art" => "nach", "ziel" => a.id}
               })

      assert m =~ "sich selbst"
    end
  end

  describe "streichen" do
    test "einen eigenen Eintrag: erlaubt" do
      [a] = anlegen!([], phase("Irrtum", ["f1"]))

      assert {:ok, [], m} = Entwurf.streichen([a], %{"id" => a.id, "grund" => "doch keine Phase"})
      assert m =~ "gestrichen"
    end

    test "einen kuratierten: abgelehnt, mit dem Weg nach vorn" do
      kuratiert = %{
        id: "chr-k",
        titel: "T",
        text: "Text",
        fakt_ids: [],
        wichtigkeit: "phase",
        zeit_bezug: %{"art" => "isoliert"},
        kuratiert?: true,
        kuratierter_text: "Text",
        neu?: false
      }

      assert {:error, m} = Entwurf.streichen([kuratiert], %{"id" => "chr-k", "grund" => "weg"})
      assert m =~ "kuratiert"
      assert m =~ "eintrag_ergaenzen"
      assert m =~ "eintrag_einordnen"
    end

    test "ein Eintrag, auf den sich andere beziehen, wird nicht einfach entfernt" do
      [a] = anlegen!([], phase("Erste", ["f1"]))

      [_, b] =
        anlegen!([a], phase("Zweite", ["f2"], %{"art" => "nach", "ziel" => a.id}))

      assert {:error, m} = Entwurf.streichen([a, b], %{"id" => a.id, "grund" => "weg"})
      assert m =~ b.id
      assert m =~ "ins Leere"
    end

    test "ohne Grund keine Streichung" do
      [a] = anlegen!([], phase("X", ["f1"]))
      assert {:error, m} = Entwurf.streichen([a], %{"id" => a.id})
      assert m =~ "grund"
    end
  end

  describe "offene_fakten — die Zahl gegen das Verschlucken (#1111)" do
    test "nennt, was in keinem Eintrag liegt" do
      [a] = anlegen!([], phase("Erste", ["f1"]))
      assert Entwurf.offene_fakten([a], ["f1", "f2", "f3"]) == ["f2", "f3"]
    end

    test "leer, wenn alles zugeordnet ist" do
      [a] = anlegen!([], phase("Alles", ["f1", "f2", "f3"]))
      assert Entwurf.offene_fakten([a], ["f1", "f2", "f3"]) == []
    end
  end

  describe "ordnen — Durchreichung an die Ordnung" do
    test "liefert die Reihenfolge" do
      [a] = anlegen!([], phase("Erste", ["f1"]))
      [_, b] = anlegen!([a], phase("Zweite", ["f2"], %{"art" => "nach", "ziel" => a.id}))

      assert {:ok, %{reihenfolge: [[erst], [dann]]}} = Entwurf.ordnen([a, b])
      assert erst == a.id
      assert dann == b.id
    end
  end
end
