defmodule Worker.Jack.ProbierenTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Probieren, Stand}

  @claim "Die Gruppe trifft den Schieber im Hinterzimmer."

  defp verify(hinweis \\ "Du hast eine mögliche Übereinstimmung gefunden — verifiziere."),
    do: {:error, %{"outcome" => "verify", "hinweis" => hinweis}}

  # n Einreichungen mit Antwort verify; liefert Zustand, Stand und die Hinweise.
  defp serie(p, s, n) do
    Enum.reduce(1..n, {p, s, []}, fn _, {p, s, hinweise} ->
      {p, s, {_, a}} = Probieren.nachsehen(p, s, "aussage", %{"claim" => @claim}, verify())
      {p, s, hinweise ++ [a["hinweis"]]}
    end)
  end

  defp probieren(s), do: for({"probieren.jsonl", e} <- Stand.journal_liste(s), do: e)

  test "Abfrageserie: Hinweis bei der 10., dann bei jeder 5., vorn im hinweis" do
    s = Stand.neu(phase: 2)
    {p, s, hinweise} = serie(Probieren.neu(), s, 15)

    mit = for {h, i} <- Enum.with_index(hinweise, 1), h =~ "Einreichungen standen", do: i
    assert mit == [10, 15]

    assert Enum.at(hinweise, 9) ==
             "Deine letzten 10 Einreichungen standen alle schon im Bestand. aussage() ist zum " <>
               "Eintragen da, nicht zum Nachsehen. Geh die Blöcke weiter der Reihe nach durch " <>
               "und trag ein, was du dort findest.\n\n" <>
               "Du hast eine mögliche Übereinstimmung gefunden — verifiziere."

    assert p.serie == 15

    assert probieren(s) == [
             %{"art" => "abfrageserie", "n" => 10, "phase" => 2},
             %{"art" => "abfrageserie", "n" => 15, "phase" => 2}
           ]
  end

  test "eine Eintragung oder eine Entscheidung setzt die Serie zurück, fix nicht" do
    s = Stand.neu(phase: 2)
    {p, s, _} = serie(Probieren.neu(), s, 9)

    {p, _s, _} =
      Probieren.nachsehen(p, s, "aussage", %{}, {:error, %{"outcome" => "fix", "hinweis" => ""}})

    assert p.serie == 9

    for {name, outcome} <- [
          {"aussage", "written"},
          {"aussage", "modify"},
          {"aussage_entscheiden", "verify"}
        ] do
      {q, _, _} = Probieren.nachsehen(p, s, name, %{}, {:ok, %{"outcome" => outcome}})
      assert q.serie == 0, "#{name}/#{outcome}"
    end
  end

  test "im Verifizierungsdurchgang kein Serien-Hinweis, gezählt wird trotzdem" do
    {p, s, hinweise} = serie(Probieren.neu(), Stand.neu(phase: 2, durchgang: 2), 15)
    refute Enum.any?(hinweise, &(&1 =~ "Einreichungen standen"))
    assert p.serie == 15
    assert probieren(s) == []
  end

  test "suche mit Aussagesatz: ab sechs Wörtern, oder wie eine eingereichte Aussage" do
    s = Stand.neu(phase: 2)
    p = Probieren.neu()

    {p, s, {:ok, text}} =
      Probieren.nachsehen(
        p,
        s,
        "suche",
        %{"begriff" => "der Schieber sitzt im Hinterzimmer fest"},
        {:ok, "3 Fundstelle(n):"}
      )

    assert text ==
             "HINWEIS: suche() durchsucht nur den Mitschnitt, nicht den Bestand — ob etwas schon " <>
               "eingetragen ist, kannst du damit nicht prüfen. Trag ein, was du im Mitschnitt " <>
               "findest; steht es schon da, zeigt dir aussage() das beim Eintragen.\n\n" <>
               "3 Fundstelle(n):"

    # kurz, aber Teil einer eingereichten Aussage (mind. 20 Zeichen, Leerraum egal)
    {p, s, _} = Probieren.nachsehen(p, s, "aussage", %{"claim" => @claim}, verify())

    {p, s, {:ok, text}} =
      Probieren.nachsehen(
        p,
        s,
        "suche",
        %{"begriff" => "den  SCHIEBER im Hinterzimmer"},
        {:ok, "x"}
      )

    assert text =~ ~r/^HINWEIS: /

    # ein gewöhnlicher Suchbegriff bleibt unberührt
    assert {_, _, {:ok, "x"}} =
             Probieren.nachsehen(p, s, "suche", %{"begriff" => "Schieber"}, {:ok, "x"})

    assert [
             %{"art" => "suche_mit_aussagesatz", "grund" => "lang", "phase" => 2},
             %{"art" => "suche_mit_aussagesatz", "grund" => "wie_eingereichte_aussage"}
           ] = probieren(s)
  end

  test "kurze Aussagen werden nicht gemerkt; andere Werkzeuge gehen unverändert durch" do
    s = Stand.neu(phase: 2)

    {p, s, _} =
      Probieren.nachsehen(Probieren.neu(), s, "aussage", %{"claim" => "Kurz."}, verify())

    assert p.eingereicht == []

    assert {^p, ^s, {:ok, "unverändert"}} =
             Probieren.nachsehen(p, s, "block", %{"nr" => 3}, {:ok, "unverändert"})

    assert {^p, ^s, {:error, "kaputt"}} = Probieren.nachsehen(p, s, nil, %{}, {:error, "kaputt"})
  end
end
