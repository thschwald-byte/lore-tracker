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
        # Issue #1220: beides muss auf den ENDZUSTAND warten, nicht auf den
        # Anstoß — sonst sieht der nächste Test einen Reader, der nicht
        # antwortet, und bekommt die -1 aus #1164 als Messwert.
        #
        # `Process.exit/2` ist asynchron: der Name `Hub.Reader` bleibt
        # registriert, bis der Prozess wirklich tot ist. Trifft
        # `restart_child` dieses Fenster, scheitert der Neustart still.
        beende(stumm)

        # Das Ergebnis GEHÖRT geprüft: scheitert der Neustart (etwa mit
        # `{:error, {:already_started, _}}`, weil der Name noch belegt war),
        # sagt das genau die Ursache — sonst läuft man erst in die Wartezeit
        # unten und sieht nur die Wirkung.
        assert {:ok, _} = Supervisor.restart_child(Hub.Supervisor, Hub.Reader)

        # Und ein benannter GenServer ist registriert, BEVOR `init/1` fertig
        # ist (hier: das Abonnement der WorkerRegistry). Wer auf die Pid
        # wartet, wartet auf zu wenig — die Lehre aus #887, dort an der
        # ETS-Tabelle von Hub.RateLimit, gefunden auf demselben CI-Schritt.
        warte_auf_antwort()
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

  # Wartet, bis der Prozess wirklich beendet ist — `Process.exit/2` schickt
  # nur das Signal.
  defp beende(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> flunk("der stumme Prozess ist nach 1 s nicht beendet")
      end
    end
  end

  # Wartet, bis der Reader wieder ANTWORTET. Eine echte Tiefe ist nie negativ
  # (#1164), also ist `>= 0` genau die Bedingung „wieder bedienbar".
  defp warte_auf_antwort(versuche \\ 100) do
    cond do
      Reader.queue_depth() >= 0 ->
        :ok

      versuche > 0 ->
        Process.sleep(10)
        warte_auf_antwort(versuche - 1)

      true ->
        flunk("Hub.Reader antwortet nach 1 s nicht — die folgenden Tests messen -1")
    end
  end
end
