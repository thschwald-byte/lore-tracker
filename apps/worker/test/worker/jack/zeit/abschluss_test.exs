defmodule Worker.Jack.Zeit.AbschlussTest do
  @moduledoc """
  #1247 (Z2): was `fertig()` verlangt.

  Maintainer (19.09.2026): „fertig verlangt, dass jedes utt zugeordnet ist:
  entweder davor/danach oder fällt raus."
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.{Abschluss, Setzen, Stand}
  alias Worker.Timeline.Kette

  defp zeile(nr, id),
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "x",
      text: "t",
      block_id: "b",
      block_text: nil,
      ooc?: false
    }

  defp lies_sprechlinie(n), do: for(i <- 1..n, do: zeile(i, "u#{i}"))

  defp alles_gelesen(s), do: Stand.gelesen(s, s.mitschnitt)

  # Seit dem Kettenumbau (20.09.2026) ist „entschieden" die zweite Schranke:
  # Jede Zeile liegt in einem Glied oder ist ausdrücklich draussen. Die Tests
  # prüfen je EINE Bedingung; damit die anderen nicht dazwischenfunken,
  # reihen sie vorab alles ein — ausser dort, wo genau das der Gegenstand ist.
  defp alles_eingereiht(s) do
    ids = Enum.map(s.mitschnitt, & &1.utterance_id)
    {:ok, s, _} = Stand.kette(s, &Kette.anhaengen(&1, ids))
    s
  end

  defp nur_lesen_offen(s), do: alles_eingereiht(s)

  describe "die Leseabdeckung" do
    test "blockiert, solange Zeilen nie ausgegeben wurden" do
      # Ohne diese Schranke hiesse „fertig" bloss „Jack hat aufgehört": Er
      # könnte nach 3 von 100 Zeilen abschliessen, und die übrigen 97 gälten
      # als richtig eingeordnet — ein Fehler, der wie ein Ergebnis aussieht.
      s = Stand.neu(:einsortieren, lies_sprechlinie(100)) |> alles_eingereiht()
      s = Stand.gelesen(s, Enum.take(s.mitschnitt, 3))

      assert [hindernis] = Abschluss.hindernisse(s)
      assert hindernis =~ "97 von 100"
    end

    test "die Ablehnung nennt Zahl UND Stellen, nicht nur ein Nein" do
      # #1211-Lehre: Eine Ablehnung, die die gezählte Zahl verschweigt,
      # schickte den Chronik-Jack durch 112 Fakten, obwohl seine Arbeit
      # vollständig war.
      s = Stand.neu(:einsortieren, lies_sprechlinie(20)) |> alles_eingereiht()
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
      s = Stand.neu(:einsortieren, lies_sprechlinie(100)) |> alles_eingereiht()

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "1–100"
      # Nicht hundert Nummern in einem Satz.
      assert length(String.split(h, ",")) < 20
    end

    test "mehrere Lücken werden einzeln genannt" do
      # Der häufige Fall: Jack liest mitten im Mitschnitt weiter und lässt
      # vorn eine Lücke. Eine Aufzählung „ab der nächsten" verstecke sie.
      m = lies_sprechlinie(100)
      mitte = Enum.filter(m, &(&1.nr in 21..60))
      s = Stand.neu(:einsortieren, m) |> alles_eingereiht() |> Stand.gelesen(mitte)

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "1–20"
      assert h =~ "61–100"
    end

    test "einzelne Zeilen bleiben einzelne Nummern" do
      m = lies_sprechlinie(10)

      s =
        Stand.neu(:einsortieren, m)
        |> alles_eingereiht()
        |> Stand.gelesen(Enum.reject(m, &(&1.nr in [3, 7])))

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "3, 7"
    end

    test "alles gelesen und nichts angefasst → darf abschliessen" do
      # Die Erzählposition IST eine Zuordnung. Wer nichts anfasst, hat nichts
      # offen — kein Quittieren je Utterance.
      s = Stand.neu(:einsortieren, lies_sprechlinie(50)) |> alles_gelesen() |> alles_eingereiht()

      assert Abschluss.hindernisse(s) == []
    end
  end

  describe "die Entscheidung: in ein Glied oder ausdrücklich heraus" do
    # Maintainer, 20.09.2026: „Default beim Start: Kette ist leer — jack soll
    # bewusst einsortieren." Damit ist „offen" eindeutig; vorher hiess „nicht
    # angefasst" zweierlei zugleich.
    test "blockiert, solange Zeilen unentschieden sind" do
      s = Stand.neu(:einsortieren, lies_sprechlinie(100)) |> alles_gelesen()

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "100 von 100 Zeilen sind noch nicht entschieden"
      assert h =~ "1–100"
      assert h =~ "haenge_an_kette", "die Ablehnung nennt den Ausweg"
      assert h =~ "nicht_in_die_kette"
    end

    test "eingereihte Zeilen sind entschieden" do
      m = lies_sprechlinie(10)
      ids = Enum.map(m, & &1.utterance_id)
      s = Stand.neu(:einsortieren, m) |> alles_gelesen()
      {:ok, s, _} = Stand.kette(s, &Kette.anhaengen(&1, ids))

      assert Abschluss.hindernisse(s) == []
    end

    test "Tischgespräch ist entschieden, wenn es DRAUSSEN ist" do
      # Der alte Weg brauchte zwei Schritte — etikettieren und aus der Linie
      # nehmen — und eine eigene Schranke dafür, dass beides zusammenpasst.
      # `nicht_in_die_kette` ist derselbe Aufruf: Was draussen ist, ist
      # entschieden, und es kann gar nicht mehr auf der Kette liegen.
      m = lies_sprechlinie(10)
      {tisch, rest} = Enum.split(m, 3)

      tisch_ids = Enum.map(tisch, & &1.utterance_id)
      rest_ids = Enum.map(rest, & &1.utterance_id)
      s = Stand.neu(:einsortieren, m) |> alles_gelesen()
      {:ok, s, _} = Stand.kette(s, &Kette.draussen(&1, tisch_ids, "Tisch"))
      {:ok, s, _} = Stand.kette(s, &Kette.anhaengen(&1, rest_ids))

      assert Abschluss.hindernisse(s) == []
      assert Kette.reihenfolge(s.kette) == rest_ids
    end

    test "ein Teil entschieden, der Rest nicht — die Ablehnung nennt genau den Rest" do
      m = lies_sprechlinie(10)
      s = Stand.neu(:einsortieren, m) |> alles_gelesen()
      {:ok, s, _} = Stand.kette(s, &Kette.anhaengen(&1, ~w(u1 u2 u3)))
      {:ok, s, _} = Stand.kette(s, &Kette.draussen(&1, ~w(u4 u5), "Tisch"))

      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "5 von 10"
      assert h =~ "6–10"
    end

    test "ein gelöschtes Glied macht seine Zeilen wieder unentschieden" do
      # Herausnehmen ist kein Urteil über den Inhalt — wer falsch geschnitten
      # hat, soll neu schneiden, ohne dass die Zeilen als Tisch gelten.
      m = lies_sprechlinie(5)
      ids = Enum.map(m, & &1.utterance_id)
      s = Stand.neu(:einsortieren, m) |> alles_gelesen()
      {:ok, s, glied} = Stand.kette(s, &Kette.anhaengen(&1, ids))
      assert Abschluss.hindernisse(s) == []

      {:ok, s, _} = Stand.kette(s, &Kette.loeschen(&1, glied.id))
      assert [h] = Abschluss.hindernisse(s)
      assert h =~ "5 von 5"
    end
  end

  describe "die Eindeutigkeit der Reihe" do
    test "Zeitpunkte und Spannen blockieren nie — sie sind vollständig für sich" do
      s =
        Stand.neu(:einsortieren, lies_sprechlinie(5))
        |> alles_gelesen()
        |> alles_eingereiht()
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
      s = Stand.neu(:pruefen, lies_sprechlinie(4))
      s = Stand.gelesen(s, [zeile(1, "u1"), zeile(3, "u3")])

      assert Enum.map(Abschluss.nie_gelesen(s), & &1.nr) == [2, 4]
    end
  end
end
