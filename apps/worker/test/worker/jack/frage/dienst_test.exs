defmodule Worker.Jack.Frage.DienstTest do
  @moduledoc """
  Issue #850: Start, Abbruch und die Absage bei belegter Karte.

  Der Abbruch beendet den **Task**, nicht erst den nächsten Rundenwechsel: Er
  hält den `Req.post` an Ollama, und eine Frist „bis zum Ende des laufenden
  Aufrufs" liesse die Karte bei einem 27b-Modell auf 200 Fakten noch Dutzende
  Sekunden belegt — für niemanden.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Jack.Frage.Dienst

  setup do
    ensure_started(Worker.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Worker.TaskSupervisor)
    end)

    ensure_started(Dienst.registry(), fn ->
      Registry.start_link(keys: :unique, name: Dienst.registry())
    end)

    :ok
  end

  defp lauf_id, do: "lauf-#{System.unique_integer([:positive])}"

  describe "abbrechen/1" do
    test "auf einen unbekannten Lauf ist kein Fehler" do
      # Ein Abbruch auf etwas längst Beendetes darf nicht knallen: Der
      # Betrachter drückt ihn, wenn die Antwort gerade eintrifft.
      assert Dienst.abbrechen(lauf_id()) == :ok
    end

    test "beendet einen laufenden Task und gibt die ID wieder frei" do
      id = lauf_id()
      parent = self()

      {:ok, _} =
        Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
          {:ok, _} = Registry.register(Dienst.registry(), id, :frage)
          send(parent, :registriert)
          Process.sleep(60_000)
        end)

      assert_receive :registriert, 1000
      assert Dienst.laeuft?(id)

      assert Dienst.abbrechen(id) == :ok

      # Die Registry gibt den Eintrag mit dem Prozess frei.
      warte_bis(fn -> not Dienst.laeuft?(id) end)
      refute Dienst.laeuft?(id)
    end
  end

  describe "laeuft?/1" do
    test "false für eine unbekannte ID" do
      refute Dienst.laeuft?(lauf_id())
    end
  end

  describe "dieselbe Lauf-ID zweimal" do
    test "der zweite Lauf meldet :laeuft_schon statt zu starten" do
      id = lauf_id()
      parent = self()

      {:ok, _} =
        Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
          {:ok, _} = Registry.register(Dienst.registry(), id, :frage)
          send(parent, :registriert)
          Process.sleep(60_000)
        end)

      assert_receive :registriert, 1000

      {:ok, _} = Dienst.starten(id, "cid", "Wer?", &send(parent, &1))

      assert_receive {:frage_fehler, ^id, :laeuft_schon}, 1000

      Dienst.abbrechen(id)
    end
  end

  defp warte_bis(pruefung, versuche \\ 50) do
    cond do
      pruefung.() -> :ok
      versuche == 0 -> :aufgegeben
      true -> Process.sleep(10) && warte_bis(pruefung, versuche - 1)
    end
  end
end
