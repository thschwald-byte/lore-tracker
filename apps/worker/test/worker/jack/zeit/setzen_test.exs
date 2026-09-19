defmodule Worker.Jack.Zeit.SetzenTest do
  @moduledoc """
  #1247 (Z2): die drei Fälle beim Setzen eines Ankers — frei, belegt,
  abgesegnet.

  Die Regel stammt vom Maintainer (19.09.2026): „es darf an einem utt mehrere
  anker geben — wenn ein anker an ein utt mit vorhandenen anker soll, über
  werkzeug zurückmelden 'da ist schon xy', dann kann jack per werkzeug sagen
  'dazu' und er kann sagen 'löschen'".
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.Setzen

  defp guid_gibt, do: fn -> "g-test-1" end

  defp wunsch(art \\ :zeitpunkt, wert \\ "kurz nach zwölf") do
    %{
      utterance_ids: ["u1106"],
      art: art,
      wert: wert,
      welt: "spielwelt",
      beleg: "dann wird es jetzt so kurz nach zwölf sein"
    }
  end

  defp bestehend(art, wert, extra \\ %{}) do
    Map.merge(
      %{anker_id: "z_alt", art: art, wert: wert, abgesegnet_am: "", quelle: "jack"},
      extra
    )
  end

  describe "die Stelle ist frei" do
    test "wird gesetzt, mit content-adressierter Kennung" do
      assert {:gesetzt, anker} = Setzen.entscheiden(wunsch(), [], guid_gibt())

      assert String.starts_with?(anker.anker_id, "z_")
      assert anker.art == :zeitpunkt
      assert anker.quelle == "jack"
      assert anker.abgesegnet_am == ""
    end

    test "die Utterance-Menge wird sortiert und entdoppelt" do
      w = %{wunsch() | utterance_ids: ["u3", "u1", "u3"]}
      assert {:gesetzt, anker} = Setzen.entscheiden(w, [], guid_gibt())
      assert anker.utterance_ids == ["u1", "u3"]
    end
  end

  describe "dort hängt schon ein maschineller Anker" do
    test "wird NICHT gesetzt, sondern zurückgefragt" do
      bestand = [bestehend(:spanne, "eine Stunde")]

      assert {:rueckfrage, r} = Setzen.entscheiden(wunsch(), bestand, guid_gibt())

      assert r.guid == "g-test-1"
      # Die Antwort nennt, WAS dort steht — sonst müsste Jack raten, wogegen
      # er anläuft.
      assert r.text =~ "eine Stunde"
      assert r.text =~ "Spanne"
      # Und dass nichts passiert ist.
      assert r.text =~ "noch nichts"
      # Und beide Wege.
      assert r.text =~ "dazu"
      assert r.text =~ "ersetzen"
    end

    test "mit Entscheidung `dazu` wird gesetzt — beide hängen dann an der Utterance" do
      bestand = [bestehend(:spanne, "eine Stunde")]

      assert {:gesetzt, anker} =
               Setzen.entscheiden(wunsch(), bestand, guid_gibt(), {:dazu, "g-test-1"})

      # Der reale Fall: eine Utterance nennt eine Dauer UND den daraus
      # folgenden Zeitpunkt (seattleV5 S3, Block 1106).
      assert anker.art == :zeitpunkt
      refute anker.anker_id == "z_alt"
    end

    test "mit Entscheidung `ersetzen` ebenso" do
      bestand = [bestehend(:zeitpunkt, "4:11")]

      assert {:gesetzt, _} =
               Setzen.entscheiden(wunsch(), bestand, guid_gibt(), {:ersetzen, "g-test-1"})
    end
  end

  describe "dort hängt etwas Abgesegnetes" do
    test "wird verworfen, und die Antwort nennt die Festlegung" do
      bestand = [bestehend(:zeitpunkt, "22:45", %{abgesegnet_am: "2026-09-19"})]

      assert {:verworfen, v} = Setzen.entscheiden(wunsch(), bestand, guid_gibt())

      assert v.text =~ "22:45"
      assert v.text =~ "2026-09-19"
      assert v.text =~ "Mensch"
      # Kein Ausweg-loses „geht nicht": das kostete beim Chronik-Jack 28 von
      # 51 Runden (#1211).
      assert v.text =~ "konflikt_eintragen"
      assert v.text =~ "anders ein"
    end

    test "auch eine Entscheidung hebelt die Absegnung nicht aus" do
      bestand = [bestehend(:zeitpunkt, "22:45", %{abgesegnet_am: "2026-09-19"})]

      assert {:verworfen, _} =
               Setzen.entscheiden(wunsch(), bestand, guid_gibt(), {:ersetzen, "g-test-1"})

      assert {:verworfen, _} =
               Setzen.entscheiden(wunsch(), bestand, guid_gibt(), {:dazu, "g-test-1"})
    end

    test "sie gewinnt auch, wenn daneben ein maschineller hängt" do
      bestand = [
        bestehend(:spanne, "eine Stunde"),
        bestehend(:zeitpunkt, "22:45", %{abgesegnet_am: "2026-09-19", anker_id: "z_mensch"})
      ]

      assert {:verworfen, _} = Setzen.entscheiden(wunsch(), bestand, guid_gibt())
    end

    test "String-Schlüssel (wie aus dem Speicher) werden genauso erkannt" do
      bestand = [%{"art" => "zeitpunkt", "wert" => "22:45", "abgesegnet_am" => "2026-09-19"}]

      assert {:verworfen, v} = Setzen.entscheiden(wunsch(), bestand, guid_gibt())
      assert v.text =~ "22:45"
    end
  end

  describe "loesen/2" do
    test "schreibt eine reguläre Zeile mit Art geloest, kein Delete" do
      {:gesetzt, anker} = Setzen.entscheiden(wunsch(), [], guid_gibt())
      geloest = Setzen.loesen(anker, "Tischgespräch")

      assert geloest.art == :geloest
      assert geloest.zweifel == "Tischgespräch"
      # Dieselbe Adresse — sonst wäre es kein Zurücknehmen, sondern ein
      # zweites Objekt.
      assert geloest.anker_id == anker.anker_id
    end
  end
end
