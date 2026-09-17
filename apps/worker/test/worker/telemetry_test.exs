defmodule Worker.TelemetryTest do
  @moduledoc """
  Issue #542: die Vorfall-Zählung des Workers.

  Geprüft wird das Verhalten, nicht die innere Form: was zählt, was
  schweigt, was laut wird.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Worker.Telemetry

  setup do
    # Die Suite läuft mit `level: :warning` (config/test.exs) — die stille
    # und die laute Meldung sind hier aber genau der Unterschied, um den es
    # geht, und eine info-Zeile entstünde gar nicht erst. `async: false`
    # oben ist die Bedingung dafür, dass das keine Nachbartests trifft.
    vorher = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: vorher) end)

    # Der Anwendungsbaum des Workers startet nur mit vorhandenem Pairing
    # (`Worker.Application.paired?/0`) — in der Testumgebung läuft der
    # Reporter also nicht von selbst. ExUnit räumt ihn nach jedem Test ab,
    # jeder Test beginnt damit mit leeren Zählern.
    start_supervised!(Telemetry)
    :ok
  end

  # Ein Takt meldet das Fenster und leert es. `stand/0` dahinter ist kein
  # Selbstzweck: der Aufruf ist synchron und stellt sicher, dass der Takt
  # verarbeitet ist, bevor das Log gelesen wird.
  defp takt! do
    capture_log([level: :info], fn ->
      send(Telemetry, :takt)
      Telemetry.stand()
    end)
  end

  describe "laut?/2 — die Schwellen" do
    test "ein einzelner Task-Absturz ist sofort laut" do
      assert Telemetry.laut?(%{task_crash: 1}, 0)
    end

    test "ein einzelner unbekannter Ereignis-Typ ist sofort laut" do
      assert Telemetry.laut?(%{unbekannter_event_kind: 1}, 0)
    end

    test "Pipeline-Fehler werden erst in Häufung laut" do
      refute Telemetry.laut?(%{pipeline_fehler: 4}, 0)
      assert Telemetry.laut?(%{pipeline_fehler: 5}, 0)
    end

    test "ein wachsender Publish-Rückstand ist laut, auch ohne jeden Vorfall" do
      assert Telemetry.laut?(%{}, 1)
    end

    test "ein schrumpfender oder gleichbleibender Rückstand ist es nicht" do
      refute Telemetry.laut?(%{}, 0)
      refute Telemetry.laut?(%{}, -20)
    end

    test "die Schwellen decken alle Signale ab" do
      # Ein Signal ohne Schwelle fiele auf den Vorgabewert 1 zurück — das
      # wäre kein Fehler, aber eine unausgesprochene Entscheidung.
      for s <- Telemetry.signale(), do: assert(Map.has_key?(Telemetry.schwellen(), s))
    end
  end

  describe "zählen" do
    test "ein Vorfall erhöht seinen Zähler" do
      vorher = Telemetry.stand()[:pipeline_fehler]
      Telemetry.zaehle(:pipeline_fehler, quelle: "extract")
      assert Telemetry.stand()[:pipeline_fehler] == vorher + 1
    end

    test "der Ruf schreibt selbst nichts ins Log" do
      # Der Vorfall wird an seiner Entstehung bereits geschrieben; eine
      # zweite Zeile je Vorfall würde bei einer Fehlerserie das Log fluten,
      # in dem er gefunden werden soll.
      log =
        capture_log(fn ->
          for _ <- 1..20, do: Telemetry.zaehle(:pipeline_fehler, quelle: "gapfill")
          Telemetry.stand()
        end)

      refute log =~ "worker.signale"
      refute log =~ "gapfill"
    end

    test "ein Ruf ohne laufenden Reporter scheitert nicht" do
      # Mix-Tasks und Tests laufen ohne den Anwendungsbaum; ein Zählruf darf
      # dort nichts umbringen.
      assert :ok = GenServer.cast(:gibt_es_nicht_542, {:zaehle, :task_crash, nil})
    end

    test "unbekannte Signale werden gezählt statt verworfen" do
      # Ein Tippfehler am Aufrufer soll auffallen, nicht verschwinden.
      Telemetry.zaehle(:tippfehler_signal)
      assert Telemetry.stand()[:tippfehler_signal] == 1
    end
  end

  describe "melden" do
    test "ohne Vorfälle bleibt der Reporter still" do
      assert takt!() == ""
    end

    test "Vorfälle im Fenster erzeugen genau eine Zeile" do
      Telemetry.zaehle(:pipeline_fehler, quelle: "extract")
      Telemetry.zaehle(:pipeline_fehler, quelle: "verify")
      log = takt!()

      assert log =~ "[telemetry] event=worker.signale"
      assert log =~ "pipeline_fehler=2"
      assert [_] = Regex.scan(~r/event=worker\.signale/, log)
    end

    test "die Quellen stehen in der Zeile" do
      Telemetry.zaehle(:task_crash, quelle: "Worker.TaskSupervisor")
      assert takt!() =~ "quellen=Worker.TaskSupervisor"
    end

    test "dieselbe Quelle steht nur einmal" do
      for _ <- 1..5, do: Telemetry.zaehle(:task_crash, quelle: "Worker.TaskSupervisor")
      log = takt!()

      assert log =~ "task_crash=5"
      assert [_] = Regex.scan(~r/Worker\.TaskSupervisor/, log)
    end

    test "höchstens fünf verschiedene Quellen" do
      # Ohne Deckel wüchse die Liste bei einer Absturzschleife mit
      # wechselnden Prozessnamen unbegrenzt — im Zustand eines Prozesses,
      # der genau dann leben muss, wenn etwas schiefgeht.
      for i <- 1..9, do: Telemetry.zaehle(:task_crash, quelle: "q#{i}")
      log = takt!()

      assert log =~ "task_crash=9"
      assert length(Regex.scan(~r/q\d/, log)) == 5
    end

    test "ein Task-Absturz wird zur Warnung, ein einzelner Pipeline-Fehler nicht" do
      Telemetry.zaehle(:task_crash, quelle: "task")
      assert takt!() =~ "[warning]"

      Telemetry.zaehle(:pipeline_fehler, quelle: "extract")
      log = takt!()
      assert log =~ "worker.signale"
      refute log =~ "[warning]"
    end

    test "nach dem Melden beginnt das Fenster bei null" do
      Telemetry.zaehle(:pipeline_fehler)
      takt!()
      assert Telemetry.stand()[:pipeline_fehler] == 0
      assert takt!() == "", "ein leeres Fenster darf nicht erneut melden"
    end
  end
end
