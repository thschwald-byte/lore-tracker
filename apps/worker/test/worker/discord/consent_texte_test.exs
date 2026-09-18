defmodule Worker.Discord.ConsentTexteTest do
  @moduledoc """
  Issue #1046: kein Text darf den abgeschafften Sprech-Pfad empfehlen.

  Die gesprochene Zustimmung ist seit **#1005** ausgesetzt — Akustik ist nicht
  identitätsgebunden (sagt A den Satz und B hat Lautsprecher statt Kopfhörer,
  landet A's Stimme in B's Spur, und die Erkennung machte daraus B's
  Einwilligung). Zugestimmt wird seitdem per Klick.

  Die Ansage wurde damals umgestellt, **eine Stelle blieb zurück**: der
  Fehlertext in `/admin/errors`, der dem Spielleiter riet, der Sprecher möge
  „den in der Ansage genannten Satz sprechen". Wer dem folgte, verlor die
  nächste Tonspur auch — und las es ausgerechnet dann, wenn schon eine
  verworfen worden war.

  Geprüft wird der Quelltext, nicht das Verhalten: Diese Texte laufen nur im
  Zusammenspiel mit einem verbundenen Discord-Bot, und der Defekt war nie ein
  Verhaltensfehler, sondern eine Formulierung, die niemand mehr gelesen hat.
  """
  use ExUnit.Case, async: true

  @sprech_pfad ~r/(Satz\s+(spricht|sagt|sprechen)|genannten\s+Satz)/i

  describe "Fehlermeldung bei fehlender Einwilligung" do
    setup do
      %{quelle: File.read!("lib/worker/discord/voice_errors.ex")}
    end

    test "empfiehlt nicht den ausgesetzten Sprech-Pfad", %{quelle: q} do
      refute Regex.match?(@sprech_pfad, q),
             "Ein Text rät wieder zum Sprechen — das wirkt seit #1005 nicht mehr (#1046)."
    end

    test "nennt den Weg, der wirkt", %{quelle: q} do
      # Ohne einen genannten Weg bliebe die Meldung eine Diagnose ohne Ausweg.
      assert q =~ "Knopf", "der Fehlertext muss sagen, wie zugestimmt wird"
    end

    test "verspricht nicht, dass verworfenes Audio zurückkommt", %{quelle: q} do
      # `ConsentState.keepable_frames/2` deckt nur Intervalle AB der
      # Zustimmung — die Einwilligung wirkt ausschliesslich nach vorn. Ein
      # Text, der anderes nahelegt, wäre eine falsche Zusage.
      assert q =~ "nicht zurück"
    end
  end

  describe "Knopf im Sprachkanal" do
    test "der angezeigte Text nennt den Klick, nicht das Sprechen" do
      text = Worker.Discord.ConsentButton.content("Testkampagne")

      refute Regex.match?(@sprech_pfad, text)
      assert text =~ "Klicke auf"
    end

    test "er sagt die Konsequenz des Nichtstuns" do
      # Ohne sie wäre die Einwilligung nicht informiert — der Grund, warum
      # dieser Satz überhaupt im Text steht.
      text = Worker.Discord.ConsentButton.content(nil)
      assert text =~ "nicht gespeichert"
    end

    test "er verspricht beim Widerruf keine Löschung" do
      # Ein Widerruf beendet die Aufzeichnung ab diesem Moment; bereits
      # Gespeichertes zu löschen wäre ein eigener Pfad, und „wird gelöscht"
      # wäre hier eine falsche Zusage (Art. 7 Abs. 3 DSGVO berührt die
      # bisherige Rechtmässigkeit nicht).
      text = Worker.Discord.ConsentButton.content(nil)
      assert text =~ "nicht gelöscht"
    end
  end
end
