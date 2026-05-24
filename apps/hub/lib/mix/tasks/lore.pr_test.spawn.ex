defmodule Mix.Tasks.Lore.PrTest.Spawn do
  @shortdoc "Auto-spawn PR-test instance for current branch (Issue #186)"

  @moduledoc """
  Convenience-Wrapper für `mix lore.pr_test`. Ermittelt automatisch den
  aktuellen Branch (`git rev-parse --abbrev-ref HEAD`), räumt stale Stacks
  auf den eigenen Slot-Ports ab (Pre-Cleanup) und ruft den bestehenden
  `lore.pr_test`-Task mit `--seed` auf. Port wird aus dem cwd-Slot in
  `CLAUDE.local.md` allokiert (siehe `Mix.Tasks.Lore.PrTest.Ports`).

  Pflicht-Schritt im CLAUDE.md-Workflow nach `tea pulls create` (Issues
  #186 + #190). Volle Stack-Anatomie + Spawn-Flow + Tear-Down siehe
  `docs/PR-Test-Setup.md`.

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

    cleanup_own_slot!()

    Mix.Task.run("lore.pr_test", [branch, "--seed"])
  end

  # Pre-Cleanup (Issue #190): vor jedem Spawn die eigenen Slot-Ports
  # leerräumen, damit `spawn` immer auf den primären Slot-Port landet
  # und kein "Slot-Port-Hopping weil 4005 noch stale ist" entsteht.
  #
  # Für jeden Slot-Port: existiert `/tmp/pr-<port>/hub.pid`, ist da ein
  # früherer Stack stehen geblieben → `lore.pr_test_down <port>` aufrufen.
  # Idempotent: wenn nichts läuft, no-op (Down-Task ist robust gegen
  # fehlende PID-Files).
  defp cleanup_own_slot! do
    cwd =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        {_, _} -> File.cwd!()
      end

    slot_ports = Mix.Tasks.Lore.PrTest.Ports.slot_for_cwd!(cwd)

    cleaned_any? =
      Enum.reduce(slot_ports, false, fn port, acc ->
        if has_running_stack?(port) do
          Mix.shell().info("  Pre-Cleanup: stale Stack auf Port #{port} → lore.pr_test_down")
          Mix.Task.rerun("lore.pr_test_down", [Integer.to_string(port)])
          true
        else
          acc
        end
      end)

    # Race-Condition: kill PID → BEAM-TCP-Verbindung zu EPMD schließt erst
    # mit ~1s Verzögerung, EPMD hält den sname bis dahin reserviert. Wenn
    # spawn sofort einen neuen BEAM mit demselben sname startet → "name
    # seems to be in use" → BEAM stirbt direkt nach Startup. 2s Puffer
    # nach Pre-Cleanup gibt EPMD Zeit den alten Eintrag aufzuräumen.
    if cleaned_any?, do: Process.sleep(2_000)
  end

  defp has_running_stack?(port) do
    File.exists?("/tmp/pr-#{port}/hub.pid") or
      File.exists?("/tmp/pr-#{port}/worker-0.pid")
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
