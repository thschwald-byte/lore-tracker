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
          # Spaltenlos sein dürfen die Bogen-Progressionen (ihr Ergebnis steht
          # in der Nachlese) und die beiden Stufen der Zeitlinie (#1247 — sie
          # hat in der CampaignLive noch keine eigene Spalte; das wäre #1243).
          assert stufe.name in ~w(render_arc_progressions zeit_gedaechtnis zeit),
                 "#{stufe.name} hat keine Spalte — Absicht? Dann hier eintragen."

          # **Und sie muss ihre Gruppe selbst nennen.** Der Statusendpunkt
          # (#1218) gruppiert darüber; bis #1247 hiess jede spaltenlose Stufe
          # dort „boegen", und die Zeitlinie wäre zu einer Bogen-Progression
          # geworden.
          assert is_binary(Map.get(stufe, :gruppe)),
                 "#{stufe.name} ist spaltenlos und nennt keine :gruppe — im " <>
                   "Statusendpunkt wäre sie nicht zuzuordnen."

        spalte ->
          assert spalte in @col_names,
                 "Stufe #{stufe.name} zeigt auf Spalte #{inspect(spalte)}, die es nicht gibt"
      end
    end
  end

  # **Die zweite Hälfte der Falle** (bob, 19.09.2026): Der Wächter oben
  # verlangt eine Gruppe von SPALTENLOSEN Stufen. Eine Stufe *mit* Spalte,
  # deren Gruppe eine andere sein müsste, fiele still auf die Spalte zurück —
  # genau der Fall, der zu diesem Umbau geführt hat, eine Ebene versetzt. Und
  # ein Tippfehler in `:gruppe` erzeugte eine Gruppe, die niemand erwartet:
  # Der Statusendpunkt zeigte sie an, und niemand fragte, woher sie kommt.
  @gruppen @col_names ++ ~w(zeit boegen)

  test "jede Gruppe ist eine bekannte — ein Tippfehler erfindet keine neue" do
    for stufe <- PipelineStufen.alle() do
      gruppe = Map.get(stufe, :gruppe) || stufe.spalte

      assert gruppe in @gruppen,
             "Stufe #{stufe.name} gehört zur Gruppe #{inspect(gruppe)}, die es nicht " <>
               "gibt. Absicht? Dann hier eintragen — sonst ist es ein Tippfehler, " <>
               "den nur der Statusendpunkt zeigt."
    end
  end

  test "eine Stufe MIT Spalte trägt keine abweichende Gruppe — ausser bewusst" do
    abweichend =
      for stufe <- PipelineStufen.alle(),
          g = Map.get(stufe, :gruppe),
          not is_nil(stufe.spalte),
          g != stufe.spalte,
          do: {stufe.name, stufe.spalte, g}

    # Heute gibt es keine. Wer die erste einträgt, soll hier begründen, warum
    # die Oberfläche sie anders gruppiert als der Statusendpunkt — sonst ist
    # es ein Versehen, das an beiden Orten Verschiedenes anzeigt.
    assert abweichend == [],
           "Spalte und Gruppe fallen auseinander: #{inspect(abweichend)}"
  end

  test "die Protokoll-Spalte gehört keiner Stufe — sie ist die Quelle" do
    spalten = Enum.map(PipelineStufen.alle(), & &1.spalte)

    refute "protokoll" in spalten,
           "Protokoll ist der Eingang des Laufs, keine seiner Stufen (die " <>
             "Transkription meldet als `stage1` über einen eigenen Melder)."
  end

  test "keine zwei Stufen teilen sich eine Spalte — außer den je drei Stufen der drei Jacks" do
    belegt =
      PipelineStufen.alle()
      |> Enum.reject(&is_nil(&1.spalte))
      |> Enum.group_by(& &1.spalte, & &1.name)
      |> Enum.filter(fn {_spalte, namen} -> length(namen) > 1 end)
      |> Map.new()

    # J4 (#1207): Gedächtnis, Extraktion und Verifikation sind ein Jack-Lauf,
    # dessen Ergebnis die Fakten-Spalte ist. J5 (#1209): Überblick, Schreiben
    # und Durchsicht sind die Läufe des Resümee-Jack, Ergebnis die
    # Resümee-Spalte. J6 (#1210): dasselbe für den Epos-Jack und die
    # Epos-Spalte. J7 (#1211): dasselbe für den Chronik-Jack — mit der
    # Besonderheit, dass im Normalbetrieb (Verfeinerung) nur die mittlere
    # Stufe läuft; die anderen beiden melden dann schlicht nichts. Alles
    # andere wäre ein Fehler in der Zuordnung.
    assert belegt == %{
             "fakten" => ["jack_gedaechtnis", "extract", "jack_verifikation"],
             "summaries" => ["resuemee_ueberblick", "render", "resuemee_durchsicht"],
             "epos" => ["epos_ueberblick", "render_epos", "epos_durchsicht"],
             "chronik" => ["chronik_ueberblick", "timeline", "chronik_durchsicht"]
           }
  end

  test "der Arbeitet-Hinweis einer Spalte kommt aus derselben Liste" do
    # campaign_live.html.heex fragt die Fakten-Spalte darüber — vorher stand
    # dort ein Literal, dem neue Stufen gefehlt hätten.
    assert PipelineStufen.namen_fuer_spalte("fakten") ==
             ["jack_gedaechtnis", "extract", "jack_verifikation"]

    assert PipelineStufen.namen_fuer_spalte("summaries") ==
             ["resuemee_ueberblick", "render", "resuemee_durchsicht"]

    assert PipelineStufen.namen_fuer_spalte("protokoll") == []
  end
end
