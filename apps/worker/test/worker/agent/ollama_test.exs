defmodule Worker.Agent.Modell.OllamaTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Modell.Ollama
  alias Worker.Agent.Werkzeug

  defp echo do
    Werkzeug.neu(
      name: "echo",
      beschreibung: "Gibt den Text zurück.",
      parameter: %{type: :object, properties: %{text: %{type: :string}}, required: [:text]},
      ausfuehren: fn _ -> {:ok, ""} end
    )
  end

  describe "anfrage/3" do
    test "Nachrichten, Werkzeuge und Optionen im Format der Chat-API" do
      nachrichten = [
        %{role: :system, content: "S"},
        %{role: :user, content: "U"},
        %{
          role: :assistant,
          content: nil,
          tool_calls: [%{id: "c1", name: "echo", argumente: {:ok, %{"text" => "hi"}}}]
        },
        %{role: :tool, tool_call_id: "c1", name: "echo", content: "echo: hi", fehler: false}
      ]

      body = Ollama.anfrage(nachrichten, [echo()], modell: "m", temperatur: 0.2, max_ausgabe: 512)

      assert %{"model" => "m", "stream" => false, "temperature" => 0.2, "max_tokens" => 512} =
               body

      assert [
               %{"role" => "system", "content" => "S"},
               %{"role" => "user", "content" => "U"},
               %{
                 "role" => "assistant",
                 "content" => "",
                 "tool_calls" => [
                   %{
                     "id" => "c1",
                     "type" => "function",
                     "function" => %{"name" => "echo", "arguments" => ~s({"text":"hi"})}
                   }
                 ]
               },
               %{"role" => "tool", "tool_call_id" => "c1", "content" => "echo: hi"}
             ] = body["messages"]

      assert [%{"type" => "function", "function" => %{"name" => "echo", "parameters" => params}}] =
               body["tools"]

      # Streng per Default (Werkzeug.neu): minLength und additionalProperties
      # gehen mit an das Modell, damit es die Pflicht vorher sieht.
      assert params == %{
               "type" => "object",
               "properties" => %{"text" => %{"type" => "string", "minLength" => 1}},
               "required" => ["text"],
               "additionalProperties" => false
             }
    end

    test "Argumente, die kein JSON waren, gehen roh zurück; ohne Werkzeuge kein tools-Feld" do
      nachrichten = [
        %{
          role: :assistant,
          content: "x",
          tool_calls: [%{id: "c", name: "e", argumente: {:error, "{kaputt"}}]
        }
      ]

      body = Ollama.anfrage(nachrichten, [], modell: "m", extra: %{"seed" => 7})

      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "temperature")
      assert body["seed"] == 7

      assert [%{"tool_calls" => [%{"function" => %{"arguments" => "{kaputt"}}]}] =
               body["messages"]
    end

    test "eine Modellantwort ohne Aufrufe hat kein tool_calls-Feld" do
      body = Ollama.anfrage([%{role: :assistant, content: "x", tool_calls: []}], [], modell: "m")
      assert [%{"role" => "assistant", "content" => "x"} = n] = body["messages"]
      refute Map.has_key?(n, "tool_calls")
    end
  end

  describe "antwort/1" do
    defp roh(
           message,
           finish \\ "stop",
           usage \\ %{"prompt_tokens" => 10, "completion_tokens" => 3}
         ) do
      %{"choices" => [%{"message" => message, "finish_reason" => finish}], "usage" => usage}
    end

    test "Werkzeugaufruf mit Argumenten als JSON-Text" do
      m = %{
        "role" => "assistant",
        "content" => "",
        "reasoning" => "ich denke",
        "tool_calls" => [
          %{"id" => "call_1", "function" => %{"name" => "echo", "arguments" => ~s({"text":"hi"})}}
        ]
      }

      assert {:ok,
              %{
                text: nil,
                denken: "ich denke",
                stopp: :werkzeuge,
                aufrufe: [%{id: "call_1", name: "echo", argumente: {:ok, %{"text" => "hi"}}}],
                nutzung: %{eingabe: 10, ausgabe: 3}
              }} = Ollama.antwort(roh(m, "tool_calls"))
    end

    test "Argumente, die kein JSON-Objekt sind, werden {:error, roh}" do
      aufrufe = [
        %{"id" => "a", "function" => %{"name" => "e", "arguments" => "{kaputt"}},
        %{"id" => "b", "function" => %{"name" => "e", "arguments" => "[1]"}},
        %{"id" => "c", "function" => %{"name" => "e", "arguments" => ""}},
        %{"id" => "d", "function" => %{"name" => "e", "arguments" => %{"schon" => "map"}}}
      ]

      assert {:ok, %{aufrufe: [a, b, c, d]}} = Ollama.antwort(roh(%{"tool_calls" => aufrufe}))
      assert a.argumente == {:error, "{kaputt"}
      assert b.argumente == {:error, "[1]"}
      assert c.argumente == {:ok, %{}}
      assert d.argumente == {:ok, %{"schon" => "map"}}
    end

    test "fehlende Aufruf-ID wird eindeutig vergeben" do
      ohne_id = %{"function" => %{"name" => "e", "arguments" => "{}"}}

      assert {:ok, %{aufrufe: [a, b]}} =
               Ollama.antwort(roh(%{"tool_calls" => [ohne_id, ohne_id]}))

      assert "aufruf_" <> _ = a.id
      assert a.id != b.id
    end

    test "Stoppgründe" do
      aufrufe = [%{"id" => "a", "function" => %{"name" => "e", "arguments" => "{}"}}]

      assert {:ok, %{stopp: :stop, text: "fertig"}} =
               Ollama.antwort(roh(%{"content" => "fertig"}))

      assert {:ok, %{stopp: :stop}} = Ollama.antwort(roh(%{"content" => "x"}, nil))
      assert {:ok, %{stopp: :laenge}} = Ollama.antwort(roh(%{"content" => "x"}, "length"))
      assert {:ok, %{stopp: :laenge}} = Ollama.antwort(roh(%{"tool_calls" => aufrufe}, "length"))
      assert {:ok, %{stopp: :werkzeuge}} = Ollama.antwort(roh(%{"tool_calls" => aufrufe}, "stop"))

      assert {:error, {:stoppgrund, "content_filter"}} =
               Ollama.antwort(roh(%{}, "content_filter"))
    end

    test "fehlende usage wird nil, fremde Form ein Fehler" do
      assert {:ok, %{nutzung: nil}} = Ollama.antwort(roh(%{"content" => "x"}, "stop", nil))
      assert {:error, {:antwortform, %{"error" => "x"}}} = Ollama.antwort(%{"error" => "x"})
    end
  end
end
