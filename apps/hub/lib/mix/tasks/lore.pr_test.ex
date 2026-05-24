defmodule Mix.Tasks.Lore.PrTest do
  @shortdoc "Spin up a PR-test instance (Hub + Worker(s) + optional Romeo seed)"

  @moduledoc """
  Single-shot PR-test setup (Issue #167; siehe auch #186 Slot-Lookup +
  `lore.pr_test.spawn`-Wrapper, #190 Detach-Gotchas).

  Volle Stack-Anatomie + Spawn-Flow + Tear-Down: `docs/PR-Test-Setup.md`.


  Bootet eine isolierte Hub-Instanz auf einem freien PR-Test-Port (4001 oder
  4002) zusammen mit einem oder mehreren pre-gepairten Workern. Alles als
  detached Background-Prozesse — der Mix-Task selbst terminiert nach Setup
  und öffnet den Browser auf das frische Dashboard.

      mix lore.pr_test issue-167-foo
      mix lore.pr_test issue-167-foo --seed
      mix lore.pr_test issue-167-foo --admins 615...,123... --seed

  Default-Admin-Discord-ID kommt aus `LORE_LOCAL_ADMIN_DISCORD_ID` (.env).
  Mit `--admins id1,id2` mehrere Workers für Multi-Worker-Szenarien.

  ## Was passiert

  1. Findet freien Port aus {4001, 4002} (CLAUDE.local.md-Sektion
     "Currently running PR-test instances" wird gelesen).
  2. `git worktree add ../lore-pr-$PORT $BRANCH` + `ln -sf .env`.
  3. Generiert fresh `LORE_JWT_SECRET` für diesen Stack.
  4. Hub-BEAM startet als detached `hub_pr$PORT`; Logs → `/tmp/pr-$PORT/hub.log`, PID → `/tmp/pr-$PORT/hub.pid`.
  5. Pro Admin: Worker-Mnesia wird via `mix run --no-start` pre-seedet
     (hub_token, worker_id, admin_discord_id direkt geschrieben — kein
     Discord-Pair-Flow nötig). Worker-BEAM startet als detached
     `worker_pr${PORT}_$IDX`.
  6. Wenn `--seed`: `mix lore.seed.romeo --hub http://localhost:$PORT
     --as-admin <first-admin>`.
  7. Browser öffnet auf `http://localhost:$PORT/`.
  8. CLAUDE.local.md "Currently running PR-test instances" wird aktualisiert.

  ## Tear-down

      mix lore.pr_test_down 4001

  Killt Hub + alle Worker-BEAMs (via PID-Files), entfernt Worktree, löscht
  /tmp-Mnesia-Dirs, räumt CLAUDE.local.md auf.
  """

  use Mix.Task

  alias Mix.Tasks.Lore.PrTest.{Runner, Ports}

  @impl Mix.Task
  def run(args) do
    # .env laden — Mix-Task triggert runtime.exs nicht automatisch.
    load_dotenv()

    {opts, positional} =
      OptionParser.parse!(args,
        strict: [seed: :boolean, admins: :string],
        aliases: [s: :seed, a: :admins]
      )

    branch =
      case positional do
        [branch] ->
          branch

        _ ->
          Mix.raise(
            "Usage: mix lore.pr_test <branch> [--seed] [--admins id1,id2,id3]"
          )
      end

    admins = parse_admins(opts)
    seed? = Keyword.get(opts, :seed, false)

    port = Ports.allocate!()

    Runner.run(%{
      branch: branch,
      port: port,
      admins: admins,
      seed?: seed?
    })
  end

  defp parse_admins(opts) do
    case opts[:admins] do
      nil ->
        case System.get_env("LORE_LOCAL_ADMIN_DISCORD_ID") do
          nil ->
            Mix.raise(
              "Either --admins id1,id2 or LORE_LOCAL_ADMIN_DISCORD_ID env-var required (set in .env)"
            )

          id ->
            [String.trim(id)] |> Enum.reject(&(&1 == ""))
            |> case do
              [] -> Mix.raise("LORE_LOCAL_ADMIN_DISCORD_ID ist leer")
              list -> list
            end
        end

      str ->
        str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  # Mix-Tasks bekommen runtime.exs nicht automatisch. Wir laden .env hier
  # manuell und schreiben ins OS-Env, damit nachfolgende System.get_env-
  # Reads + System.cmd-Subprozesse die Vars sehen.
  defp load_dotenv do
    case Code.ensure_loaded(Dotenvy) do
      {:module, _} ->
        env_dir = Path.expand("../../../../..", __DIR__)

        files = [
          Path.join(env_dir, ".env"),
          Path.join(env_dir, ".env.dev")
        ]

        Enum.each(files, fn f ->
          if File.exists?(f) do
            case File.read(f) do
              {:ok, content} ->
                for line <- String.split(content, "\n"),
                    line = String.trim(line),
                    line != "" and not String.starts_with?(line, "#"),
                    [k, v] = String.split(line, "=", parts: 2),
                    k = String.trim(k),
                    v = strip_quotes(String.trim(v)) do
                  System.put_env(k, v)
                end

              _ ->
                :ok
            end
          end
        end)

      _ ->
        :ok
    end
  end

  defp strip_quotes("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp strip_quotes("'" <> rest), do: String.trim_trailing(rest, "'")
  defp strip_quotes(s), do: s
end
