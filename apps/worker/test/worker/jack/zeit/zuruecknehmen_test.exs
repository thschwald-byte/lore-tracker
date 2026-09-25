defmodule Worker.Jack.Zeit.ZuruecknehmenTest do
  @moduledoc """
  #1247: **Jack kann einen Anker zurücknehmen** — ohne Ersatz.

  Der Anlass steht im Denkstrom des Laufs vom 24.09.2026. Jack schrieb
  fünfzehnmal denselben Gedanken:

  > „the '60 Jahre her' span is causing the conflict because it's pulling the
  > timeline back to 2055 … The real issue is that this span needs a concrete
  > event to attach to, but it's just a relative reference without one. I think
  > the cleanest solution is to remove this span entirely."

  Sechs Minuten, fachlich richtig erkannt — und kein Werkzeug dafür.
  `anker_ersetzen` verlangt einen Ersatz, und „nichts" ist keiner. Die
  Mechanik dagegen war längst da: `Setzen.loesche_kettenplatz/2`, gebaut und
  dokumentiert, mit **null Aufrufern** (die Klasse „Apparat ohne Producer",
  die dieses Repo mit #724 und #1109 zweimal erzeugt hat).
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Aufruf
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Stand, Werkzeuge}

  defp zeile(nr),
    do: %{
      nr: nr,
      utterance_id: "u#{nr}",
      sprecher: "SL",
      text: "Zeile #{nr}",
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp halter(opts \\ []) do
    {:ok, h} =
      Halter.start_link(Stand.neu(:einsortieren, Enum.map(1..5, &zeile/1), opts),
        abbild: &Stand.abbild/1
      )

    h
  end

  defp ruf(h, name, felder) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  defp mit_spanne do
    h = halter()
    {:ok, _} = ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})

    {:ok, _} =
      ruf(h, "setz_spanne", %{
        "zeilen" => [2],
        "wert" => "60 Jahre",
        "welt" => "spielwelt",
        "beleg" => "Das war 60 Jahre her."
      })

    h
  end

  defp aktive_anker(h) do
    Halter.stand(h).anker
    |> Map.values()
    |> Enum.reject(&(to_string(&1[:art] || &1["art"]) == "geloest"))
  end

  describe "die Rücknahme" do
    test "nimmt den Anker aus der Rechnung, lässt die Zeilen in der Kette" do
      h = mit_spanne()
      assert length(aktive_anker(h)) == 1

      assert {:ok, text} =
               ruf(h, "nimm_anker_zurueck", %{
                 "zeilen" => [2],
                 "art" => "spanne",
                 "grund" => "eine Dauer ohne Bezugspunkt trägt nicht"
               })

      assert text =~ "Zurückgenommen: Spanne „60 Jahre“"
      assert aktive_anker(h) == []
      assert Worker.Timeline.Kette.anzahl(Halter.stand(h).kette) == 1
    end

    test "schreibt einen Grabstein, kein Delete (#698)" do
      # Die Row muss stehen bleiben: Ein Delete käme bei vertauschter
      # Zustellung zwischen zwei Workern als gesetzter Anker zurück.
      h = mit_spanne()
      ruf(h, "nimm_anker_zurueck", %{"zeilen" => [2], "art" => "spanne", "grund" => "weg"})

      [geloest] = Map.values(Halter.stand(h).anker)
      assert to_string(geloest[:art]) == "geloest"
      assert geloest[:zweifel] == "weg"
      assert geloest[:wert] == "60 Jahre", "der Wortlaut bleibt lesbar, sonst fehlt der Befund"
    end

    test "der Grund steht an der Stelle — sonst weiss niemand, was Jack sah" do
      h = mit_spanne()

      ruf(h, "nimm_anker_zurueck", %{
        "zeilen" => [2],
        "art" => "spanne",
        "grund" => "zieht die Linie auf 2055 zurück"
      })

      assert [%{zweifel: "zieht die Linie auf 2055 zurück"}] = Map.values(Halter.stand(h).anker)
    end
  end

  describe "was nicht geht — und jede Absage nennt den Weg" do
    test "zweimal dasselbe: die zweite Absage sagt, wo man nachsieht" do
      h = mit_spanne()
      ruf(h, "nimm_anker_zurueck", %{"zeilen" => [2], "art" => "spanne", "grund" => "weg"})

      assert {:error, text} =
               ruf(h, "nimm_anker_zurueck", %{
                 "zeilen" => [2],
                 "art" => "spanne",
                 "grund" => "nochmal"
               })

      assert text =~ "hängt von mir keine Spanne"
      assert text =~ "lies_kette()"
    end

    test "eine andere Art an derselben Zeile wird nicht verwechselt" do
      # An einer Utterance dürfen mehrere Anker hängen (Spanne + Zeitpunkt).
      # Ohne das `art`-Feld träfe die Rücknahme den falschen.
      h = mit_spanne()

      assert {:error, text} =
               ruf(h, "nimm_anker_zurueck", %{
                 "zeilen" => [2],
                 "art" => "zeitpunkt",
                 "grund" => "x"
               })

      assert text =~ "kein Zeitpunkt"
      assert length(aktive_anker(h)) == 1, "die Spanne muss stehen bleiben"
    end

    test "was ein Mensch abgesegnet hat, nimmt kein Lauf zurück" do
      # Dieselbe Regel wie beim Setzen. Und sie nennt melde_konflikt, statt
      # nur abzulehnen — eine Absage ohne Ausweg kostete in #1211 28 von 51
      # Runden.
      mensch = %{
        anker_id: "z_mensch",
        utterance_ids: ["u2"],
        art: :zeitpunkt,
        wert: "am 15. November 2080",
        welt: "spielwelt",
        beleg: "",
        zweifel: "",
        quelle: "mensch",
        abgesegnet_von: "Tom",
        abgesegnet_am: "2026-09-20"
      }

      h = halter(anker: [mensch])
      {:ok, _} = ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 5})

      assert {:error, text} =
               ruf(h, "nimm_anker_zurueck", %{
                 "zeilen" => [2],
                 "art" => "zeitpunkt",
                 "grund" => "passt nicht"
               })

      assert text =~ "2026-09-20"
      assert text =~ "am 15. November 2080"
      assert text =~ "melde_konflikt"
      assert length(aktive_anker(h)) == 1
    end
  end

  describe "die Verdrahtung" do
    test "das Werkzeug steht in der Namensliste des Einsortier-Laufs" do
      # Ohne diesen Eintrag ist die Definition unerreichbar — genau so ist es
      # beim ersten Anlauf passiert: „Werkzeug gibt es nicht", obwohl es
      # definiert war.
      s = Stand.neu(:einsortieren, Enum.map(1..3, &zeile/1))
      assert "nimm_anker_zurueck" in Werkzeuge.namen(s)
      assert Enum.any?(Werkzeuge.definitionen(s), &(&1.name == "nimm_anker_zurueck"))
    end

    test "und es setzt aendert_bestand — sonst zählt offen() weiter" do
      s = Stand.neu(:einsortieren, Enum.map(1..3, &zeile/1))
      d = Enum.find(Werkzeuge.definitionen(s), &(&1.name == "nimm_anker_zurueck"))
      assert d[:aendert_bestand] == true
    end
  end
end
