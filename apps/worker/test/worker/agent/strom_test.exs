defmodule Worker.Agent.StromTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Modell.{Ollama, Strom}

  defp data(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp delta(d, grund \\ nil),
    do: data(%{"choices" => [%{"delta" => d, "finish_reason" => grund}]})

  # Bytes in beliebigen Stücken einlesen; Deltas sammeln.
  defp lesen(stuecke) do
    Enum.reduce(stuecke, {Strom.neu(), []}, fn b, {s, acc} ->
      {s, d} = Strom.einlesen(s, b)
      {s, acc ++ d}
    end)
  end

  defp antwort(s) do
    {:ok, body} = Strom.ergebnis(s)
    Ollama.antwort(body)
  end

  test "Denken und Text als Deltas in Reihenfolge, auch wenn Zeilen und Zeichen zerschnitten ankommen" do
    ganz =
      delta(%{"reasoning" => "Ich "}) <>
        delta(%{"reasoning" => "überlege."}) <>
        delta(%{"content" => "Kaffee für "}) <>
        delta(%{"content" => "alle."}, "stop") <> "data: [DONE]\n\n"

    # an jeder Stelle geschnitten, auch mitten im „ü“
    stuecke = for <<b::binary-size(1) <- ganz>>, do: b
    {s, deltas} = lesen(stuecke)

    assert deltas == [
             {:denken, "Ich "},
             {:denken, "überlege."},
             {:text, "Kaffee für "},
             {:text, "alle."}
           ]

    assert {:ok, %{text: "Kaffee für alle.", denken: "Ich überlege.", stopp: :stop, aufrufe: []}} =
             antwort(s)
  end

  test "ein Werkzeugaufruf in Teilen: id und Name zuerst, Argumente in Stücken" do
    {s, []} =
      lesen([
        delta(%{
          "tool_calls" => [
            %{"index" => 0, "id" => "c1", "function" => %{"name" => "bloecke", "arguments" => ""}}
          ]
        }),
        delta(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s({"von":)}}]}),
        delta(
          %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s(0,"bis":9})}}]},
          "tool_calls"
        ),
        "data: [DONE]\n\n"
      ])

    assert {:ok, %{stopp: :werkzeuge, aufrufe: [a]}} = antwort(s)
    assert a == %{id: "c1", name: "bloecke", argumente: {:ok, %{"von" => 0, "bis" => 9}}}
  end

  test "zwei ganze Aufrufe ohne Index, Argumente als Objekt, Nutzung im letzten Stück" do
    {s, _} =
      lesen([
        delta(%{
          "tool_calls" => [%{"id" => "a", "function" => %{"name" => "cast", "arguments" => %{}}}]
        }),
        delta(%{
          "tool_calls" => [
            %{"id" => "b", "function" => %{"name" => "block", "arguments" => %{"nummer" => 3}}}
          ]
        }),
        delta(%{}, "stop"),
        data(%{"choices" => [], "usage" => %{"prompt_tokens" => 900, "completion_tokens" => 40}}),
        "data: [DONE]\n\n"
      ])

    assert {:ok,
            %{
              aufrufe: [%{name: "cast"}, %{name: "block", argumente: {:ok, %{"nummer" => 3}}}],
              nutzung: n
            }} =
             antwort(s)

    assert n == %{eingabe: 900, ausgabe: 40}
  end

  test "Kommentarzeilen und CRLF stören nicht; Stoppgrund length bleibt erhalten" do
    {s, [{:text, "ab"}]} =
      lesen([
        ": keep-alive\r\n\r\n",
        String.replace(delta(%{"content" => "ab"}, "length"), "\n", "\r\n")
      ])

    assert {:ok, %{stopp: :laenge, text: "ab"}} = antwort(s)
  end

  test "ein Fehler im Strom, eine kaputte Zeile und ein abgebrochener Strom sind Fehler" do
    {s, _} = lesen([data(%{"error" => %{"message" => "model not found"}})])
    assert {:error, {:strom, %{"message" => "model not found"}}} = Strom.ergebnis(s)

    {s, _} = lesen(["data: {kaputt\n\n"])
    assert {:error, {:antwortform, "{kaputt"}} = Strom.ergebnis(s)

    {s, [{:text, "halb"}]} = lesen([delta(%{"content" => "halb"})])
    assert {:error, {:strom_unvollstaendig, roh}} = Strom.ergebnis(s)
    assert roh =~ "halb"
  end
end
