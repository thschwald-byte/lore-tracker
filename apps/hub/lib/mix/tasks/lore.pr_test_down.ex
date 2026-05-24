defmodule Mix.Tasks.Lore.PrTestDown do
  @shortdoc "Tear down a PR-test instance (kills BEAMs, removes worktree + /tmp)"

  @moduledoc """
  Tear-down zum Counter-Part `mix lore.pr_test`.

      mix lore.pr_test_down 4001

  Killt alle Hub/Worker-BEAMs via PID-Files in `/tmp/pr-$PORT/`,
  entfernt das Git-Worktree, löscht das Runtime-Verzeichnis, räumt den
  CLAUDE.local.md-Eintrag auf.
  """

  use Mix.Task

  @repo_root Path.expand("../../../../..", __DIR__)

  @impl Mix.Task
  def run([port_str]) do
    port = String.to_integer(port_str)
    runtime_dir = "/tmp/pr-#{port}"
    worktree = "#{@repo_root}/../lore-pr-#{port}"

    Mix.shell().info("Tear-down PR-Test-Stack port=#{port}")

    kill_pids!(runtime_dir)
    remove_worktree!(worktree)
    remove_runtime!(runtime_dir)
    cleanup_claude_local_md!(port)

    Mix.shell().info("Done.")
  end

  def run(_) do
    Mix.raise("Usage: mix lore.pr_test_down <port>")
  end

  defp kill_pids!(runtime_dir) do
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

    # Kurzes Warten bis die BEAMs runter sind, bevor wir Worktree wegmachen.
    Process.sleep(2_000)
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
