defmodule Shared.LoreBackupGuardTest do
  @moduledoc """
  Issue #995: `mix lore.backup` meldete einen Lauf mit 0 gesicherten Tabellen als
  Erfolg — dieselbe grüne "Done"-Meldung wie ein echtes Backup, nur mit einer
  leicht überlesenen 0 mitten im Text, plus eine gültige aber LEERE .bup-Datei.
  Typischer Auslöser: LORE_MNESIA_DIR vergessen → frischer, leerer Default-Pfad.
  Der Fehlschlag fiel erst im DR-Fall auf.

  Getestet wird der reine Guard (`ensure_backupable!/2`) — der Task selbst
  bootet Mnesia und schaltet global `:mnesia, :dir` um; ihn hier zu fahren würde
  die Mnesia-Instanz der übrigen Suite umkonfigurieren.

  Liegt in der worker-Suite, weil `shared` standalone nicht bootet (CLAUDE.md:
  „shared-Logik wird aus der hub-/worker-Suite mitgetestet").
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.Backup

  test "0 Tabellen -> Mix.raise, KEIN stiller Erfolg" do
    assert_raise Mix.Error, fn -> Backup.ensure_backupable!([], "/tmp/leeres-mnesia-dir") end
  end

  test "die Fehlermeldung nennt Ursache, Verzeichnis und den Weg raus" do
    err =
      assert_raise Mix.Error, fn ->
        Backup.ensure_backupable!([], "/tmp/vergessenes-dir")
      end

    msg = Exception.message(err)
    # Welches Verzeichnis war leer?
    assert msg =~ "/tmp/vergessenes-dir"
    # Was ist vermutlich die Ursache + wie behebt man sie?
    assert msg =~ "LORE_MNESIA_DIR"
    # Und die Zusicherung, dass NICHTS geschrieben wurde (sonst sucht der User
    # nach einer Datei, die es nicht gibt).
    assert msg =~ "Kein Backup geschrieben"
  end

  test "mindestens eine Tabelle -> :ok, Task läuft normal weiter" do
    assert Backup.ensure_backupable!([:worker_campaigns], "/tmp/egal") == :ok

    assert Backup.ensure_backupable!(
             [:worker_campaigns, :worker_sessions, :worker_utterances],
             "/tmp/egal"
           ) == :ok
  end
end
