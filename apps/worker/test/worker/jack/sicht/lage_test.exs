defmodule Worker.Jack.Sicht.LageTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.Sicht.Lage

  @t "2026-09-10T15:00:00Z"

  defp ev(l, ereignis, daten \\ %{}),
    do: Lage.ereignis(l, Map.merge(%{"ereignis" => ereignis, "t" => @t}, daten))

  test "ein Lauf von start bis ende" do
    {l, _} = Lage.stand(Lage.neu(), %{"bestand" => 7})

    {l, [%{"art" => "lauf", "neue_runde" => false}]} =
      ev(l, "start", %{
        "modell_name" => "qwen",
        "werkzeuge" => ["bloecke", "fertig"],
        "kontext_fenster" => 1000
      })

    assert %{"bestand_start" => 7, "modell" => "qwen", "werkzeug_liste" => ["bloecke", "fertig"]} =
             l.lauf

    {l, [%{"neue_runde" => true}]} = ev(l, "anfrage", %{"runde" => 1})
    assert l.lauf["wartet_seit"] == @t

    {l, [%{"art" => "delta", "was" => "denken", "text" => "Ich "}]} =
      ev(l, "delta", %{"art" => "denken", "text" => "Ich "})

    {l, _} = ev(l, "delta", %{"art" => "denken", "text" => "lese."})

    {l, _} =
      ev(l, "antwort", %{
        "runde" => 1,
        "ms" => 900,
        "stopp" => "werkzeuge",
        "denken" => "Ich lese.",
        "text" => nil,
        "aufrufe" => [
          %{"id" => "a", "name" => "bloecke", "argumente" => %{"von" => 0, "bis" => 9}}
        ],
        "nutzung" => %{eingabe: 250, ausgabe: 40}
      })

    assert l.denkt == "Ich lese."

    assert %{"runden" => 1, "wartet_seit" => nil, "kontext_jetzt" => 250, "kontext_prozent" => 25} =
             l.lauf

    assert [%{"runde" => 1, "eingabe" => 250, "ausgabe" => 40, "aufrufe" => ["bloecke"]}] =
             l.lauf["letzte"]

    assert Enum.map(l.spur, & &1["was"]) == ~w(start denkt ruft)
    assert List.last(l.spur)["text"] == "bloecke(bis=9, von=0)"

    {l, _} = ev(l, "ergebnis", %{"name" => "bloecke", "art" => "ok", "text" => "0\tX\tText"})
    {l, _} = ev(l, "ergebnis", %{"name" => "fertig", "art" => "error", "text" => "offen"})
    {l, _} = ev(l, "wiederholung", %{"name" => "suche", "folge" => "warnung", "anzahl" => 4})
    {l, _} = ev(l, "kompaktierung", %{"weggefallen" => 0, "tokens" => 10})
    {l, _} = ev(l, "kompaktierung", %{"weggefallen" => 12, "tokens" => 900})

    {l, _} =
      ev(l, "antwort", %{
        "runde" => 2,
        "stopp" => "laenge",
        "aufrufe" => [%{"id" => "b", "name" => "notiz", "roh" => "{kaputt"}],
        "nutzung" => %{"eingabe" => 400, "ausgabe" => 5}
      })

    {l, _} = ev(l, "ende", %{"ende" => ":halt", "runden" => 2})

    assert %{
             "werkzeuge" => %{"bloecke" => 1, "fertig" => 1},
             "fehler" => 1,
             "wiederholungen" => 1,
             "kompaktierungen" => 1,
             "am_deckel" => 1,
             "ende" => "halt",
             "kontext_jetzt" => 400
           } = l.lauf

    assert Enum.find(l.spur, &(&1["text"] == "notiz({kaputt)"))

    assert List.last(l.spur) == %{
             "was" => "ende",
             "text" => "Lauf beendet: halt nach 2 Runden",
             "t" => @t
           }
  end

  test "eine neue Anfrage leert den Denkraum; ohne Deltas steht der Gedanke aus der Antwort" do
    {l, _} = ev(Lage.neu(), "delta", %{"art" => "text", "text" => "alt"})
    {l, _} = ev(l, "anfrage")
    assert {l.denkt, l.schreibt} == {"", ""}

    {l, _} = ev(l, "antwort", %{"denken" => "Aus der Datei.", "text" => "Gut.", "aufrufe" => []})
    assert {l.denkt, l.schreibt} == {"Aus der Datei.", "Gut."}
  end

  test "der Denkraum wird vorn gekürzt, ohne ein Zeichen zu zerschneiden" do
    {l, _} =
      ev(Lage.neu(), "delta", %{"art" => "denken", "text" => String.duplicate("ä", 40_000)})

    assert byte_size(l.denkt) <= 60_000
    assert String.valid?(l.denkt)
    assert Jason.encode!(Lage.zustand(l))
  end

  test "kommt der Stand erst nach dem Start, füllt er den Ausgangsbestand nach" do
    {l, _} = ev(Lage.neu(), "start", %{"werkzeuge" => []})
    assert l.lauf["bestand_start"] == nil

    {l, [%{"art" => "stand"}, %{"art" => "lauf"}]} = Lage.stand(l, %{"bestand" => 3})
    assert l.lauf["bestand_start"] == 3

    {_, [%{"art" => "stand"}]} = Lage.stand(l, %{"bestand" => 4})
  end
end
