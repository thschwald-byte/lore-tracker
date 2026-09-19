defmodule Worker.Jack.Zeit.EinhaengenTest do
  @moduledoc """
  #1247 (Z4): dass der Zeit-Jack an der richtigen Stelle läuft — und dass sein
  Fehlschlag den Lauf nicht mitreisst.

  **Ein Quelltext-Wächter, kein Ende-zu-Ende-Lauf.** Die Verdrahtung bricht
  still: Wer die Zeile aus `run_wahrheitsbild/4` entfernt oder hinter das
  Resümee schiebt, bekommt keinen roten Test und keine Warnung — nur eine
  Linie, die eine Sitzung hinterherhinkt, oder gar keine. Dieselbe Klasse wie
  der `glatt_flag_guard_test.exs` (#1153) und der `voice_session_anchor_test`
  (#1060).
  """
  use ExUnit.Case, async: true

  @pipeline Path.expand("../../../../lib/worker/recording/pipeline.ex", __DIR__)

  defp quelle, do: File.read!(@pipeline)

  test "der Zeit-Jack hängt in der with-Kette von run_wahrheitsbild" do
    assert quelle() =~ ":ok <- zeit_jack(session, campaign, run_id, deps)",
           "Der Zeit-Jack muss als Glied der with-Kette stehen, nicht als " <>
             "Seiteneffekt daneben — nur so ist an der Kette selbst zu sehen, " <>
             "an welcher Stelle er läuft."
  end

  test "er läuft NACH dem Bestand und VOR dem Resümee" do
    q = quelle()

    bestand = index(q, "{:ok, verified} <- bestand_lesen(")
    zeit = index(q, ":ok <- zeit_jack(")
    resuemee = index(q, "{:ok, rendered} <- tag_error(render.(verified)")

    assert bestand < zeit,
           "Der Gedächtnis-Lauf liest die Fakten — vor dem Bestand gäbe es nichts zu lesen."

    assert zeit < resuemee,
           "Die Linie ist Wahrheitsbasis, keine Prosa: Der Chronik-Jack muss sie " <>
             "lesen können, und der läuft hinter dem Resümee."
  end

  test "ein Fehlschlag reisst den Lauf nicht mit" do
    q = quelle()
    rumpf = rumpf_von(q, "defp zeit_jack(")

    assert rumpf =~ "rescue",
           "Ohne rescue nähme eine Ausnahme den Prozess mit, und alles danach " <>
             "(Resümee, Chronik, Epos) entfiele — die #1211-Lehre."

    refute rumpf =~ "{:error",
           "zeit_jack/4 darf niemals einen Fehler in die with-Kette geben: Eine " <>
             "Linie ist eine Verbesserung, keine Vorbedingung."
  end

  test "deps.zeit schaltet ihn ab — Tests brauchen kein Modell" do
    assert rumpf_von(quelle(), "defp zeit_jack(") =~ ":aus"
  end

  defp index(q, teil) do
    assert String.contains?(q, teil), "nicht gefunden: #{teil}"
    :binary.match(q, teil) |> elem(0)
  end

  # Von der Kopfzeile bis zur nächsten Funktionsdefinition auf Modulebene.
  defp rumpf_von(q, kopf) do
    von = index(q, kopf)
    rest = binary_part(q, von, byte_size(q) - von)

    case :binary.match(rest, "\n  defp ", scope: {7, byte_size(rest) - 7}) do
      {bis, _} -> binary_part(rest, 0, bis)
      :nomatch -> rest
    end
  end
end
