defmodule HubWeb.CampaignLive.GlattFensterTest do
  @moduledoc """
  Issue #1153 (C6): die Hub-Seite des Text-Fensters aus #1152.

  Festgenagelt sind genau die Eigenschaften, deren stilles Versagen die Spalte
  kaputtmachte, ohne einen Fehler zu erzeugen:

  - Ein Block mit `text: nil` ist **betextet** — sonst wird er endlos
    nachgefordert (ein Ereignis pro Re-Render).
  - Bereits geladene Texte werden **nicht erneut** angefordert — sonst füllt
    jeder Tastendruck im Kurations-Feld die #1149-Schlange mit Wiederholungen.
  - Der Anker zählt auf der **gefilterten** Liste — eine Zahl aus der
    ungefilterten verspräche Blöcke, die der aktive Filter nicht zeigt (#883).
  - Ein alter Worker (jeder Block trägt Text) führt zu **null** Anforderungen.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.GlattFenster, as: GF

  defp skelett(id), do: %{"block_id" => id, "hat_luecke" => false, "status" => nil}
  defp voll(id, text \\ "Text"), do: Map.put(skelett(id), "text", text)

  describe "betextet?/1 — die Anwesenheit des Schlüssels entscheidet" do
    test "ein Block mit Text ist betextet" do
      assert GF.betextet?(voll("b1"))
    end

    test "ein Block OHNE den Schlüssel ist unbetextet" do
      refute GF.betextet?(skelett("b1"))
    end

    test "text: nil zählt als BETEXTET — sonst wird er endlos nachgefordert" do
      assert GF.betextet?(Map.put(skelett("b1"), "text", nil))
    end
  end

  describe "ein Block ohne hat_luecke bringt nichts zum Absturz (#710-Klasse)" do
    test "glatt_curatable_count zählt ihn als KEINE Lücke, statt zu werfen" do
      # `nil and ...` wirft BadBooleanError statt falsch zu sein. Fünf Stellen
      # hatten dieses Muster; aufgefallen, als der C6-Nachladepfad
      # `glatt_view_for` erstmals ausserhalb des Templates aufrief.
      sm = %{"session_id" => "s1", "blocks" => [%{"block_id" => "b1"}]}

      assert HubWeb.CampaignLive.Components.glatt_curatable_count(sm) == 0
    end

    test "glatt_blocks(kuratieren) filtert ihn heraus, statt zu werfen" do
      sm = %{"session_id" => "s1", "blocks" => [%{"block_id" => "b1"}]}

      assert HubWeb.CampaignLive.Components.glatt_blocks(sm, "kuratieren") == []
    end

    test "glatt_view_for fällt auf einfach zurück, statt zu werfen" do
      sm = %{"session_id" => "s1", "blocks" => [%{"block_id" => "b1"}]}

      assert HubWeb.CampaignLive.Components.glatt_view_for(%{}, sm) == "einfach"
    end
  end

  describe "fehlende_ids/2" do
    test "nennt nur die sichtbaren Blöcke ohne Text" do
      assert GF.fehlende_ids([voll("b1"), skelett("b2"), skelett("b3")], %{}) == ["b2", "b3"]
    end

    test "fordert bereits Geladenes NICHT erneut an" do
      assert GF.fehlende_ids([skelett("b1"), skelett("b2")], %{"b1" => %{"text" => "da"}}) ==
               ["b2"]
    end

    test "alter Worker: jeder Block trägt Text — nichts anzufordern" do
      assert GF.fehlende_ids([voll("b1"), voll("b2")], %{}) == []
    end

    test "leere Ansicht fordert nichts an" do
      assert GF.fehlende_ids([], %{}) == []
    end

    test "keine Dubletten" do
      assert GF.fehlende_ids([skelett("b1"), skelett("b1")], %{}) == ["b1"]
    end
  end

  describe "unbetextet_zahl/2 — der Anker aus #883" do
    test "zählt die unbetexteten der übergebenen (gefilterten) Liste" do
      assert GF.unbetextet_zahl([voll("b1"), skelett("b2"), skelett("b3")], %{}) == 2
    end

    test "alles betextet ergibt 0 — der Anker verschwindet" do
      assert GF.unbetextet_zahl([voll("b1"), voll("b2")], %{}) == 0
    end

    test "ein nachgeladener Block zaehlt NICHT mehr als unbetextet (dave, Fund 1)" do
      # Der Kern des Fundes: nachgeladene Texte liegen in `glatt_texte`, NIE im
      # Skelett. Zaehlte der Anker nur `betextet?/1` auf der Rohliste, bliebe die
      # Zahl nach jedem erfolgreichen Nachladen stehen und der Anker verschwaende
      # nie — an seattleV4 S3 gemessen "426 noch ohne Text", auch wenn alles da ist.
      geladen = %{"b2" => %{"text" => "nachgeladen"}}

      assert GF.unbetextet_zahl([voll("b1"), skelett("b2"), skelett("b3")], geladen) == 1
    end

    test "alles nachgeladen ergibt 0 — der Anker verschwindet wirklich" do
      geladen = %{"b1" => %{"text" => "x"}, "b2" => %{"text" => "y"}}

      assert GF.unbetextet_zahl([skelett("b1"), skelett("b2")], geladen) == 0
    end

    test "eine quittierte, aber unbeantwortete ID zaehlt nicht mehr mit" do
      # Sonst zeigte der Anker dauerhaft einen Rest an, den niemand je holen kann.
      geladen = GF.quittiere(%{}, ["b1"], %{})

      assert GF.unbetextet_zahl([skelett("b1")], geladen) == 0
    end
  end

  describe "quittiere/3 — der Abbruch der Nachlade-Kette (dave, Fund 3)" do
    test "gelieferte Texte kommen an, unbeantwortete werden als %{} vermerkt" do
      ergebnis = GF.quittiere(%{}, ["b1", "b2"], %{"b1" => %{"text" => "da"}})

      assert ergebnis["b1"] == %{"text" => "da"}
      assert ergebnis["b2"] == %{}
    end

    test "eine unbeantwortete ID wird NICHT erneut angefordert" do
      # Ohne das dreht die Kette endlos, sobald der Worker eine ID nicht kennt
      # (z.B. nach einem Re-Smoothing mit neuen Block-IDs).
      geladen = GF.quittiere(%{}, ["b1"], %{})

      assert GF.fehlende_ids([skelett("b1")], geladen) == []
    end

    test "der %{}-Vermerk aendert den Block nicht" do
      geladen = GF.quittiere(%{}, ["b1"], %{})
      block = skelett("b1")

      assert GF.mit_text(block, geladen) == block
      refute GF.betextet?(GF.mit_text(block, geladen))
    end

    test "Bestand bleibt erhalten, geliefert gewinnt gegen den Vermerk" do
      bestand = %{"alt" => %{"text" => "bleibt"}}
      ergebnis = GF.quittiere(bestand, ["b1"], %{"b1" => %{"text" => "neu"}})

      assert ergebnis["alt"] == %{"text" => "bleibt"}
      assert ergebnis["b1"] == %{"text" => "neu"}
    end
  end

  describe "die Nachlade-Kette terminiert (dave, Fund 3)" do
    test "jede Runde verkleinert die fehlende Menge ECHT — bis sie leer ist" do
      # Der Beweis, dass die Kette in `apply_ergebnis/2` endet: mit Deckel 2 auf
      # 3 fehlenden Bloecken sind es 2, dann 1, dann 0 — nie ein Stillstand.
      smoothed = [
        %{"session_id" => "s1", "blocks" => [skelett("b1"), skelett("b2"), skelett("b3")]}
      ]

      runde = fn geladen -> GF.fehlende_aus_ansicht(smoothed, %{}, %{}, geladen, 2) end
      # Der Worker antwortet auf ALLES; Deckel 2 heisst zwei Runden plus Leerlauf.
      antwort = fn ids -> Map.new(ids, &{&1, %{"text" => "t"}}) end

      r1 = runde.(%{})
      assert length(r1) == 2

      g1 = GF.quittiere(%{}, r1, antwort.(r1))
      r2 = runde.(g1)
      assert length(r2) == 1

      g2 = GF.quittiere(g1, r2, antwort.(r2))
      assert runde.(g2) == []
    end

    test "auch wenn der Worker NICHTS liefert, endet die Kette" do
      # Der gefaehrliche Fall: eine ID, die der Worker nicht kennt (neue
      # Block-IDs nach einem Re-Smoothing). Ohne Quittung waere das eine
      # Endlosschleife, die laeuft, solange die Seite offen ist.
      smoothed = [%{"session_id" => "s1", "blocks" => [skelett("b1"), skelett("b2")]}]
      runde = fn geladen -> GF.fehlende_aus_ansicht(smoothed, %{}, %{}, geladen, 5) end

      r1 = runde.(%{})
      assert length(r1) == 2

      assert runde.(GF.quittiere(%{}, r1, %{})) == []
    end
  end

  describe "mit_text/2 — die eine Stelle, an der beide zusammenkommen" do
    test "reichert einen Skelett-Block an" do
      b = GF.mit_text(skelett("b1"), %{"b1" => %{"text" => "geladen", "roh_text" => "roh"}})

      assert b["text"] == "geladen"
      assert b["roh_text"] == "roh"
      assert b["block_id"] == "b1"
    end

    test "ein vorhandener Text wird NICHT überschrieben" do
      assert GF.mit_text(voll("b1", "original"), %{"b1" => %{"text" => "neu"}})["text"] ==
               "original"
    end

    test "ohne passenden Eintrag bleibt der Block unverändert" do
      assert GF.mit_text(skelett("b1"), %{"b9" => %{"text" => "x"}}) == skelett("b1")
    end

    test "Skelett-Felder überleben das Anreichern" do
      skel = %{"block_id" => "b1", "hat_luecke" => true, "status" => "bestaetigt"}
      b = GF.mit_text(skel, %{"b1" => %{"text" => "t"}})

      assert b["hat_luecke"] == true
      assert b["status"] == "bestaetigt"
    end
  end

  describe "merge_texte/2" do
    test "neue Texte gewinnen bei gleicher ID" do
      merged = GF.merge_texte(%{"b1" => %{"text" => "alt"}}, %{"b1" => %{"text" => "neu"}})

      assert merged["b1"]["text"] == "neu"
    end

    test "eine kaputte Antwort lässt den Bestand stehen" do
      alt = %{"b1" => %{"text" => "alt"}}

      assert GF.merge_texte(alt, nil) == alt
      assert GF.merge_texte(alt, "quatsch") == alt
    end
  end
end
