defmodule Worker.Agent.WiederholungTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Wiederholung

  # Spielt eine Folge von Aufrufschlüsseln durch und liefert, bei welchem
  # Aufruf (1-basiert) mit welcher Wiederholungsnummer gewarnt wurde.
  defp warnungen(folge, schwelle \\ 3) do
    {_, warn} =
      folge
      |> Enum.with_index(1)
      |> Enum.reduce({Wiederholung.neu(schwelle), []}, fn {k, i}, {w, acc} ->
        case Wiederholung.beobachten(w, k) do
          {w, nil} -> {w, acc}
          {w, n} -> {w, acc ++ [{i, n}]}
        end
      end)

    warn
  end

  defp aufruf(name, x), do: {name, {:ok, %{"x" => x}}}

  test "drei Wiederholungen: gewarnt beim vierten gleichen Aufruf und jedem weiteren" do
    assert warnungen(List.duplicate(aufruf("suche", "a"), 5)) == [{4, 3}, {5, 4}]
  end

  test "Schleife über mehrere Werkzeuge: 1 → 2 → 3 → von vorn" do
    zyklus = [aufruf("werkzeug1", "a"), aufruf("werkzeug2", "b"), aufruf("werkzeug3", "c")]
    folge = zyklus |> List.duplicate(4) |> List.flatten()
    assert warnungen(folge) == [{10, 3}, {11, 3}, {12, 3}]
  end

  test "gezählt wird über den ganzen Lauf, auch mit viel Anderem dazwischen" do
    a = aufruf("suche", "a")
    anderes = fn start -> for i <- start..(start + 49), do: aufruf("bloecke", "#{i}") end
    folge = [a] ++ anderes.(0) ++ [a] ++ anderes.(100) ++ [a, a]
    assert warnungen(folge) == [{length(folge), 3}]
  end

  test "andere Argumente sind ein anderer Aufruf" do
    assert warnungen(for x <- ~w(a b c d e), do: aufruf("suche", x)) == []
  end

  test "gleiche Argumente an ein anderes Werkzeug sind ein anderer Aufruf" do
    folge = for name <- ~w(a b c d), do: aufruf(name, "x")
    assert warnungen(folge) == []
  end

  test "kaputte Argumente werden am Rohtext wiedererkannt" do
    assert warnungen(List.duplicate({"aussage", {:error, "{kaputt"}}, 4)) == [{4, 3}]
  end

  test "die Schwelle ist einstellbar, false schaltet ab" do
    assert warnungen(List.duplicate(aufruf("suche", "a"), 2), 1) == [{2, 1}]
    assert Wiederholung.neu(false) == nil
    assert Wiederholung.beobachten(nil, :k) == {nil, nil}
  end

  test "die Warnung nennt Werkzeug, Zahl und was zu tun ist" do
    text = Wiederholung.warnung("suche", 3)
    assert text =~ "suche"
    assert text =~ "zum 4. Mal"
    assert text =~ "Lass diesen Punkt liegen und mach mit dem nächsten weiter."
  end
end
