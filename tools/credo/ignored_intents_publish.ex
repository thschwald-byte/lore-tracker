defmodule LoreTracker.Credo.Check.IgnoredIntentsPublish do
  @moduledoc """
  Issue #544 (Cut 2): Port von `lore.audit`-Regel 5 — ignorierter
  `Worker.Intents.publish/1`-Return.

  `Worker.Intents.publish/1` liefert `{:ok, seq}` | `{:ok, :pending}` (bei
  Hub-Disconnect) | `{:error, …}`. Wird der Return verworfen, bleibt ein
  Hub-Disconnect (`:pending`) unbemerkt → kein Replay-Pfad, das Event ist still
  verloren (die dominante Defekt-Klasse). Gewollt: Return matchen/loggen.

  **AST-präzise „unused return"** statt Zeilen-Regex: geflaggt wird ein
  `…Intents.publish(…)`-Call nur, wenn er ein **Nicht-letztes** Statement eines
  `__block__` ist — sein Wert also tatsächlich verworfen wird. `{:ok, _} =
  publish(…)` (gematcht), `… |> publish()` (gepiped) und das Block-End-Statement
  (Funktions-Return) werden korrekt NICHT geflaggt — die Zeilen-Regex
  (`^\\s*Worker.Intents.publish(`) übersieht den gematchten/gepipeten Fall bzw.
  flaggt unabhängig von der Verwendung.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Ignorierter Worker.Intents.publish/1-Return verschluckt {:ok, :pending}
      (Hub-Disconnect) → Event still verloren. Return matchen/loggen.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.ast()
    |> collect([])
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.map(&issue_for(issue_meta, &1))
  end

  # In einem Block sind alle Statements bis auf das letzte „Wert verworfen".
  defp collect({:__block__, _, stmts}, acc) when is_list(stmts) do
    non_last = Enum.drop(stmts, -1)

    acc =
      Enum.reduce(non_last, acc, fn stmt, a ->
        case publish_line(stmt) do
          nil -> a
          line -> [line | a]
        end
      end)

    # Auch in geschachtelte Blöcke absteigen.
    Enum.reduce(stmts, acc, &collect/2)
  end

  defp collect({_form, _meta, args}, acc), do: collect(args, acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect({l, r}, acc), do: collect(r, collect(l, acc))
  defp collect(_other, acc), do: acc

  # Bare `…Intents.publish(…)`-Call (nicht als RHS eines `=`, nicht in `|>` —
  # die wären andere AST-Knoten, kein direkter Block-Statement-Call).
  defp publish_line({{:., _, [{:__aliases__, _, mods}, :publish]}, meta, args})
       when is_list(mods) and is_list(args) do
    if List.last(mods) == :Intents, do: Keyword.get(meta, :line, 0), else: nil
  end

  defp publish_line(_), do: nil

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Ignorierter Worker.Intents.publish/1-Return — {:ok, :pending} " <>
          "(Hub-Disconnect) geht still verloren. Return matchen/loggen.",
      line_no: line_no,
      trigger: "Worker.Intents.publish"
    )
  end
end
