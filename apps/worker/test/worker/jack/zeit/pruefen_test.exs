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

  # **Der Halter liefert eine Kette, in der alles liegt.** Seit sie leer
  # beginnt (#1247, 20.09.2026), wird ein Anker an einer nicht eingereihten
  # Zeile abgelehnt. Diese Datei prüft die Schranke des PRÜF-Laufs; dass
  # vorher eingereiht sein muss, ist Vorbedingung.
  defp halter(lauf, opts \\ []) do
    {:ok, h} =
      Halter.start_link(Stand.neu(lauf, mitschnitt(), opts), abbild: &Stand.abbild/1)

    ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})
    h
  end

  # **Für einen Widerspruch braucht es mehrere Glieder.** Ein Glied ist eine
  # Zeiteinheit: Liegen alle Zeilen darin, gibt es genau einen Punkt, und
  # zwischen einem Punkt und sich selbst kann keine Spanne überlaufen. Die
  # Fixture legt deshalb drei Glieder an — so, wie eine echte Sitzung
  # eingereiht würde.
  defp halter_je_glied(lauf) do
    {:ok, h} = Halter.start_link(Stand.neu(lauf, mitschnitt()), abbild: &Stand.abbild/1)
    for nr <- 1..5, do: ruf(h, "haenge_an_kette", %{"zeilen" => [nr]})
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
    ruf(h, "setz_zeitpunkt", %{
      "zeilen" => [1],
      "wert" => "22:00",
      "welt" => "spielwelt",
      "beleg" => "Es ist jetzt zweiundzwanzig Uhr."
    })

    ruf(h, "setz_spanne", %{
      "zeilen" => [3],
      "wert" => "zwei Stunden",
      "welt" => "spielwelt",
      "beleg" => "Ihr seid zwei Stunden unterwegs."
    })

    ruf(h, "setz_zeitpunkt", %{
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
      h = halter_je_glied(:pruefen) |> mit_widerspruch()

      assert [hindernis] = Abschluss.hindernisse(stand(h))
      assert hindernis =~ "Befund"
      # Die Ablehnung nennt, worum es geht — nicht bloss „da ist noch etwas".
      assert hindernis =~ "Minuten"

      assert art(h, "fertig") == :error

      # lies_kette() zeigt die Befunde — damit sind sie angesehen.
      antwort = ruf(h, "lies_kette")
      assert antwort =~ "Befunde:"

      assert Abschluss.hindernisse(stand(h)) == []
      assert art(h, "fertig") == :halt
    end

    test "offen() nennt die ungesehenen Befunde, nicht die Zeilen" do
      h = halter_je_glied(:pruefen) |> mit_widerspruch()

      antwort = ruf(h, "offen")
      assert antwort =~ "Befund"
      refute antwort =~ "noch nicht gelesen"
      refute antwort =~ "nicht entschieden"
    end
  end

  describe "ein Befund ohne Anker ist trotzdem abhakbar" do
    test "der Spannen-Überlauf trägt keine anker_id und bekommt eine eigene Kennung" do
      # Ohne diese Kennung wäre die Schranke des Prüf-Laufs unter keinen
      # Umständen zu erfüllen: `gesehen` hakt über die ID ab, und `nil` ist
      # nie enthalten. Der Lauf liefe in den Rundendeckel — die Klasse, die
      # beim Chronik-Jack 28 von 51 Runden gekostet hat (#1211).
      h = halter_je_glied(:pruefen) |> mit_widerspruch()

      befunde = Abschluss.befunde(stand(h))
      ueberlauf = Enum.find(befunde, &(&1.art == :spannen_ueberlauf))

      assert ueberlauf, "der Widerspruch der Fixture muss einen Überlauf-Befund erzeugen"
      assert is_nil(ueberlauf.anker_id)
      assert is_binary(ueberlauf.id) and ueberlauf.id != ""

      ruf(h, "lies_kette")
      assert Abschluss.hindernisse(stand(h)) == []
    end
  end

  describe "lies_kette() zeigt die Befunde in Portionen" do
    test "gezeigt werden die ungesehenen; ein zweiter Aufruf bringt die nächsten" do
      # Sonst gilt mit einem einzigen Aufruf alles als angesehen, sobald es
      # mehr Befunde gibt, als in eine Antwort passen.
      h = halter_je_glied(:pruefen) |> mit_widerspruch()
      linie = Worker.Timeline.Linie.bauen(stellen(), Map.values(stand(h).anker))

      erste = Lesen.befunde_zum_zeigen(stand(h), linie)
      assert length(erste) >= 1

      ruf(h, "lies_kette")
      # Nach dem Ansehen sind keine ungesehenen mehr da — gezeigt wird dann
      # wieder der Bestand, aber nichts bleibt unentdeckt.
      assert Enum.reject(linie.befunde, &MapSet.member?(stand(h).gesehen, &1.id)) == []
    end

    test "das Merkmal der Wiederholungssperre hängt an der Zahl der gesehenen Befunde" do
      # Ohne das zählte der zweite lies_kette()-Aufruf als Wiederholung, obwohl er
      # neue Befunde zeigt (Muster der Suchen, #1210).
      w = Werkzeuge.fuer(halter(:pruefen)) |> Enum.find(&(&1.name == "lies_kette"))

      assert is_function(w.wiederholung_merkmal, 1)
    end
  end

  describe "lies_kette() zeigt GLIEDER, adressiert über Zeilennummern" do
    # Der Defekt vom 19.09.2026 war, dass `ab` die Position in der Reihe war
    # statt eine Zeilennummer — bei 459 gelösten Zeilen bedeutete
    # `lies_kette(ab: n)` etwas anderes als `lies_sprechlinie(ab: n)`. Seit
    # dem Kettenumbau zeigt es Glieder, und `ab` filtert sie über ihre
    # Zeilenspanne.
    test "ein Glied erscheint unter seiner Zeilenspanne" do
      h = halter(:pruefen)
      antwort = ruf(h, "lies_kette", %{"ab" => 1})

      assert antwort =~ "Glied"
      assert antwort =~ "Zeilen 1–5"
    end

    test "hinter dem letzten Glied sagt die Antwort das, statt leer zu bleiben" do
      h = halter(:pruefen)
      antwort = ruf(h, "lies_kette", %{"ab" => 99})

      assert antwort =~ "Ab Zeile 99 liegt kein Glied mehr in der Kette"
    end

    test "die leere Kette sagt, was zu tun ist" do
      {:ok, h} = Halter.start_link(Stand.neu(:einsortieren, mitschnitt()), abbild: &Stand.abbild/1)
      antwort = ruf(h, "lies_kette", %{})

      assert antwort =~ "noch LEER"
      assert antwort =~ "haenge_an_kette"
      assert antwort =~ "5 unentschieden"
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
