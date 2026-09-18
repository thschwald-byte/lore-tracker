defmodule Worker.Jack.Chronik.NotizenTest do
  @moduledoc """
  Issue #1211: der Überblick des Chronik-Jack muss abschließbar sein.

  Der erste echte Lauf (18.09.2026, seattleV5 S1) ist hier gescheitert —
  `{:chronik_ueberblick_ohne_abschluss, {:abbruch, {:wiederholung, "notiz"}}}`
  nach 638 s. Drei Ursachen, die zusammen jeden Abschluss unmöglich machten:
  `notiz` war das Werkzeug des Resümee-Jack und erzwang die Abschnitte
  FORM/GLIEDERUNG/OFFEN, `Stand.abschnitte(:chronik)` fiel über einen
  Auffangzweig still auf eben diese zurück, und `fertig` prüfte gegen die
  Chronik-EINTRÄGE, die es im Überblick noch gar nicht gibt — es verwies auf
  `chronik_eintrag()`, ein Werkzeug, das dieser Lauf nicht hat.

  Kein Test hat das gesehen, weil alle mit einem geskripteten Modell liefen,
  das `fertig` aufrief, ohne dass eine Ablehnung ihn je erreicht hätte.
  Deshalb prüft dieser Test den **ganzen Weg**: notieren, ablehnen lassen,
  vollständig zuordnen, abschließen.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.{Abschluss, Notizen}
  alias Worker.Jack.Resuemee.Stand

  defp fakt(id, typ \\ "ereignis"), do: %{id: id, fakt_id: "echt-" <> id, typ: typ}

  defp stand(fakten, notizen \\ []) do
    %Stand{
      art: :chronik,
      lauf: :ueberblick,
      fakten: fakten,
      notizen: notizen,
      eintraege: [],
      chronik: [],
      boegen: [],
      gelesen: MapSet.new(),
      mitschnitt: %{straenge: [], bloecke: []}
    }
  end

  defp notieren(s, eintraege), do: Notizen.notiz(s, %{"eintraege" => eintraege})

  defp phase(schluessel, fakten, abschnitt \\ "PHASEN") do
    %{
      "abschnitt" => abschnitt,
      "schluessel" => schluessel,
      "zeile" => "worum es geht",
      "fakten" => fakten,
      "boegen" => []
    }
  end

  describe "die Abschnitte sind die der Chronik" do
    test "PHASEN und SCHLUESSELSZENEN werden angenommen" do
      s = stand([fakt("f1"), fakt("f2")])

      {s, {:ok, _}} =
        notieren(s, [
          phase("insel-auftrag", ["f1"]),
          phase("tod-kodex", ["f2"], "SCHLUESSELSZENEN")
        ])

      assert Enum.map(s.notizen, & &1.abschnitt) == ["PHASEN", "SCHLUESSELSZENEN"]
      assert Enum.map(s.notizen, & &1.schluessel) == ["insel-auftrag", "tod-kodex"]
    end

    test "das Werkzeug bietet dem Modell die Chronik-Abschnitte an, nicht die des Resümees" do
      notiz = Enum.find(Notizen.werkzeuge(stand([fakt("f1")])), &(&1.name == "notiz"))

      assert notiz, "der Überblick braucht ein notiz — ohne es kann er nichts gruppieren"

      enum =
        notiz.parameter["properties"]["eintraege"]["items"]["properties"]["abschnitt"]["enum"]

      assert enum == Stand.abschnitte(:chronik)
      assert "PHASEN" in enum
      refute "GLIEDERUNG" in enum, "das ist der Weg des Resümee-Jack, nicht die Chronik"
    end

    test "die Werkzeugliste des Chronik-Jack zieht die EIGENEN Notizen" do
      # Quelltext-Wächter statt eines vollen Stands: `Werkzeuge.definitionen/1`
      # braucht Mitschnitt und Lesebasis, und genau diese Zeile war der
      # Defekt — sie holte `Resuemee.Notizen`, dessen `notiz` vom Resümee
      # spricht und FORM/GLIEDERUNG erzwingt.
      quelle = File.read!("lib/worker/jack/chronik/werkzeuge.ex")

      assert quelle =~
               "alias Worker.Jack.Chronik.{Abschluss, Durchsicht, Entwurf, Lesen, Notizen}"

      refute quelle =~ "Resuemee.{Halter, Notizen",
             "die Notizen müssen die der Chronik sein, nicht die des Resümee-Jack"
    end

    test "eine unbekannte Art wirft, statt still auf das Resümee zurückzufallen" do
      # Die Art kommt aus einer Variablen, sonst sieht der Compiler schon
      # beim Übersetzen, dass keine Klausel passt, und warnt — im Test ist
      # genau das ja der Punkt.
      art = Enum.random([:gibt_es_nicht])

      assert_raise FunctionClauseError, fn -> Stand.abschnitte(art) end
    end
  end

  describe "Regeln" do
    test "eine Gruppe ohne Fakt wird abgelehnt" do
      s = stand([fakt("f1")])
      {_s, {:error, antwort}} = notieren(s, [phase("leer", [])])
      assert Jason.encode!(antwort) =~ "nennt keinen Fakt"
    end

    test "einen Fakt, den es nicht gibt, nimmt sie nicht an" do
      s = stand([fakt("f1")])
      {_s, {:error, antwort}} = notieren(s, [phase("a", ["f9"])])
      assert Jason.encode!(antwort) =~ "Fakten gibt es nicht"
    end

    test "ein Geschehen liegt in höchstens einer Gruppe — die Ablehnung nennt die andere" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("erste", ["f1", "f2"])])
      {_s, {:error, antwort}} = notieren(s, [phase("zweite", ["f2"])])

      text = Jason.encode!(antwort)
      assert text =~ "liegt schon in"
      assert text =~ "erste"
    end

    test "derselbe Schlüssel ersetzt — und darf seine eigenen Fakten behalten" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1", "f2"])])

      assert [%{schluessel: "a", fakten: ["f1", "f2"]}] = s.notizen
    end

    test "OFFEN braucht keine Fakten" do
      s = stand([fakt("f1")])

      {s, {:ok, _}} =
        notieren(s, [
          %{"abschnitt" => "OFFEN", "schluessel" => "wer ist X?", "zeile" => "unklar"}
        ])

      assert [%{abschnitt: "OFFEN"}] = s.notizen
    end
  end

  describe "Abbild für die Laufsicht" do
    # Ohne eigenes Abbild fällt der Halter auf das des Resümee-Jack zurück:
    # die Laufsicht zeigte den Chronik-Lauf als `jack: "resuemee"` mit
    # Wörtern, Gliederung und max_woerter — am ersten echten Lauf gesehen.
    test "nennt sich chronik und trägt die Zahlen dieses Jacks" do
      s = stand([fakt("f1"), fakt("f2"), fakt("welt", "zustand")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      a = Notizen.abbild(s)

      assert a["jack"] == "chronik"
      assert a["betriebsart"] == "aufbau"
      assert a["phasen"] == 1
      assert a["geschehen"] == 2
      assert a["offene_geschehen"] == ["f2", "welt"]
      refute Map.has_key?(a, "max_woerter")
      refute Map.has_key?(a, "gliederung")
    end

    test "zählt Schlüsselszenen und Ausgeschlossenes getrennt" do
      s = stand([fakt("f1"), fakt("f2")])

      {s, {:ok, _}} =
        notieren(s, [
          phase("tod", ["f1"], "SCHLUESSELSZENEN"),
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "w",
            "zeile" => "Mechanik",
            "fakten" => ["f2"],
            "boegen" => []
          }
        ])

      a = Notizen.abbild(s)
      assert a["phasen"] == 0
      assert a["schluesselszenen"] == 1
      assert a["ausserhalb"] == 1
      assert a["offene_geschehen"] == []
    end
  end

  describe "NICHT_ZEITLEISTE — begründet draussen (Maintainer, 18.09.2026)" do
    test "ohne Fakten wird der Ausschluss abgelehnt" do
      s = stand([fakt("f1")])

      {_s, {:error, antwort}} =
        notieren(s, [
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "würfel",
            "zeile" => "Mechanik",
            "fakten" => [],
            "boegen" => []
          }
        ])

      assert Jason.encode!(antwort) =~ "kein Fakt genannt"
    end

    test "ein ausgeschlossener Fakt gilt als behandelt — fertig lässt durch" do
      s = stand([fakt("f1"), fakt("f2")])

      {s, {:ok, _}} =
        notieren(s, [
          phase("a", ["f1"]),
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "würfel",
            "zeile" => "Probenmechanik ohne Handlungsfolge",
            "fakten" => ["f2"],
            "boegen" => []
          }
        ])

      assert Abschluss.offene_geschehen(s) == []
      assert Abschluss.ausserhalb(s) == ["echt-f2"]
      assert Abschluss.hindernisse(s) == []
    end

    test "ein Fakt kann nicht zugleich in einer Gruppe und draussen liegen" do
      s = stand([fakt("f1")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      {_s, {:error, antwort}} =
        notieren(s, [
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "x",
            "zeile" => "Grund",
            "fakten" => ["f1"],
            "boegen" => []
          }
        ])

      assert Jason.encode!(antwort) =~ "liegt schon in"
    end
  end

  describe "Vorbereitung am Tisch (Maintainer, 18.09.2026)" do
    # Am Lauf gesehen: Jack plante „Character creation 2080 (meta)" als
    # Chronik-Eintrag und nannte es selbst „meta" — der Auftrag nannte nur
    # Würfelmechanik und Tischgespräch, und Charaktererstellung hat ja Folgen.
    test "der Auftrag weist Vorbereitung am Tisch nach NICHT_ZEITLEISTE" do
      for vorlage <- ~w(chronik_ueberblick chronik_schreiben chronik_verfeinerung) do
        # Umbrüche zu Leerzeichen: die Vorlagen sind auf 79 Zeichen gesetzt,
        # ein Prüfbegriff fällt sonst über das Zeilenende und der Test ist
        # rot, obwohl der Text stimmt.
        text =
          "priv/jack/auftraege/#{vorlage}.md"
          |> File.read!()
          |> String.replace(~r/\s+/, " ")

        assert text =~ "Vorbereitung am Tisch", vorlage
        assert text =~ "erstellt Charaktere", vorlage

        assert text =~ "Der Inhalt zählt, nicht wer ihn am Tisch ausgesprochen",
               "#{vorlage}: der INHALT einer erzählten Rückblende gehört in eine Phase — " <>
                 "ohne diese Abgrenzung wirft Jack die Weltgeschichte mit hinaus"
      end
    end

    test "das Werkzeug nennt beides: Vorbereitung raus, erzählter Inhalt rein" do
      notiz = Enum.find(Notizen.werkzeuge(stand([fakt("f1")])), &(&1.name == "notiz"))

      assert notiz.beschreibung =~ "Vorbereitung am Tisch"
      assert notiz.beschreibung =~ "Charaktererstellung"
      assert notiz.beschreibung =~ "INHALT"
    end
  end

  describe "kurze IDs im Gespräch, echte im Abgleich" do
    test "die Notizen halten die kurzen IDs, gruppiert/1 liefert die echten" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1", "f2"])])

      assert [%{fakten: ["f1", "f2"]}] = s.notizen
      assert Notizen.gruppiert(s) == ["echt-f1", "echt-f2"]
    end

    test "die Ablehnung nennt dem Modell die kurze ID, nicht die echte" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      assert [m] = Abschluss.hindernisse(s)
      assert m =~ "f2"
      refute m =~ "echt-f2"
    end
  end

  describe "Abschluss des Überblicks" do
    test "ohne jede Bewertung geht es nicht" do
      assert [m] = Abschluss.hindernisse(stand([fakt("f1")]))
      assert m =~ "noch nichts notiert"
      assert m =~ "NICHT_ZEITLEISTE", "der Weg hinaus gehört in die Ablehnung"
      assert m =~ "notiz()"
      refute m =~ "chronik_eintrag()", "dieses Werkzeug hat der Überblick nicht"
    end

    test "ein Geschehen ohne Gruppe hält auf — und wird benannt" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      assert [m] = Abschluss.hindernisse(s)
      assert m =~ "f2"
      refute m =~ "f1"
    end

    test "auch ein Zustand will bewertet werden — irgendwie" do
      s = stand([fakt("f1"), fakt("welt", "zustand")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      assert [m] = Abschluss.hindernisse(s)
      assert m =~ "welt"

      # In die Gruppe genommen: bewertet.
      {mit_gruppe, {:ok, _}} = notieren(s, [phase("a", ["f1", "welt"])])
      assert Abschluss.hindernisse(mit_gruppe) == []

      # Oder begründet hinaus: ebenfalls bewertet.
      {draussen, {:ok, _}} =
        notieren(s, [
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "weltwissen",
            "zeile" => "dauerhafter Zustand ohne Zeitpunkt",
            "fakten" => ["welt"],
            "boegen" => []
          }
        ])

      assert Abschluss.hindernisse(draussen) == []
    end

    test "sind alle Fakten bewertet, LÄSST fertig den Überblick durch" do
      s = stand([fakt("f1"), fakt("f2"), fakt("welt", "zustand")])

      {s, {:ok, _}} =
        notieren(s, [
          phase("a", ["f1"]),
          phase("b", ["f2"], "SCHLUESSELSZENEN"),
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "weltwissen",
            "zeile" => "dauerhafter Zustand",
            "fakten" => ["welt"],
            "boegen" => []
          }
        ])

      assert Abschluss.hindernisse(s) == []
      assert Abschluss.ist_ueberblick(s) == %{"gruppen" => 2, "fakten_zugeordnet" => 2}

      {_s, {status, _antwort}} =
        Abschluss.fertig(s, %{
          "gruppen" => 2,
          "fakten_zugeordnet" => 2,
          "offen_geblieben" => ""
        })

      # `:halt` ist der Erfolg: ein angenommenes `fertig` beendet den Lauf.
      # Und `offen_geblieben` darf leer sein, wenn nichts offen ist.
      assert status == :halt
    end

    test "sind ALLE Fakten ausserhalb, ist das ein gültiges Ergebnis" do
      # Maintainer, 18.09.2026: „wenn alle NICHT_ZEITLEISTE sind — dann ist
      # das ok". Eine Sitzung, die nur am Tisch stattfand, hat keine Chronik —
      # und das ist eine Aussage, kein Fehler.
      s = stand([fakt("f1"), fakt("f2")])

      {s, {:ok, _}} =
        notieren(s, [
          %{
            "abschnitt" => "NICHT_ZEITLEISTE",
            "schluessel" => "vorbereitung",
            "zeile" => "Charaktererstellung am Tisch",
            "fakten" => ["f1", "f2"],
            "boegen" => []
          }
        ])

      assert Abschluss.hindernisse(s) == []
      assert Abschluss.ausserhalb(s) |> length() == 2
    end

    test "fertig lehnt ab, solange ein Geschehen offen ist" do
      s = stand([fakt("f1"), fakt("f2")])
      {s, {:ok, _}} = notieren(s, [phase("a", ["f1"])])

      {_s, {status, antwort}} =
        Abschluss.fertig(s, %{
          "gruppen" => 1,
          "fakten_zugeordnet" => 2,
          "offen_geblieben" => "nichts"
        })

      assert status == :error
      assert Jason.encode!(antwort) =~ "f2"
    end
  end
end
