defmodule Worker.Agent.OllamaStromTest do
  # Streaming gegen einen echten HTTP-Server: ein Plug, der Server-Sent Events
  # in Stücken schickt, wie `/v1/chat/completions` mit `stream: true`.
  use ExUnit.Case, async: true

  alias Worker.Agent.Modell.Ollama

  defmodule Stub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, stuecke: stuecke, status: status}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:anfrage, Jason.decode!(body)})

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(status)

      Enum.reduce(stuecke, conn, fn stueck, conn ->
        {:ok, conn} = chunk(conn, stueck)
        conn
      end)
    end
  end

  defp server(stuecke, status \\ 200) do
    ref = :"ollama_stub_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(Stub, %{test: self(), stuecke: stuecke, status: status},
        port: 0,
        ref: ref,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  defp sse(delta, grund \\ nil),
    do:
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => delta, "finish_reason" => grund}]}) <> "\n\n"

  defp aufruf(url) do
    test = self()

    Ollama.antworten([%{role: :user, content: "hallo"}], [],
      endpunkt: url,
      modell: "stub",
      bei_delta: fn art, text -> send(test, {:delta, art, text}) end
    )
  end

  test "Denken und Text kommen Stück für Stück an, die Antwort ist die zusammengesetzte" do
    url =
      server([
        sse(%{"reasoning" => "Ich denke "}),
        sse(%{"reasoning" => "nach."}),
        # ein Stück, das mitten in der Zeile endet
        String.slice(sse(%{"content" => "Hallo Welt"}), 0, 20),
        String.slice(sse(%{"content" => "Hallo Welt"}), 20..-1//1) <> sse(%{}, "stop"),
        "data: " <>
          Jason.encode!(%{
            "choices" => [],
            "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 5}
          }) <>
          "\n\n",
        "data: [DONE]\n\n"
      ])

    assert {:ok, a} = aufruf(url)
    assert a.text == "Hallo Welt"
    assert a.denken == "Ich denke nach."
    assert a.stopp == :stop
    assert a.nutzung == %{eingabe: 12, ausgabe: 5}

    assert_received {:anfrage,
                     %{"stream" => true, "stream_options" => %{"include_usage" => true}}}

    assert_received {:delta, :denken, "Ich denke "}
    assert_received {:delta, :denken, "nach."}
    assert_received {:delta, :text, "Hallo Welt"}
  end

  test "ein Fehlerstatus wird zum Fehler mit Body, ohne Deltas" do
    url = server([~s({"error":"model 'stub' not found"})], 404)
    assert {:error, {:http, 404, body}} = aufruf(url)
    assert body =~ "not found"
    refute_received {:delta, _, _}
  end

  test "ein abgebrochener Strom wird zum Fehler, nicht zu einer halben Antwort" do
    url = server([sse(%{"content" => "halb"})])
    assert {:error, {:strom_unvollstaendig, _}} = aufruf(url)
  end
end
