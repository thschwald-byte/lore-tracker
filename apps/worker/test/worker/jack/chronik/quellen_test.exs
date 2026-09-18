defmodule Worker.Jack.Chronik.QuellenTest do
  @moduledoc """
  Ein Chronik-Eintrag muss seine Belegblöcke tragen (#1211).

  Sie standen bis zum 18.09.2026 leer — am echten Lauf gefunden, nicht im
  Test: der Eintrag kannte seine 47 Fakten, aber keine Quelle. Daran hängt
  die ganze Oberflächen-Anbindung der Chronik (🕳-Lückenmarker, Sprungmarke
  ins Protokoll, Scroll-Sync lösen alle über `source_refs` auf), und keiner
  dieser Wege wird rot, wenn die Liste leer ist — sie zeigen einfach nichts.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Pipeline

  # Die Fakt-Form der Lesebasis (`Resuemee.Eingabe`), auf das Nötige gekürzt.
  defp fakt(fakt_id, sitzung, refs),
    do: %{fakt_id: fakt_id, sitzung: sitzung, refs: refs, id: "S#{sitzung}-F1"}

  defp payloads(eintraege, fakten) do
    # `payloads/4` baut die Ereignisse, ohne sie zu publizieren — genau
    # deshalb ist es herausgezogen: über den Publish-Pfad wäre hier ein
    # laufender Materializer nötig, und was ein Eintrag TRÄGT, bliebe
    # ungeprüft.
    Pipeline.payloads(
      %{id: "s-2"},
      %{id: "c-1"},
      %{eintraege: eintraege, rangfolge: Enum.map(eintraege, & &1.id), trichter: %{}},
      fakten
    )
  end

  describe "payloads/4" do
    test "sammelt die Belegblöcke der Fakten eines Eintrags, ohne Dubletten" do
      fakten = [
        fakt("f_aa", 1, ["b_1", "b_2"]),
        fakt("f_bb", 1, ["b_2", "b_3"]),
        fakt("f_cc", 2, ["b_9"])
      ]

      eintrag = %{
        id: "chr-1",
        titel: "Eine Phase",
        text: "Text",
        wichtigkeit: "phase",
        fakt_ids: ["f_aa", "f_bb"],
        zeit_bezug: []
      }

      [p] = payloads([eintrag], fakten)

      # b_2 kommt aus zwei Fakten und steht trotzdem einmal da.
      assert Enum.sort(p["source_refs"]) == ["b_1", "b_2", "b_3"]
      refute "b_9" in p["source_refs"], "ein nicht genannter Fakt trägt nichts bei"
      assert p["sitzungen"] == [1]
    end

    test "nennt jede Sitzung, die den Eintrag trägt — eine Phase gehört keiner einzelnen" do
      fakten = [fakt("f_aa", 1, ["b_1"]), fakt("f_bb", 3, ["b_7"])]

      eintrag = %{
        id: "chr-2",
        titel: "Über zwei Sitzungen",
        text: "Text",
        wichtigkeit: "phase",
        fakt_ids: ["f_aa", "f_bb"],
        zeit_bezug: []
      }

      [p] = payloads([eintrag], fakten)

      assert p["sitzungen"] == [1, 3]
      # `session_id` nennt nur den Auslöser des Laufs und wird bei jeder
      # Verfeinerung überschrieben — deshalb braucht es `sitzungen` daneben.
      assert p["session_id"] == "s-2"
    end

    test "ein unbekannter Fakt lässt den Eintrag nicht scheitern" do
      eintrag = %{
        id: "chr-3",
        titel: "Mit Altlast",
        text: "Text",
        wichtigkeit: "phase",
        # `f_weg` kennt die Eingabe nicht mehr (neu extrahiert seit dem Lauf,
        # der ihn eintrug) — er trägt nichts bei, statt zu werfen.
        fakt_ids: ["f_aa", "f_weg"],
        zeit_bezug: []
      }

      [p] = payloads([eintrag], [fakt("f_aa", 1, ["b_1"])])

      assert p["source_refs"] == ["b_1"]
      assert p["sitzungen"] == [1]
    end
  end
end
