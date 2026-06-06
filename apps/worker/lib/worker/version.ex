defmodule Worker.Version do
  @moduledoc """
  Compile-time-resolved Worker-Version + Git-SHA + Dirty-Flag.

  `vsn` kommt aus `apps/worker/mix.exs`, `sha` aus `git rev-parse --short HEAD`,
  `dirty?` aus `git status --porcelain` (truthy wenn working-tree dreckig).
  Beides wird zur Compile-Zeit aufgelöst — in iex-Sessions bleibt der SHA
  bis recompile alt, bei Worker-Releases (build-time hat git verfügbar)
  ist der SHA der tatsächlich verteilte Stand.
  """

  @vsn Mix.Project.config()[:version]

  @sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha)
          _ -> "unknown"
        end)

  @dirty? (case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
             {"", 0} -> false
             {_, 0} -> true
             _ -> true
           end)

  # Issue #624: `display/0` zur Compile-Zeit auflösen. Frühere Variante mit
  # `format/1` + Runtime-`if @dirty?` triggerte einen Dialyzer-guard_fail —
  # `@dirty?` ist Compile-Zeit-Konstante, also sah Dialyzer einen Branch als
  # tot. Hier wird die Auswahl beim Modul-Compile entschieden, kein Branch
  # zur Laufzeit, keine Type-Analyse-Inkonsistenz.
  @display (if @dirty?,
              do: "#{@vsn}+dev (#{@sha}-dirty)",
              else: "#{@vsn} (#{@sha})")

  @spec current() :: %{vsn: String.t(), sha: String.t(), dirty?: boolean()}
  def current, do: %{vsn: @vsn, sha: @sha, dirty?: @dirty?}

  @spec display() :: String.t()
  def display, do: @display
end
