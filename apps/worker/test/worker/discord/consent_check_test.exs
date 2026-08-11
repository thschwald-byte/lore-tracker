defmodule Worker.Discord.ConsentCheckTest do
  @moduledoc """
  Issue #1002: die Frames→Urteil-Auswertung. Getestet werden die Kanten, die
  OHNE Whisper erreichbar sind — leere Frames, SSRC ohne User-Mapping,
  fehlgeschlagener Clip-Bau. Alle müssen fail-closed enden (nie `:granted`).

  Der Whisper-Pfad selbst wird hier nicht getrieben (braucht whisper-cli +
  Modell + echte Opus-Frames); seine Urteilslogik hängt an
  `Worker.Recording.ConsentPhrase` und ist dort vollständig getestet.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentCheck

  test "keine Frames → kein Urteil (und damit keine Zustimmung)" do
    assert ConsentCheck.evaluate_frames([], %{}) == %{}
  end

  test "nicht-Listen/Map-Eingaben werden abgefangen statt zu crashen" do
    assert ConsentCheck.evaluate_frames(nil, %{}) == %{}
    assert ConsentCheck.evaluate_frames([], nil) == %{}
  end

  test "SSRC ohne User-Mapping erscheint NICHT im Ergebnis" do
    # Ein Urteil ohne geklärte Identität wäre schlimmer als keins — es könnte
    # eine Zustimmung der falschen Person zuschreiben.
    frames = [%{ssrc: 4242, opus: <<1, 2, 3>>, arrival_ms: 0}]

    assert ConsentCheck.evaluate_frames(frames, %{}) == %{}
  end

  test "unbrauchbare Frames eines bekannten Sprechers → :unclear, nie :granted" do
    # Müll-Opus: der Clip-Bau (oder die Transkription) scheitert. Muss als
    # unclear enden — ein technischer Fehler darf keine Zustimmung unterstellen.
    frames = [%{ssrc: 7, opus: <<0, 0, 0, 0>>, arrival_ms: 0}]

    result = ConsentCheck.evaluate_frames(frames, %{7 => 12_345})

    assert Map.keys(result) == ["12345"]
    refute result["12345"] == :granted
  end
end
