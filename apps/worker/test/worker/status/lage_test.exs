defmodule Worker.Status.LageTest do
  @moduledoc """
  Issue #1218: die Ableitung der Statusmap. Pur, also ohne Prozesse und ohne
  Socket — hier liegt die ganze Logik, die eine Anzeige falsch leuchten lassen
  könnte.
  """
  use ExUnit.Case, async: true

  alias Shared.PipelineStufen
  alias Worker.Status.Lage

  # Ein Lauf in der Form, die `Fortschritt.serialisiere/1` liefert.
  defp lauf(stufen_status, opts \\ []) do
    stufen =
      Enum.map(PipelineStufen.alle(), fn stufe ->
        %{
          "name" => stufe.name,
          "titel" => stufe.titel,
          "spalte" => stufe.spalte,
          "status" => Map.get(stufen_status, stufe.name, "offen"),
          "fertig" => Keyword.get(opts, :fertig, 0),
          "gesamt" => Keyword.get(opts, :gesamt),
          "durchgang" => nil,
          "dauer_ms" => nil
        }
      end)

    %{
      "aktiv" => Keyword.get(opts, :aktiv, true),
      "run_id" => "r1",
      "session_id" => "s1",
      "campaign_id" => "c1",
      "gestartet_vor_ms" => 1000,
      "still_seit_ms" => Keyword.get(opts, :still_seit_ms, 0),
      "stufen" => stufen
    }
  end

  defp gruppe(lage, spalte), do: Enum.find(lage["gruppen"], &(&1["spalte"] == spalte))

  describe "ohne Lauf" do
    test "bleibt die Anzeige leer statt zu raten" do
      lage = Lage.baue([], false)

      assert lage["aufnahme"] == false
      assert lage["lauf"] == nil
      assert lage["teilnehmer"] == []
      assert Enum.all?(lage["gruppen"], &(&1["zustand"] == "offen"))
    end

    test "und die Gruppen stehen trotzdem alle da, in Laufreihenfolge" do
      spalten = Lage.baue([], false)["gruppen"] |> Enum.map(& &1["spalte"])
      assert spalten == ["glatt", "fakten", "summaries", "chronik", "epos", "boegen"]
    end
  end

  describe "Gruppenzustand" do
    test "läuft, sobald eine ihrer Stufen läuft" do
      lage = Lage.baue([lauf(%{"extract" => "laeuft"})], true)

      assert gruppe(lage, "fakten")["zustand"] == "laeuft"
      assert gruppe(lage, "glatt")["zustand"] == "offen"
      assert lage["aufnahme"] == true
    end

    test "fertig erst, wenn alle Stufen der Gruppe fertig sind" do
      teil = Lage.baue([lauf(%{"jack_gedaechtnis" => "fertig"})], false)
      assert gruppe(teil, "fakten")["zustand"] == "offen"

      ganz =
        Lage.baue(
          [
            lauf(%{
              "jack_gedaechtnis" => "fertig",
              "extract" => "fertig",
              "jack_verifikation" => "fertig"
            })
          ],
          false
        )

      assert gruppe(ganz, "fakten")["zustand"] == "fertig"
    end

    test "unterscheidet gescheiterte Pflicht von gescheiterter Zugabe" do
      pflicht = Lage.baue([lauf(%{"extract" => "fehler"})], false)
      assert gruppe(pflicht, "fakten")["zustand"] == "fehler"

      zugabe = Lage.baue([lauf(%{"jack_verifikation" => "fehler"})], false)
      assert gruppe(zugabe, "fakten")["zustand"] == "zugabe_fehler"
    end

    test "eine laufende Stufe schlägt eine gescheiterte Zugabe derselben Gruppe" do
      lage = Lage.baue([lauf(%{"jack_verifikation" => "fehler", "extract" => "laeuft"})], false)
      assert gruppe(lage, "fakten")["zustand"] == "laeuft"
    end
  end

  describe "Zustand des Laufs" do
    test "läuft, solange sich etwas regt" do
      assert Lage.baue([lauf(%{"extract" => "laeuft"})], false)["lauf"]["zustand"] == "laeuft"
    end

    test "still, wenn lange nichts mehr kam — nicht läuft" do
      # Der Fall, der eine Anzeige schon einmal einen toten Lauf als aktiv
      # zeigen ließ.
      l = lauf(%{"extract" => "laeuft"}, still_seit_ms: PipelineStufen.still_ms() + 1)
      assert Lage.baue([l], false)["lauf"]["zustand"] == "still"
    end

    test "fertig, wenn der Lauf nicht mehr aktiv ist" do
      l = lauf(%{"render_arc_progressions" => "fertig"}, aktiv: false)
      assert Lage.baue([l], false)["lauf"]["zustand"] == "fertig"
    end

    test "fehler, sobald eine Pflichtstufe gescheitert ist" do
      l = lauf(%{"extract" => "fehler"}, aktiv: false)
      assert Lage.baue([l], false)["lauf"]["zustand"] == "fehler"
    end

    test "ein aktiver Lauf schlägt einen älteren abgeschlossenen" do
      alt = lauf(%{"render_arc_progressions" => "fertig"}, aktiv: false)
      neu = lauf(%{"smooth" => "laeuft"})

      assert Lage.baue([alt, neu], false)["lauf"]["zustand"] == "laeuft"
    end
  end

  describe "Zahlen" do
    test "reisen mit, wo die Stufe zählbar ist und ihre Gesamtzahl kennt" do
      l = lauf(%{"extract" => "laeuft"}, fertig: 4, gesamt: 7)
      lauf_map = Lage.baue([l], false)["lauf"]

      assert lauf_map["stufe"] == "extract"
      assert lauf_map["erledigt"] == 4
      assert lauf_map["gesamt"] == 7
    end

    test "fehlen, solange die Gesamtzahl unbekannt ist — kein „3 von ?“" do
      l = lauf(%{"extract" => "laeuft"}, fertig: 3, gesamt: nil)
      lauf_map = Lage.baue([l], false)["lauf"]

      refute Map.has_key?(lauf_map, "erledigt")
      refute Map.has_key?(lauf_map, "gesamt")
    end

    test "fehlen bei Stufen ohne zählbare Einheit — kein erfundenes 1/1" do
      l = lauf(%{"render" => "laeuft"}, fertig: 0, gesamt: nil)
      assert Lage.baue([l], false)["lauf"]["stufe"] == "render"
      refute Map.has_key?(Lage.baue([l], false)["lauf"], "gesamt")
    end
  end
end
