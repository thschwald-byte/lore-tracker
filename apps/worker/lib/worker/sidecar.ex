defmodule Worker.Sidecar do
  @moduledoc """
  Lifecycle-Manager für den Faithfulness-NLI-Sidecar (Python-FastAPI,
  Issue #281b). Bei Worker-Start:

  1. Findet uvicorn-Binary (default `~/.venvs/faithfulness-sidecar/bin/uvicorn`,
     override via `LORE_SIDECAR_UVICORN_PATH`)
  2. Findet das Sidecar-Script unter `priv/sidecar/faithfulness_sidecar.py`
  3. Wählt freien TCP-Port (default 8765, override via `LORE_SIDECAR_PORT`;
     fallback auf OS-zugewiesenen Port wenn 8765 belegt — z.B. bei mehreren
     Workern auf derselben Maschine)
  4. Spawnt uvicorn als OS-Subprocess via `Port.open/2` mit `:spawn_executable`
  5. Pollt `/health` bis das NLI-Model geladen ist (max 90s — initial Download
     der 400 MB Modell-Gewichte kann lange dauern)
  6. Schreibt die URL in `Worker.Settings` (`:faithfulness_sidecar_url`) — ab
     da nutzt `Worker.LLM.Faithfulness.score/2` den echten NLI-Sidecar

  Bei Worker-Shutdown (Supervisor terminate → terminate/2):
  - Leert die `:faithfulness_sidecar_url`-Setting
  - SIGTERM auf den OS-PID, kurzes Warten, SIGKILL als Backstop

  Defensive: jede Fehlbedingung loggt + skipt. Probelauf-Qualität fällt dann
  auf `Worker.LLM.Faithfulness.coverage_score/2` zurück (Trigram-Overlap-Proxy).
  Skip-Gate: `LORE_SIDECAR_DISABLE=1` für Setups die den Sidecar bewusst
  abschalten wollen.
  """

  use GenServer
  require Logger

  @default_port 8765
  @default_uvicorn_path "~/.venvs/faithfulness-sidecar/bin/uvicorn"
  @health_poll_interval_ms 1_000
  @health_poll_max_attempts 90

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      # Mehr als die SIGTERM-Wartezeit in kill_sidecar/1, damit terminate/2
      # ohne vorzeitiges brutal_kill abläuft.
      shutdown: 5_000
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    if System.get_env("LORE_SIDECAR_DISABLE") == "1" do
      Logger.info("Sidecar: LORE_SIDECAR_DISABLE=1 — autostart übersprungen")
      :ignore
    else
      case start_sidecar() do
        {:ok, state} ->
          send(self(), :poll_health)
          {:ok, state}

        {:error, reason} ->
          Logger.warning(
            "Sidecar: autostart fehlgeschlagen (#{inspect(reason)}). " <>
              "Probelauf-Qualität nutzt coverage_score-Fallback."
          )

          :ignore
      end
    end
  end

  @impl true
  def handle_info(:poll_health, %{attempts: a} = state) when a >= @health_poll_max_attempts do
    Logger.warning(
      "Sidecar: /health hat nach #{@health_poll_max_attempts}s nicht 200 geliefert — gebe auf"
    )

    {:stop, :health_timeout, state}
  end

  def handle_info(:poll_health, %{port_number: port_number, attempts: a} = state) do
    case sidecar_health(port_number) do
      :ok ->
        url = "http://127.0.0.1:#{port_number}"
        :ok = Worker.Settings.put(:faithfulness_sidecar_url, url)
        Logger.info("Sidecar: ready at #{url} (NLI-Modell geladen)")
        {:noreply, %{state | ready?: true}}

      :error ->
        Process.send_after(self(), :poll_health, @health_poll_interval_ms)
        {:noreply, %{state | attempts: a + 1}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Sidecar: uvicorn beendete sich mit exit_status=#{status}")
    Worker.Settings.put(:faithfulness_sidecar_url, nil)
    {:stop, :sidecar_exited, %{state | port: nil}}
  end

  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Worker.Settings.put(:faithfulness_sidecar_url, nil)
    kill_sidecar(state)
    :ok
  end

  # ─── Internals ────────────────────────────────────────────────────

  defp start_sidecar do
    with {:ok, uvicorn} <- find_uvicorn(),
         {:ok, sidecar_dir} <- find_sidecar_dir(),
         {:ok, port_number} <- pick_port() do
      args = [
        "--app-dir",
        sidecar_dir,
        "faithfulness_sidecar:app",
        "--host",
        "127.0.0.1",
        "--port",
        Integer.to_string(port_number)
      ]

      Logger.info("Sidecar: spawne #{uvicorn} (port=#{port_number})")

      port =
        Port.open(
          {:spawn_executable, uvicorn},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ]
        )

      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          {:ok,
           %{
             port: port,
             os_pid: os_pid,
             port_number: port_number,
             uvicorn: uvicorn,
             attempts: 0,
             ready?: false
           }}

        nil ->
          {:error, :port_already_dead}
      end
    end
  end

  defp find_uvicorn do
    candidates = [
      System.get_env("LORE_SIDECAR_UVICORN_PATH"),
      Path.expand(@default_uvicorn_path),
      System.find_executable("uvicorn")
    ]

    case Enum.find(candidates, &valid_uvicorn?/1) do
      nil -> {:error, :no_uvicorn_found}
      path -> {:ok, path}
    end
  end

  defp valid_uvicorn?(nil), do: false
  defp valid_uvicorn?(path) when is_binary(path), do: File.exists?(path)

  defp find_sidecar_dir do
    dir = Application.app_dir(:worker, "priv/sidecar")
    script = Path.join(dir, "faithfulness_sidecar.py")

    if File.exists?(script) do
      {:ok, dir}
    else
      {:error, {:no_sidecar_script, script}}
    end
  end

  defp pick_port do
    requested =
      case System.get_env("LORE_SIDECAR_PORT") do
        nil ->
          @default_port

        s ->
          case Integer.parse(s) do
            {n, _} -> n
            :error -> @default_port
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
            Logger.info("Sidecar: Port #{requested} belegt → fallback auf OS-Port #{port}")
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
        # /health liefert {"status":"ok","model":"...","loaded":true} sobald
        # die Modell-Gewichte geladen sind. Davor liefert es loaded:false
        # (FastAPI ist schon erreichbar, lifespan-init noch nicht fertig).
        if String.contains?(to_string(body), "\"loaded\":true"), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp kill_sidecar(%{os_pid: os_pid, port: port}) when is_integer(os_pid) do
    Logger.info("Sidecar: SIGTERM pid=#{os_pid}")
    _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    # 1.5s Grace + SIGKILL als Backstop. Muss kleiner als child_spec.shutdown
    # bleiben, sonst killt der Supervisor uns mit :brutal_kill.
    Process.sleep(1_500)
    _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    if is_port(port), do: Port.close(port)
    :ok
  end

  defp kill_sidecar(_), do: :ok
end
