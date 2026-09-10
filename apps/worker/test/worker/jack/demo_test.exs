defmodule Worker.Jack.DemoTest do
  # Die Demo der Laufsicht ohne Pausen: ihre Aussagen müssen gegen die
  # Werkzeuge gültig bleiben, sonst zeigt `mix lore.jack.demo` Ablehnungen,
  # wo keine gemeint sind.
  use ExUnit.Case, async: true

  alias Worker.Jack.{Demo, Sicht}

  @tag :tmp_dir
  test "beide Phasen enden mit fertig; vier Aussagen, eine Vorlage (zählt als Ablehnung)", %{
    tmp_dir: dir
  } do
    {:ok, sicht} = Sicht.start_link(port: 0)
    assert Sicht.seiten(sicht) == 0

    e = Demo.laufen(sicht: sicht, ablage: dir, tempo: 0)
    assert {:ok, %{ende: :halt}} = e.phase1
    assert {:ok, %{ende: :halt}} = e.phase2

    s = dir |> Path.join("phase2/stand.json") |> File.read!() |> Jason.decode!()
    assert %{"bestand" => 4, "abgelehnt" => 1, "journal" => %{"dubletten.jsonl" => 1}} = s

    # fünf Aufrufe: vier eingetragen, einer als Vorlage zurückgewiesen
    assert %{"lauf" => %{"ende" => "halt", "werkzeuge" => %{"aussage" => 5}}} =
             Sicht.zustand(sicht)
  end
end
