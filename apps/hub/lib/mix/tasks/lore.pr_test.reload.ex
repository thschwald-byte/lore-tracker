defmodule Mix.Tasks.Lore.PrTest.Reload do
  @shortdoc "Bestückt eine laufende Teststage mit neuem Code — ohne die Mnesia zu verlieren"

  @moduledoc """
  Bringt eine laufende Teststage auf den aktuellen Stand ihres Branches, ohne
  ihr Datenverzeichnis anzufassen (Issue #850).

      mix lore.pr_test.reload 4001
      mix lore.pr_test.reload 4001 --nur worker
      mix lore.pr_test.reload 4001 --ohne-git

  Der Weg, den es ersetzt, ist `mix lore.pr_test_down` plus ein frischer Spawn —
  und der wirft die Worker-Mnesia weg. Darin stecken regelmässig Daten, die
  nicht reproduzierbar sind: eine per Event-Replay eingespielte Kampagne,
  Stunden Pipeline-Rechenzeit eines Jack-Laufs. Danach spielt man sie neu ein.

  Drei Schritte, in dieser Reihenfolge:

  1. **Worktree auf den Stand des Branches** (`--ohne-git` überspringt das).
    Der Branch steht im Lock unter `~/Projekte/.claude-issue-locks/`; geholt
    wird aus dem Haupt-Repo, nicht von Codeberg — der Stand soll der sein, an
    dem gerade gearbeitet wird, auch ungepusht.
  2. **Übersetzen** — vor dem Beenden, damit die Stage nicht während des
    Compiles steht und ein Fehlschlag sie nicht beendet zurücklässt.
  3. **BEAMs neu starten** (`Mix.Tasks.Lore.PrTest.Neustart`), Umgebung und
    Arbeitsverzeichnis aus `/proc`, Datenverzeichnis unberührt.

  **Der Hub allein braucht das oft gar nicht:** `config/dev.exs` hat den
  Code-Reloader, geänderte Module lädt er bei der nächsten Anfrage nach. Für
  neue Module und alles im Worker gilt das nicht — deshalb ist der Standard
  „beide".
  """

  use Mix.Task

  alias Mix.Tasks.Lore.PrTest.Neustart

  @repo_root Path.expand("../../../../..", __DIR__)

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv, strict: [nur: :string, ohne_git: :boolean])

    port = port!(rest)
    nur = nur!(opts[:nur])
    worktree = Neustart.worktree(port) || Mix.raise("Keine laufende Stage auf Port #{port}.")

    Mix.shell().info("Teststage #{port} — Worktree #{worktree}")

    unless opts[:ohne_git], do: git_aktualisieren!(worktree, port)
    uebersetzen!(worktree)
    Neustart.neu_starten(port, nur)

    Mix.shell().info("Fertig. http://localhost:#{port}/ — die Mnesia ist unberührt.")
  end

  defp port!([p]) do
    case Integer.parse(p) do
      {port, ""} -> port
      _ -> Mix.raise("Port muss eine Zahl sein, war: #{p}")
    end
  end

  defp port!(_), do: Mix.raise("Aufruf: mix lore.pr_test.reload <port> [--nur hub|worker]")

  defp nur!(nil), do: nil
  defp nur!("hub"), do: :hub
  defp nur!("worker"), do: :worker
  defp nur!(anderes), do: Mix.raise("--nur kennt hub oder worker, nicht #{anderes}")

  # ─── Schritt 1: Git ───────────────────────────────────────────────────

  defp git_aktualisieren!(worktree, port) do
    case branch(port) do
      nil ->
        Mix.shell().info("  Kein Branch im Lock — Worktree bleibt, wie er ist.")

      branch ->
        Mix.shell().info("  Hole #{branch} aus dem Arbeits-Repo …")

        {_, 0} =
          System.cmd("git", ["fetch", @repo_root, branch],
            cd: worktree,
            stderr_to_stdout: true
          )

        # Der Worktree hat detached HEAD (Issue #190) — genau dafür ist er da.
        {_, 0} =
          System.cmd("git", ["checkout", "--detach", "FETCH_HEAD"],
            cd: worktree,
            stderr_to_stdout: true
          )

        {sha, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: worktree)
        Mix.shell().info("  #{String.trim(sha)}")
    end
  end

  # Der Branch steht im PR-Test-Lock (Issue #330), vierte Spalte.
  defp branch(port) do
    lock =
      Path.join([System.user_home!(), "Projekte/.claude-issue-locks", "pr-test-#{port}.lock"])

    with {:ok, inhalt} <- File.read(lock),
         [_worktree, _hub, _worker, branch | _] <- inhalt |> String.trim() |> String.split("|") do
      branch
    else
      _ -> nil
    end
  end

  # ─── Schritt 2: übersetzen ────────────────────────────────────────────

  defp uebersetzen!(worktree) do
    Mix.shell().info("  Übersetze …")

    {ausgabe, status} =
      System.cmd("mix", ["compile"],
        cd: worktree,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      # Bewusst vor dem Beenden: eine laufende Stage mit altem Code ist besser
      # als eine beendete ohne neuen.
      Mix.raise("Übersetzen gescheitert — die Stage läuft unverändert weiter:\n#{ausgabe}")
    end

    Mix.shell().info("  Übersetzt.")
  end
end
