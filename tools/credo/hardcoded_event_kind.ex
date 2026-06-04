defmodule LoreTracker.Credo.Check.HardcodedEventKind do
  @moduledoc """
  Issue #544 (Cut 2): Port von `lore.audit`-Regel 3 — hardcodierte Event-Kind-
  Strings (`%{"kind" => "Foo"}`) außerhalb der SSoT.

  Ein hardcodierter PascalCase-Kind-String ist Drift-Risiko: ein Producer-
  Rename in `Shared.Events` zieht ihn nicht mit → der Subscriber bricht still.
  Gewollt ist die SSoT-Funktion (`Shared.Events.x()`). Ausgenommen: die
  Definition (`shared/lib/shared/events.ex`) und der Materializer-Switch
  (`worker/lib/worker/materializer.ex`).

  **Warum AST den #471/#549-FP strukturell fixt**: ein `"kind" => "Foo"` in
  einem `@moduledoc`-String oder Kommentar ist **kein** Map-Knoten im AST —
  nur echte Map-Paare `{"kind", "Foo"}` matchen. Der Doku-Beispiel-False-
  Positive, der den events_ssot_guard (#471) und lore.audit (#536) rotfärbte,
  kann hier gar nicht erst entstehen.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Hardcodierter Event-Kind-String statt Shared.Events-SSoT → Rename-Drift.
      Shared.Events.<kind>() nutzen.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @pascal ~r/^[A-Z][A-Za-z0-9]+$/

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if exempt_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> collect(0, [])
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    end
  end

  defp exempt_file?(filename) do
    String.contains?(filename, "shared/lib/shared/events.ex") or
      String.contains?(filename, "worker/lib/worker/materializer.ex")
  end

  # Map-/Keyword-Paar `{"kind", "<Pascal>"}` — bare 2-Tuple ohne eigene Meta,
  # daher die Zeile vom nächst-umschließenden Knoten (`line`).
  defp collect({"kind", val}, line, acc) when is_binary(val) do
    if Regex.match?(@pascal, val), do: [line | acc], else: acc
  end

  defp collect({_form, meta, args}, line, acc) when is_list(meta) do
    collect(args, Keyword.get(meta, :line, line), acc)
  end

  defp collect(list, line, acc) when is_list(list) do
    Enum.reduce(list, acc, fn c, a -> collect(c, line, a) end)
  end

  defp collect({l, r}, line, acc), do: collect(r, line, collect(l, line, acc))
  defp collect(_other, _line, acc), do: acc

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Hardcodierter Event-Kind-String — Shared.Events-SSoT nutzen " <>
          "(sonst Rename-Drift, Subscriber bricht still).",
      line_no: line_no,
      trigger: "kind"
    )
  end
end
