# Issue #571: TimerWithoutCleanup disabled — Self-Reschedule-Health-Poll.
# handle_info(:poll_health) → send_after(:poll_health) bis das Sidecar
# ready ist. Soll ohne Cancel weiterlaufen; bei :sidecar_exited stoppt
# der GenServer und nimmt den Timer mit. Folge-Cut für Check-Tune offen.
# credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup
defmodule Worker.Sidecar do
  @moduledoc """
  Lifecycle-Manager für Python-FastAPI-Sidecars (Issue #281b, generalisiert in
  Issue #296). Eine GenServer-Instanz pro Sidecar, konfiguriert über eine
  Spec-Map. Bei Worker-Start:

  1. Findet uvicorn-Binary (Spec-`uvicorn_default`, override via Spec-`uvicorn_env`,
     fallback `System.find_executable("uvicorn")`)
  2. Findet das Sidecar-Script unter `priv/sidecar/<spec.script>`
  3. Wählt freien TCP-Port (Spec-`default_port`, override via Spec-`port_env`;
     fallback auf OS-zugewiesenen Port wenn belegt — z.B. bei mehreren Workern)
  4. Spawnt uvicorn als OS-Subprocess via `Port.open/2` mit `:spawn_executable`
     (inkl. Spec-`extra_env` als zusätzliche Subprozess-Env-Vars)
  5. Pollt `/health` bis das Modell geladen ist (max `health_max_attempts`s)
  6. Schreibt die URL in `Worker.Settings` unter Spec-`setting_key`

  Bei Worker-Shutdown (Supervisor terminate → terminate/2):
  - Leert die Spec-`setting_key`-Setting
  - SIGTERM auf den OS-PID, kurzes Warten, SIGKILL als Backstop

  Defensive: jede Fehlbedingung loggt + skipt. Skip-Gate: Spec-`disable_env` == "1".

  Zwei Instanzen werden im Supervisor gestartet (siehe `Worker.Application`):
  - Faithfulness-NLI-Sidecar (Port 8765, `:faithfulness_sidecar_url`)
  - Diarisierungs-Sidecar (Port 8766, `:diarization_sidecar_url`, pyannote)
  """

  use GenServer
  require Logger

  @health_poll_interval_ms 1_000
  @default_health_max_attempts 90

  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: spec.name)

  def child_spec(spec) do
    %{
      id: spec.name,
      start: {__MODULE__, :start_link, [spec]},
      type: :worker,
      restart: :transient,
      # Mehr als die SIGTERM-Wartezeit in kill_sidecar/1, damit terminate/2
      # ohne vorzeitiges brutal_kill abläuft.
      shutdown: 5_000
    }
  end

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)

    if System.get_env(spec.disable_env) == "1" do
      Logger.info("Sidecar[#{spec.label}]: #{spec.disable_env}=1 — autostart übersprungen")
      :ignore
    else
      case start_sidecar(spec) do
        {:ok, state} ->
          send(self(), :poll_health)
          {:ok, state}

        {:error, reason} ->
          Logger.warning(
            "Sidecar[#{spec.label}]: autostart fehlgeschlagen (#{inspect(reason)}) — übersprungen."
          )

          :ignore
      end
    end
  end

  @impl true
  def handle_info(:poll_health, %{spec: spec, attempts: a} = state)
      when a >= spec.health_max_attempts do
    Logger.warning(
      "Sidecar[#{spec.label}]: /health hat nach #{spec.health_max_attempts}s nicht 200 geliefert — gebe auf"
    )

    {:stop, :health_timeout, state}
  end

  def handle_info(:poll_health, %{spec: spec, port_number: port_number, attempts: a} = state) do
    case sidecar_health(port_number) do
      :ok ->
        url = "http://127.0.0.1:#{port_number}"
        :ok = Worker.Settings.put(spec.setting_key, url)
        Logger.info("Sidecar[#{spec.label}]: ready at #{url} (Modell geladen)")
        {:noreply, %{state | ready?: true}}

      :error ->
        Process.send_after(self(), :poll_health, @health_poll_interval_ms)
        {:noreply, %{state | attempts: a + 1}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{spec: spec, port: port} = state) do
    Logger.warning("Sidecar[#{spec.label}]: uvicorn beendete sich mit exit_status=#{status}")
    Worker.Settings.put(spec.setting_key, nil)
    {:stop, :sidecar_exited, %{state | port: nil}}
  end

  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{spec: spec} = state) do
    Worker.Settings.put(spec.setting_key, nil)
    kill_sidecar(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ─── Internals ────────────────────────────────────────────────────

  defp start_sidecar(spec) do
    with {:ok, uvicorn} <- find_uvicorn(spec),
         {:ok, sidecar_dir} <- find_sidecar_dir(spec),
         {:ok, port_number} <- pick_port(spec) do
      args = [
        "--app-dir",
        sidecar_dir,
        spec.app,
        "--host",
        "127.0.0.1",
        "--port",
        Integer.to_string(port_number)
      ]

      Logger.info("Sidecar[#{spec.label}]: spawne #{uvicorn} #{spec.app} (port=#{port_number})")

      {executable, exec_args, tag_symlink} = build_spawn_target(uvicorn, args, spec.label)

      port_opts =
        [:binary, :exit_status, :stderr_to_stdout, args: exec_args] ++ env_opt(spec.extra_env)

      port = Port.open({:spawn_executable, executable}, port_opts)

      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          {:ok,
           %{
             spec: spec,
             port: port,
             os_pid: os_pid,
             port_number: port_number,
             uvicorn: uvicorn,
             tag_symlink: tag_symlink,
             attempts: 0,
             ready?: false
           }}

        nil ->
          remove_tag_symlink(tag_symlink)
          {:error, :port_already_dead}
      end
    end
  end

  # Issue #403: In PR-Test-Stacks (LORE_PRTEST_TAG gesetzt) den Sidecar-Prozess
  # so starten, dass er in `ps`/`pgrep` seinem Issue + Port zuordenbar ist —
  # via Symlink `<venv-bin>/<tag>-sidecar-<label>` → python, der direkt gespawnt
  # wird (`<symlink> -m uvicorn …`). argv0 ist dann der Symlink-Pfad und trägt
  # den Tag.
  #
  # WARUM Symlink statt `exec -a`: `exec -a title python` setzt argv0 auf einen
  # Nicht-Pfad → CPython findet die venv-site-packages nicht mehr ("No module
  # named uvicorn"). Der Symlink liegt neben pyvenv.cfg im venv-bin, also bleibt
  # die venv-Detection intakt, UND der Tag steht im argv0.
  #
  # Ohne Tag (prod/dev) oder ohne auffindbares venv-python: direkter Spawn wie
  # gehabt → kein Verhaltensunterschied. Rückgabe: {executable, args, symlink|nil}.
  defp build_spawn_target(uvicorn, args, label) do
    with tag when is_binary(tag) and tag != "" <- System.get_env("LORE_PRTEST_TAG"),
         python when is_binary(python) <- venv_python(uvicorn) do
      title = "#{tag}-sidecar-#{label}"
      link = Path.join(Path.dirname(python), title)
      _ = File.rm(link)

      case File.ln_s(python, link) do
        :ok -> {link, ["-m", "uvicorn" | args], link}
        _ -> {uvicorn, args, nil}
      end
    else
      _ -> {uvicorn, args, nil}
    end
  end

  # python3/python neben dem uvicorn-Binary im venv-bin. nil → ungetaggt weiter.
  defp venv_python(uvicorn) do
    dir = Path.dirname(uvicorn)
    Enum.find([Path.join(dir, "python3"), Path.join(dir, "python")], &File.exists?/1)
  end

  defp remove_tag_symlink(nil), do: :ok
  defp remove_tag_symlink(path), do: File.rm(path)

  # Port.open env-Option: charlist-Tupel. Leer → keine Option (erbt Worker-Env).
  defp env_opt([]), do: []

  defp env_opt(extra_env) when is_list(extra_env) do
    [{:env, Enum.map(extra_env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}]
  end

  defp find_uvicorn(spec) do
    candidates = [
      System.get_env(spec.uvicorn_env),
      Path.expand(spec.uvicorn_default),
      System.find_executable("uvicorn")
    ]

    case Enum.find(candidates, &valid_uvicorn?/1) do
      nil -> {:error, :no_uvicorn_found}
      path -> {:ok, path}
    end
  end

  defp valid_uvicorn?(nil), do: false
  defp valid_uvicorn?(path) when is_binary(path), do: File.exists?(path)

  defp find_sidecar_dir(spec) do
    dir = Application.app_dir(:worker, "priv/sidecar")
    script = Path.join(dir, spec.script)

    if File.exists?(script) do
      {:ok, dir}
    else
      {:error, {:no_sidecar_script, script}}
    end
  end

  defp pick_port(spec) do
    requested =
      case System.get_env(spec.port_env) do
        nil ->
          spec.default_port

        s ->
          case Integer.parse(s) do
            {n, _} -> n
            :error -> spec.default_port
          end
      end

    case :gen_tcp.listen(requested, [:binary]) do
      {:ok, listener} ->
        :gen_tcp.close(listener)
        {:ok, requested}

      {:error, :eaddrinuse} ->
        case :gen_tcp.listen(0, [:binary]) do
          {:ok, listener} ->
            {:ok, port} = :inet.port(listener)
            :gen_tcp.close(listener)

            Logger.info(
              "Sidecar[#{spec.label}]: Port #{requested} belegt → fallback auf OS-Port #{port}"
            )

            {:ok, port}

          {:error, reason} ->
            {:error, {:no_free_port, reason}}
        end

      {:error, reason} ->
        {:error, {:listen_failed, reason}}
    end
  end

  defp sidecar_health(port_number) do
    url = String.to_charlist("http://127.0.0.1:#{port_number}/health")
    request = {url, []}
    http_opts = [{:timeout, 1_000}, {:connect_timeout, 500}]

    case :httpc.request(:get, request, http_opts, []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        if String.contains?(to_string(body), "\"loaded\":true"), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp kill_sidecar(%{os_pid: os_pid, port: port} = state) when is_integer(os_pid) do
    # Issue #403: Tag-Symlink ZUERST entfernen — der laufende uvicorn hat seinen
    # Pfad beim execve schon aufgelöst, braucht ihn nicht mehr. Würde der
    # Supervisor uns während des 1,5s-Grace unten brutal-killen, liefe ein
    # Cleanup am Ende nie → der Symlink bliebe im venv-bin liegen.
    remove_tag_symlink(Map.get(state, :tag_symlink))

    Logger.info("Sidecar: SIGTERM pid=#{os_pid}")
    _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    # 1.5s Grace + SIGKILL als Backstop. Muss kleiner als child_spec.shutdown
    # bleiben, sonst killt der Supervisor uns mit :brutal_kill.
    Process.sleep(1_500)
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  defp kill_sidecar(_), do: :ok

  # ─── Specs ────────────────────────────────────────────────────────

  @doc """
  Spec für den Faithfulness-NLI-Sidecar (Issue #281b). Unverändertes Verhalten
  gegenüber der hartcodierten Vorversion.
  """
  def faithfulness_spec do
    %{
      name: :faithfulness_sidecar,
      label: "faithfulness",
      uvicorn_default: "~/.venvs/faithfulness-sidecar/bin/uvicorn",
      uvicorn_env: "LORE_SIDECAR_UVICORN_PATH",
      script: "faithfulness_sidecar.py",
      app: "faithfulness_sidecar:app",
      default_port: 8765,
      port_env: "LORE_SIDECAR_PORT",
      setting_key: :faithfulness_sidecar_url,
      disable_env: "LORE_SIDECAR_DISABLE",
      extra_env: [],
      health_max_attempts: @default_health_max_attempts
    }
  end

  @doc """
  Spec für den Diarisierungs-Sidecar (pyannote, Issue #19/#296). Eigener venv,
  Port 8766, eigener Disable-Schalter. `MIOPEN_DEBUG_COMGR_HIP_BUILD_FATBIN=0`
  fixt den MIOpen-RNN-Kernel-Build auf AMD/ROCm (gfx1100) und ist auf NVIDIA ein
  No-op. `HUGGINGFACE_TOKEN` wird durchgereicht, falls in der Worker-Env gesetzt
  (sonst greift der `huggingface-cli login`-Cache). Erststart lädt mehrere
  Modelle → großzügigeres Health-Timeout.
  """
  def diarization_spec do
    hf_env =
      case System.get_env("HUGGINGFACE_TOKEN") do
        nil -> []
        "" -> []
        token -> [{"HUGGINGFACE_TOKEN", token}]
      end

    %{
      name: :diarization_sidecar,
      label: "diarization",
      uvicorn_default: "~/.venvs/diarization-sidecar/bin/uvicorn",
      uvicorn_env: "LORE_DIARIZATION_UVICORN_PATH",
      script: "diarization_sidecar.py",
      app: "diarization_sidecar:app",
      default_port: 8766,
      port_env: "LORE_DIARIZATION_SIDECAR_PORT",
      setting_key: :diarization_sidecar_url,
      disable_env: "LORE_DIARIZATION_SIDECAR_DISABLE",
      extra_env: [{"MIOPEN_DEBUG_COMGR_HIP_BUILD_FATBIN", "0"}] ++ hf_env,
      health_max_attempts: 180
    }
  end
end
