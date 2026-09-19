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

  describe "was bewusst KEINE Uhrzeit ist" do
    test "Wortformen bleiben ohne Zahl — sie sind zwölfdeutig" do
      # „drei viertel elf" ist 10:45 ODER 22:45. Welche gilt, steht nicht im
      # Ausdruck, sondern im Gespräch — das ist Jacks Urteil, nicht das eines
      # Regex. Ein geratenes AM/PM wäre ein Fehler von zwölf Stunden, der wie
      # ein Ergebnis aussieht.
      assert Ausdruck.tagesminute("drei viertel elf") == nil
      assert Ausdruck.tagesminute("halb zehn") == nil
      assert Ausdruck.tagesminute("kurz nach zwölf") == nil
    end

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
