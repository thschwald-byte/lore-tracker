defmodule Worker.Agent.NeuversuchTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Neuversuch

  test "Vorgabe wie pi: drei Neuversuche, 2, 4 und 8 Sekunden" do
    {:ok, n} = Neuversuch.neu([])

    assert n.versuche == 3
    assert Enum.map(1..3, &Neuversuch.wartezeit(n, &1)) == [2000, 4000, 8000]
    assert Neuversuch.nochmal?(n, {:netz, "weg"}, 3)
    refute Neuversuch.nochmal?(n, {:netz, "weg"}, 4)
    refute Neuversuch.nochmal?(nil, {:netz, "weg"}, 1)
  end

  test "wiederholbar: abgebrochener Strom, Transport, 500/502/503/504, Stromfehler nach pis Mustern" do
    assert Neuversuch.wiederholbar?({:strom_unvollstaendig, "data: …"})
    assert Neuversuch.wiederholbar?({:netz, "socket closed"})
    for s <- [500, 502, 503, 504], do: assert(Neuversuch.wiederholbar?({:http, s, ""}))
    assert Neuversuch.wiederholbar?({:strom, "connection error"})
    assert Neuversuch.wiederholbar?({:strom, %{"message" => "request timeout"}})
  end

  test "nicht wiederholbar: Client-Fehler, Antwortform, Stoppgrund, fremde Stromfehler, Ausnahmen" do
    for grund <- [
          {:http, 400, ""},
          {:http, 501, ""},
          {:antwortform, %{}},
          {:stoppgrund, "content_filter"},
          {:strom, "model not found"},
          {:ausnahme, "kaputt"},
          :kaputt
        ],
        do: refute(Neuversuch.wiederholbar?(grund), inspect(grund))
  end

  test "ungültige Angaben sind Fehler" do
    assert {:error, _} = Neuversuch.neu(versuche: -1)
    assert {:error, _} = Neuversuch.neu(basis_ms: 1.5)
    assert {:error, _} = Neuversuch.neu(anders: 1)
  end
end
