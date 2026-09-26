defmodule Worker.Jack.Frage.GespraechTest do
  @moduledoc """
  Issue #850: der Halter der Chat-Verläufe. Kein Mnesia, kein Modell — der
  Prozess hält nur Verläufe und räumt sie weg.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Frage.Gespraech

  defp halter do
    {:ok, pid} = start_supervised({Gespraech, []}, id: {Gespraech, make_ref()})
    pid
  end

  defp stand(text), do: %{auftrag: "Auftrag", verlauf: [%{role: :user, content: text}]}

  test "merken und holen" do
    h = halter()
    assert Gespraech.holen("g1", h) == nil

    Gespraech.merken("g1", stand("eins"), h)
    assert %{auftrag: "Auftrag", verlauf: [%{content: "eins"}]} = Gespraech.holen("g1", h)
  end

  test "nil als ID ist kein Gespräch — und kein Fehler" do
    h = halter()

    # Der Modus „Frage" führt keins. Der Aufrufer soll nicht unterscheiden
    # müssen; täte er es, wäre die eine vergessene Stelle ein stiller
    # Absturz mitten im Lauf.
    assert Gespraech.holen(nil, h) == nil
    assert Gespraech.merken(nil, stand("x"), h) == :ok
    assert Gespraech.verwerfen(nil, h) == :ok
    assert Gespraech.anzahl(h) == 0
  end

  test "verwerfen entfernt, unbekannte IDs sind kein Fehler" do
    h = halter()
    Gespraech.merken("g1", stand("eins"), h)
    Gespraech.verwerfen("g1", h)
    assert Gespraech.holen("g1", h) == nil
    assert Gespraech.verwerfen("gibtsnicht", h) == :ok
  end

  test "der Deckel verdrängt das ÄLTESTE, nicht irgendeins" do
    h = halter()

    # Ein zufälliges Opfer träfe gerade das, an dem jemand arbeitet.
    for i <- 1..Gespraech.max_gespraeche() do
      Gespraech.merken("g#{i}", stand("nr #{i}"), h)
      # Die Zeit ist monoton in Millisekunden; ohne Abstand hätten zwei
      # Einträge denselben Stempel und „das älteste" wäre Zufall.
      Process.sleep(2)
    end

    assert Gespraech.anzahl(h) == Gespraech.max_gespraeche()

    Gespraech.merken("neu", stand("neu"), h)

    assert Gespraech.anzahl(h) == Gespraech.max_gespraeche()
    assert Gespraech.holen("g1", h) == nil, "das älteste hätte weichen müssen"
    assert Gespraech.holen("neu", h) != nil
  end

  test "ein bestehendes Gespräch fortzuschreiben verdrängt niemanden" do
    h = halter()

    for i <- 1..Gespraech.max_gespraeche() do
      Gespraech.merken("g#{i}", stand("nr #{i}"), h)
      Process.sleep(2)
    end

    Gespraech.merken("g1", stand("neuer Stand"), h)

    assert Gespraech.anzahl(h) == Gespraech.max_gespraeche()
    assert %{verlauf: [%{content: "neuer Stand"}]} = Gespraech.holen("g1", h)
  end

  test "das Holen hält am Leben" do
    h = halter()
    Gespraech.merken("g1", stand("eins"), h)
    Process.sleep(5)
    Gespraech.holen("g1", h)

    # Verfallen soll, was niemand mehr fortsetzt — nicht, was lange dauert.
    # Geprüft am Zeitstempel im Zustand, weil die echte Frist 30 Minuten ist.
    zustand = :sys.get_state(h)
    assert %{"g1" => %{ts: ts}} = zustand
    assert ts >= System.monotonic_time(:millisecond) - 5
  end

  test "der Sweep wirft Verfallenes weg" do
    h = halter()
    Gespraech.merken("frisch", stand("a"), h)

    # Einen alten Eintrag unterschieben, statt eine halbe Stunde zu warten.
    :sys.replace_state(h, fn s ->
      Map.put(s, "alt", %{
        stand: stand("b"),
        ts: System.monotonic_time(:millisecond) - 10 * Gespraech.ttl_ms()
      })
    end)

    send(h, :sweep)
    _ = :sys.get_state(h)

    assert Gespraech.holen("alt", h) == nil
    assert Gespraech.holen("frisch", h) != nil
  end
end
