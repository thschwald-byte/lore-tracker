defmodule Worker.Agent.WiederholungTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Wiederholung

  # Spielt eine Folge von Aufrufschlüsseln durch und liefert, bei welchem
  # Aufruf (1-basiert) welcher Status kam.
  defp status_folge(folge, opts \\ []) do
    {:ok, w} = Wiederholung.neu(opts)

    {_, acc} =
      folge
      |> Enum.with_index(1)
      |> Enum.reduce({w, []}, fn {k, i}, {w, acc} ->
        case Wiederholung.beobachten(w, k) do
          {w, nil} -> {w, acc}
          {w, status} -> {w, acc ++ [{i, status}]}
        end
      end)

    acc
  end

  defp aufruf(name, x), do: {name, {:ok, %{"x" => x}}}

  test "Default: Warnung beim 4. und 5. gleichen Aufruf, Abbruch beim 6." do
    assert status_folge(List.duplicate(aufruf("suche", "a"), 6)) == [
             {4, {:warnung, 4}},
             {5, {:warnung, 5}},
             {6, {:abbruch, 6}}
           ]
  end

  test "Schleife über mehrere Werkzeuge: 1 → 2 → 3 → von vorn" do
    zyklus = [aufruf("werkzeug1", "a"), aufruf("werkzeug2", "b"), aufruf("werkzeug3", "c")]
    folge = zyklus |> List.duplicate(4) |> List.flatten()

    assert status_folge(folge) == [
             {10, {:warnung, 4}},
             {11, {:warnung, 4}},
             {12, {:warnung, 4}}
           ]
  end

  test "gezählt wird über den ganzen Lauf, auch mit viel Anderem dazwischen" do
    a = aufruf("suche", "a")
    anderes = fn start -> for i <- start..(start + 49), do: aufruf("bloecke", "#{i}") end
    folge = [a] ++ anderes.(0) ++ [a] ++ anderes.(100) ++ [a, a]
    assert status_folge(folge) == [{length(folge), {:warnung, 4}}]
  end

  test "andere Argumente oder ein anderes Werkzeug sind ein anderer Aufruf" do
    assert status_folge(for x <- ~w(a b c d e f), do: aufruf("suche", x)) == []
    assert status_folge(for name <- ~w(a b c d e f), do: aufruf(name, "x")) == []
  end

  test "kaputte Argumente werden am Rohtext wiedererkannt" do
    assert status_folge(List.duplicate({"aussage", {:error, "{kaputt"}}, 4)) == [
             {4, {:warnung, 4}}
           ]
  end

  test "die Schwellen sind einstellbar" do
    folge = List.duplicate(aufruf("suche", "a"), 4)

    assert status_folge(folge, warnung: 3, abbruch: 4) == [
             {3, {:warnung, 3}},
             {4, {:abbruch, 4}}
           ]
  end

  test "eine Bestandsänderung setzt nur die :bis_aenderung-Aufrufe zurück" do
    {:ok, w} = Wiederholung.neu([])
    lesen = {"aussagen", {:ok, %{"von" => 0}}}
    suchen = {"suche", {:ok, %{"begriff" => "x"}}}

    w =
      Enum.reduce(1..3, w, fn _, w ->
        {w, nil} = Wiederholung.beobachten(w, lesen, :bis_aenderung)
        {w, nil} = Wiederholung.beobachten(w, suchen, :zaehlt)
        w
      end)

    w = Wiederholung.bestand_geaendert(w)
    assert {w, nil} = Wiederholung.beobachten(w, lesen, :bis_aenderung)
    assert {_, {:warnung, 4}} = Wiederholung.beobachten(w, suchen, :zaehlt)
  end

  test "unsinnige Schwellen werden abgelehnt, nil ist die abgeschaltete Sperre" do
    assert {:error, _} = Wiederholung.neu(warnung: 1)
    assert {:error, _} = Wiederholung.neu(warnung: 4, abbruch: 4)
    assert {:error, _} = Wiederholung.neu(warnung: "4")
    assert Wiederholung.beobachten(nil, :k) == {nil, nil}
    assert Wiederholung.bestand_geaendert(nil) == nil
  end

  test "Warnung und Abbruch im Wortlaut des Spikes, mit dem Aufruf in Kurzform" do
    a = Wiederholung.kurz_aufruf("suche", %{"begriff" => "Tür", "ab" => 3})
    assert a == ~s|suche({"ab":3,"begriff":"Tür"})|

    assert Wiederholung.texte(:warnung, a, 4, 6) ==
             {~s|Du wiederholst dich: suche({"ab":3,"begriff":"Tür"}) ist dein 4. gleicher | <>
                "Aufruf in diesem Lauf. Er wird nicht ausgeführt — das Ergebnis wäre dasselbe " <>
                "wie vorher.",
              "Verfolge diese Sache nicht weiter und mach mit der nächsten weiter. Rufst du " <>
                "genau diesen Aufruf ein 6. Mal auf, wird der Lauf abgebrochen."}

    {_, fuenfte} = Wiederholung.texte(:warnung, a, 5, 6)
    assert String.ends_with?(fuenfte, "abgebrochen — das wäre der nächste.")

    assert Wiederholung.texte(:abbruch, a, 6, 6) ==
             {~s|Das ist dein 6. gleicher Aufruf: suche({"ab":3,"begriff":"Tür"}). | <>
                "Der Lauf wird jetzt abgebrochen.", "Lauf abgebrochen wegen Wiederholung."}

    assert Wiederholung.text({"F", "H"}) == "WIEDERHOLUNG — F H"
  end

  test "kanon sortiert Schlüssel auf jeder Ebene; lange Aufrufe werden gekürzt" do
    assert Wiederholung.kanon(%{"b" => [%{"z" => 1, "a" => nil}], "a" => "x"}) ==
             ~s|{"a":"x","b":[{"a":null,"z":1}]}|

    lang = Wiederholung.kurz_aufruf("notiz", %{"zeile" => String.duplicate("a", 200)})
    assert String.length(lang) == String.length("notiz()") + 138
    assert String.ends_with?(lang, "…)")
  end
end
