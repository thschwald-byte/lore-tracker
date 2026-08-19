defmodule Worker.Recording.PipelineZeitGroundingTest do
  @moduledoc """
  Issue #1068 (E4): Feld-Grounding der Zeitangabe.

  Die Fälle sind an den 13 Fakten mit Datum aus `free-seattle-bereinigt`
  kalibriert (worker_prod, 2026-08-19) — dort standen **9 von 13 nicht
  wörtlich** im Quelltext.
  """
  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.Parsing

  defp block(id, text), do: %{id: id, text: text, discord_id: "d", quell_utterance_ids: [id]}

  defp grounde(datum, refs, bloecke) do
    Parsing.grounde_zeitangabe(
      %{"in_game_date" => datum, "source_refs" => refs},
      bloecke
    )
  end

  describe "die drei Stufen" do
    test "wörtlich — der Ausdruck steht so im Text" do
      b = [block("b1", "Wir haben von 2055 bis 2065 gespielt, damals als Schüler.")]
      f = grounde("2055 bis 2065", ["b1"], b)
      assert f["zeit_beleg"] == "woertlich"
      assert f["zeit_beleg_ref"] == true
    end

    test "normalisiert — nur Interpunktion trennt" do
      # Der reale Fall: im Transkript steht „24. Dezember. 2011" (ASR-Punkt),
      # das Modell schrieb „24. Dezember 2011".
      b = [block("b1", "Alles am 24. Dezember. 2011, in Japan, der erste Drache.")]
      f = grounde("24. Dezember 2011", ["b1"], b)
      assert f["zeit_beleg"] == "normalisiert"
    end

    test "abgeleitet — das Modell hat gerechnet" do
      # Der häufigste reale Fall: aus „in den frühen 2000ern" wurde „1.1.2010".
      b = [block("b1", "In den frühen 2000ern tötet die Vitas-Plage Millionen.")]
      f = grounde("1.1.2010", ["b1"], b)
      assert f["zeit_beleg"] == "abgeleitet"
      assert f["zeit_beleg_ref"] == false
    end

    test "die Entinterpunktierung darf Zahlen nicht verschmelzen" do
      # „1.1.2010" wird zu „1 1 2010" — das darf NICHT auf einen Text
      # zutreffen, der bloss irgendwo eine 2010 enthält.
      b = [block("b1", "Im Jahr 2010 war das noch anders.")]
      assert grounde("1.1.2010", ["b1"], b)["zeit_beleg"] == "abgeleitet"
    end
  end

  describe "Chunk gegen zitierte Blöcke — zwei verschiedene Fehler" do
    test "im Chunk, aber nicht in den Refs → Attributionsfehler" do
      bloecke = [
        block("b1", "Der Angriff beginnt."),
        block("b2", "Das war im Herbst 2040.")
      ]

      # Der Fakt zitiert b1, der Ausdruck steht aber in b2.
      f = grounde("Herbst 2040", ["b1"], bloecke)
      assert f["zeit_beleg"] == "woertlich", "nicht erfunden — steht im Chunk"
      assert f["zeit_beleg_ref"] == false, "aber falsch zugeordnet"
    end

    test "in beiden → sauber" do
      bloecke = [block("b1", "Das war im Herbst 2040."), block("b2", "Egal.")]
      f = grounde("Herbst 2040", ["b1"], bloecke)
      assert f["zeit_beleg"] == "woertlich"
      assert f["zeit_beleg_ref"] == true
    end

    test "in keinem von beiden → erfunden oder gerechnet" do
      bloecke = [block("b1", "Der Angriff beginnt."), block("b2", "Nichts Zeitliches.")]
      f = grounde("Herbst 2040", ["b1"], bloecke)
      assert f["zeit_beleg"] == "abgeleitet"
      assert f["zeit_beleg_ref"] == false
    end
  end

  describe "Randfälle" do
    test "ohne Datum kein Beleg-Feld" do
      b = [block("b1", "irgendwas")]

      for datum <- [nil, "", "   "] do
        f = Parsing.grounde_zeitangabe(%{"in_game_date" => datum, "source_refs" => []}, b)
        refute Map.has_key?(f, "zeit_beleg"), "#{inspect(datum)} braucht kein Beleg-Feld"
      end
    end

    test "leerer Chunk" do
      assert grounde("2070", ["b1"], [])["zeit_beleg"] == "abgeleitet"
    end

    test "Fakt ohne source_refs — Chunk zählt trotzdem" do
      b = [block("b1", "Das war 2070.")]
      f = grounde("2070", [], b)
      assert f["zeit_beleg"] == "woertlich", "im Chunk belegt"
      assert f["zeit_beleg_ref"] == false, "aber keine Quelle zugeordnet"
    end
  end

  describe "Ende-zu-Ende durch parse_facts_json" do
    test "das Grounding läuft im echten Parse-Pfad" do
      utts = [
        %{id: "u1", text: "Die Plage kam in den frühen 2000ern.", discord_id: "d"},
        %{id: "u2", text: "Genau, ab 2000 änderte sich alles.", discord_id: "d"}
      ]

      roh =
        Jason.encode!(%{
          "facts" => [
            %{"claim" => "Die Plage kam", "in_game_date" => "1.1.2010", "source_refs" => ["u1"]},
            %{"claim" => "Umbruch beginnt", "in_game_date" => "ab 2000", "source_refs" => ["u2"]}
          ]
        })

      {:ok, fakten} = Parsing.parse_facts_json(roh, utts)
      belege = Map.new(fakten, &{&1["claim"], &1["zeit_beleg"]})

      # Gerechnet → abgeleitet. Abgeschrieben → wörtlich. Genau die
      # Unterscheidung, um die es in #1068 geht.
      assert belege["Die Plage kam"] == "abgeleitet"
      assert belege["Umbruch beginnt"] == "woertlich"
    end
  end
end
