defmodule HubWeb.TrackerAufraeumen do
  @moduledoc """
  Issue #1227: ein getrackter Worker verschwindet nicht mit seinem Prozess.

  `Phoenix.Tracker` erfährt vom Ende erst über das `:DOWN` und verarbeitet es
  asynchron. Wer nur `send(pid, :stop)` schreibt (oder sich darauf verlässt,
  dass ein `spawn_link`-Kind am Testende ohnehin stirbt), lässt den Eintrag
  also für eine Weile stehen — auf dieser Maschine 0–2 ms gemessen, auf dem
  geteilten CI-Runner länger. Der nächste Test sieht dann einen Worker, den es
  nicht mehr geben sollte; `Hub.WorkerRegistry.any_active_recording?/0` sagt
  `true`, und der Bericht zeigt auf das falsche Opfer (Lauf 1070: nicht der
  Erzeuger fiel um, sondern `HubWeb.HealthControllerTest`).

  Deshalb wartet jeder Erzeuger hier auf den **Endzustand**, und zwar in
  `on_exit`: scheitert eine Zusicherung vorher, wird die letzte Testzeile nie
  erreicht — ein fehlgeschlagener Test risse sonst den nächsten mit.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Hub.WorkerRegistry

  @doc """
  Registriert das Aufräumen für einen getrackten Worker: Prozess beenden, sein
  Ende abwarten, dann warten, bis er aus `WorkerRegistry.list/0` verschwunden
  ist. Vor dem Ende des Tests aufrufen (`on_exit` nimmt später nichts mehr an).
  """
  def raeumt_auf(pid, worker_id) when is_pid(pid) and is_binary(worker_id) do
    on_exit(fn -> aufraeumen(pid, worker_id) end)
    pid
  end

  # `on_exit` läuft, nachdem der Testprozess beendet ist — ein per `spawn_link`
  # verbundenes Kind ist dann meist schon tot und `send/2` verpufft. Genau
  # deshalb ist die Bedingung unten der Tracker-Eintrag und nicht der Prozess.
  defp aufraeumen(pid, worker_id) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
    end

    assert warte_bis(fn -> not gelistet?(worker_id) end),
           "#{worker_id} steht nach dem Aufräumen noch im Tracker — " <>
             "der nächste Test sähe ihn als laufende Aufnahme"
  end

  @doc "Steht dieser Worker gerade im Tracker?"
  def gelistet?(worker_id) do
    Enum.any?(WorkerRegistry.list(), fn {id, _} -> id == worker_id end)
  end

  @doc "Pollt die Bedingung bis zu einer Sekunde; `false`, wenn sie nie eintritt."
  def warte_bis(fun) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
