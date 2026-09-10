defmodule Worker.Jack.SichtTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Halter, Sicht, Stand, Werkzeuge}

  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    # Streamt, wenn die Laufzeit bei_delta mitgibt — wie Ollama mit Beobachter.
    @impl true
    def antworten(_nachrichten, _werkzeuge, opts) do
      if melden = opts[:bei_delta], do: melden.(:denken, "Ich lese zuerst.")

      {:ok,
       Agent.get_and_update(Keyword.fetch!(opts, :skript), fn [kopf | rest] -> {kopf, rest} end)}
    end
  end

  defp starten(opts \\ []) do
    {:ok, sicht} = Sicht.start_link(Keyword.put_new(opts, :port, 0))
    {sicht, "http://127.0.0.1:#{Sicht.port(sicht)}"}
  end

  defp warten_bis(bedingung, versuche \\ 100) do
    cond do
      bedingung.() -> :ok
      versuche == 0 -> flunk("Bedingung nicht erreicht")
      true -> Process.sleep(10) && warten_bis(bedingung, versuche - 1)
    end
  end

  test "Seite, Zustand und 404" do
    {sicht, url} = starten()
    send(sicht, {:jack_stand, %{"bestand" => 2, "phase" => 1}})

    send(
      sicht,
      {:agent,
       %{
         "ereignis" => "start",
         "t" => "2026-09-10T15:00:00Z",
         "modell_name" => "m",
         "werkzeuge" => ["bloecke"]
       }}
    )

    assert %{status: 200, body: html} = Req.get!(url <> "/", retry: false)
    assert html =~ "Jack — Laufsicht"
    assert html =~ "new EventSource('/strom')"

    assert %{
             status: 200,
             body: %{
               "stand" => %{"bestand" => 2},
               "lauf" => %{"modell" => "m", "bestand_start" => 2}
             }
           } = Req.get!(url <> "/zustand", retry: false)

    assert %{status: 404} = Req.get!(url <> "/gibt-es-nicht", retry: false)
  end

  test "der Strom bringt jedes Ereignis sofort, Deltas eingeschlossen" do
    {sicht, url} = starten()
    test = self()

    task =
      Task.async(fn ->
        Req.get(url <> "/strom",
          retry: false,
          receive_timeout: 5_000,
          into: fn {:data, daten}, acc ->
            send(test, {:sse, daten})
            {:cont, acc}
          end
        )
      end)

    warten_bis(fn -> map_size(:sys.get_state(sicht).seiten) == 1 end)

    send(sicht, {:agent, %{"ereignis" => "delta", "art" => "denken", "text" => "hm", "t" => "x"}})
    assert_receive {:sse, "data: " <> json}, 2_000
    assert %{"art" => "delta", "was" => "denken", "text" => "hm"} = Jason.decode!(json)

    send(sicht, {:jack_stand, %{"bestand" => 1}})
    assert_receive {:sse, "data: " <> json}, 2_000
    assert %{"art" => "stand", "stand" => %{"bestand" => 1}} = Jason.decode!(json)

    Task.shutdown(task, :brutal_kill)
    warten_bis(fn -> :sys.get_state(sicht).seiten == %{} end)
  end

  @tag :tmp_dir
  test "ein Lauf mit Sicht als Beobachter von Laufzeit und Halter", %{tmp_dir: dir} do
    {sicht, _url} = starten()
    bloecke = for i <- 0..4, do: %{text: "Satz #{i}.", sprecher: "X", block_id: "b#{i}"}
    {:ok, halter} = Halter.start_link(Stand.neu(bloecke: bloecke), beobachter: sicht, ablage: dir)

    {:ok, skript} =
      Agent.start_link(fn ->
        [
          %{
            text: nil,
            denken: "Ich lese zuerst.",
            aufrufe: [%{id: "a", name: "bloecke", argumente: {:ok, %{"von" => 0, "bis" => 4}}}],
            stopp: :werkzeuge,
            nutzung: %{eingabe: 300, ausgabe: 20}
          },
          %{text: "Genug für heute.", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}
        ]
      end)

    assert {:ok, %{ende: :fertig}} =
             Worker.Agent.laufen(
               modell: {Skript, skript: skript},
               system: "S",
               nachrichten: [%{role: :user, content: "Lies."}],
               werkzeuge: Werkzeuge.fuer(halter),
               beobachter: sicht,
               protokoll: Path.join(dir, "protokoll.jsonl"),
               kontext: [fenster: 1000, reserve: 100, behalten: 100]
             )

    z = Sicht.zustand(sicht)

    assert %{
             "runden" => 2,
             "ende" => "fertig",
             "werkzeuge" => %{"bloecke" => 1},
             "kontext_fenster" => 1000,
             "bestand_start" => 0
           } = z["lauf"]

    assert z["stand"]["gelesen"] == [[0, 4]]
    assert Enum.any?(z["spur"], &(&1["was"] == "ruft" and &1["text"] == "bloecke(bis=4, von=0)"))

    # derselbe Lauf aus seinen Dateien, in einer zweiten Sicht
    {nachlese, _} = starten(protokoll: Path.join(dir, "protokoll.jsonl"), ablage: dir)
    n = Sicht.zustand(nachlese)
    assert %{"runden" => 2, "ende" => "fertig", "werkzeuge" => %{"bloecke" => 1}} = n["lauf"]
    assert n["lauf"]["bestand_start"] == nil
    assert n["stand"]["gelesen"] == [[0, 4]]
  end

  # Ranch meldet den belegten Port selbst als Fehler im Log.
  @tag capture_log: true
  test "ein belegter Port ist ein Fehler beim Start, kein Absturz" do
    {_sicht, url} = starten()
    Process.flag(:trap_exit, true)
    assert {:error, {:port, _grund}} = Sicht.start_link(port: URI.parse(url).port)
  end
end
