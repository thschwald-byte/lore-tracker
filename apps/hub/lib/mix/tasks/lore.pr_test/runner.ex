defmodule Mix.Tasks.Lore.PrTest.Runner do
  @moduledoc false

  require Logger

  @repo_root Path.expand("../../../../../..", __DIR__)

  @spec run(%{branch: String.t(), port: 4001 | 4002, admins: [String.t()], seed?: boolean}) ::
          :ok
  def run(%{branch: branch, port: port, admins: admins, seed?: seed?}) do
    worktree = "#{@repo_root}/../lore-pr-#{port}"
    runtime_dir = "/tmp/pr-#{port}"
    jwt_secret = Base.encode64(:crypto.strong_rand_bytes(32))
    hostname = short_hostname()

    Mix.shell().info("PR-Test setup → port #{port}, branch #{branch}, admins #{length(admins)}")

    File.mkdir_p!(runtime_dir)
    ensure_worktree!(branch, worktree)
    symlink_env!(worktree)

    hub_node = :"hub_pr#{port}@#{hostname}"
    start_hub!(worktree, runtime_dir, port, jwt_secret, hub_node)
    wait_for_hub_ready!(port)

    worker_descriptors =
      Enum.with_index(admins, fn admin, idx ->
        %{idx: idx, admin: admin, worker_id: uuid_v7()}
      end)

    Enum.each(worker_descriptors, fn d ->
      jwt = sign_jwt!(jwt_secret, d.worker_id, d.admin)
      preseed_worker_mnesia!(worktree, runtime_dir, port, d, jwt)
      start_worker!(worktree, runtime_dir, port, d, hostname)
    end)

    if seed? do
      first_admin = List.first(admins)
      seed_romeo!(worktree, port, first_admin)
    end

    update_claude_local_md!(port, branch, admins)
    open_browser!(port)
    print_summary(port, branch, worker_descriptors, runtime_dir)
    :ok
  end

  # ─── worktree + env ─────────────────────────────────────────────

  defp ensure_worktree!(branch, worktree) do
    if File.dir?(worktree) do
      Mix.shell().info("  Worktree #{worktree} existiert — reuse.")
    else
      Mix.shell().info("  Worktree anlegen: #{worktree} (branch #{branch})")

      case System.cmd("git", ["worktree", "add", worktree, branch],
             cd: @repo_root,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {out, _} ->
          Mix.raise("git worktree add fehlgeschlagen:\n#{out}")
      end
    end
  end

  defp symlink_env!(worktree) do
    target = Path.join(worktree, ".env")

    unless File.exists?(target) do
      File.ln_s!(Path.join(@repo_root, ".env"), target)
    end
  end

  # ─── hub-BEAM ───────────────────────────────────────────────────

  defp start_hub!(worktree, runtime_dir, port, jwt_secret, hub_node) do
    log = Path.join(runtime_dir, "hub.log")
    pid_file = Path.join(runtime_dir, "hub.pid")
    hub_mnesia = Path.join(runtime_dir, "hub-mnesia")
    File.mkdir_p!(hub_mnesia)

    env = [
      {"LORE_MNESIA_DIR", hub_mnesia},
      {"LORE_JWT_SECRET", jwt_secret},
      {"PORT", Integer.to_string(port)}
    ]

    sname = hub_node |> Atom.to_string() |> String.split("@") |> List.first()

    cmd =
      Enum.join(
        [
          "elixir",
          "--sname",
          sname,
          "--cookie",
          cookie!(),
          "--no-halt",
          "-S",
          "mix",
          "phx.server"
        ],
        " "
      )

    spawn_detached!(cmd, Path.join(worktree, "apps/hub"), env, log, pid_file)
    Mix.shell().info("  Hub-BEAM (#{sname}) → port #{port}, log #{log}")
  end

  defp wait_for_hub_ready!(port) do
    Mix.shell().info("  Warte auf Hub readiness (http://localhost:#{port}/) …")

    deadline = System.monotonic_time(:millisecond) + 60_000

    poll = fn poll ->
      case :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 500) do
        {:ok, sock} ->
          :gen_tcp.close(sock)
          :ok

        {:error, _} ->
          if System.monotonic_time(:millisecond) > deadline do
            Mix.raise("Hub auf Port #{port} startete nicht innerhalb 60s")
          end

          Process.sleep(500)
          poll.(poll)
      end
    end

    poll.(poll)
    # Geben dem Hub noch ein paar 100ms für PubSub + WorkerRegistry bootstrap
    Process.sleep(500)
  end

  # ─── jwt mint (lokal, kein RPC) ─────────────────────────────────

  defp sign_jwt!(jwt_secret, worker_id, admin_discord_id) do
    # Wir nutzen Hub.WorkerJWT direkt aus diesem Mix-Task-BEAM. Damit es
    # mit dem korrekten Secret signiert, setzen wir das App-Env *temporär*
    # für die Sign-Dauer.
    prev = Application.get_env(:hub, :jwt_secret)
    Application.put_env(:hub, :jwt_secret, jwt_secret)

    try do
      Hub.WorkerJWT.sign_token(%{worker_id: worker_id, admin_discord_id: admin_discord_id})
    after
      if prev, do: Application.put_env(:hub, :jwt_secret, prev), else: Application.delete_env(:hub, :jwt_secret)
    end
  end

  # ─── worker mnesia preseed ──────────────────────────────────────

  defp preseed_worker_mnesia!(worktree, runtime_dir, port, descriptor, jwt) do
    worker_mnesia = Path.join(runtime_dir, "worker-#{descriptor.idx}-mnesia")
    File.mkdir_p!(worker_mnesia)

    seeder_sname = "pr_seeder_#{port}_#{descriptor.idx}"

    code = """
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()
    :ok = Worker.Repo.put_state_many(%{
      hub_token: #{inspect(jwt)},
      worker_id: #{inspect(descriptor.worker_id)},
      admin_discord_id: #{inspect(descriptor.admin)},
      hub_base_url: "http://localhost:#{port}",
      last_applied_seq: 0
    })
    :ok = Worker.Repo.upsert_user(#{inspect(descriptor.admin)}, "PR-Test User")
    """

    env = [{"LORE_MNESIA_DIR", worker_mnesia}]

    {output, status} =
      System.cmd(
        "elixir",
        [
          "--sname",
          seeder_sname,
          "--cookie",
          cookie!(),
          "-S",
          "mix",
          "run",
          "--no-start",
          "-e",
          code
        ],
        cd: Path.join(worktree, "apps/worker"),
        env: env,
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("Worker-Mnesia-Preseed (idx=#{descriptor.idx}) failed:\n#{output}")
    end

    Mix.shell().info(
      "  Worker[#{descriptor.idx}] Mnesia pre-seedet (admin=#{descriptor.admin})"
    )
  end

  # ─── worker-BEAM ────────────────────────────────────────────────

  defp start_worker!(worktree, runtime_dir, port, descriptor, hostname) do
    worker_mnesia = Path.join(runtime_dir, "worker-#{descriptor.idx}-mnesia")
    log = Path.join(runtime_dir, "worker-#{descriptor.idx}.log")
    pid_file = Path.join(runtime_dir, "worker-#{descriptor.idx}.pid")
    sname = "worker_pr#{port}_#{descriptor.idx}"

    env = [
      {"LORE_MNESIA_DIR", worker_mnesia},
      {"HUB_BASE_URL", "http://localhost:#{port}"},
      # Setup-Port-Konflikt vermeiden falls paired? mal false returnt
      {"LORE_WORKER_SETUP_PORT", "#{4090 + descriptor.idx}"}
    ]

    cmd =
      Enum.join(
        [
          "elixir",
          "--sname",
          sname,
          "--cookie",
          cookie!(),
          "--no-halt",
          "-S",
          "mix",
          "run"
        ],
        " "
      )

    spawn_detached!(cmd, Path.join(worktree, "apps/worker"), env, log, pid_file)
    Mix.shell().info("  Worker-BEAM (#{sname}) → log #{log}")
  end

  # ─── romeo seed ─────────────────────────────────────────────────

  defp seed_romeo!(worktree, port, admin) do
    Mix.shell().info("  Seed Romeo-Demo via mix lore.seed.romeo …")

    {output, status} =
      System.cmd(
        "mix",
        [
          "lore.seed.romeo",
          "--hub",
          "http://localhost:#{port}",
          "--as-admin",
          admin
        ],
        cd: worktree,
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.shell().error("  Seed failed (status #{status}):\n#{output}")
    else
      Mix.shell().info("  Seed durch.")
    end
  end

  # ─── claude.local.md ────────────────────────────────────────────

  defp update_claude_local_md!(port, branch, admins) do
    path = Path.join(@repo_root, "CLAUDE.local.md")

    case File.read(path) do
      {:error, _} ->
        :ok

      {:ok, content} ->
        entry =
          "- Port #{port}: branch `#{branch}`, admins #{Enum.join(admins, ", ")}, started #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}"

        new_content =
          Regex.replace(
            ~r/(##\s*Currently running PR-test instances\s*\n+)(_None\._.*?\n|.*?)(?=\n##|\z)/s,
            content,
            "\\1#{entry}\n",
            global: false
          )

        File.write!(path, new_content)
    end
  end

  # ─── browser ────────────────────────────────────────────────────

  defp open_browser!(port) do
    url = "http://localhost:#{port}/"

    case System.find_executable("xdg-open") do
      nil ->
        Mix.shell().info("  Browser-Open: kein xdg-open → öffne manuell #{url}")

      bin ->
        spawn(fn -> System.cmd(bin, [url]) end)
        Mix.shell().info("  Browser-Open: #{url}")
    end
  end

  defp print_summary(port, branch, worker_descriptors, runtime_dir) do
    Mix.shell().info("""

    PR-Test-Stack up:
      Branch:     #{branch}
      Port:       #{port}
      Workers:    #{length(worker_descriptors)} (admins: #{Enum.map_join(worker_descriptors, ", ", & &1.admin)})
      Runtime:    #{runtime_dir}
      Logs:       tail -f #{runtime_dir}/hub.log #{runtime_dir}/worker-0.log

    Tear-down:
      mix lore.pr_test_down #{port}
    """)
  end

  # ─── helpers ────────────────────────────────────────────────────

  defp spawn_detached!(cmd, cwd, env_list, log_file, pid_file) do
    env_prefix =
      env_list
      |> Enum.map(fn {k, v} -> "#{k}=#{shell_quote(v)}" end)
      |> Enum.join(" ")

    full =
      "cd #{shell_quote(cwd)} && nohup env #{env_prefix} #{cmd} > #{shell_quote(log_file)} 2>&1 & echo $! > #{shell_quote(pid_file)} ; disown"

    {_, 0} = System.cmd("bash", ["-c", full])
    :ok
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp short_hostname do
    {out, 0} = System.cmd("hostname", ["-s"])
    String.trim(out)
  end

  defp cookie! do
    case File.read("#{System.user_home!()}/.erlang.cookie") do
      {:ok, c} -> String.trim(c)
      {:error, _} -> "lore-pr-cookie"
    end
  end

  defp uuid_v7 do
    UUIDv7.generate()
  end
end
