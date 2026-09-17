defmodule Hub.WorkerRegistryRecordingTest do
  @moduledoc """
  Issue #703: WorkerRegistry.any_active_recording?/0 — Deploy-Gate-Signal.
  Nutzt dasselbe held_sessions-Tracking wie #468, keine neue State-Quelle.

  **Issue #1227: das Aufräumen wartet auf den Endzustand.** Vorher endete jeder
  Test direkt nach `send(pid, :stop)`. Das ist asynchron in zwei Stufen — der
  Prozess muss sterben, und `Phoenix.Tracker` muss das `:DOWN` erst verarbeiten.
  Der nächste Test sah deshalb gelegentlich einen Worker, der längst gehen
  sollte, und „ohne held_sessions -> false" bekam ein `true`. Unter
  Coverage-Instrumentierung ist alles langsamer, deshalb kippte es dort und
  lokal fast nie (dieselbe Klasse wie #1120, #1157, #1158, #1220).

  Zwei Konsequenzen daraus stehen unten im Code:

  - Gewartet wird auf das **Verschwinden aus `WorkerRegistry.list/0`**, nicht
    auf den Prozesstod. Der Prozesstod ist nur die erste der beiden Stufen.
  - Das Aufräumen liegt in `on_exit`, nicht in der letzten Zeile des Tests.
    Scheitert eine Zusicherung vorher, wurde die letzte Zeile nie erreicht —
    ein fehlgeschlagener Test riss so den nächsten mit, und der Bericht zeigte
    auf das falsche Opfer.
  """

  use ExUnit.Case, async: false

  alias Hub.WorkerRegistry

  defp track_and_hold(worker_id, session_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = WorkerRegistry.track(worker_id, "admin-test")

        if session_id do
          {:ok, _} = WorkerRegistry.add_held_session(worker_id, session_id)
        end

        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 2_000
    on_exit(fn -> aufraeumen(pid, worker_id) end)
    pid
  end

  # `on_exit` läuft, nachdem der Testprozess beendet ist — der verlinkte
  # Track-Prozess ist dann meist schon tot, und `send/2` verpufft. Genau
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

    assert wait_until(fn -> not gelistet?(worker_id) end),
           "#{worker_id} steht nach dem Aufräumen noch im Tracker — " <>
             "der nächste Test sähe ihn als laufende Aufnahme"
  end

  defp gelistet?(worker_id) do
    Enum.any?(WorkerRegistry.list(), fn {id, _} -> id == worker_id end)
  end

  defp wait_until(fun) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  test "kein Worker verbunden -> false" do
    refute WorkerRegistry.any_active_recording?()
  end

  test "Worker verbunden, aber ohne held_sessions -> false" do
    worker_id = "w-rec-empty-#{System.unique_integer([:positive])}"
    track_and_hold(worker_id, nil)

    assert wait_until(fn -> gelistet?(worker_id) end), "Worker wurde nie getrackt"

    refute WorkerRegistry.any_active_recording?()
  end

  test "ein Worker hält eine Session -> true" do
    worker_id = "w-rec-holds-#{System.unique_integer([:positive])}"
    track_and_hold(worker_id, "sess-1")

    assert wait_until(fn -> WorkerRegistry.any_active_recording?() end),
           "die gehaltene Session kam nie im Tracker an"
  end

  test "mehrere Worker, nur einer hält eine Session -> true" do
    idle_id = "w-rec-idle-#{System.unique_integer([:positive])}"
    holder_id = "w-rec-holder-#{System.unique_integer([:positive])}"

    track_and_hold(idle_id, nil)
    track_and_hold(holder_id, "sess-2")

    assert wait_until(fn ->
             Enum.any?(WorkerRegistry.list(), fn {id, meta} ->
               id == holder_id and MapSet.size(Map.get(meta, :held_sessions, MapSet.new())) > 0
             end)
           end),
           "die gehaltene Session kam nie im Tracker an"

    assert WorkerRegistry.any_active_recording?()
  end
end
