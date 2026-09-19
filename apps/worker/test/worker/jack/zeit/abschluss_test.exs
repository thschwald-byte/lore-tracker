defmodule Worker.Jack.Zeit.AbschlussTest do
  @moduledoc """
  #1247 (Z2): was `fertig()` verlangt.

  Maintainer (19.09.2026): „fertig verlangt, dass jedes utt zugeordnet ist:
  entweder davor/danach oder fällt raus."
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.{Abschluss, Setzen, Stand}

  defp zeile(nr, id),
    do: %{nr: nr, utterance_id: id, sprecher: "x", text: "t", block_id: "b", block_text: nil, ooc?: false}

  defp mitschnitt(n), do: for(i <- 1..n, do: zeile(i, "u#{i}"))

  defp alles_gelesen(s), do: Stand.gelesen(s, s.mitschnitt)

  # Seit #1247 braucht jede Zeile eine Einordnung. Die Tests dieser Datei
  # prüfen je EINE Bedingung; damit die anderen nicht dazwischenfunken,
  # ordnen sie vorab ein — ausser dort, wo genau das der Gegenstand ist.
  defp alles_eingeordnet(s), do: Stand.einordnen(s, s.mitschnitt, :ingame)

  defp nur_lesen_offen(s), do: s |> alles_eingeordnet()

  describe "die Leseabdeckung" do
    test "blockiert, solange Zeilen nie ausgegeben wurden" do
      # Ohne diese Schranke hiesse „fertig" bloss „Jack hat aufgehört": Er
      # könnte nach 3 von 100 Zeilen abschliessen, und die übrigen 97 gälten
      # als richtig eingeordnet — ein Fehler, der wie ein Ergebnis aussieht.
      s = Stand.neu(:einsortieren, mitschnitt(100)) |> alles_eingeordnet()
      s = Stand.gelesen(s, Enum.take(s.mitschnitt, 3))

      assert [hindernis] = Abschluss.hindernisse(s)
      assert hindernis =~ "97 von 100"
    end

    test "die Ablehnung nennt Zahl UND Stellen, nicht nur ein Nein" do
      # #1211-Lehre: Eine Ablehnung, die die gezählte Zahl verschweigt,
      # schickte den Chronik-Jack durch 112 Fakten, obwohl seine Arbeit
      # vollständig war.
      s = Stand.neu(:einsortieren, mitschnitt(20)) |> alles_eingeordnet()
      s = Stand.gelesen(s, Enum.take(s.mitschnitt, 18))

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "2 von 20"
      # Die konkreten Nummern, damit er sie gezielt schliessen kann.
      assert h =~ "19"
      assert h =~ "20"
    end

    test "viele offene Stellen werden zu BEREICHEN, nicht zu einer Nummernliste" do
      # Eine Liste der „nächsten zwölf" ist bei hundert offenen Zeilen keine
      # Auskunft: Sie sagt nicht, WO die Lücken sind, und legt nahe, es seien
      # nur diese (Maintainer, 19.09.2026).
      s = Stand.neu(:einsortieren, mitschnitt(100)) |> alles_eingeordnet()

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "1–100"
      # Nicht hundert Nummern in einem Satz.
      assert length(String.split(h, ",")) < 20
    end

    test "mehrere Lücken werden einzeln genannt" do
      # Der häufige Fall: Jack liest mitten im Mitschnitt weiter und lässt
      # vorn eine Lücke. Eine Aufzählung „ab der nächsten" verstecke sie.
      m = mitschnitt(100)
      mitte = Enum.filter(m, &(&1.nr in 21..60))
      s = Stand.neu(:einsortieren, m) |> alles_eingeordnet() |> Stand.gelesen(mitte)

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "1–20"
      assert h =~ "61–100"
    end

    test "einzelne Zeilen bleiben einzelne Nummern" do
      m = mitschnitt(10)

      s =
        Stand.neu(:einsortieren, m)
        |> alles_eingeordnet()
        |> Stand.gelesen(Enum.reject(m, &(&1.nr in [3, 7])))

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "3, 7"
    end

    test "alles gelesen und nichts angefasst → darf abschliessen" do
      # Die Erzählposition IST eine Zuordnung. Wer nichts anfasst, hat nichts
      # offen — kein Quittieren je Utterance.
      s = Stand.neu(:einsortieren, mitschnitt(50)) |> alles_gelesen() |> alles_eingeordnet()

      assert Abschluss.hindernisse(s) == []
    end
  end

  describe "die Einordnung" do
    # Maintainer, 19.09.2026: „er muss zu jeder schreiben Tischgespräch /
    # In-Game / unklar — alle utts mit tischgespräche müssen aus der kette
    # entfernt sein."
    test "blockiert, solange Zeilen keine Einordnung haben" do
      s = Stand.neu(:einsortieren, mitschnitt(100)) |> alles_gelesen()

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "100 von 100 Zeilen sind noch nicht eingeordnet"
      assert h =~ "1–100"
    end

    test "Tischgespräch muss AUS der Kette heraus, nicht nur etikettiert" do
      # Eine Zeile, die als Tisch eingeordnet ist und trotzdem auf der Linie
      # liegt, wird interpoliert und bekommt eine Spielzeit, die es nicht gibt.
      m = mitschnitt(10)

      s =
        Stand.neu(:einsortieren, m)
        |> alles_gelesen()
        |> Stand.einordnen(m, :ingame)
        |> Stand.einordnen(Enum.take(m, 3), :tisch)

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "3 Zeile(n) sind als Tischgespräch eingeordnet"
      assert h =~ "1–3"
    end

    test "gelöst und als Tisch eingeordnet ist in Ordnung" do
      m = mitschnitt(10)
      raus = Enum.take(m, 3)

      anker =
        Setzen.bauen(%{
          utterance_ids: Enum.map(raus, & &1.utterance_id),
          art: :geloest,
          wert: "Tisch",
          welt: "tisch",
          beleg: ""
        })

      s =
        Stand.neu(:einsortieren, m)
        |> alles_gelesen()
        |> Stand.einordnen(m, :ingame)
        |> Stand.einordnen(raus, :tisch)
        |> Stand.setzen(anker)

      assert Abschluss.hindernisse(s) == []
    end
  end

  describe "die Eindeutigkeit der Reihe" do
    test "eine Verschiebung ohne auflösbares Ziel blockiert" do
      s =
        Stand.neu(:einsortieren, mitschnitt(5))
        |> alles_gelesen() |> alles_eingeordnet()
        |> Stand.setzen(
          Setzen.bauen(%{
            utterance_ids: ["u3"],
            art: :ordnung,
            wert: "vor dem Überfall",
            welt: "spielwelt",
            beleg: "b"
          })
          |> Map.put(:ziel, "gibt-es-nicht")
        )

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "kein auflösbares Ziel"
    end

    test "mit auflösbarem Ziel ist sie in Ordnung" do
      s =
        Stand.neu(:einsortieren, mitschnitt(5))
        |> alles_gelesen() |> alles_eingeordnet()
        |> Stand.setzen(
          Setzen.bauen(%{
            utterance_ids: ["u3"],
            art: :ordnung,
            wert: "vor dem Überfall",
            welt: "spielwelt",
            beleg: "b"
          })
          |> Map.put(:ziel, "u1")
        )

      assert Abschluss.hindernisse(s) == []
    end

    test "Zeitpunkte und Spannen blockieren nie — sie sind vollständig für sich" do
      s =
        Stand.neu(:einsortieren, mitschnitt(5))
        |> alles_gelesen() |> alles_eingeordnet()
        |> Stand.setzen(
          Setzen.bauen(%{
            utterance_ids: ["u1"],
            art: :zeitpunkt,
            wert: "elf Uhr",
            welt: "spielwelt",
            beleg: "b"
          })
        )
        |> Stand.setzen(
          Setzen.bauen(%{
            utterance_ids: ["u2"],
            art: :spanne,
            wert: "zwei Stunden",
            welt: "spielwelt",
            beleg: "b"
          })
        )

      assert Abschluss.hindernisse(s) == []
    end
  end

  describe "nie_gelesen/1" do
    test "liefert die Zeilen selbst, nicht nur ihre Zahl" do
      s = Stand.neu(:pruefen, mitschnitt(4))
      s = Stand.gelesen(s, [zeile(1, "u1"), zeile(3, "u3")])

      assert Enum.map(Abschluss.nie_gelesen(s), & &1.nr) == [2, 4]
    end
  end
end
