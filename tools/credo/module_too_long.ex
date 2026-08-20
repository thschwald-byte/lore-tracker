defmodule LoreTracker.Credo.Check.ModuleTooLong do
  @moduledoc """
  Issue #544: God-Module-Erkennung — der Headline-Use-Case des Issues.

  Die Umbrella-Code-Review (2026-06-04) fand mehrere God-Module
  (pipeline.ex 2134 Z., repo.ex 1631, materializer.ex 1583,
  admin_probelauf_live.ex 1474). Credo hat von Haus aus keinen File-Zeilen-
  Count-Check (nur lange Funktionen / Komplexität / Nesting) — daher als
  Custom-Check: ein File über `:max_lines` Zeilen ist ein Refactoring-Kandidat
  (zu viele Verantwortlichkeiten, schwer zu testen/reviewen).

  Bewusst pro File (nicht pro `defmodule`), weil hier ~1 Modul pro File gilt
  und die Review ebenfalls in Datei-Zeilen maß.

  ## Issue #1097: gezählt wird CODE, nicht Zeilen

  Bis hierher zählte der Check `SourceFile.lines() |> length()` — jede Zeile
  gleich, ob Code, Leerzeile, `@moduledoc` oder Begründungskommentar. Über
  alle 256 Dateien gemessen (2026-08-20) sind davon nur **60 % Code**; bei den
  Dateien nahe der Grenze fällt der Anteil auf **49 %**
  (`voice_session.ex`: 916 Zeilen, davon 452 Code und 367 Doku).

  Damit maß der Check die Sorgfalt mit, die in diesem Projekt ausdrücklich
  gewollt ist — Begründungskommentare am Code sind hier keine Zutat, sondern
  das Mittel gegen Wissensverlust zwischen Sessions. Und er zeigte auf die
  falschen Dateien: `artifacts.ex` war mit 995 Zeilen die knappste im Repo,
  nach Code aber nur Rang 3; die grösste Code-Datei
  (`einstellungen_live.ex`, 775) stand nach Gesamtzeilen auf Rang 3.

  Gezählt wird jetzt, was `code_lines/1` übriglässt: keine Leerzeilen, keine
  `#`-Kommentare, keine `@moduledoc`/`@doc`/`@typedoc`/`@shortdoc`-Heredocs.
  Die Grenze liegt entsprechend niedriger (600 statt 1000).

  **Was das nicht kann.** Zeilenzahl bleibt ein Proxy für „zu viele
  Verantwortlichkeiten" — nur ein etwas ehrlicherer. Ein Modul mit 400 Zeilen
  Code und sechs Zuständigkeiten ist ein God-Module, das dieser Check nicht
  sieht; ein generierter 700-Zeilen-Mapper ist keins und wird trotzdem
  geflaggt. Ein Schnitt, der nur Zeilen verteilt, um unter die Zahl zu kommen,
  erzeugt zwei Module, die sich gegenseitig brauchen — das ist schlechter als
  eine lange Datei.

  Ebenfalls unverändert: der Check misst den **Zwischenstand** einer Datei,
  nicht das Ergebnis einer Änderung. Ein PR, der eine Datei am Ende
  verkleinert, kann sie zwischendurch über die Grenze schieben (real passiert:
  `audio_buffer.ex` 981 → 1157 → 959). Und zwei parallele Branches, von denen
  keiner allein die Grenze reisst, können sie zusammen reissen — rot wird dann
  master, nicht der PR.
  """
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [max_lines: 600, bestand: []],
    explanations: [
      check: """
      Ein File über :max_lines CODE-Zeilen ist ein God-Module-Refactoring-
      Kandidat. In kohäsive Module entlang von Verantwortlichkeiten aufteilen —
      nicht Zeilen verschieben, bis der Check schweigt.

      Gezählt werden nur Code-Zeilen: Leerzeilen, `#`-Kommentare und
      Doku-Heredocs (`@moduledoc`/`@doc`/`@typedoc`/`@shortdoc`) zählen NICHT
      (Issue #1097 — die Doku-Dichte dieses Projekts ist Absicht und soll
      nicht bestraft werden).
      """,
      params: [
        max_lines: "Maximale CODE-Zeilen pro File (Default 600).",
        bestand:
          "Ratsche für Bestandsdateien: `[{\"pfad/datei.ex\", 775}]`. Die Datei " <>
            "darf ihren eingetragenen Stand halten, aber nicht überschreiten — " <>
            "wächst sie um eine Zeile, wird der Check rot. Sinkt sie unter " <>
            "`:max_lines`, gilt wieder die reguläre Grenze und der Eintrag kann weg."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  # Beginn eines Doku-Heredocs: `@moduledoc """` (auch `~S"""`).
  @doc_heredoc ~r/^\s*@(moduledoc|doc|typedoc|shortdoc)\s+(~[A-Za-z])?"""/
  # Einzeiliges Doku-Attribut: `@doc false`, `@moduledoc "kurz"`.
  @doc_single ~r/^\s*@(moduledoc|doc|typedoc|shortdoc)\s+(false|"(\\.|[^"\\])*")\s*$/

  @impl true
  def run(%SourceFile{} = source_file, params) do
    max_lines = Params.get(params, :max_lines, __MODULE__)
    bestand = Params.get(params, :bestand, __MODULE__)
    lines = SourceFile.lines(source_file)
    count = code_lines(lines)
    grenze = grenze_fuer(source_file.filename, bestand, max_lines)

    if count > grenze do
      issue_meta = IssueMeta.for(source_file, params)
      [issue_for(issue_meta, count, length(lines), grenze)]
    else
      []
    end
  end

  @doc """
  Die Grenze für eine Datei: ihr Bestands-Eintrag, sonst `max_lines`.

  Die Ratsche (Issue #1097) hält Bestandsdateien auf ihrem heutigen Stand
  fest, statt sie auszunehmen. Der Unterschied ist der Punkt: eine Ausnahme
  ist unsichtbar und wächst mit, eine Ratsche macht jedes Wachstum sofort rot
  und schrumpft von selbst — sinkt die Datei unter `max_lines`, greift wieder
  die reguläre Grenze und der Eintrag ist überflüssig.

  Ein Bestands-Eintrag UNTER `max_lines` wird ignoriert (`max/2`): er könnte
  eine Datei sonst strenger gaten als die reguläre Grenze, und das wäre eine
  Regel, die niemand gelesen hat.
  """
  @spec grenze_fuer(String.t() | nil, [{String.t(), integer()}], integer()) :: integer()
  def grenze_fuer(filename, bestand, max_lines) do
    case List.keyfind(bestand || [], to_string(filename), 0) do
      {_pfad, erlaubt} when is_integer(erlaubt) -> max(erlaubt, max_lines)
      _ -> max_lines
    end
  end

  @doc """
  Zählt die Code-Zeilen einer Datei: alles ausser Leerzeilen, `#`-Kommentaren
  und Doku-Heredocs.

  Nimmt entweder Credos `{lineno, text}`-Liste oder eine Liste roher Strings —
  die zweite Form macht die Funktion ohne Credo-Fixture testbar.

  **Die Grenze der Erkennung, benannt statt versteckt:** ein Doku-Heredoc
  endet an der ersten Zeile, die nur `\"\"\"` enthält. Ein Heredoc, das selbst
  eine solche Zeile einrückungsgleich enthält, endet für diese Zählung zu
  früh — der Rest zählt dann als Code. Das ist bewusst in die vorsichtige
  Richtung falsch: im Zweifel wird MEHR als Code gezählt, der Check schlägt
  also eher zu früh an als zu spät.
  """
  @spec code_lines([{integer(), String.t()}] | [String.t()]) :: non_neg_integer()
  def code_lines(lines) do
    lines
    |> Enum.map(fn
      {_no, text} -> text
      text when is_binary(text) -> text
    end)
    |> Enum.reduce({0, false}, &klassifiziere/2)
    |> elem(0)
  end

  # {Zähler, im_doku_heredoc?}
  defp klassifiziere(text, {n, true}) do
    if String.trim(text) == ~s("""), do: {n, false}, else: {n, true}
  end

  defp klassifiziere(text, {n, false}) do
    cond do
      Regex.match?(@doc_heredoc, text) -> {n, true}
      Regex.match?(@doc_single, text) -> {n, false}
      String.trim(text) == "" -> {n, false}
      String.starts_with?(String.trim(text), "#") -> {n, false}
      true -> {n + 1, false}
    end
  end

  defp issue_for(issue_meta, count, total, max_lines) do
    format_issue(
      issue_meta,
      message:
        "God-Module: #{count} Code-Zeilen (> #{max_lines}; #{total} Zeilen gesamt) — " <>
          "in kohäsive Module entlang von Verantwortlichkeiten aufteilen.",
      line_no: 1,
      trigger: "defmodule"
    )
  end
end
