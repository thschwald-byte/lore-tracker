defmodule LoreTracker.Credo.Check.TimerWithoutCleanup do
  @moduledoc """
  Issue #544 (Cut 2): Port von `lore.audit`-Regel 4 — Timer ohne Cleanup.

  `Process.send_after(self(), …)` ohne ein `Process.cancel_timer/1` irgendwo im
  selben File: nach einem LiveView-/GenServer-Restart feuert der alte Timer
  weiter (Zombie-Timer), oder ein neuer überlagert den alten. Faustregel — wer
  `send_after` schedult, hält die Ref und canceled sie beim Reschedule/Terminate.

  File-Level-Heuristik (wie lore.audit): hat das File `send_after(self())` UND
  kein `cancel_timer`, werden alle send_after-Stellen geflaggt. AST statt Grep:
  matcht den Call strukturell (kein Treffer auf `cancel_timer` in einem
  Kommentar/Doc-String, das die Grep-Variante fälschlich als „Cleanup
  vorhanden" zählen würde).
  """
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Process.send_after(self(), …) ohne Process.cancel_timer im File →
      Zombie-Timer nach Restart. Ref halten + beim Reschedule/Terminate canceln.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    ast = SourceFile.ast(source_file)

    {send_after_lines, has_cancel?} = scan(ast, {[], false})

    if send_after_lines != [] and not has_cancel? do
      send_after_lines
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    else
      []
    end
  end

  defp scan({_form, meta, args} = node, {lines, cancel?}) when is_list(meta) do
    lines = if send_after_self?(node), do: [Keyword.get(meta, :line, 0) | lines], else: lines
    cancel? = cancel? or cancel_timer?(node)
    scan(args, {lines, cancel?})
  end

  defp scan(list, acc) when is_list(list), do: Enum.reduce(list, acc, &scan/2)
  defp scan({l, r}, acc), do: scan(r, scan(l, acc))
  defp scan(_other, acc), do: acc

  # Process.send_after(self(), …) — erstes Arg ist self().
  defp send_after_self?(
         {{:., _, [{:__aliases__, _, [:Process]}, :send_after]}, _, [{:self, _, _} | _]}
       ),
       do: true

  defp send_after_self?(_), do: false

  defp cancel_timer?({{:., _, [{:__aliases__, _, [:Process]}, :cancel_timer]}, _, _}), do: true
  defp cancel_timer?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Process.send_after(self(), …) ohne Process.cancel_timer im File — " <>
          "Zombie-Timer-Leak nach Restart.",
      line_no: line_no,
      trigger: "Process.send_after"
    )
  end
end
