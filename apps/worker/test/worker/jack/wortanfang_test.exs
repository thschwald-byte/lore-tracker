defmodule Worker.Jack.WortanfangTest do
  @moduledoc """
  Issue #1238: Jacks Suchwerkzeuge verglichen per Teilstring — auf Deutsch
  unbrauchbar. An der eingefrorenen S3-Referenz (1802 Blöcke echter Mitschnitt)
  gemessen lieferte „Gang" 16 Fundstellen, von denen **keine** das Wort enthielt
  (Eingang, Ausgang, gegangen, Eingangsportal); „Bar" 14 (Bargäste, furchtbar,
  bombardiert); „Ort" 28 mit einer echten.

  **Die Grenze steht nur am Wortanfang** (Entscheidung des Maintainers,
  18.09.2026) — Deutsch ist asymmetrisch: was vorn angehängt wird, ist fast
  immer ein anderes Wort, was hinten dranhängt, meist dasselbe. Eine beidseitige
  Grenze hätte bei „kamera" elf von 24 echten Treffern weggeworfen und „Wache"
  vom Plural „Wachen" getrennt.

  Geprüft wird hier die Regel selbst (`Worker.Jack.Beleg`) — die beiden
  Aufrufstellen erben sie, und die Werkzeug-Beschreibungen sagen sie an.
  """

  use ExUnit.Case, async: true

  alias Worker.Jack.Beleg

  defp findet?(text, begriff), do: Beleg.wort?(text, Beleg.wortmuster(begriff))

  describe "die Komposita-Falle, die den Defekt ausmachte" do
    test "ein Begriff mitten im Wort zählt nicht" do
      refute findet?("Sie kommen durch den Eingang.", "Gang")
      refute findet?("Wir sind rausgegangen.", "Gang")
      refute findet?("Am Eingangsportal steht eine Wache.", "Gang")
      refute findet?("Das ist furchtbar.", "Bar")
      refute findet?("Es liegt dort drüben.", "Ort")
      refute findet?("Das Haus wurde bombardiert.", "Bar")
    end

    test "dasselbe Wort wird gefunden" do
      assert findet?("Der Gang ist dunkel.", "Gang")
      assert findet?("Wir treffen uns in der Bar.", "Bar")
      assert findet?("Nenn mir den Ort.", "Ort")
    end
  end

  describe "die deutsche Flexion bleibt erhalten" do
    # Genau dafür steht die Grenze nur vorn: eine beidseitige hätte all das
    # verloren — an echten Daten elf von 24 Treffern bei „kamera".
    test "Plural, Genitiv und Komposita mit dem Begriff vorn" do
      assert findet?("Die Kameras laufen.", "Kamera")
      assert findet?("Wir sehen die Kamerafeeds.", "Kamera")
      assert findet?("Zwei Wachen stehen davor.", "Wache")
      assert findet?("Der Drohnenbetrieb ist eingestellt.", "Drohne")
      assert findet?("Er kauft Laternen.", "Laterne")
    end
  end

  describe "die benannte Grenze — homograf beginnende Wörter" do
    test "was die Regel NICHT fängt, steht so im Ticket" do
      # „heiß" findet weiterhin „heißt", „bar" weiterhin „Bargäste". Der Preis
      # ist bewusst gewählt; wer ihn wegnehmen will, braucht Lemmatisierung —
      # und die ist ausdrücklich nicht gewollt (#1109/#1213-Klasse).
      assert findet?("Wie heißt du?", "heiß")
      assert findet?("Die Bargäste drehen sich um.", "Bar")
    end
  end

  describe "Groß- und Kleinschreibung, Mehrwortbegriffe" do
    test "Schreibweise ist egal" do
      assert findet?("Der MONITOR piept.", "monitor")
      assert findet?("die freie stadt", "Freie Stadt")
    end

    test "Sonderzeichen im Begriff sind kein Muster" do
      # Regex.escape: ein Punkt bleibt ein Punkt.
      refute findet?("Der Gong schlägt.", "G.ng")
    end
  end

  describe "die Werkzeuge sagen ihre Regel an" do
    # Toms Vorgabe (18.09.): „das muss das Tool dann auch sagen — auch im
    # Help." Ein Werkzeug, dessen Semantik sich ändert, ohne dass seine
    # Beschreibung es sagt, lädt das Modell zum Raten ein.
    defp quelle(pfad) do
      Path.join([__DIR__, "..", "..", "..", pfad]) |> Path.expand() |> File.read!()
    end

    test "die Beschreibung von suche nennt die Wortanfangs-Regel mit Beispiel" do
      src = quelle("lib/worker/jack/lesen.ex")
      assert src =~ "ANFAENGT"
      assert src =~ "Kamera"
      assert src =~ "findet nicht"
    end

    test "die Beschreibung von suche_sitzung/suche_bisher ebenso" do
      src = quelle("lib/worker/jack/resuemee/suche.ex")
      assert src =~ "ANFÄNGT"
      assert src =~ "Kameras"

      refute src =~ "ein Wortteil genügt",
             "die alte Zusage steht noch in der Beschreibung — dann sucht Jack nach einer Regel, die es nicht mehr gibt"
    end
  end

  describe "der Rückfall sagt, was es sonst gäbe" do
    test "wortteile nennt nur Wörter, in denen der Begriff INNEN steckt" do
      text = "Der Eingang neben dem Gangwerk, wir sind rausgegangen."
      teile = Beleg.wortteile(text, "gang")

      assert "eingang" in teile
      assert "rausgegangen" in teile
      # „gangwerk" beginnt mit dem Begriff — das findet die Suche selbst.
      refute "gangwerk" in teile
    end

    test "ohne Vorkommen im Wortinneren ist die Liste leer" do
      assert Beleg.wortteile("Der Gang ist dunkel.", "gang") == []
    end
  end
end
