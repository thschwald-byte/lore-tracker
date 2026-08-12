defmodule Worker.Discord.CaptureOutcomeTest do
  @moduledoc """
  Issue #1008: „Aufnahme lief, aber kein Transkript" war ein STILLER
  Totalverlust — der GM sah während der Sitzung nichts Auffälliges und merkte
  erst hinterher, dass nichts angekommen war; in `/admin/errors` stand nichts,
  weil die betroffenen Stellen nur `Logger` schrieben.

  Die Ursache jenes Vorfalls war die vertauschte Stop-Reihenfolge (#1011). Diese
  Bewertung ist nicht deren Fix, sondern die Zusicherung, dass ein Ausfall des
  Discord-Pfads nie wieder unsichtbar bleibt — egal aus welchem Grund.

  Bewusst getestet ist auch, was KEINE Fehlerklasse auslöst: der Teilausfall.
  Einzelne unauflösbare Frames sind normal (Discords `:speaking`-Event, das die
  Sprecher-Zuordnung füllt, kommt nicht garantiert vor dem ersten Paket — real
  beobachtet sind ~10 Frames ≈ 200 ms zu Sprechbeginn). Daraus eine Fehlerklasse
  zu machen hieße, eine Schwelle zu erfinden, die niemand kalibriert hat.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.VoiceErrors

  test "gar kein Paket empfangen -> :no_frames" do
    # Der Bot saß im Kanal, es wurde gesprochen, und es kam nichts an.
    assert VoiceErrors.capture_outcome(0, 0) == :no_frames
  end

  test "kein einziges Paket zuordenbar -> :unresolved" do
    # Nach einem Voice-Reconnect vergibt Discord die SSRCs neu. Ohne Identität
    # wird nichts gespeichert (es gäbe keine Einwilligung, die es deckt) — das
    # ist richtig, aber es darf nicht schweigend passieren.
    assert VoiceErrors.capture_outcome(500, 500) == :unresolved
  end

  test "Teilausfall ist KEIN Fehler (keine erfundene Schwelle)" do
    assert VoiceErrors.capture_outcome(500, 10) == :ok
    assert VoiceErrors.capture_outcome(500, 499) == :ok
  end

  test "sauberer Lauf -> :ok" do
    assert VoiceErrors.capture_outcome(500, 0) == :ok
  end

  test "die Reihenfolge der Klauseln: 0 Frames gewinnt über die Gleichheit" do
    # `capture_outcome(0, 0)` erfüllt formal auch „alle Frames unauflösbar".
    # Die aussagekräftigere Meldung ist „kein Paket empfangen" — sie nennt eine
    # andere Ursache (Bot stummgeschaltet) und einen anderen Prüfschritt.
    assert VoiceErrors.capture_outcome(0, 0) == :no_frames
  end
end
