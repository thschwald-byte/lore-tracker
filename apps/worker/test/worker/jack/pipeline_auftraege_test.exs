defmodule Worker.Jack.PipelineAuftraegeTest do
  # J4 (#1207): Jacks Aufträge im Betrieb sind Vorlagen, in die je Sitzung
  # die Blockzahlen eingesetzt werden.
  use ExUnit.Case, async: true

  alias Worker.Jack.Pipeline

  test "fuellen setzt letzte Blocknummer und Anzahl ein" do
    assert Pipeline.fuellen("Blöcke 0 bis {{letzter_block}}, {{anzahl_bloecke}} Blöcke.", 40) ==
             "Blöcke 0 bis 39, 40 Blöcke."
  end

  @tag :tmp_dir
  test "auftraege liest die drei Vorlagen und füllt sie", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "phase1.md"), "0 bis {{letzter_block}}")
    File.write!(Path.join(dir, "phase2.md"), "{{anzahl_bloecke}} Blöcke")
    File.write!(Path.join(dir, "folgelauf.md"), "Block {{letzter_block}}")

    assert {:ok, %{phase1: "0 bis 1801", phase2: "1802 Blöcke", folgelauf: "Block 1801"}} =
             Pipeline.auftraege(1802, dir)
  end

  @tag :tmp_dir
  test "fehlt eine Vorlage, ist es ein Fehler", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "phase1.md"), "x")

    assert {:error, {:auftrag_fehlt, pfad}} = Pipeline.auftraege(10, dir)
    assert pfad =~ "phase2.md" or pfad =~ "folgelauf.md"
  end
end
