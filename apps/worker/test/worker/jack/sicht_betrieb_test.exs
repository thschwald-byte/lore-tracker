defmodule Worker.Jack.SichtBetriebTest do
  # J4 (#1207): die Laufsicht im Worker — ohne Port kein Prozess, ein
  # belegter Port ist kein Startfehler.
  use ExUnit.Case, async: true

  alias Worker.Jack.Sicht

  test "ohne Port startet keine Laufsicht" do
    assert Sicht.betrieb(nil) == :ignore
  end

  test "ein belegter Port ist eine Warnung, kein Fehler" do
    # Wie der Supervisor im Worker: der gescheiterte Start schickt dem
    # verlinkten Aufrufer ein Exit-Signal.
    Process.flag(:trap_exit, true)
    {:ok, erste} = Sicht.start_link(port: 0)
    port = Sicht.port(erste)

    assert Sicht.betrieb(port, name: :sicht_betrieb_test) == :ignore
    assert Process.whereis(:sicht_betrieb_test) == nil

    GenServer.stop(erste)
  end

  test "mit freiem Port läuft sie unter ihrem Namen" do
    assert {:ok, pid} = Sicht.betrieb(0, name: :sicht_betrieb_frei)
    assert Process.whereis(:sicht_betrieb_frei) == pid
    GenServer.stop(pid)
  end
end
