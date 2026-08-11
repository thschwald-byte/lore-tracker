defmodule Worker.Recording.ConsentPhraseTest do
  @moduledoc """
  Issue #1002: die gesprochene Einwilligung. Der wichtigste Test hier ist der
  **Negations-Test** — er pinnt genau den Fehler, an dem die bestehende
  Mikro-Setup-Funktion scheitern würde (Bag-of-Words: „ich stimme der Aufnahme
  NICHT zu" enthält alle erwarteten Wörter → 100 % Match → Ablehnung als
  Zustimmung gezählt).

  Leitregel, die hier festgenagelt wird: nur `:granted` erlaubt Aufzeichnung;
  ein falsches `:granted` zeichnet jemanden gegen seinen Willen auf, ein
  falsches `:unclear` kostet nur einen zweiten Versuch.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.ConsentPhrase

  describe "Zustimmung wird erkannt" do
    test "der kanonische Satz" do
      assert ConsentPhrase.evaluate("Ich stimme der Aufnahme zu.") == :granted
    end

    test "unabhängig von Groß/Kleinschreibung und Satzzeichen" do
      assert ConsentPhrase.evaluate("ICH STIMME DER AUFNAHME ZU!!!") == :granted
      assert ConsentPhrase.evaluate("ich stimme der aufnahme zu") == :granted
    end

    test "mit ASR-typischem Vor-/Nachgeplapper" do
      assert ConsentPhrase.evaluate("Ähm, also, ich stimme der Aufnahme zu, okay?") == :granted
    end

    test "Variante Aufzeichnung statt Aufnahme" do
      assert ConsentPhrase.evaluate("Ich stimme der Aufzeichnung zu.") == :granted
    end

    test "Variante einverstanden" do
      assert ConsentPhrase.evaluate("Ich bin mit der Aufnahme einverstanden.") == :granted
      assert ConsentPhrase.evaluate("Mit der Aufzeichnung einverstanden.") == :granted
    end
  end

  describe "Negations-Veto — der Kern-Sicherheitstest (#1002)" do
    test "„nicht\" kippt die Zustimmung, obwohl ALLE Zustimmungswörter da sind" do
      # Bag-of-Words würde hier 100 % Match liefern. Muss :declined sein.
      assert ConsentPhrase.evaluate("Ich stimme der Aufnahme nicht zu.") == :declined
    end

    test "weitere Ablehnungsformen" do
      for text <- [
            "Ich stimme der Aufnahme keinesfalls zu.",
            "Nein, ich stimme der Aufnahme zu... nein.",
            "Ich bin mit der Aufnahme nicht einverstanden.",
            "Ich widerspreche der Aufnahme.",
            "Ich widerrufe meine Zustimmung zur Aufnahme.",
            "Ich untersage die Aufnahme.",
            "Ich lehne die Aufnahme ab.",
            "Ich stimme der Aufnahme niemals zu."
          ] do
        assert ConsentPhrase.evaluate(text) == :declined, "nicht als Ablehnung erkannt: #{text}"
      end
    end

    test "Stamm-Match fängt Flexions- und Verstärkungsformen (die exakte Liste tat es nicht)" do
      # „keinesfalls\" fiel beim ersten Entwurf durch, weil nur kein/keine/keinen
      # gelistet waren — deshalb Präfix-Stämme.
      for text <- [
            "Ich stimme der Aufnahme keineswegs zu.",
            "Ich verweigere die Aufnahme.",
            "Ich bin dagegen, dass die Aufnahme läuft.",
            "Die Aufnahme ist mir nichts recht.",
            "Ohne meine Zustimmung keine Aufnahme."
          ] do
        assert ConsentPhrase.evaluate(text) == :declined, "nicht vetoet: #{text}"
      end
    end

    test "übervorsichtig: Negationswort ohne Bezug zur Zustimmung vetoert auch" do
      # Absicht, nicht Versehen: lieber ein zweiter Versuch als eine
      # Aufzeichnung gegen den Willen. Dokumentiert im Moduledoc.
      assert ConsentPhrase.evaluate("Ich stimme der Aufnahme zu, kein Problem.") == :declined
    end
  end

  describe "unklar (fail-closed)" do
    test "Schweigen / leeres Transkript" do
      assert ConsentPhrase.evaluate("") == :unclear
      assert ConsentPhrase.evaluate("   ") == :unclear
      assert ConsentPhrase.evaluate(nil) == :unclear
    end

    test "beliebiges Spielgeplauder ist keine Zustimmung" do
      assert ConsentPhrase.evaluate("Ich greife den Orkhäuptling mit dem Schwert an.") == :unclear
      assert ConsentPhrase.evaluate("Moment, mein Mikro spinnt.") == :unclear
    end

    test "halbe Formulierung genügt nicht" do
      assert ConsentPhrase.evaluate("Ich stimme zu.") == :unclear
      assert ConsentPhrase.evaluate("Aufnahme.") == :unclear
      assert ConsentPhrase.evaluate("Ja.") == :unclear
    end

    test "das Wort Zustimmung allein genügt nicht" do
      assert ConsentPhrase.evaluate("Zustimmung") == :unclear
    end

    test "nicht-Binaries" do
      assert ConsentPhrase.evaluate(42) == :unclear
      assert ConsentPhrase.evaluate(%{}) == :unclear
    end
  end

  describe "version/0" do
    test "hält das v<n>-Format, das das Lattice erwartet" do
      # `Worker.Materializer.version_rank/1` liefert für alles andere still 0 —
      # eine Version wie "1.0" oder "2026-08" würde damit lautlos jede
      # Versions-Prüfung aushebeln (Rang 0 ≥ Rang 0). Deshalb hier festgenagelt.
      version = ConsentPhrase.version()
      assert version =~ ~r/^v\d+$/, "Version muss v<n> sein, ist: #{inspect(version)}"
      assert Worker.Materializer.version_rank(version) > 0
    end
  end

  describe "granted?/1 — nur Zustimmung erlaubt Aufzeichnung" do
    test "granted ja, declined und unclear nein" do
      assert ConsentPhrase.granted?(:granted)
      refute ConsentPhrase.granted?(:declined)
      refute ConsentPhrase.granted?(:unclear)
    end

    test "jeder Nicht-granted-Wert ist fail-closed" do
      refute ConsentPhrase.granted?(nil)
      refute ConsentPhrase.granted?(:irgendwas)
    end
  end

  describe "canonical_phrase/0" do
    test "ist der Satz, um den gebeten wird — und wird selbst als Zustimmung erkannt" do
      phrase = ConsentPhrase.canonical_phrase()
      assert is_binary(phrase)
      assert ConsentPhrase.evaluate(phrase) == :granted
    end
  end

  describe "Gegenprobe zur Mikro-Setup-Toleranz" do
    # Die Bag-of-Words-Logik des Mikro-Setups hier nachgebaut (das Original lebt
    # im Hub, `HubWeb.CampaignLive.Mic.phrase_match?/2` — für den Worker nicht
    # erreichbar). Dokumentiert WARUM es zwei Funktionen gibt: wer die Consent-
    # Prüfung je auf die tolerante Variante umstellt, sieht diesen Test rot.
    defp bag_of_words_match?(expected, transcript, threshold \\ 0.6) do
      norm = fn t ->
        t |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ") |> String.split()
      end

      words = norm.(expected)
      set = MapSet.new(norm.(transcript))
      Enum.count(words, &MapSet.member?(set, &1)) / length(words) >= threshold
    end

    test "die tolerante Logik hält die Ablehnung für Zustimmung — evaluate/1 nicht" do
      ablehnung = "Ich stimme der Aufnahme nicht zu."

      assert bag_of_words_match?("Ich stimme der Aufnahme zu", ablehnung),
             "Vorbedingung: die tolerante Logik matcht hier (deshalb ist sie für Consent untauglich)"

      assert ConsentPhrase.evaluate(ablehnung) == :declined
    end
  end
end
