defmodule Worker.Jack.McpTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Mcp

  defp echo do
    Werkzeug.neu(
      name: "echo",
      beschreibung: "Gibt den Text zurück.",
      parameter: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      ausfuehren: fn %{"text" => t} -> {:ok, "echo: " <> t} end
    )
  end

  defp fertig do
    Werkzeug.neu(
      name: "fertig",
      beschreibung: "Beendet die Phase.",
      parameter: %{"type" => "object", "properties" => %{}},
      wiederholung: :frei,
      ausfuehren: fn _ -> {:halt, "Abgeschlossen."} end
    )
  end

  defp aufruf(id, name, args),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

  defp ergebnis({[%{"result" => r}], z}), do: {r, z}

  test "initialize nennt Version, Werkzeug-Fähigkeit und Server; Benachrichtigungen bleiben ohne Antwort" do
    z = Mcp.neu([echo()])

    assert {[%{"id" => 1, "result" => r}], z} =
             Mcp.behandeln(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "initialize",
                 "params" => %{"protocolVersion" => "2025-06-18"}
               },
               z
             )

    assert %{"protocolVersion" => "2025-06-18", "capabilities" => %{"tools" => _}} = r

    assert {[], _} =
             Mcp.behandeln(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, z)

    assert {[%{"id" => 2, "result" => %{}}], _} =
             Mcp.behandeln(%{"id" => 2, "method" => "ping"}, z)

    assert {[%{"id" => 3, "error" => %{"code" => -32_601}}], _} =
             Mcp.behandeln(%{"id" => 3, "method" => "resources/list"}, z)
  end

  test "tools/list: Name, Beschreibung und das strenge Schema als inputSchema, in Reihenfolge" do
    {r, _} =
      ergebnis(Mcp.behandeln(%{"id" => 1, "method" => "tools/list"}, Mcp.neu([echo(), fertig()])))

    assert [
             %{
               "name" => "echo",
               "description" => "Gibt den Text zurück.",
               "inputSchema" => %{"required" => ["text"], "additionalProperties" => false}
             },
             %{"name" => "fertig"}
           ] = r["tools"]
  end

  @tag :tmp_dir
  test "tools/call nach den Regeln der Laufzeit; jedes Ergebnis steht im Journal", %{tmp_dir: dir} do
    journal = Path.join(dir, "werkzeuge.jsonl")
    z = Mcp.neu([echo(), fertig()], journal: journal)

    {r, z} = ergebnis(Mcp.behandeln(aufruf(1, "echo", %{"text" => "hallo"}), z))
    assert r == %{"content" => [%{"type" => "text", "text" => "echo: hallo"}], "isError" => false}

    {r, z} = ergebnis(Mcp.behandeln(aufruf(2, "echo", %{}), z))

    assert %{"isError" => true, "content" => [%{"text" => "Argumente für echo ungültig:" <> _}]} =
             r

    {r, z} = ergebnis(Mcp.behandeln(aufruf(3, "gibtsnicht", %{}), z))

    assert %{
             "isError" => true,
             "content" => [%{"text" => "Werkzeug \"gibtsnicht\" gibt es nicht." <> _}]
           } = r

    {r, z} = ergebnis(Mcp.behandeln(aufruf(4, "fertig", %{}), z))
    assert %{"isError" => false, "content" => [%{"text" => "Abgeschlossen."}]} = r
    assert z.ende == :halt

    {r, _} = ergebnis(Mcp.behandeln(aufruf(5, "echo", %{"text" => "danach"}), z))

    assert %{
             "isError" => true,
             "content" => [
               %{"text" => "Nicht ausgeführt: die Phase ist mit fertig() abgeschlossen."}
             ]
           } = r

    zeilen =
      journal |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(zeilen, & &1["art"]) == ["ok", "error", "error", "halt", "error"]

    assert %{"name" => "echo", "argumente" => %{"text" => "hallo"}, "text" => "echo: hallo"} =
             hd(zeilen)
  end

  test "die Wiederholungssperre gilt wie in der Laufzeit: Warnung, dann Abbruch" do
    z = Mcp.neu([echo()], wiederholungen: [warnung: 2, abbruch: 3])
    {r1, z} = ergebnis(Mcp.behandeln(aufruf(1, "echo", %{"text" => "x"}), z))
    {r2, z} = ergebnis(Mcp.behandeln(aufruf(2, "echo", %{"text" => "x"}), z))
    {r3, z} = ergebnis(Mcp.behandeln(aufruf(3, "echo", %{"text" => "x"}), z))
    {r4, _} = ergebnis(Mcp.behandeln(aufruf(4, "echo", %{"text" => "y"}), z))

    assert r1["isError"] == false
    assert %{"isError" => true, "content" => [%{"text" => "WIEDERHOLUNG — " <> _}]} = r2
    assert %{"isError" => true} = r3
    assert z.ende == :abbruch
    assert %{"content" => [%{"text" => "Nicht ausgeführt: der Lauf ist abgebrochen."}]} = r4
  end
end
