defmodule HubWeb.PipelineStufenSpaltenTest do
  @moduledoc """
  Issue #1122: das Laufband trägt die Spalten der CampaignLive in deren
  Reihenfolge. Jede Stufe zeigt dafür auf eine Spalte — zeigt sie auf eine, die
  es nicht gibt, erscheint im Band eine Spalte ohne Inhalt oder der Punkt
  landet nirgends. Nichts davon wird von allein rot: dieselbe Klasse wie die
  drei von Hand gepflegten Permission-Listen aus #1090, wo ein fehlender
  Eintrag einen toten Knopf erzeugte.
  """
  use ExUnit.Case, async: true

  alias Shared.PipelineStufen

  # Wert-Sync mit HubWeb.CampaignLive.@col_names und dem Duplikat in
  # CampaignLive.Components (dort Compile-Literal wegen des col_toggle-Guards).
  @col_names ~w(chronik epos summaries glatt fakten protokoll)

  test "jede Stufe zeigt auf eine existierende Spalte (oder bewusst auf keine)" do
    for stufe <- PipelineStufen.alle() do
      case stufe.spalte do
        nil ->
          # Nur die Bogen-Progressionen dürfen spaltenlos sein — ihr Ergebnis
          # steht in der Nachlese, nicht in einer Spalte.
          assert stufe.name == "render_arc_progressions",
                 "#{stufe.name} hat keine Spalte — Absicht? Dann hier eintragen."

        spalte ->
          assert spalte in @col_names,
                 "Stufe #{stufe.name} zeigt auf Spalte #{inspect(spalte)}, die es nicht gibt"
      end
    end
  end

  test "die Protokoll-Spalte gehört keiner Stufe — sie ist die Quelle" do
    spalten = Enum.map(PipelineStufen.alle(), & &1.spalte)

    refute "protokoll" in spalten,
           "Protokoll ist der Eingang des Laufs, keine seiner Stufen (die " <>
             "Transkription meldet als `stage1` über einen eigenen Melder)."
  end

  test "keine zwei Stufen teilen sich eine Spalte — außer Extraktion und Prüfung" do
    belegt =
      PipelineStufen.alle()
      |> Enum.reject(&is_nil(&1.spalte))
      |> Enum.group_by(& &1.spalte, & &1.name)
      |> Enum.filter(fn {_spalte, namen} -> length(namen) > 1 end)
      |> Map.new()

    # Beide erzeugen die Fakten-Spalte: die Extraktion füllt sie, die Prüfung
    # markiert darin. Alles andere wäre ein Fehler in der Zuordnung.
    assert belegt == %{"fakten" => ["extract", "verify"]}
  end
end
