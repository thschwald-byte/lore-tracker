defmodule LoreTracker.Credo.Check.SyncReaderInMount do
  @moduledoc """
  Issue #544 (Decision-Gate-Spike): die `sync_reader_in_mount`-Regel aus
  `mix lore.audit` (#535) als **AST-Custom-Check** — der entscheidende
  Beweis, dass Credo die #557-Lessons aushält.

  `Reader.read/2` läuft synchron im LiveView-Prozess und blockiert ihn, bis
  der Worker antwortet (bis ~15 s). In `start_async`/`handle_async`/
  `assign_async`/`Task.*` gewrappt ist derselbe Read **async** und korrekt —
  genau der Pattern, den die Regel ERZWINGEN soll (vgl. #549, der diese
  Exemption als same-line-Regex nachrüstete).

  **Warum AST statt Regex** (#557 Root-Cause #1): „blockiert dieser Read die
  GUI?" ist Bedeutung, kein Text. Dieser Check sammelt Reader.read-Knoten
  **unterhalb** eines Wrapper-Knotens im Syntaxbaum und nimmt sie aus — fängt
  damit auch den **multi-line**-Fall, den die same-line-Regex strukturell
  nicht sehen kann.

  **AST-ist-nicht-FP-frei-Caveat** (#557): `Reader.read(scope)` (direkt) und
  `… |> Reader.read()` (gepiped) sind im AST verschiedene Knoten mit
  verschiedener Arity. Der Matcher prüft nur den Dot-Call-**Head**
  (`Reader.read`), nicht die Arg-Zahl → beide Formen werden erfasst.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Synchroner Reader.read/2 im LiveView friert den LV-Prozess ein.
      In start_async/handle_async/assign_async/Task.* wrappen (async).
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @local_wrappers [:start_async, :handle_async, :assign_async]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if lv_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> sync_read_lines(false, [])
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    else
      []
    end
  end

  # Nur die LiveView-Schicht des Hub (+ sidebar_context) — sonst ist ein
  # Reader.read kein Mount-/GUI-Blocker (Worker-RPC etc.).
  defp lv_file?(filename) do
    String.contains?(filename, "/hub_web/live/") or
      String.ends_with?(filename, "sidebar_context.ex")
  end

  # Rekursiver, kontext-tragender Walk: `in_async?` propagiert in den ganzen
  # Subtree eines Wrapper-Knotens. Ein Reader.read-Knoten wird nur geflaggt,
  # wenn sein KONTEXT nicht async ist.
  defp sync_read_lines({_form, meta, args} = node, in_async?, acc) when is_list(meta) do
    child_async? = in_async? or async_wrapper?(node)

    acc =
      if reader_read?(node) and not in_async? do
        [Keyword.get(meta, :line, 0) | acc]
      else
        acc
      end

    sync_read_lines(args, child_async?, acc)
  end

  defp sync_read_lines(list, in_async?, acc) when is_list(list) do
    Enum.reduce(list, acc, fn child, a -> sync_read_lines(child, in_async?, a) end)
  end

  defp sync_read_lines({left, right}, in_async?, acc) do
    sync_read_lines(right, in_async?, sync_read_lines(left, in_async?, acc))
  end

  defp sync_read_lines(_other, _in_async?, acc), do: acc

  # `Reader.read(...)` bzw. `…Reader.read(...)` — Arity egal (direkt + gepiped).
  defp reader_read?({{:., _, [{:__aliases__, _, mods}, :read]}, _, _}) when is_list(mods) do
    :Reader in mods
  end

  defp reader_read?(_), do: false

  # Lokale Wrapper (start_async/handle_async/assign_async) + alles auf dem
  # Task-/Task.Supervisor-Alias.
  defp async_wrapper?({fun, _, args}) when fun in @local_wrappers and is_list(args), do: true

  defp async_wrapper?({{:., _, [{:__aliases__, _, mods}, _fun]}, _, _}) when is_list(mods),
    do: :Task in mods

  defp async_wrapper?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Synchroner Reader.read/2 im LiveView blockiert den LV-Prozess — " <>
          "in start_async/assign_async/Task.* wrappen.",
      line_no: line_no,
      trigger: "Reader.read"
    )
  end
end
