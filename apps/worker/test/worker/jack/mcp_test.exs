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

  # Über das echte stdio eines eigenen Elixir-Prozesses, nicht über StringIO:
  # StringIO bildet die Umwandlung des :unicode-stdio nicht nach, ein Test
  # darüber wäre auch ohne die Korrektur grün.
  defp elixir_mit(skript, umgebung \\ []) do
    elixir = System.find_executable("elixir")

    # ALLE Codepfade des laufenden Systems, nicht nur :worker und :jason. Zwei
    # Pfade reichen lokal, weil dort sonst nichts nachgeladen werden muss; in
    # der CI fehlte dem Unterprozess Code, er starb vor der ersten Antwort, und
    # der Test sah nur ein ausbleibendes Ergebnis (PR #1212, Läufe 1036–1038).
    # `:code.get_path/0` ist genau die Liste, mit der der Test selbst läuft.
    pfade = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    # `:stderr_to_stdout`, weil ein Fehler im Unterprozess sonst unsichtbar
    # ist: die Antwort bleibt aus, und der Test meldet nur „keine Antwort“.
    # Genau so stand der Lauf in der CI rot da, während er lokal grün war
    # (PR #1212) — die Silent-Failure-Klasse aus CLAUDE.md.
    Port.open({:spawn_executable, elixir}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 65_536},
      env: umgebung,
      args: pfade ++ ["-e", skript]
    ])
  end

  # Die Frist bleibt unter ExUnits eigener Grenze von 60 s — sonst killt
  # ExUnit den Test, bevor die Meldung unten je erscheint (Lauf 1038). Was der
  # Unterprozess bis dahin gesagt hat (dank `:stderr_to_stdout` auch ein
  # Absturz), steht in der Meldung — sonst bliebe „keine Antwort“ die einzige
  # Spur.
  # Die Antwort ist die erste Zeile, die nach JSON-RPC aussieht. Alles davor
  # ist Rauschen des Unterprozesses (Warnungen der VM, Meldungen auf stderr):
  # es wird gesammelt und erscheint in der Fehlermeldung, statt die Antwort zu
  # verdrängen. Genau daran scheiterte der Lauf in der CI, nachdem
  # `:stderr_to_stdout` das Rauschen sichtbar gemacht hatte (PR #1212).
  defp json_von(port, gesammelt \\ []) do
    receive do
      {^port, {:data, {:eol, "{" <> _ = zeile}}} ->
        zeile

      {^port, {:data, {:eol, zeile}}} ->
        json_von(port, [zeile | gesammelt])

      {^port, {:data, {:noeol, teil}}} ->
        json_von(port, [teil | gesammelt])

      {^port, {:exit_status, status}} ->
        flunk("Der Prozess endete mit #{status}. Ausgabe: #{ausgabe(gesammelt)}")
    after
      30_000 -> flunk("keine JSON-Antwort. Ausgabe bis dahin: #{ausgabe(gesammelt)}")
    end
  end

  # Die nächste Zeile, wie sie kommt — für den Voraussetzungs-Test, der gerade
  # KEIN JSON erwartet.
  defp zeile_von(port, gesammelt \\ []) do
    receive do
      {^port, {:data, {:eol, zeile}}} ->
        zeile

      {^port, {:data, {:noeol, teil}}} ->
        zeile_von(port, [teil | gesammelt])

      {^port, {:exit_status, status}} ->
        flunk("Der Prozess endete mit #{status}. Ausgabe: #{ausgabe(gesammelt)}")
    after
      30_000 -> flunk("keine Antwort vom Prozess. Ausgabe bis dahin: #{ausgabe(gesammelt)}")
    end
  end

  defp ausgabe([]), do: "(nichts)"
  defp ausgabe(teile), do: teile |> Enum.reverse() |> Enum.join()

  test "Voraussetzung: binwrite auf das stdio von Elixir verbiegt UTF-8" do
    port = elixir_mit(~s|IO.binwrite(:stdio, "Tür\\n")|)
    assert zeile_von(port) == "TÃ¼r"
  end

  test "bedienen: Umlaute kommen über das echte stdio unverändert hin und zurück" do
    port =
      elixir_mit("""
      w = Worker.Agent.Werkzeug.neu(
        name: "echo",
        beschreibung: "Gibt den Text zurück.",
        parameter: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]},
        ausfuehren: fn %{"text" => t} -> {:ok, "echo: " <> t} end
      )
      Worker.Jack.Mcp.bedienen(Worker.Jack.Mcp.neu([w]), :stdio, :stdio)
      """)

    Port.command(port, [Jason.encode!(aufruf(1, "echo", %{"text" => "Tür zurück"})), ?\n])

    assert %{"id" => 1, "result" => %{"content" => [%{"text" => "echo: Tür zurück"}]}} =
             Jason.decode!(json_von(port))

    Port.close(port)
  end

  # Der Fall, der in der CI rot war (Läufe 1036–1040 zu PR #1212): steht die
  # Standardeingabe auf :unicode, wandelt Elixir die UTF-8-Bytes eines Umlauts
  # in EIN Zeichen — `IO.binread` gibt danach ein einzelnes Byte zurück (252
  # statt 195/188), und die Zeile ist kein gültiges JSON mehr. Der Umweg über
  # `:io.setopts(encoding: :latin1)` half nicht: er stellt nur die AUSGABE um,
  # die Eingabe liest weiter Unicode, und `:io.getopts/1` meldet trotzdem
  # `:latin1`. `Mcp.bedienen/3` lässt die Geräte deshalb in Ruhe und liest und
  # schreibt mit `IO.read/2`/`IO.write/2`.
  test "bedienen: Umlaute überleben auch, wenn die Standardeingabe auf Unicode steht" do
    port =
      elixir_mit(
        """
        w = Worker.Agent.Werkzeug.neu(
          name: "echo",
          beschreibung: "Gibt den Text zurück.",
          parameter: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]},
          ausfuehren: fn %{"text" => t} -> {:ok, "echo: " <> t} end
        )
        Worker.Jack.Mcp.bedienen(Worker.Jack.Mcp.neu([w]), :stdio, :stdio)
        """,
        [{~c"LANG", ~c"C.UTF-8"}, {~c"LC_ALL", ~c"C.UTF-8"}, {~c"ELIXIR_ERL_OPTIONS", ~c"+fnu"}]
      )

    Port.command(port, [Jason.encode!(aufruf(1, "echo", %{"text" => "Tür zurück"})), ?\n])

    assert %{"id" => 1, "result" => %{"content" => [%{"text" => "echo: Tür zurück"}]}} =
             Jason.decode!(json_von(port))

    Port.close(port)
  end

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

  # Wächter: der Byte-Weg darf nicht zurückkommen. `IO.binread`/`IO.binwrite`
  # auf einem Unicode-Gerät verstümmeln jeden Umlaut, und `:io.setopts` wirkt
  # nur auf die Ausgabe — beides oben gemessen. Ein Rückfall röte sonst erst
  # wieder die CI, nicht die Suite.
  test "Wächter: mcp.ex fasst weder die Kodierung an noch die Byte-Funktionen" do
    # Ohne die Doku-Blöcke: dort stehen die Namen als Begründung, nicht als Code.
    code =
      "lib/worker/jack/mcp.ex"
      |> File.read!()
      |> String.split(~s|"""|)
      |> Enum.take_every(2)
      |> Enum.join("\n")

    for verboten <- ["IO.binread", "IO.binwrite", ":io.setopts", ":io.getopts"] do
      refute String.contains?(code, verboten),
             "#{verboten} steht wieder in mcp.ex — siehe bedienen/3 im Moduldoc."
    end
  end
end
