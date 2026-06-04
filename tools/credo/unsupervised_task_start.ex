defmodule LoreTracker.Credo.Check.UnsupervisedTaskStart do
  @moduledoc """
  Issue #544 (Cut 2): Port von `lore.audit`-Regel 1 — unsupervised `Task.start/1`.

  Ein `Task.start(fn -> … end)` läuft ohne Supervisor: crasht der Task, geht
  der Fehler **still** verloren (kein Restart, kein Log). Gewollt ist
  `Task.Supervisor.start_child/2` (überwacht) oder zumindest `Task.start_link`
  (Crash propagiert zum Caller). Mix-Tasks (`lib/mix/tasks/`) sind ausgenommen —
  dort ist Fire-and-Forget im CLI-Kontext ok.

  AST statt Regex: matcht den `Task.start`-Aufruf strukturell (nicht
  `Task.start_link`, nicht `Task.Supervisor.start_child`), unabhängig von
  Einrückung/Zeilenumbruch.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Unsupervised Task.start/1 verschluckt Task-Crashes still.
      Task.Supervisor.start_child/2 (überwacht) oder Task.start_link nutzen.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if exempt_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> collect_lines(false, [])
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    end
  end

  # Mix-Tasks sind Fire-and-Forget-tolerant (CLI, kein Daemon-Kontext).
  defp exempt_file?(filename), do: String.contains?(filename, "/mix/tasks/")

  defp collect_lines({_form, meta, args} = node, _ctx, acc) when is_list(meta) do
    acc = if task_start?(node), do: [Keyword.get(meta, :line, 0) | acc], else: acc
    collect_lines(args, nil, acc)
  end

  defp collect_lines(list, ctx, acc) when is_list(list),
    do: Enum.reduce(list, acc, fn c, a -> collect_lines(c, ctx, a) end)

  defp collect_lines({l, r}, ctx, acc), do: collect_lines(r, ctx, collect_lines(l, ctx, acc))
  defp collect_lines(_other, _ctx, acc), do: acc

  # `Task.start(...)` — exakt `:start` (nicht start_link/start_child) auf dem
  # Task-Alias.
  defp task_start?({{:., _, [{:__aliases__, _, mods}, :start]}, _, args})
       when is_list(mods) and is_list(args),
       do: List.last(mods) == :Task

  defp task_start?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Unsupervised Task.start/1 verschluckt Task-Crashes still — " <>
          "Task.Supervisor.start_child/2 oder Task.start_link nutzen.",
      line_no: line_no,
      trigger: "Task.start"
    )
  end
end
