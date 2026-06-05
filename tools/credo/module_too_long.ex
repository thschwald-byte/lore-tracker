defmodule LoreTracker.Credo.Check.ModuleTooLong do
  @moduledoc """
  Issue #544: God-Module-Erkennung — der Headline-Use-Case des Issues.

  Die Umbrella-Code-Review (2026-06-04) fand mehrere God-Module
  (pipeline.ex 2134 Z., repo.ex 1631, materializer.ex 1583,
  admin_probelauf_live.ex 1474). Credo hat von Haus aus keinen File-Zeilen-
  Count-Check (nur lange Funktionen / Komplexität / Nesting) — daher als
  Custom-Check: ein File über `:max_lines` Zeilen ist ein Refactoring-Kandidat
  (zu viele Verantwortlichkeiten, schwer zu testen/reviewen).

  Crude-aber-effektiv: Zeilenzahl als Proxy für „zu groß". Bewusst pro File
  (nicht pro `defmodule`), weil hier ~1 Modul pro File gilt und die Review
  ebenfalls in Datei-Zeilen maß.
  """
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [max_lines: 1000],
    explanations: [
      check: """
      Ein File über :max_lines Zeilen ist ein God-Module-Refactoring-Kandidat.
      In kohäsive Module entlang von Verantwortlichkeiten aufteilen.
      """,
      params: [max_lines: "Maximale Zeilenzahl pro File (Default 1000)."]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    max_lines = Params.get(params, :max_lines, __MODULE__)
    line_count = source_file |> SourceFile.lines() |> length()

    if line_count > max_lines do
      issue_meta = IssueMeta.for(source_file, params)
      [issue_for(issue_meta, line_count, max_lines)]
    else
      []
    end
  end

  defp issue_for(issue_meta, line_count, max_lines) do
    format_issue(
      issue_meta,
      message:
        "God-Module: #{line_count} Zeilen (> #{max_lines}) — in kohäsive " <>
          "Module entlang von Verantwortlichkeiten aufteilen.",
      line_no: 1,
      trigger: "defmodule"
    )
  end
end
