defmodule Worker.Timeline.AusdruckTest do
  @moduledoc """
  #1247 (Z1): aus dem gesprochenen Ausdruck wird eine Zahl — und wo nicht,
  bleibt er absichtlich ohne.

  Der Schwerpunkt liegt auf der **Uhrzeit**: Sie ist am Spieltisch der
  häufigste genannte Zeitpunkt, und `Worker.Timeline.Parser` kennt sie nur
  als „kann ich nicht". Die Tests halten beides fest — was gelesen wird und
  was bewusst nicht.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.{Ausdruck, Calendar}

  defp cal, do: Calendar.default()

  describe "tagesminute/1 liest die ziffernförmige Uhrzeit" do
    test "die drei Schreibweisen ergeben dieselbe Minute" do
      assert Ausdruck.tagesminute("22:45") == 22 * 60 + 45
      assert Ausdruck.tagesminute("22 Uhr 45") == 22 * 60 + 45
      assert Ausdruck.tagesminute("um 22 uhr 45 ungefähr") == 22 * 60 + 45
    end

    test "ohne Minutenangabe ist es die volle Stunde" do
      assert Ausdruck.tagesminute("22 Uhr") == 22 * 60
    end

    test "einstellige Stunden und führende Nullen" do
      assert Ausdruck.tagesminute("9:05") == 9 * 60 + 5
      assert Ausdruck.tagesminute("0:00") == 0
    end
  end

  describe "halbtag_minute/1 — die Wortform ist der Normalfall" do
    test "die DREI echten Anker der Referenzsitzung" do
      # dave hat die handgelesene Referenzliste ausgezählt (19.09.2026): Alle
      # drei echten Spielwelt-Uhrzeit-Anker aus S3 sind Wortform, keiner
      # ziffernförmig. Der erste Wurf dieses Moduls löste genau sie nicht auf.
      assert Ausdruck.halbtag_minute("Drei viertel elf") == 10 * 60 + 45
      assert Ausdruck.halbtag_minute("kurz nach zwölf") == 5
      assert Ausdruck.halbtag_minute("Es ist kurz vor zwei") == 60 + 50
    end

    test "die übrigen Formen der geschlossenen Liste" do
      assert Ausdruck.halbtag_minute("halb elf") == 10 * 60 + 30
      assert Ausdruck.halbtag_minute("viertel nach zehn") == 10 * 60 + 15
      assert Ausdruck.halbtag_minute("viertel vor zwölf") == 11 * 60 + 45
      assert Ausdruck.halbtag_minute("gegen acht Uhr") == 8 * 60
      assert Ausdruck.halbtag_minute("zehn Uhr") == 10 * 60
    end

    test "das längere Muster schlägt das kürzere — sonst eine halbe Stunde daneben" do
      # Stünde das kürzere Muster vorn, läse es aus „drei viertel elf" die
      # Form „viertel elf" (10:15 statt 10:45). Still und um 30 Minuten
      # falsch.
      assert Ausdruck.halbtag_minute("drei viertel elf") == 10 * 60 + 45
      assert Ausdruck.halbtag_minute("viertel elf") == 10 * 60 + 15
    end

    test "die Halbtagsminute bleibt im 12-Stunden-Raum" do
      for w <- ["kurz nach zwölf", "halb eins", "viertel vor eins", "zwölf Uhr"] do
        assert Ausdruck.halbtag_minute(w) in 0..719, w
      end
    end

    test "eine ziffernförmige Uhrzeit ist hier nichts — sie ist schon eindeutig" do
      assert Ausdruck.halbtag_minute("22:45") == nil
      assert Ausdruck.halbtag_minute("22 Uhr 45") == nil
    end

    test "das Rauschen der echten Sitzung wird nicht getroffen" do
      # daves Befundliste: Nuyen-Beträge, Seitenzahlen, Modifikatoren,
      # Entfernungen, Schadenswerte. Eine Zahl ist keine Zeit.
      for w <- ["2000 jeder", "Seite 42", "um eins erhöht", "5 bis 50 Meter", "um sechs K"] do
        assert Ausdruck.halbtag_minute(w) == nil, w
        assert Ausdruck.tagesminute(w) == nil, w
      end
    end
  end

  describe "Modifikator vor einer ZIFFER — die echten Anker aus S4" do
    test "der Modifikator bleibt erhalten: 18:50, nicht 19:00" do
      # Die nackte Ziffernform allein las daraus „19 Uhr" und verlor den
      # Modifikator. Zwei Blöcke später steht die glatte Zeit — die beiden
      # dürfen nicht auf denselben Punkt fallen, sonst verschwindet die
      # Anfahrt (dave, 19.09.2026).
      assert Ausdruck.tagesminute("kommt ihr kurz vor 19 Uhr dort an") == 18 * 60 + 50
      assert Ausdruck.tagesminute("Also um 19 Uhr Beginn") == 19 * 60
    end

    test "die übrigen ziffernförmigen Anker aus S4" do
      assert Ausdruck.tagesminute("fahren um 12:30 Uhr los") == 12 * 60 + 30
      assert Ausdruck.tagesminute("um 14:30 oder 15 Uhr an") == 14 * 60 + 30
    end

    test "die Ziffernform gilt im 24-Stunden-Raum, nicht im Halbtag" do
      assert Ausdruck.tagesminute("halb 19 Uhr") == 18 * 60 + 30
      assert Ausdruck.halbtag_minute("kurz vor 19 Uhr") == nil
    end

    test "gegen und um brauchen das Wort Uhr — sie sind sonst zu häufig" do
      # Die Falsch-Positiven aus S2, das Rauschen dieser Sitzung.
      for w <- [
            "um eins reduzieren",
            "um zwei Haupthandlungen",
            "um Drei von vier Spielern",
            "gegen 5 Grad"
          ] do
        assert Ausdruck.tagesminute(w) == nil, w
        assert Ausdruck.halbtag_minute(w) == nil, w
      end
    end

    test "die Runde rechnet selbst um — und die Ziffernform gewinnt" do
      # Block 1203: „Drei Viertel neun ist kurz vor neun, also 20:45 Uhr wäre
      # die richtige Uhrzeit." Ein Beleg aus dem Material, dass abends die
      # Nachmittagslesart gilt — und eine Probe auf die Musterreihenfolge an
      # einem echten Satz statt an einem konstruierten.
      satz = "Drei Viertel neun ist kurz vor neun, also 20:45 Uhr wäre die richtige Uhrzeit."
      assert Ausdruck.tagesminute(satz) == 20 * 60 + 45

      # Dieselbe Uhrzeit, nur als Wortform gesagt: derselbe Punkt im
      # Nachmittagsraum.
      hm = Ausdruck.halbtag_minute("Drei Viertel neun")
      assert Ausdruck.mit_halbtag(hm, "nachmittag") == 20 * 60 + 45
    end
  end

  describe "mit_halbtag/2 — wenn Jack ihn doch weiß" do
    test "vormittag und nachmittag machen die Wortform eindeutig" do
      hm = Ausdruck.halbtag_minute("drei viertel elf")

      assert Ausdruck.mit_halbtag(hm, "vormittag") == 10 * 60 + 45
      assert Ausdruck.mit_halbtag(hm, "nachmittag") == 22 * 60 + 45
    end

    test "unklar, leer und Unbekanntes lassen sie der Kette" do
      hm = Ausdruck.halbtag_minute("drei viertel elf")

      assert Ausdruck.mit_halbtag(hm, "unklar") == nil
      assert Ausdruck.mit_halbtag(hm, nil) == nil
      assert Ausdruck.mit_halbtag(hm, "abends") == nil
    end
  end

  describe "was bewusst KEINE Uhrzeit ist" do
    test "ein Datum wird nicht als Uhrzeit gelesen" do
      # Der Punkt als Trenner ist deshalb nicht erlaubt: „15.11." sähe sonst
      # aus wie 15:11.
      assert Ausdruck.tagesminute("15.11.2080") == nil
      assert Ausdruck.tagesminute("am 15. November") == nil
    end

    test "unmögliche Werte ergeben nichts" do
      assert Ausdruck.tagesminute("25:99") == nil
      assert Ausdruck.tagesminute("") == nil
      assert Ausdruck.tagesminute(nil) == nil
    end
  end

  describe "aufloesen/2" do
    test "ein Datum wird zur absoluten Minute, eine Uhrzeit zur Tagesminute" do
      datum = Ausdruck.aufloesen(%{art: :zeitpunkt, wert: "15.11.2080"}, cal())
      uhr = Ausdruck.aufloesen(%{art: :zeitpunkt, wert: "22:45"}, cal())

      assert is_integer(datum.minute)
      assert rem(datum.minute, 1440) == 0, "ein Datum beginnt um Mitternacht"

      refute Map.has_key?(uhr, :minute)
      assert uhr.tagesminute == 22 * 60 + 45
    end

    test "eine Wortform bekommt die Halbtagsminute, keine Tagesminute" do
      a = Ausdruck.aufloesen(%{art: :zeitpunkt, wert: "Drei viertel elf"}, cal())

      assert a.halbtag_minute == 10 * 60 + 45
      refute Map.has_key?(a, :tagesminute)
    end

    test "mit genanntem Halbtag wird daraus sofort eine Tagesminute" do
      a =
        Ausdruck.aufloesen(
          %{art: :zeitpunkt, wert: "Drei viertel elf", halbtag: "nachmittag"},
          cal()
        )

      assert a.tagesminute == 22 * 60 + 45
      refute Map.has_key?(a, :halbtag_minute)
    end

    test "eine Spanne bekommt ihre Dauer in Minuten" do
      a = Ausdruck.aufloesen(%{art: :spanne, wert: "zwei Stunden lang"}, cal())
      assert a.minuten == 120
    end

    test "ein unlesbarer Ausdruck bekommt keine Zahl — und bleibt stehen" do
      a = Ausdruck.aufloesen(%{art: :zeitpunkt, wert: "irgendwann später"}, cal())

      refute Map.has_key?(a, :minute)
      refute Map.has_key?(a, :tagesminute)
      assert a.wert == "irgendwann später"
    end
  end
end
