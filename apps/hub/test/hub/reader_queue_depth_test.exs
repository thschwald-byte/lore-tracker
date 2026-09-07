defmodule Hub.ReaderQueueDepthTest do
  @moduledoc """
  Issue #1164: `queue_depth/0` muss „unbekannt" von „leer" unterscheidbar
  halten.

  **Warum das ein eigener Test ist.** Der Fehlerwert war `0` — der harmloseste
  mögliche Wert, und damit der falsche. Die Speicher-Zeile (#1087) meldete
  dann „Schlange leer", wo in Wirklichkeit „keine Antwort" galt. Genau die
  Unterscheidung, für die das Feld gebaut wurde, ging im Fehlerfall verloren:
  ein Herd und ein ruhiger Moment sehen beide nach wenig Speicher aus, und die
  Schlangentiefe ist das Einzige, was sie trennt.

  Nichts daran wäre aufgefallen — kein Fehler, keine Log-Zeile, nur eine
  falsche Null in einer Kennzahl, auf die sich das nächste Warnsignal (#1163)
  stützen soll.
  """

  use ExUnit.Case, async: false

  alias Hub.Reader

  describe "im Normalbetrieb" do
    test "liefert die tatsächliche Tiefe" do
      # Der echte Reader läuft im Application-Tree und hat eine leere Schlange.
      assert Reader.queue_depth() == 0
    end
  end

  describe "wenn der Reader nicht antwortet" do
    setup do
      :ok = Supervisor.terminate_child(Hub.Supervisor, Hub.Reader)

      # Ein Prozess, der den Namen hält, aber niemals antwortet — genau der
      # Zustand unter Speicherdruck, für den das Feld existiert.
      stumm =
        spawn(fn ->
          Process.register(self(), Hub.Reader)
          Process.sleep(:infinity)
        end)

      on_exit(fn ->
        if Process.alive?(stumm), do: Process.exit(stumm, :kill)
        # Den echten Reader zurück in den Tree, sonst sehen die folgenden
        # Tests einen Baum ohne ihn.
        Supervisor.restart_child(Hub.Supervisor, Hub.Reader)
      end)

      # Auf die Registrierung warten, sonst läuft der Call ins Leere statt in
      # den Timeout — das wäre ein anderer Fehlerpfad.
      Process.sleep(50)
      :ok
    end

    test "meldet -1 statt einer erfundenen Null" do
      # Die eigentliche Aussage: der Fehlerwert darf nicht wie ein gültiger
      # Messwert aussehen.
      assert Reader.queue_depth() == -1
    end

    test "der Fehlerwert ist von jeder echten Tiefe unterscheidbar" do
      # Eine echte Schlange ist nie negativ. Damit ist -1 eindeutig, ohne dass
      # die Log-Zeile ein zusätzliches Feld braucht.
      assert Reader.queue_depth() < 0
    end
  end
end
