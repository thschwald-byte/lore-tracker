defmodule Worker.Recording.CampaignReplay do
  @moduledoc """
  Campaign-Level Pipeline-Replay (Issue #104).

  Triggert für eine Campaign sequentiell `Worker.Recording.Pipeline.run_for_session/1`
  pro Session (direkter In-Process-Call, kein Hub-Roundtrip seit #121), wartet
  via `Pipeline`-State zwischen den Sessions bis idle, und broadcastet
  Progress als `pipeline_status`-Event (kind: `"campaign_replay"`, mit
  `current` / `total` / `session_id`) damit der Hub-LiveView einen Banner
  zeichnen kann.

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

  alias Worker.{Recording, Repo}

  # Wait-Timeout pro Session. Bei großen Modellen (30B+) kann ein einzelner
  # Stage-3-Call alleine schon 10–15 min brauchen — mit 30 min Toleranz fällt
  # ein Replay nicht reflexartig in Avalanche-Modus wenn das Modell langsam ist.
  # Schlägt der Timeout trotzdem zu, wird der ganze Replay abgebrochen statt
  # die nächste Session zu triggern (sonst stapelt sich Pipeline.running auf).
  @stage_timeout_ms 30 * 60_000
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

    result =
      sessions
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {session, idx}, _ ->
        notify(campaign_id, run_id, "session_started", %{
          "current" => idx,
          "total" => total,
          "session_id" => session.id,
          "session_number" => session.number
        })

        # Direkter Pipeline-Call statt Hub-Roundtrip via RegenerateRequested-
        # Event. Pipeline.run_for_session/1 wirft :running-Marker raus + startet
        # die Stages; wir warten via :sys.get_state(Pipeline) bis idle.
        :ok = Recording.Pipeline.run_for_session(session.id)

        case wait_pipeline_idle(session.id) do
          :ok ->
            notify(campaign_id, run_id, "session_done", %{
              "current" => idx,
              "total" => total,
              "session_id" => session.id,
              "session_number" => session.number
            })

            {:cont, :ok}

          {:error, :stage_timeout} ->
            # Avalanche-Schutz: wenn die Pipeline für eine Session nach
            # @stage_timeout_ms noch nicht idle ist, ist das Modell zu langsam
            # für die aktuelle Konfiguration. Weitere Sessions zu triggern
            # würde nur Pipeline.running aufstapeln und die Ollama-Queue
            # vollmüllen. Lieber abbrechen + klar reporten.
            Logger.error(
              "CampaignReplay: Pipeline für session=#{session.id} nicht idle nach " <>
                "#{div(@stage_timeout_ms, 60_000)}min — Replay abgebrochen (Avalanche-Schutz). " <>
                "Vermutlich Modell zu langsam für Stage-3-Prompt. Settings prüfen."
            )

            notify(campaign_id, run_id, "aborted", %{
              "current" => idx,
              "total" => total,
              "session_id" => session.id,
              "session_number" => session.number,
              "reason" => "stage_timeout"
            })

            {:halt, {:error, :stage_timeout}}
        end
      end)

    case result do
      :ok ->
        notify(campaign_id, run_id, "finished", %{"total" => total, "current" => total})
        Logger.info("CampaignReplay: run #{run_id} done")

      {:error, reason} ->
        Logger.warning("CampaignReplay: run #{run_id} aborted (#{inspect(reason)})")
    end

    send(parent, {:run_done, run_id})
  end

  # Polled wait — die Pipeline-Engine ist im selben BEAM, also schauen wir
  # in deren GenServer-State ob die Session noch in der `running`-MapSet ist.
  # Bei Timeout: NICHT mit nächster Session weitermachen (sonst stapelt sich
  # Pipeline.running auf und Ollama läuft in eine Queue-Avalanche). Stattdessen
  # `{:error, :stage_timeout}` zurück — der Caller bricht den ganzen Replay ab.
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
        {:error, :stage_timeout}

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
