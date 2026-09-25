defmodule Worker.Jack.Chronik.ZeitlinieTest do
  @moduledoc """
  #1247 (Z3): die Chronik **sieht** die Kette und darf sich gegen sie
  entscheiden.

  Maintainer, 25.09.2026: „die chronik soll sich entscheiden können die kette
  zu benutzen — aber soll sich auch dagegen entscheiden dürfen", und: „er kann
  und darf abweichen — und er soll nicht ungeprüft übernehmen."

  Geprüft wird deshalb nicht, dass die Kette gewinnt, sondern dass sie
  **prüfbar** ankommt: neben der eigenen Angabe des Fakts, mit Beleg, und mit
  dem Unterschied zwischen belegt und gerechnet. Ein Angebot ohne Beleg wäre
  keines — es liesse sich nur glauben.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Eingabe
  alias Worker.Jack.Resuemee.Lesen
  alias Worker.Timeline.Linie

  # Ein Fakt in der Form der Lesebasis, wie `Resuemee.Eingabe.fakten/4` sie baut.
  defp fakt(extra \\ %{}) do
    Map.merge(
      %{
        refs: ["b1"],
        id: "S1-F1",
        fakt_id: "f_eins",
        sitzung: 1,
        aussage: "Ryumyo erwacht am Mount Fuji.",
        figur: nil,
        typ: "ereignis",
        boegen: [],
        datum: nil,
        erzaehlzeit: "present",
        bloecke: [1],
        ohne_block: []
      },
      extra
    )
  end

  describe "die Zeile, die das Modell liest" do
    test "belegte Zeit kommt mit ihrem Zitat an — sonst ist sie nicht prüfbar" do
      zeile = Lesen.zeile(fakt(%{zeit_linie: ~s(24. Dezember 2011 belegt mit „am Fuji“)}), true)

      assert zeile =~ "Zeitlinie:"
      assert zeile =~ "24. Dezember 2011"
      assert zeile =~ "am Fuji"
    end

    test "gerechnete Zeit ist als solche markiert" do
      zeile = Lesen.zeile(fakt(%{zeit_linie: "1. August 2020 (gerechnet)"}), true)
      assert zeile =~ "(gerechnet)"
    end

    test "die eigene Angabe des Fakts bleibt daneben stehen — nichts verdrängt sie" do
      # Der Kern der Vorgabe: Würde eines das andere ersetzen, gäbe es nichts
      # zu prüfen, und ein falscher Anker verbiegt die Chronik lautlos.
      zeile =
        Lesen.zeile(
          fakt(%{datum: "im Frühjahr 2080", zeit_linie: "24. Dezember 2011 belegt mit „x“"}),
          true
        )

      assert zeile =~ "im Frühjahr 2080"
      assert zeile =~ "24. Dezember 2011"
    end

    test "ohne Kette ist die Zeile wie vor #1247" do
      ohne = Lesen.zeile(fakt(%{datum: "im Frühjahr 2080"}), true)
      refute ohne =~ "Zeitlinie"
      assert ohne =~ "im Frühjahr 2080"
    end

    test "ein Fakt ohne jede Zeit zeigt einen Strich, keinen leeren Platzhalter" do
      assert Lesen.zeile(fakt(), true) =~ "—"
    end
  end

  describe "was die Eingabe an den Fakt hängt" do
    # Eine Linie von Hand, ohne Repo: `aus_kette/3` ist pur.
    defp linie_mit(anker) do
      stellen = [
        %{utterance_id: "u1", session_number: 1, position: 1},
        %{utterance_id: "u2", session_number: 1, position: 2}
      ]

      {:ok, k, _} = Worker.Timeline.Kette.anhaengen(Worker.Timeline.Kette.neu(), ["u1", "u2"])
      Linie.aus_kette(k, anker, stellen)
    end

    test "der Beleg reist durch anker_fuer mit" do
      # Ohne diesen Durchgang wäre die Prüfpflicht nicht erfüllbar: Der Beleg
      # steht am Anker, und `anker_fuer/2` hat ihn bis zu diesem Cut
      # weggelassen.
      anker = [
        %{
          anker_id: "z1",
          utterance_ids: ["u1"],
          art: :zeitpunkt,
          wert: "am 24. Dezember 2011",
          welt: "spielwelt",
          beleg: "Da erwachte Ryumyo am Fuji.",
          zweifel: "",
          quelle: "jack"
        }
      ]

      [eintrag | _] = Linie.anker_fuer(linie_mit(anker), ["u1"])
      assert eintrag[:beleg] == "Da erwachte Ryumyo am Fuji."
      assert eintrag[:wert] == "am 24. Dezember 2011"
    end

    test "ein Fakt ohne Zeit in der Kette bekommt KEIN Feld" do
      # Kein Platzhalter: „leer" wäre eine Aussage über eine Zeit, die es
      # nicht gibt.
      [ohne] = Eingabe.mit_zeitlinie([fakt()], "gibt-es-nicht")
      refute Map.has_key?(ohne, :zeit_linie)
    end

    test "ein Fehler beim Lesen der Kette lässt die Fakten unverändert" do
      # Best-effort wie der Zeit-Jack selbst — die Chronik muss ohne Kette
      # laufen können.
      fakten = [fakt(), fakt(%{id: "S1-F2"})]
      assert Eingabe.mit_zeitlinie(fakten, "gibt-es-nicht") |> length() == 2
    end
  end

  describe "die Aufträge sagen die Prüfpflicht an" do
    test "der Schreib-Lauf nennt Beleg, gerechnet und das Recht abzuweichen" do
      text = File.read!("priv/jack/auftraege/chronik_schreiben.md")

      assert text =~ "Zeitlinie"
      assert text =~ "nicht ungeprüft übernehmen"
      assert text =~ "(gerechnet)"
      assert text =~ "entscheide\n  gegen sie"
    end

    test "und die Verfeinerung ebenso — sie ist der Normalfall" do
      text = File.read!("priv/jack/auftraege/chronik_verfeinerung.md")
      assert text =~ "nicht ungeprüft übernehmen"
    end

    test "beide nennen den Rang und den Weg zum Selbstnachsehen" do
      # Maintainer, 25.09.2026: „sag aber dass die kette meistens besser ist —
      # und dass er auch selber Zeitdaten kontextuell überprüfen soll, wenn ihm
      # etwas fishy vorkommt."
      for f <- ~w(chronik_schreiben chronik_verfeinerung) do
        text = File.read!("priv/jack/auftraege/#{f}.md")

        assert text =~ "Meistens ist die Zeitlinie die bessere Angabe",
               "#{f} nennt den Rang nicht"

        assert text =~ "schau selbst nach", "#{f} sagt nicht, dass er selbst prüfen soll"
        assert text =~ "Verdächtig heißt", "#{f} nennt keine Beispiele für verdächtig"
      end
    end

    test "und sie nennen nur Werkzeuge, die der Chronik-Jack wirklich hat" do
      # Ein Auftrag, der ein Werkzeug nennt, das es nicht gibt, schickt Jack in
      # einen Fehlversuch — und der zählt in die Wiederholungssperre (#1211).
      vorhanden =
        Worker.Jack.Chronik.Werkzeuge.namen(%Worker.Jack.Resuemee.Stand{
          lauf: :schreiben,
          art: :chronik
        })

      for w <- ~w(block bloecke suche_sitzung fakt) do
        assert w in vorhanden, "der Auftrag nennt #{w}, der Lauf hat es nicht"
      end
    end
  end
end
