defmodule LoreTracker.Credo.Check.UnescapedMarkdownRender do
  @moduledoc """
  Issue #614 (Stored-XSS-Prävention): `Earmark.as_html(_, escape: false)` im
  Hub-Web-Layer rendert rohes, ungesäubertes HTML in den Browser — exakt der
  Vektor der Stored-XSS aus #604 (GM-editierbares `content_md` floss via
  `render_md/1` mit `escape: false` ungefiltert in die Seite).

  #604 hat den unsicheren Renderer gelöscht; `render_md_safe/1` (escape: true +
  `HtmlSanitizeEx.basic_html/1`) ist seither der einzige Pfad. Dieser Check
  hält ihn so: er flaggt **am Definitionspunkt** jeden Wieder-Einbau eines
  `escape: false`-Renderns.

  **Warum am Definitionspunkt statt an der Call-Site** (#604-Lesson): die Hälfte
  der ursprünglichen XSS-Sites lag im colocated `.heex`-Template
  (`campaign_live.html.heex`), das Credo gar nicht als AST sieht (nur `*.ex`).
  Ein Call-Site-Lint auf `render_md(` hätte sie verfehlt. Jeder Render-Pfad —
  auch der vom Template konsumierte — läuft aber durch einen `.ex`-Helfer, der
  `Earmark.as_html` aufruft. Das `escape: false`-Keyword dort zu flaggen deckt
  damit auch die `.heex`-konsumierten Pfade ab.

  **AST statt Regex**: `escape: false` in einem `@moduledoc`/Kommentar ist kein
  Keyword-Knoten und kann nicht zum False-Positive werden (vgl. der
  `@moduledoc`-FP, der `hardcoded_event_kind`/#471 rotfärbte). Geflaggt wird nur
  ein echtes `Earmark.as_html(…, escape: false)`-/`as_html!`-Argument.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Earmark.as_html(…, escape: false) rendert rohes HTML → Stored-XSS-Risiko
      (#604). escape: true + HtmlSanitizeEx (render_md_safe/1) nutzen.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if hub_web_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> collect([])
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    else
      []
    end
  end

  # Nur das browser-rendernde Hub-Web-Layer — escape: false im Worker o.Ä.
  # produziert kein HTML zum Browser und ist kein XSS-Vektor.
  defp hub_web_file?(filename), do: String.contains?(filename, "/hub_web/")

  # `…Earmark.as_html(…, escape: false)` / `as_html!(…)`.
  defp collect(
         {{:., _, [{:__aliases__, _, mods}, fun]}, meta, args},
         acc
       )
       when fun in [:as_html, :as_html!] and is_list(mods) and is_list(args) do
    acc =
      if List.last(mods) == :Earmark and escape_false?(args),
        do: [Keyword.get(meta, :line, 0) | acc],
        else: acc

    collect(args, acc)
  end

  defp collect({_form, _meta, args}, acc), do: collect(args, acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect({l, r}, acc), do: collect(r, collect(l, acc))
  defp collect(_other, acc), do: acc

  # `escape: false` als Keyword in einer der Argument-Listen (Options-Liste).
  defp escape_false?(args) do
    Enum.any?(args, fn
      opts when is_list(opts) -> Keyword.get(opts, :escape) == false
      _ -> false
    end)
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Earmark.as_html mit escape: false rendert rohes HTML (Stored-XSS, " <>
          "#604) — escape: true + HtmlSanitizeEx (render_md_safe/1) nutzen.",
      line_no: line_no,
      trigger: "Earmark.as_html"
    )
  end
end
