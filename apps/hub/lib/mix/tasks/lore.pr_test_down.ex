defmodule Mix.Tasks.Lore.PrTestDown do
  @shortdoc "Tear down a PR-test instance (kills BEAMs, removes worktree + /tmp)"

  @moduledoc """
  Tear-down zum Counter-Part `mix lore.pr_test`.

      mix lore.pr_test_down 4001

  Killt alle Hub/Worker-BEAMs via PID-Files in `/tmp/pr-$PORT/`,
  entfernt das Git-Worktree, löscht das Runtime-Verzeichnis, räumt den
  CLAUDE.local.md-Eintrag auf.

  Sicherheit gegen Spawn-Varianten mit fehlerhaftem `pid_file` (Issue #198):
  zusätzlich zum `pid_file`-basierten Kill werden via
  `pgrep -f "-sname (hub_pr<port>|worker_pr<port>_)"` alle BEAMs erwischt,
  die mit dem passenden Sname laufen — egal wer sie gestartet hat.
  """

  use Mix.Task

  @repo_root Path.expand("../../../../..", __DIR__)

  @impl Mix.Task
  def run([port_str]) do
    port = String.to_integer(port_str)
    runtime_dir = "/tmp/pr-#{port}"
    worktree = "#{@repo_root}/../lore-pr-#{port}"

    Mix.shell().info("Tear-down PR-Test-Stack port=#{port}")

    kill_pids!(runtime_dir, port)
    remove_worktree!(worktree)
    remove_runtime!(runtime_dir)
    cleanup_claude_local_md!(port)

    Mix.shell().info("Done.")
  end

  def run(_) do
    Mix.raise("Usage: mix lore.pr_test_down <port>")
  end

  defp kill_pids!(runtime_dir, port) do
    pid_files = Path.wildcard(Path.join(runtime_dir, "*.pid"))

    Enum.each(pid_files, fn pid_file ->
      case File.read(pid_file) do
        {:ok, pid_str} ->
          pid = pid_str |> String.trim() |> String.to_integer()
          # SIGTERM, gibt dem BEAM Zeit für Cleanup.
          case System.cmd("kill", [Integer.to_string(pid)], stderr_to_stdout: true) do
            {_, 0} -> Mix.shell().info("  kill #{pid} (#{Path.basename(pid_file)})")
            {out, _} -> Mix.shell().info("  kill #{pid} skipped: #{String.trim(out)}")
          end

        {:error, _} ->
          :ok
      end
    end)

    # pid_file ist fragil — wenn der Spawn-Wrapper-Bash drinsteht statt
    # des BEAM (siehe Issue #198), überleben die BEAMs den obigen Kill.
    # Fallback: alles was via `--sname hub_pr<port>` oder
    # `--sname worker_pr<port>_*` läuft per pgrep einsammeln + killen.
    Process.sleep(500)
    kill_by_sname!(port)

    # Kurzes Warten bis die BEAMs runter sind, bevor wir Worktree wegmachen.
    Process.sleep(2_000)
  end

  defp kill_by_sname!(port) do
    pattern = "-sname (hub_pr#{port}|worker_pr#{port}_)"

    case System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true) do
      {out, 0} ->
        pids =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Enum.each(pids, fn pid ->
          case System.cmd("kill", [pid], stderr_to_stdout: true) do
            {_, 0} -> Mix.shell().info("  kill #{pid} (sname-match)")
            {out, _} -> Mix.shell().info("  kill #{pid} skipped: #{String.trim(out)}")
          end
        end)

      {_, _} ->
        # pgrep exit 1 = keine Treffer; alles andere = pgrep nicht da.
        :ok
    end
  end

  defp remove_worktree!(worktree) do
    if File.dir?(worktree) do
      case System.cmd("git", ["worktree", "remove", "--force", worktree], cd: @repo_root) do
        {_, 0} ->
          Mix.shell().info("  Worktree removed: #{worktree}")

        {out, _} ->
          Mix.shell().info("  Worktree-Remove gestolpert: #{out}. Manuell prüfen.")
      end
    end
  end

  defp remove_runtime!(runtime_dir) do
    if File.dir?(runtime_dir) do
      File.rm_rf!(runtime_dir)
      Mix.shell().info("  Runtime removed: #{runtime_dir}")
    end
  end

  defp cleanup_claude_local_md!(port) do
    path = Path.join(@repo_root, "CLAUDE.local.md")

    case File.read(path) do
      {:error, _} ->
        :ok

      {:ok, content} ->
        # Entferne Zeilen, die unsere Port-Marker tragen.
        new_content =
          content
          |> String.split("\n")
          |> Enum.reject(fn line ->
            String.contains?(line, "Port #{port}:") and String.contains?(line, "branch")
          end)
          |> Enum.join("\n")

        # Wenn unter der Section nichts mehr steht außer Whitespace,
        # füge "_None._" ein.
        new_content =
          Regex.replace(
            ~r/(##\s*Currently running PR-test instances\s*\n+)(\n+##\s|\z)/,
            new_content,
            "\\1_None._\n\n\\2"
          )

        File.write!(path, new_content)
    end
  end
end
