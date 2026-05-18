defmodule Worker.Discord.PythonVoice do
  @moduledoc """
  Wraps the `voice_sidecar/bot.py` Python process via a Port.

  Discord's DAVE (E2EE) requirement on the voice gateway means Nostrum
  can't currently do voice receive. `py-cord` 2.6+ implements DAVE, so
  we run a small Python child process and proxy join/leave commands to
  it. Status events from the Python side are logged; transcribed
  utterances flow back via the hub's `/dev/event` HTTP endpoint, so
  Worker doesn't need to forward them itself.

  The Port is spawned lazily on the first `join_voice/3` call and
  recycled if it crashes. `Application.stop(:worker)` (e.g. from
  Worker.Lifecycle.shutdown) sends a clean `shutdown` op first.
  """

  use GenServer

  require Logger

  @sidecar_dir Path.join(File.cwd!(), "voice_sidecar")

  defp python_exe do
    Application.get_env(:worker, :lore_voice_python) ||
      System.get_env("LORE_VOICE_PYTHON") ||
      "python"
  end

  # ─── API ─────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def join_voice(guild_id, channel_id, session_id) do
    GenServer.call(__MODULE__, {:join, guild_id, channel_id, session_id})
  end

  def leave_voice(guild_id) do
    GenServer.call(__MODULE__, {:leave, guild_id})
  end

  def alive?, do: GenServer.call(__MODULE__, :alive?)

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{port: nil, buffer: ""}}
  end

  @impl true
  def handle_call({:join, guild_id, channel_id, session_id}, _from, state) do
    state = ensure_port(state)

    if state.port do
      send_op(state.port, %{
        "op" => "join",
        "guild_id" => to_string(guild_id),
        "channel_id" => to_string(channel_id),
        "session_id" => to_string(session_id)
      })

      {:reply, :ok, state}
    else
      {:reply, {:error, :sidecar_unavailable}, state}
    end
  end

  def handle_call({:leave, guild_id}, _from, state) do
    if state.port do
      send_op(state.port, %{"op" => "leave", "guild_id" => to_string(guild_id)})
      {:reply, :ok, state}
    else
      {:reply, {:error, :sidecar_unavailable}, state}
    end
  end

  def handle_call(:alive?, _from, state) do
    {:reply, state.port != nil, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port, buffer: buf} = state) do
    {:noreply, %{state | buffer: buf <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("PythonVoice: sidecar exited (status=#{status}); will respawn on next op")
    {:noreply, %{state | port: nil, buffer: ""}}
  end

  def handle_info(msg, state) do
    Logger.debug(fn -> "PythonVoice: unhandled #{inspect(msg)}" end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    try do
      send_op(port, %{"op" => "shutdown"})
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_, _), do: :ok

  # ─── Internal ────────────────────────────────────────────────────

  defp ensure_port(%{port: nil} = state) do
    case spawn_sidecar() do
      {:ok, port} ->
        Logger.info("PythonVoice: spawned sidecar (port=#{inspect(port)})")
        %{state | port: port, buffer: ""}

      {:error, reason} ->
        Logger.error("PythonVoice: spawn failed: #{inspect(reason)}")
        state
    end
  end

  defp ensure_port(state), do: state

  defp spawn_sidecar do
    script = Path.join(@sidecar_dir, "bot.py")

    case File.exists?(script) do
      false ->
        {:error, {:no_script, script}}

      true ->
        env = sidecar_env()

        port =
          Port.open(
            {:spawn_executable, System.find_executable(python_exe()) || python_exe()},
            [
              {:args, [script]},
              {:cd, @sidecar_dir},
              {:env, env},
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:line, 4096}
            ]
          )

        {:ok, port}
    end
  end

  defp sidecar_env do
    token = Application.get_env(:worker, :discord_voice_bot_token)
    hub = Worker.Repo.get_state(:hub_base_url) || "http://localhost:4000"

    extras =
      Enum.reject(
        [
          {~c"DISCORD_VOICE_BOT_TOKEN", token},
          {~c"HUB_BASE_URL", hub},
          {~c"WHISPER_BIN", Application.get_env(:worker, :whisper_bin)},
          {~c"WHISPER_MODEL", Application.get_env(:worker, :whisper_model)},
          {~c"WHISPER_LANG", Application.get_env(:worker, :whisper_lang)}
        ],
        fn {_k, v} -> is_nil(v) end
      )

    Enum.map(extras, fn {k, v} -> {k, String.to_charlist(v)} end)
  end

  defp send_op(port, map) do
    Port.command(port, [Jason.encode!(map), "\n"])
  end

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, %{"event" => "error"} = ev} ->
        Logger.error("PythonVoice: #{inspect(ev)}")

      {:ok, %{"event" => event} = ev} ->
        Logger.info("PythonVoice: #{event} #{inspect(Map.delete(ev, "event"))}")

      _ ->
        Logger.debug(fn -> "PythonVoice: raw #{inspect(line)}" end)
    end
  end
end
