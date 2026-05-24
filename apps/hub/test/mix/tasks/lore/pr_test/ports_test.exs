defmodule Mix.Tasks.Lore.PrTest.PortsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.PrTest.Ports

  describe "port_free?/2" do
    test "true wenn Port nicht in occupied-Liste UND nicht lokal in Listen-Mode" do
      # Wir picken einen sehr hohen Port — sehr unwahrscheinlich dass der
      # gerade gebunden ist auf der Test-Maschine.
      assert Ports.port_free?(54321, [])
    end

    test "false wenn Port in occupied-Liste" do
      refute Ports.port_free?(4001, [4001])
    end
  end
end
