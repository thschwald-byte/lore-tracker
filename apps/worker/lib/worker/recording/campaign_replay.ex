defmodule Worker.Recording.CampaignReplay do
  @moduledoc """
  Campaign-Level Pipeline-Replay (Issue #104).

  Triggert für eine Campaign sequentiell `RegenerateRequested` pro Session,
  wartet via `Worker.Recording.Pipeline`-State zwischen den Sessions bis
  idle, und broadcastet Progress als `pipeline_status`-Event (kind:
  `"campaign_replay"`, mit `current` / `total` / `session_id`) damit der
  Hub-LiveView einen Banner zeichnen kann.

  Lock: nur ein Replay pro Worker. Zweite Anfrage bei laufendem Replay →
  `{:error, {:already_running, run_id}}`.

  Im Unterschied zur `Worker.Probelauf`-Engine (#74): hier wird **keine**
  eigene Probelauf-Campaign geseedet — wir laufen über die echte
  User-Campaign, alle Sessions die schon existieren werden durch die
  Pipeline geschickt. Resümees / Epos / Chronik werden überschrieben.

  Sessions ohne Utterances werden übersprungen (Pipeline würde sowieso
  „skipping LLM stages" loggen, aber wir vermeiden den Trigger gleich).
  """

  use GenServer
  require Logger

  alias Worker.{Intents, Repo}

  @stage_timeout_ms 15 * 60_000
  @pipeline_poll_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ─── Public API ───────────────────────────────────────────────────

  @doc """
  Startet einen Campaign-Replay für die angegebene Campaign-ID. Returns
  `{:ok, run_id}` oder `{:error, {:already_running, run_id}}`.
  """
  @spec start(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:already_running, String.t()}} | {:error, term()}
  def start(campaign_id, started_by_discord_id)
      when is_binary(campaign_id) and is_binary(started_by_discord_id) do
    GenServer.call(__MODULE__, {:start, campaign_id, started_by_discord_id})
  end

  @doc "Aktueller Run oder nil."
  @spec running() :: nil | map()
  def running, do: GenServer.call(__MODULE__, :running)

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{running: nil}}

  @impl true
  def handle_call({:start, campaign_id, started_by}, _from, %{running: nil} = state) do
    sessions =
      campaign_id
      |> Repo.list_sessions()
      |> Enum.filter(fn s -> Repo.list_utterances(s.id) != [] end)

    if sessions == [] do
      {:reply, {:error, :no_sessions_with_utterances}, state}
    else
      run_id = UUIDv7.generate()
      pid = self()

      Task.start(fn -> run_loop(run_id, campaign_id, started_by, sessions, pid) end)

      run = %{
        run_id: run_id,
        campaign_id: campaign_id,
        started_by: started_by,
        total: length(sessions),
        started_at: DateTime.utc_now()
      }

      {:reply, {:ok, run_id}, %{state | running: run}}
    end
  end

  def handle_call({:start, _, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run.run_id}}, state}
  end

  def handle_call(:running, _from, state), do: {:reply, state.running, state}

  @impl true
  def handle_info({:run_done, run_id}, state) do
    case state.running do
      %{run_id: ^run_id} ->
        Logger.info("CampaignReplay: run #{run_id} cleared")
        {:noreply, %{state | running: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # ─── Loop ────────────────────────────────────────────────────────

  defp run_loop(run_id, campaign_id, started_by, sessions, parent) do
    Logger.info(
      "CampaignReplay: start run=#{run_id} campaign=#{campaign_id} sessions=#{length(sessions)} by=#{started_by}"
    )

    notify(campaign_id, run_id, "started", %{
      "total" => length(sessions),
      "current" => 0
    })

    total = length(sessions)

    sessions
    |> Enum.with_index(1)
    |> Enum.each(fn {session, idx} ->
      notify(campaign_id, run_id, "session_started", %{
        "current" => idx,
        "total" => total,
        "session_id" => session.id,
        "session_number" => session.number
      })

      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.regenerate_requested(),
          "scope" => "session_pipeline",
          "session_id" => session.id,
          "campaign_id" => campaign_id
        })

      :ok = wait_pipeline_idle(session.id)

      notify(campaign_id, run_id, "session_done", %{
        "current" => idx,
        "total" => total,
        "session_id" => session.id,
        "session_number" => session.number
      })
    end)

    notify(campaign_id, run_id, "finished", %{
      "total" => total,
      "current" => total
    })

    Logger.info("CampaignReplay: run #{run_id} done")
    send(parent, {:run_done, run_id})
  end

  # Polled wait — die Pipeline-Engine ist im selben BEAM, also schauen wir
  # in deren GenServer-State ob die Session noch in der `running`-MapSet ist.
  # Bei timeout brechen wir den Wait ab, der Replay läuft trotzdem mit der
  # nächsten Session weiter (Issue #104: nicht abbrechen bei Stage-Failed,
  # nächste Session noch versuchen).
  defp wait_pipeline_idle(session_id) do
    deadline = System.monotonic_time(:millisecond) + @stage_timeout_ms
    do_wait(session_id, deadline)
  end

  defp do_wait(session_id, deadline) do
    state = :sys.get_state(Worker.Recording.Pipeline)
    running = Map.get(state, :running, MapSet.new())

    cond do
      not MapSet.member?(running, session_id) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        Logger.warning("CampaignReplay: timeout waiting for session=#{session_id}, moving on")
        :ok

      true ->
        Process.sleep(@pipeline_poll_ms)
        do_wait(session_id, deadline)
    end
  end

  # ─── PubSub-Notifier ─────────────────────────────────────────────

  defp notify(campaign_id, run_id, status, extra) do
    payload =
      Map.merge(
        %{
          "kind" => "campaign_replay",
          "campaign_id" => campaign_id,
          "run_id" => run_id,
          "status" => status,
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        extra
      )

    Worker.HubClient.publish_status(payload)
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
  end
end
