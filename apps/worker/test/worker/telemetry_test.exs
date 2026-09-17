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

  describe "Signal 4 — wie der vorherige Lauf geendet hat" do
    setup do
      Worker.Repo.put_state(:lauf_begonnen_at, nil)
      Worker.Repo.put_state(:halt_angekuendigt_at, nil)
      :ok
    end

    defp abgang!(lauf, angekuendigt) do
      Worker.Repo.put_state(:lauf_begonnen_at, lauf)
      Worker.Repo.put_state(:halt_angekuendigt_at, angekuendigt)
      capture_log([level: :info], fn -> Telemetry.melde_vorherigen_abgang() end)
    end

    test "der allererste Start meldet nichts" do
      assert abgang!(nil, nil) == ""
    end

    test "ein Abgang ohne Ankündigung ist laut" do
      # Der letzte Lauf hat `halt_node/1` nie erreicht: abgestürzt, vom
      # Kernel abgeräumt oder hart abgeschossen.
      log = abgang!(System.system_time(:millisecond) - 60_000, nil)

      assert log =~ "[warning]"
      assert log =~ "event=worker.abgang"
      assert log =~ "art=unangekuendigt"
    end

    test "ein zügiger angekündigter Abgang ist nur eine Notiz" do
      jetzt = System.system_time(:millisecond)
      log = abgang!(jetzt - 120_000, jetzt - 2_000)

      assert log =~ "art=geordnet"
      refute log =~ "[warning]"
    end

    test "ein hängender Abgang ist laut und nennt die Dauer" do
      # Der Fall aus #1048: der Halt kommt nicht durch, der Watchdog
      # vollstreckt, und selbst der Backstop hat nicht gegriffen.
      jetzt = System.system_time(:millisecond)
      ueber = Worker.Lifecycle.halt_grace_ms() + 60_000
      log = abgang!(jetzt - 200_000, jetzt - ueber)

      assert log =~ "[warning]"
      assert log =~ "art=haengend"
      assert log =~ "schwelle_ms="

      # Nicht auf die exakte Zahl prüfen: zwischen dem Setzen und dem Lesen
      # vergeht echte Zeit, und ein Vergleich auf Gleichheit wäre ein Flake,
      # der irgendwann unter Last zuschlägt (die #1157/#1158-Klasse).
      [_, gemeldet] = Regex.run(~r/dauer_ms=(\d+)/, log)
      assert String.to_integer(gemeldet) >= ueber
    end

    test "nach dem Bericht ist die Ankündigung verbraucht und der Lauf vermerkt" do
      # Ohne das Zurücksetzen meldete jeder Start denselben alten Abgang
      # erneut — und der nächste echte Absturz sähe aus wie ein geordneter.
      jetzt = System.system_time(:millisecond)
      abgang!(jetzt - 120_000, jetzt - 2_000)

      assert Worker.Repo.get_state(:halt_angekuendigt_at) == nil
      assert is_integer(Worker.Repo.get_state(:lauf_begonnen_at))
    end

    test "ein kaputter Stand bringt den Bootpfad nicht um" do
      # Der Bericht läuft im Start der Anwendung; scheitert er, startet der
      # Worker nicht. Eine Beobachtung darf das nie verursachen.
      assert abgang!("kein Zeitstempel", "auch keiner") == ""
      assert Telemetry.melde_vorherigen_abgang() == :ok
    end
  end
end
