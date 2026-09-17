defmodule Worker.Jack.Sicht.LageKonsoleTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.Sicht.Lage

  @t "2026-09-10T15:00:00Z"

  defp ev(l, ereignis, daten),
    do: Lage.ereignis(l, Map.merge(%{"ereignis" => ereignis, "t" => @t}, daten))

  defp teile(l), do: for(t <- Lage.zustand(l)["konsole"], do: {t["was"], t["text"]})

  defp gestartet do
    {l, _} =
      ev(Lage.neu(), "start", %{
        "modell_name" => "m",
        "werkzeuge" => ["lesen"],
        "kontext_fenster" => 1000
      })

    l
  end

  defp antwort(l, denken, text, aufrufe \\ []) do
    ev(l, "antwort", %{
      "runde" => 1,
      "ms" => 5,
      "stopp" => "werkzeuge",
      "denken" => denken,
      "text" => text,
      "aufrufe" => aufrufe
    })
  end

  test "live: Deltas füllen die Konsole, die Antwort wiederholt sie nicht, eine neue Runde leert nichts" do
    {l, [%{"konsole" => [%{"was" => "runde", "text" => "── Runde 1 ──"}]}]} =
      ev(gestartet(), "anfrage", %{"runde" => 1})

    {l, _} = ev(l, "delta", %{"art" => "denken", "text" => "Ich "})
    {l, _} = ev(l, "delta", %{"art" => "denken", "text" => "lese."})
    {l, _} = ev(l, "delta", %{"art" => "text", "text" => "Los."})

    aufruf = %{"id" => "a", "name" => "lesen", "argumente" => %{"von" => 0}}
    {l, [%{"konsole" => [%{"was" => "ruft"}]}]} = antwort(l, "Ich lese.", "Los.", [aufruf])
    {l, _} = ev(l, "anfrage", %{"runde" => 2})

    assert [
             {"lauf", _},
             {"runde", "── Runde 1 ──"},
             {"denken", "Ich lese."},
             {"text", "Los."},
             {"ruft", "→ " <> _},
             {"runde", "── Runde 2 ──"}
           ] = teile(l)
  end

  test "aus der Datei, ohne Deltas, kommen Denken und Text mit der Antwort" do
    {l, _} = ev(gestartet(), "anfrage", %{"runde" => 1})
    {_l, [%{"konsole" => neu}]} = antwort(l, "Hm.", nil)
    assert [%{"was" => "denken", "text" => "Hm."}] = neu
  end

  test "Fehler, Hinweise und das Ende stehen als eigene Zeilen" do
    {l, _} = ev(gestartet(), "modell_fehler", %{"grund" => "timeout"})
    {l, _} = ev(l, "kompaktierung", %{"weggefallen" => 12, "tokens" => 90_000})
    {l, _} = ev(l, "ende", %{"ende" => ":halt", "runden" => 3})

    assert [
             {"lauf", _},
             {"fehler", "✗ Modell: timeout"},
             {"hinweis", "Kompaktiert — 12 Nachrichten zusammengefasst (bei 90000 Token)"},
             {"ende", "══ Lauf beendet: halt nach 3 Runden ══"}
           ] = teile(l)
  end

  test "ein Neuversuch steht als Hinweis in der Konsole" do
    {l, _} =
      ev(gestartet(), "neuversuch", %{
        "runde" => 1,
        "versuch" => 1,
        "von" => 3,
        "warte_ms" => 2000,
        "grund" => ~s({:netz, "weg"})
      })

    assert {"hinweis", ~s(Neuversuch 1/3 in 2 s — Modell: {:netz, "weg"})} = List.last(teile(l))
  end

  test "jede Nachricht trägt die nächste Nummer, der Zustand die zuletzt vergebene" do
    {l, [%{"n" => 1}]} =
      ev(Lage.neu(), "start", %{"modell_name" => "m", "werkzeuge" => [], "kontext_fenster" => 1})

    {l, [%{"art" => "delta", "n" => 2}]} = ev(l, "delta", %{"art" => "text", "text" => "x"})
    {l, nachrichten} = Lage.stand(l, %{"bestand" => 1})

    assert [_ | _] = nachrichten
    assert Enum.all?(nachrichten, &(&1["n"] == 3))
    assert Lage.zustand(l)["n"] == 3
  end

  test "die Konsole wird vorn gekürzt, der neueste Abschnitt bleibt" do
    gross = String.duplicate("a", 50_000)

    l =
      Enum.reduce(1..5, gestartet(), fn i, l ->
        art = if rem(i, 2) == 0, do: "text", else: "denken"
        {l, _} = ev(l, "delta", %{"art" => art, "text" => gross <> "#{i}"})
        l
      end)

    konsole = Lage.zustand(l)["konsole"]

    assert konsole |> Enum.map(&byte_size(&1["text"])) |> Enum.sum() <= 150_000
    assert List.last(konsole)["text"] =~ ~r/5$/
    refute Enum.any?(konsole, &(&1["was"] == "lauf"))
  end
end
