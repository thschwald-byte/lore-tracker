defmodule Worker.Jack.Zeit.PruefenTest do
  @moduledoc """
  #1247 (Z2): der **Prüf-Lauf** — sein Gegenstand ist die Linie, nicht der
  Mitschnitt.

  Der Anlass ist der Lauf vom 19.09.2026: Lauf 3 bekam die Anker aus Lauf 2,
  aber `gelesen` und `einordnung` starteten leer. Er musste also 2168 Zeilen
  ein zweites Mal lesen und ein zweites Mal einordnen, nur um abschliessen zu
  dürfen — während sein Auftrag das Gegenteil sagt („geh von den Befunden
  aus, nicht von Zeile 1"). Über neunzig Runden lang suchte er die Linie ab,
  statt sie zu prüfen.

  Geprüft wird deshalb der **ganze Weg** (#1211-Lehre): ablehnen lassen,
  ansehen, abschliessen.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Aufruf
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Abschluss, Lesen, Stand, Werkzeuge}

  defp zeile(nr, id, text),
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "SL",
      text: text,
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp mitschnitt do
    [
      zeile(1, "u1", "Es ist jetzt zweiundzwanzig Uhr."),
      zeile(2, "u2", "Ihr geht los."),
      zeile(3, "u3", "Ihr seid zwei Stunden unterwegs."),
      zeile(4, "u4", "Ihr kommt an."),
      zeile(5, "u5", "Es ist halb elf.")
    ]
  end

  defp halter(lauf, opts \\ []) do
    {:ok, h} =
      Halter.start_link(Stand.neu(lauf, mitschnitt(), opts), abbild: &Stand.abbild/1)

    h
  end

  # Gerufen wird über dieselbe Kette wie zur Laufzeit (s. WerkzeugeTest).
  defp laufzeit(h, name, felder) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  defp ruf(h, name, felder \\ %{}), do: laufzeit(h, name, felder) |> elem(1)
  defp art(h, name, felder \\ %{}), do: laufzeit(h, name, felder) |> elem(0)
  defp stand(h), do: Halter.stand(h)

  # Ein Widerspruch, den die Rechnung findet: zwischen 22:00 und 22:30 liegen
  # dreissig Minuten, die eingetragene Dauer sind zwei Stunden.
  defp mit_widerspruch(h) do
    ruf(h, "zeitpunkt", %{
      "zeilen" => [1],
      "wert" => "22:00",
      "welt" => "spielwelt",
      "beleg" => "Es ist jetzt zweiundzwanzig Uhr."
    })

    ruf(h, "spanne", %{
      "zeilen" => [3],
      "wert" => "zwei Stunden",
      "welt" => "spielwelt",
      "beleg" => "Ihr seid zwei Stunden unterwegs."
    })

    ruf(h, "zeitpunkt", %{
      "zeilen" => [5],
      "wert" => "22:30",
      "welt" => "spielwelt",
      "beleg" => "Es ist halb elf."
    })

    h
  end

  describe "die Schranke des Prüf-Laufs" do
    test "verlangt weder Leseabdeckung noch Einordnung — beides erbt er" do
      # Genau das war der Defekt: Mit der Einsortier-Schranke musste Lauf 3
      # alles noch einmal lesen und einordnen, bevor er abschliessen durfte.
      s = Stand.neu(:pruefen, mitschnitt())

      assert Abschluss.hindernisse(s) == [],
             "ohne Befunde darf der Prüf-Lauf sofort abschliessen, auch ohne eine " <>
               "einzige gelesene Zeile"

      # Zur Gegenprobe: derselbe Stand im Einsortier-Lauf ist voller Hindernisse.
      e = Stand.neu(:einsortieren, mitschnitt())
      assert length(Abschluss.hindernisse(e)) >= 2
    end

    test "ein Befund blockiert, bis Jack ihn angesehen hat" do
      h = halter(:pruefen) |> mit_widerspruch()

      assert [hindernis] = Abschluss.hindernisse(stand(h))
      assert hindernis =~ "Befund"
      # Die Ablehnung nennt, worum es geht — nicht bloss „da ist noch etwas".
      assert hindernis =~ "Minuten"

      assert art(h, "fertig") == :error

      # linie() zeigt die Befunde — damit sind sie angesehen.
      antwort = ruf(h, "linie")
      assert antwort =~ "Befunde:"

      assert Abschluss.hindernisse(stand(h)) == []
      assert art(h, "fertig") == :halt
    end

    test "offen() nennt die ungesehenen Befunde, nicht die Zeilen" do
      h = halter(:pruefen) |> mit_widerspruch()

      antwort = ruf(h, "offen")
      assert antwort =~ "Befund"
      refute antwort =~ "noch nicht gelesen"
      refute antwort =~ "nicht eingeordnet"
    end
  end

  describe "ein Befund ohne Anker ist trotzdem abhakbar" do
    test "der Spannen-Überlauf trägt keine anker_id und bekommt eine eigene Kennung" do
      # Ohne diese Kennung wäre die Schranke des Prüf-Laufs unter keinen
      # Umständen zu erfüllen: `gesehen` hakt über die ID ab, und `nil` ist
      # nie enthalten. Der Lauf liefe in den Rundendeckel — die Klasse, die
      # beim Chronik-Jack 28 von 51 Runden gekostet hat (#1211).
      h = halter(:pruefen) |> mit_widerspruch()

      befunde = Abschluss.befunde(stand(h))
      ueberlauf = Enum.find(befunde, &(&1.art == :spannen_ueberlauf))

      assert ueberlauf, "der Widerspruch der Fixture muss einen Überlauf-Befund erzeugen"
      assert is_nil(ueberlauf.anker_id)
      assert is_binary(ueberlauf.id) and ueberlauf.id != ""

      ruf(h, "linie")
      assert Abschluss.hindernisse(stand(h)) == []
    end
  end

  describe "linie() zeigt die Befunde in Portionen" do
    test "gezeigt werden die ungesehenen; ein zweiter Aufruf bringt die nächsten" do
      # Sonst gilt mit einem einzigen Aufruf alles als angesehen, sobald es
      # mehr Befunde gibt, als in eine Antwort passen.
      h = halter(:pruefen) |> mit_widerspruch()
      linie = Worker.Timeline.Linie.bauen(stellen(), Map.values(stand(h).anker))

      erste = Lesen.befunde_zum_zeigen(stand(h), linie)
      assert length(erste) >= 1

      ruf(h, "linie")
      # Nach dem Ansehen sind keine ungesehenen mehr da — gezeigt wird dann
      # wieder der Bestand, aber nichts bleibt unentdeckt.
      assert Enum.reject(linie.befunde, &MapSet.member?(stand(h).gesehen, &1.id)) == []
    end

    test "das Merkmal der Wiederholungssperre hängt an der Zahl der gesehenen Befunde" do
      # Ohne das zählte der zweite linie()-Aufruf als Wiederholung, obwohl er
      # neue Befunde zeigt (Muster der Suchen, #1210).
      w = Werkzeuge.fuer(halter(:pruefen)) |> Enum.find(&(&1.name == "linie"))

      assert is_function(w.wiederholung_merkmal, 1)
    end
  end

  describe "linie() adressiert über Zeilennummern, wie mitschnitt()" do
    # Der Defekt des Laufs vom 19.09.2026: `ab` war die Position in der
    # Reihe, aus der die gelösten Zeilen heraus sind — angezeigt wurden aber
    # Zeilennummern. Bei 459 gelösten Zeilen bedeutete `linie(ab: n)` etwas
    # anderes als `mitschnitt(ab: n)`, und hinter dem Ende der Reihe kam
    # nichts. Das Modell schloss daraus, die halbe Sitzung sei gelöst, und
    # prüfte das fünf Runden lang nach.
    test "eine Zeile hinter gelösten Zeilen ist unter ihrer eigenen Nummer erreichbar" do
      h = halter(:pruefen)
      ruf(h, "loesen", %{"von" => 1, "bis" => 3, "grund" => "Tischgespräch"})

      antwort = ruf(h, "linie", %{"ab" => 4})

      assert antwort =~ "von Zeile 4"
      assert antwort =~ "Ihr kommt an.", "Zeile 4 muss im Ausschnitt stehen"
    end

    test "hinter der letzten Zeile sagt die Antwort, WO die Linie endet" do
      h = halter(:pruefen)

      antwort = ruf(h, "linie", %{"ab" => 99})

      assert antwort =~ "Ab Zeile 99 liegt nichts mehr auf der Linie"
      assert antwort =~ "die letzte ist Zeile 5"
    end

    test "der Kopf sagt, dass Lücken in der Nummernfolge gelöste Zeilen sind" do
      h = halter(:pruefen)
      ruf(h, "loesen", %{"von" => 2, "bis" => 3, "grund" => "Regelfrage"})

      antwort = ruf(h, "linie", %{"ab" => 1})

      assert antwort =~ "gelöste erscheinen hier nicht"
      refute antwort =~ "Ihr geht los.", "Zeile 2 ist gelöst und darf nicht erscheinen"
    end
  end

  describe "jeder Lauf sagt selbst, was fertig() von ihm verlangt" do
    test "die Beschreibung des Prüf-Laufs spricht von Befunden, nicht vom Einordnen" do
      # Der Auffangzweig war der Defekt des Chronik-Jack (#1211): Der Lauf
      # bekam die Beschreibung eines anderen und tat die falsche Arbeit.
      pruefen = beschreibung(:pruefen, "fertig")
      assert pruefen =~ "BEFUND"
      assert pruefen =~ "NICHT noch einmal lesen"

      einsortieren = beschreibung(:einsortieren, "fertig")
      assert einsortieren =~ "JEDE Zeile"
      refute einsortieren == pruefen
    end

    test "eine unbekannte Laufart wirft, statt still eine fremde Liste zu nehmen" do
      assert_raise ArgumentError, ~r/:ausgedacht/, fn ->
        Werkzeuge.namen(%Stand{lauf: :ausgedacht})
      end
    end
  end

  describe "die Vererbung aus dem Einsortier-Lauf" do
    test "Stand.neu nimmt gelesen und einordnung entgegen" do
      s =
        Stand.neu(:pruefen, mitschnitt(),
          gelesen: MapSet.new(["u1", "u2"]),
          einordnung: %{"u1" => :ingame}
        )

      assert MapSet.member?(s.gelesen, "u1")
      assert s.einordnung["u1"] == :ingame
    end

    test "Zeit.pruefen reicht beides weiter" do
      # Quelltext-Wächter: Ein vergessenes Feld erzeugt keinen Fehler,
      # sondern einen Lauf, der von vorn anfängt — und das sieht von aussen
      # aus wie Gründlichkeit.
      quelle = File.read!("lib/worker/jack/zeit.ex")
      [_, block] = String.split(quelle, "Map.merge(eingabe, %{", parts: 2)
      block = String.slice(block, 0, 400)

      assert block =~ "gelesen: e.stand.gelesen"
      assert block =~ "einordnung: e.stand.einordnung"
      assert block =~ "anker:"
      assert block =~ "notizen:"
    end
  end

  defp beschreibung(lauf, name) do
    Stand.neu(lauf, mitschnitt())
    |> Werkzeuge.definitionen()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:beschreibung)
  end

  defp stellen,
    do: Enum.map(mitschnitt(), &%{utterance_id: &1.utterance_id, session_nr: 1, pos: &1.nr})
end
