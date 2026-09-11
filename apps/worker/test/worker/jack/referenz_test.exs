defmodule Worker.Jack.ReferenzTest do
  # Die Übersetzung des stream-json von Claude Code in das Protokoll der
  # Laufzeit. Die Ereignisformen entsprechen dem Probeaufruf vom 11.09.
  # (claude 2.1.263): system/init, assistant je Block, user mit tool_result,
  # rate_limit_event, result.
  use ExUnit.Case, async: true

  alias Worker.Jack.Referenz

  defp alle(ereignisse) do
    {aus, z} =
      Enum.reduce(ereignisse, {[], Referenz.uebersetzer()}, fn e, {acc, z} ->
        {neu, z} = Referenz.uebersetzen(e, z)
        {acc ++ neu, z}
      end)

    {rest, _} = Referenz.abschliessen(z)
    aus ++ rest
  end

  defp assistant(id, block, usage \\ %{"input_tokens" => 2, "output_tokens" => 5}),
    do: %{
      "type" => "assistant",
      "message" => %{"id" => id, "content" => [block], "usage" => usage}
    }

  test "init wird start, ohne das Präfix der MCP-Werkzeuge" do
    assert [{"start", d}] =
             alle([
               %{
                 "type" => "system",
                 "subtype" => "init",
                 "model" => "claude-fable-5-1",
                 "claude_code_version" => "2.1.263",
                 "session_id" => "s1",
                 "tools" => ["mcp__jack__bloecke", "mcp__jack__fertig"]
               }
             ])

    assert %{
             "modell_name" => "claude-fable-5-1",
             "modell" => "Claude Code 2.1.263",
             "werkzeuge" => ["bloecke", "fertig"],
             "sitzung" => "s1"
           } = d
  end

  test "die Blöcke einer Antwort werden eine antwort; Werkzeugergebnisse werden ergebnis" do
    aus =
      alle([
        assistant("m1", %{"type" => "thinking", "thinking" => ""}),
        assistant("m1", %{"type" => "text", "text" => "Ich lese."}),
        assistant("m1", %{
          "type" => "tool_use",
          "id" => "t1",
          "name" => "mcp__jack__bloecke",
          "input" => %{"von" => 0, "bis" => 9}
        }),
        %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "t1",
                "content" => [%{"type" => "text", "text" => "0 Satz"}]
              }
            ]
          }
        },
        assistant("m2", %{
          "type" => "tool_use",
          "id" => "t2",
          "name" => "mcp__jack__aussage",
          "input" => %{"claim" => "x"}
        }),
        %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "t2",
                "content" => "kaputt",
                "is_error" => true
              }
            ]
          }
        },
        assistant("m3", %{"type" => "text", "text" => "Fertig."}, %{
          "input_tokens" => 1,
          "cache_read_input_tokens" => 100,
          "cache_creation_input_tokens" => 10,
          "output_tokens" => 3
        })
      ])

    assert [
             {"anfrage", %{"runde" => 1}},
             {"antwort", a1},
             {"ergebnis",
              %{
                "runde" => 1,
                "id" => "t1",
                "name" => "bloecke",
                "art" => "ok",
                "text" => "0 Satz"
              }},
             {"anfrage", %{"runde" => 2}},
             {"antwort", %{"stopp" => "werkzeuge", "aufrufe" => [%{"name" => "aussage"}]}},
             {"ergebnis", %{"name" => "aussage", "art" => "error", "text" => "kaputt"}},
             {"anfrage", %{"runde" => 3}},
             {"antwort", a3}
           ] = aus

    assert %{
             "text" => "Ich lese.",
             "denken" => nil,
             "stopp" => "werkzeuge",
             "aufrufe" => [
               %{"id" => "t1", "name" => "bloecke", "argumente" => %{"von" => 0, "bis" => 9}}
             ]
           } = a1

    assert %{
             "stopp" => "stop",
             "text" => "Fertig.",
             "nutzung" => %{"eingabe" => 111, "ausgabe" => 3}
           } = a3
  end

  # Die Reihenfolge des ersten Probelaufs (11.09.): Claude Code führt jeden
  # Aufruf aus, sobald er da ist — Aufruf und Ergebnis wechseln sich innerhalb
  # EINER Nachricht ab.
  test "verschränkte Aufrufe derselben Nachricht bleiben eine Runde und zählen einmal" do
    u = %{"input_tokens" => 2, "cache_read_input_tokens" => 8564, "output_tokens" => 40}

    ergebnis = fn tid ->
      %{
        "type" => "user",
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => tid, "content" => "ok"}]
        }
      }
    end

    aufruf = fn tid, von ->
      assistant(
        "m2",
        %{
          "type" => "tool_use",
          "id" => tid,
          "name" => "mcp__jack__bloecke",
          "input" => %{"von" => von, "bis" => von + 9}
        },
        u
      )
    end

    aus =
      alle([
        assistant("m2", %{"type" => "thinking", "thinking" => ""}, u),
        aufruf.("t1", 0),
        ergebnis.("t1"),
        aufruf.("t2", 10),
        ergebnis.("t2"),
        aufruf.("t3", 20),
        ergebnis.("t3"),
        assistant("m3", %{"type" => "text", "text" => "weiter"})
      ])

    assert [
             {"anfrage", %{"runde" => 1}},
             {"antwort",
              %{"runde" => 1, "fortsetzung" => false, "nutzung" => %{"eingabe" => 8566}}},
             {"ergebnis", %{"runde" => 1, "id" => "t1", "name" => "bloecke"}},
             {"antwort",
              %{
                "runde" => 1,
                "fortsetzung" => true,
                "nutzung" => nil,
                "aufrufe" => [%{"id" => "t2"}]
              }},
             {"ergebnis", %{"runde" => 1, "id" => "t2"}},
             {"antwort",
              %{
                "runde" => 1,
                "fortsetzung" => true,
                "nutzung" => nil,
                "aufrufe" => [%{"id" => "t3"}]
              }},
             {"ergebnis", %{"runde" => 1, "id" => "t3"}},
             {"anfrage", %{"runde" => 2}},
             {"antwort", %{"runde" => 2, "fortsetzung" => false, "text" => "weiter"}}
           ] = aus
  end

  test "Kompaktierung, Nutzungsgrenze und Ende; eine offene Antwort geht vorher hinaus" do
    aus =
      alle([
        assistant("m1", %{"type" => "text", "text" => "a"}),
        %{
          "type" => "system",
          "subtype" => "compact_boundary",
          "compact_metadata" => %{"trigger" => "auto", "pre_tokens" => 190_000}
        },
        %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}},
        assistant("m2", %{"type" => "text", "text" => "b"}),
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "duration_ms" => 1234,
          "total_cost_usd" => 0.5,
          "usage" => %{"input_tokens" => 2, "output_tokens" => 7}
        }
      ])

    assert [
             {"anfrage", _},
             {"antwort", %{"text" => "a"}},
             {"kompaktierung",
              %{"runde" => 1, "weggefallen" => 1, "tokens" => 190_000, "ausloeser" => "auto"}},
             {"nutzungsgrenze", %{"rate_limit_info" => %{"status" => "allowed"}}},
             {"anfrage", %{"runde" => 2}},
             {"antwort", %{"text" => "b"}},
             {"ende",
              %{
                "ende" => "success",
                "fehler" => false,
                "runden" => 2,
                "ms" => 1234,
                "kosten_usd_listenpreis" => 0.5,
                "nutzung" => %{"eingabe" => 2, "ausgabe" => 7}
              }}
           ] = aus
  end

  test "bricht der Strom ab, geht die offene Antwort beim Abschließen hinaus" do
    assert [{"anfrage", _}, {"antwort", %{"text" => "halb"}}] =
             alle([assistant("m1", %{"type" => "text", "text" => "halb"})])
  end
end
