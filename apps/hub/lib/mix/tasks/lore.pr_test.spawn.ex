defmodule Mix.Tasks.Lore.PrTest.Spawn do
  @shortdoc "Auto-spawn PR-test instance for current branch (Issue #186)"

  @moduledoc """
  Convenience-Wrapper für `mix lore.pr_test`. Ermittelt automatisch den
  aktuellen Branch (`git rev-parse --abbrev-ref HEAD`) und ruft den
  bestehenden `lore.pr_test`-Task mit `--seed` auf. Port wird aus dem
  cwd-Slot in `CLAUDE.local.md` allokiert (siehe `Mix.Tasks.Lore.PrTest.Ports`).

  Pflicht-Schritt im CLAUDE.md-Workflow nach `tea pulls create` — siehe
  Issue #186.

  ## Usage

      mix lore.pr_test.spawn

  ## Failure-Modes

  - Branch ist `master` → hartes refuse (Sicherheits-Gate gegen Versehen).
  - Branch nicht ermittelbar → Mix.raise mit Hinweis auf `git checkout`.
  - Kein cwd-Slot in `CLAUDE.local.md` → Mix.raise mit Beispiel-Eintrag.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    branch = current_branch!()

    if branch == "master" do
      Mix.raise("""
      Auf 'master'. mix lore.pr_test.spawn ist nur für Feature-Branches.

      Wechsel auf einen Issue-Branch:

          git checkout -b issue-<N>-<slug>
      """)
    end

    Mix.Task.run("lore.pr_test", [branch, "--seed"])
  end

  defp current_branch! do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, _} ->
        Mix.raise("""
        Konnte aktuellen Branch nicht ermitteln (git rev-parse failed):

        #{output}
        """)
    end
  end
end
