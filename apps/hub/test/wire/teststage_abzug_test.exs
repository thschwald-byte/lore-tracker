defmodule Wire.TeststageAbzugTest do
  @moduledoc """
  Issue #1260: der Ablageort des Teststage-Defaults (`Shared.TeststageAbzug`).

  Unter `test/wire/`, wo in diesem Repo die geteilten Konstanten geprüft werden
  (Muster `resuemee_laenge_test.exs`): `shared` bootet standalone nicht, seine
  Logik wird aus der Hub-Suite mitgetestet.
  """
  use ExUnit.Case, async: true

  alias Shared.TeststageAbzug

  test "der Pfad ist absolut, außerhalb des Repos und ohne Datum" do
    # Ein datierter Ordner ist kein kanonischer Ort: Man müsste wissen, welcher
    # der richtige ist, und genau das hat am 26.09.2026 eine Stunde gekostet.
    v = TeststageAbzug.standard_verzeichnis()

    assert Path.type(v) == :absolute
    refute v =~ ~r/\d{4}-\d{2}-\d{2}/
    refute String.contains?(v, "/apps/")
    refute String.contains?(v, "lore_tracker")
  end

  test "vorhanden?/1 sieht .jsonl, sonst nichts" do
    dir = Path.join(System.tmp_dir!(), "abzug-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    refute TeststageAbzug.vorhanden?(dir), "ein fehlendes Verzeichnis ist kein Abzug"

    File.mkdir_p!(dir)
    refute TeststageAbzug.vorhanden?(dir), "ein leeres Verzeichnis ist kein Abzug"

    File.write!(Path.join(dir, "LIESMICH.md"), "Notiz für Menschen")
    refute TeststageAbzug.vorhanden?(dir), "eine Notiz ist kein Abzug"

    File.write!(Path.join(dir, "worker_events_global.jsonl"), "")
    assert TeststageAbzug.vorhanden?(dir)
  end

  test "geprüft wird die Anwesenheit, nicht der Inhalt" do
    # Ob die Ereignisse taugen, entscheidet der Worker beim Lesen
    # (`Worker.Teststage.ereignisse/1`). Ein Leser im Hub wäre ein zweiter Ort
    # für dieselbe Logik — und der Hub hat den Worker nicht als Dependency,
    # was so bleiben soll.
    dir = Path.join(System.tmp_dir!(), "abzug-mist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "kaputt.jsonl"), "das ist kein JSON")
    assert TeststageAbzug.vorhanden?(dir)
  end
end
