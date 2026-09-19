defmodule Worker.Jack.Zeit.SetzenTest do
  @moduledoc """
  #1247 (Z2): die drei Fälle beim Setzen eines Ankers — frei, belegt,
  abgesegnet — und die Prüfung der Kennung.

  Die Regel stammt vom Maintainer (19.09.2026): „es darf an einem utt mehrere
  anker geben — wenn ein anker an ein utt mit vorhandenen anker soll, über
  werkzeug zurückmelden 'da ist schon xy', dann kann jack per werkzeug sagen
  'dazu' und er kann sagen 'löschen'".
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.{Setzen, Stand}

  defp zeile(nr, id),
    do: %{nr: nr, utterance_id: id, sprecher: "x", text: "t", block_id: "b", block_text: nil, ooc?: false}

  defp stand, do: Stand.neu(:einsortieren, for(i <- 1..5, do: zeile(i, "u#{i}")))

  defp guid_gibt, do: fn -> "g-test-1" end

  defp wunsch(art \\ :zeitpunkt, wert \\ "kurz nach zwölf", ids \\ ["u1"]) do
    %{
      utterance_ids: ids,
      art: art,
      wert: wert,
      welt: "spielwelt",
      beleg: "dann wird es jetzt so kurz nach zwölf sein"
    }
  end

  defp mit(stand, art, wert, ids, extra \\ %{}) do
    anker = Setzen.bauen(wunsch(art, wert, ids)) |> Map.merge(extra)
    Stand.setzen(stand, anker)
  end

  describe "die Stelle ist frei" do
    test "wird gesetzt, mit content-adressierter Kennung" do
      assert {:gesetzt, anker} = Setzen.entscheiden(stand(), wunsch(), nil, guid_gibt())

      assert String.starts_with?(anker.anker_id, "z_")
      assert anker.quelle == "jack"
      assert anker.abgesegnet_am == ""
    end

    test "die Utterance-Menge wird sortiert und entdoppelt" do
      w = wunsch(:zeitpunkt, "x", ["u3", "u1", "u3"])
      assert {:gesetzt, anker} = Setzen.entscheiden(stand(), w, nil, guid_gibt())
      assert anker.utterance_ids == ["u1", "u3"]
    end
  end

  describe "was „dieselbe Stelle\" heißt" do
    test "gleiche Art an derselben Utterance → Rückfrage" do
      s = mit(stand(), :zeitpunkt, "4:11", ["u1"])

      assert {:rueckfrage, r} = Setzen.entscheiden(s, wunsch(), nil, guid_gibt())
      assert r.text =~ "4:11"
      assert r.text =~ "noch nichts"
      assert r.text =~ "dazu"
      assert r.text =~ "ersetzen"
    end

    test "ANDERE Art an derselben Utterance → kein Konflikt, beide hängen dort" do
      # Der reale Fall (S3, Block 1106, eine Utterance): „also ist jetzt so
      # grob eine Stunde vergangen, dann wird es jetzt so kurz nach zwölf
      # sein". Spanne und Zeitpunkt ergänzen sich — hier zurückzufragen wäre
      # die Runden-Verschwendung, vor der #1211 warnt.
      s = mit(stand(), :spanne, "eine Stunde", ["u1"])

      assert {:gesetzt, _} = Setzen.entscheiden(s, wunsch(), nil, guid_gibt())
    end

    test "Überlappung genügt — die Mengen müssen nicht gleich sein" do
      # Mengengleichheit finge den Doppeleintrag nicht: derselbe Anker in
      # leicht anderer Formulierung hat meist auch eine leicht andere Menge.
      s = mit(stand(), :zeitpunkt, "4:11", ["u1", "u2"])

      assert {:rueckfrage, _} =
               Setzen.entscheiden(s, wunsch(:zeitpunkt, "x", ["u2", "u3"]), nil, guid_gibt())
    end

    test "ein gelöster Anker blockiert nicht mehr" do
      a = Setzen.bauen(wunsch(:zeitpunkt, "4:11", ["u1"]))
      s = stand() |> Stand.setzen(a) |> Stand.setzen(Setzen.loesen(a, "Tisch"))

      assert {:gesetzt, _} = Setzen.entscheiden(s, wunsch(), nil, guid_gibt())
    end
  end

  describe "die Kennung wird geprüft, nicht geglaubt" do
    test "mit gültiger Kennung wird gesetzt" do
      s =
        stand()
        |> mit(:zeitpunkt, "4:11", ["u1"])
        |> Stand.ausgeben("g1", %{utterance_ids: ["u1"]})

      assert {:gesetzt, _} = Setzen.entscheiden(s, wunsch(), {:dazu, "g1"}, guid_gibt())
    end

    test "eine Kennung für eine ANDERE Stelle gilt nicht" do
      # Der durchspielbare Fall aus dem Review: Rückfrage zu Stelle A mit g1,
      # Antwort {:ersetzen, g1}, Wunsch auf Stelle B — der erste Wurf setzte
      # bei B, ohne zu prüfen.
      s =
        stand()
        |> mit(:zeitpunkt, "4:11", ["u4"])
        |> Stand.ausgeben("g1", %{utterance_ids: ["u4"]})

      assert {:verworfen, v} =
               Setzen.entscheiden(s, wunsch(:zeitpunkt, "x", ["u1"]), {:ersetzen, "g1"}, guid_gibt())

      assert v.text =~ "anderen Stelle"
    end

    test "eine erfundene Kennung wird als solche benannt" do
      s = mit(stand(), :zeitpunkt, "4:11", ["u1"])

      assert {:verworfen, v} = Setzen.entscheiden(s, wunsch(), {:dazu, "ausgedacht"}, guid_gibt())
      assert v.text =~ "nie ausgegeben"
    end

    test "eine eingelöste Kennung gilt nicht zweimal" do
      s =
        stand()
        |> mit(:zeitpunkt, "4:11", ["u1"])
        |> Stand.ausgeben("g1", %{utterance_ids: ["u1"]})
        |> Stand.verbrauchen("g1")

      assert {:verworfen, v} = Setzen.entscheiden(s, wunsch(), {:dazu, "g1"}, guid_gibt())
      assert v.text =~ "eingelöst"
    end

    test "eine verfallene Kennung wird von einer erfundenen unterschieden" do
      # „abgelaufen" ist normaler Ablauf, „erfunden" ein Modellfehler — eine
      # Antwort, die beides gleich behandelt, schickt Jack in die Wiederholung.
      s =
        stand()
        |> mit(:zeitpunkt, "4:11", ["u1"])
        |> Stand.ausgeben("g1", %{utterance_ids: ["u1"]})
        |> Stand.verfallen("g2")

      assert {:verworfen, v} = Setzen.entscheiden(s, wunsch(), {:dazu, "g1"}, guid_gibt())
      assert v.text =~ "verfallen"
      refute v.text =~ "nie ausgegeben"
    end
  end

  describe "dort hängt etwas Abgesegnetes" do
    test "wird verworfen, und die Antwort nennt die Festlegung" do
      s = mit(stand(), :zeitpunkt, "22:45", ["u1"], %{abgesegnet_am: "2026-09-19"})

      assert {:verworfen, v} = Setzen.entscheiden(s, wunsch(), nil, guid_gibt())

      assert v.text =~ "22:45"
      assert v.text =~ "2026-09-19"
      assert v.text =~ "Mensch"
      assert v.text =~ "konflikt_eintragen"
    end

    test "auch eine gültige Kennung hebelt sie nicht aus" do
      s =
        stand()
        |> mit(:zeitpunkt, "22:45", ["u1"], %{abgesegnet_am: "2026-09-19"})
        |> Stand.ausgeben("g1", %{utterance_ids: ["u1"]})

      assert {:verworfen, _} = Setzen.entscheiden(s, wunsch(), {:ersetzen, "g1"}, guid_gibt())
      assert {:verworfen, _} = Setzen.entscheiden(s, wunsch(), {:dazu, "g1"}, guid_gibt())
    end
  end

  describe "loesen/2" do
    test "schreibt eine reguläre Zeile mit Art geloest, auf DERSELBEN Adresse" do
      {:gesetzt, anker} = Setzen.entscheiden(stand(), wunsch(), nil, guid_gibt())
      geloest = Setzen.loesen(anker, "Tischgespräch")

      assert geloest.art == :geloest
      assert geloest.zweifel == "Tischgespräch"
      assert geloest.anker_id == anker.anker_id

      # Die Adresse beschreibt den Inhalt damit nicht mehr — bewusst: wer sie
      # beim Lösen „korrekt" neu berechnet, erzeugt eine zweite Row, und die
      # alte bliebe für immer gesetzt.
      refute geloest.anker_id ==
               Worker.Timeline.Linie.anker_id(geloest.utterance_ids, :geloest, geloest.wert)
    end
  end
end
