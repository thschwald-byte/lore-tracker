defmodule Worker.Jack.SichtFolgenTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.Sicht

  @moduletag :tmp_dir

  defp zeile(d), do: Jason.encode!(Map.put_new(d, "t", "2026-09-10T15:00:00Z")) <> "\n"

  defp runden(sicht) do
    for %{"was" => "runde", "text" => t} <- Sicht.zustand(sicht)["konsole"], do: t
  end

  defp warten_bis(bedingung, versuche \\ 200) do
    cond do
      bedingung.() -> :ok
      versuche == 0 -> flunk("Bedingung nicht erreicht")
      true -> Process.sleep(10) && warten_bis(bedingung, versuche - 1)
    end
  end

  # Aufbau wie ein Messlauf: d1/phase1/ ist Phase 1, d1/ selbst Phase 2.
  test "folgt dem jüngsten Protokoll: nur ganze Zeilen, der Stand daneben, die nächste Phase löst ab",
       %{tmp_dir: dir} do
    p1 = Path.join([dir, "d1", "phase1", "protokoll.jsonl"])
    File.mkdir_p!(Path.dirname(p1))

    File.write!(
      p1,
      zeile(%{"ereignis" => "start", "modell_name" => "m", "werkzeuge" => ["lesen"]}) <>
        zeile(%{"ereignis" => "anfrage", "runde" => 1}) <> ~s({"ereignis":"anfr)
    )

    File.write!(Path.join(Path.dirname(p1), "stand.json"), Jason.encode!(%{"bestand" => 3}))
    File.touch!(p1, System.os_time(:second) - 10)

    {:ok, sicht} = Sicht.start_link(port: 0, folgen: dir, folgen_ms: 20)
    warten_bis(fn -> runden(sicht) == ["── Runde 1 ──"] end)
    assert %{"bestand" => 3} = Sicht.zustand(sicht)["stand"]

    # Der Lauf schreibt die halbe Zeile zu Ende.
    File.write!(p1, ~s(age","runde":2}\n), [:append])
    File.touch!(p1, System.os_time(:second) - 10)
    warten_bis(fn -> runden(sicht) == ["── Runde 1 ──", "── Runde 2 ──"] end)

    # Die nächste Phase: ein jüngeres Protokoll, noch ohne eigenen Stand.
    File.write!(
      Path.join([dir, "d1", "protokoll.jsonl"]),
      zeile(%{"ereignis" => "anfrage", "runde" => 1})
    )

    warten_bis(fn -> runden(sicht) == ["── Runde 1 ──", "── Runde 2 ──", "── Runde 1 ──"] end)
    assert Sicht.zustand(sicht)["stand"] == nil

    url = "http://127.0.0.1:#{Sicht.port(sicht)}"
    assert %{status: 200, body: html} = Req.get!(url <> "/", retry: false)
    assert html =~ "id=konsole"
  end
end
