defmodule Worker.Agent.BeobachterTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug

  # Runde 1 ruft `echo`, Runde 2 endet. Streamt, wenn die Laufzeit
  # `bei_delta` mitgibt, und meldet dem Test, ob sie es tat.
  defmodule Stub do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(_nachrichten, _werkzeuge, opts) do
      runde = Agent.get_and_update(Keyword.fetch!(opts, :zaehler), &{&1 + 1, &1 + 1})
      send(Keyword.fetch!(opts, :test), {:bei_delta?, Keyword.has_key?(opts, :bei_delta)})

      if melden = opts[:bei_delta] do
        melden.(:denken, "hm")
        melden.(:text, "gut")
      end

      aufrufe =
        if runde == 1,
          do: [%{id: "a1", name: "echo", argumente: {:ok, %{"text" => "x"}}}],
          else: []

      {:ok,
       %{
         text: "gut",
         denken: "hm",
         aufrufe: aufrufe,
         stopp: if(aufrufe == [], do: :stop, else: :werkzeuge),
         nutzung: nil
       }}
    end
  end

  defp echo do
    Werkzeug.neu(
      name: "echo",
      beschreibung: "echo",
      parameter: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}},
      ausfuehren: fn %{"text" => t} -> {:ok, t} end
    )
  end

  defp laufen(opts) do
    {:ok, zaehler} = Agent.start_link(fn -> 0 end)

    [
      modell: {Stub, zaehler: zaehler, test: self()},
      system: "S",
      nachrichten: [%{role: :user, content: "A"}],
      werkzeuge: [echo()]
    ]
    |> Keyword.merge(opts)
    |> Worker.Agent.laufen()
  end

  defp sammeln(acc \\ []) do
    receive do
      {:agent, daten} -> sammeln([daten | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "der Beobachter bekommt jede Zeile und die Deltas; in die Datei gehen die Deltas nicht" do
    pfad = Path.join(System.tmp_dir!(), "beobachter_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(pfad) end)

    assert {:ok, %{ende: :fertig}} = laufen(protokoll: pfad, beobachter: self())
    ereignisse = sammeln()

    assert Enum.map(ereignisse, & &1["ereignis"]) ==
             ~w(start anfrage delta delta antwort ergebnis anfrage delta delta antwort ende)

    assert %{"runde" => 1, "art" => "denken", "text" => "hm", "t" => _} =
             Enum.find(ereignisse, &(&1["ereignis"] == "delta"))

    datei =
      pfad
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(&1)["ereignis"])

    assert datei == ~w(start anfrage antwort ergebnis anfrage antwort ende)
    assert_received {:bei_delta?, true}
  end

  test "ohne Beobachter streamt das Modell nicht" do
    assert {:ok, _} = laufen([])
    assert_received {:bei_delta?, false}
    refute_received {:agent, _}
  end

  test "ein toter Beobachter hält den Lauf nicht auf" do
    tot = spawn(fn -> :ok end)
    ref = Process.monitor(tot)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert {:ok, %{ende: :fertig}} = laufen(beobachter: tot)
  end

  test "ein Beobachter, der kein Prozess ist, ist ein Programmierfehler" do
    assert_raise ArgumentError, ~r/beobachter: pid oder nil erwartet/, fn ->
      laufen(beobachter: :sicht)
    end
  end
end
