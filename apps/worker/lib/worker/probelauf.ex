defmodule Worker.Probelauf do
  @moduledoc """
  LLM-Smoke-Test (Issue #74). Bei UI-Trigger seedet eine dedizierte
  Probelauf-Kampagne (3 Sessions à 10/30/100 hartkodierte Utterances —
  short/medium/long Prompts), fährt sie sequentiell durch die normale
  `Worker.Recording.Pipeline` und misst pro Stage Wall-Clock-Dauer +
  Erfolg/Fehler-Kategorie.

  Am Ende publisht der GenServer ein `ProbelaufFinished`-Event mit dem
  gesamten Mess-Payload + Settings-Snapshot, danach `CampaignDeleted` für
  die Probelauf-Kampagne (Cleanup via Materializer-Cascade).

  Lock: nur ein Probelauf gleichzeitig (`state.running`).

  Per-Stage-Timings kommen aus `Worker.Recording.Pipeline.notify_status/3`
  über den Worker.PubSub-Topic `"pipeline_status"`.
  """

  use GenServer
  require Logger

  alias Worker.{Intents, Repo, Settings}

  # Wie lange max. auf eine Pipeline-Stage warten, bevor die Probelauf-Engine
  # die Session als `:timeout` markiert und weitermacht. Großzügig, weil
  # Stage 3 mit 30B-Modellen auch >5min dauern kann.
  @stage_timeout_ms 15 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ─── Public API ────────────────────────────────────────────────────

  @doc """
  Startet einen Probelauf für den angegebenen Admin. Returns:
  - `{:ok, run_id}` wenn losgelegt
  - `{:error, {:already_running, run_id}}` wenn schon einer läuft
  """
  @spec start(String.t()) :: {:ok, String.t()} | {:error, {:already_running, String.t()}}
  def start(started_by_discord_id) when is_binary(started_by_discord_id) do
    GenServer.call(__MODULE__, {:start, started_by_discord_id})
  end

  @doc "Aktueller Run (oder nil)."
  @spec running() :: nil | map()
  def running, do: GenServer.call(__MODULE__, :running)

  # ─── GenServer-Callbacks ──────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{running: nil}}
  end

  @impl true
  def handle_call({:start, started_by}, _from, %{running: nil} = state) do
    run_id = UUIDv7.generate()
    settings = settings_snapshot()
    started_at = DateTime.utc_now()

    pid = self()
    Task.start(fn -> run_loop(run_id, started_by, settings, started_at, pid) end)

    {:reply, {:ok, run_id},
     %{state | running: %{run_id: run_id, started_by: started_by, started_at: started_at}}}
  end

  def handle_call({:start, _}, _from, %{running: run} = state) do
    {:reply, {:error, {:already_running, run.run_id}}, state}
  end

  def handle_call(:running, _from, state), do: {:reply, state.running, state}

  @impl true
  def handle_info({:run_done, run_id}, state) do
    case state.running do
      %{run_id: ^run_id} ->
        Logger.info("Probelauf: run #{run_id} cleared")
        {:noreply, %{state | running: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # ─── Probelauf-Loop (im Task ausgeführt) ──────────────────────────

  defp run_loop(run_id, started_by, settings, started_at, parent) do
    Logger.info("Probelauf: starting run=#{run_id} by=#{started_by}")
    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_started(),
        "run_id" => run_id,
        "started_by" => started_by,
        "started_at" => DateTime.to_iso8601(started_at),
        "settings_snapshot" => settings
      })

    campaign_id = "probelauf-" <> run_id
    owner = Repo.get_state(:admin_discord_id) || started_by

    sessions = seed(campaign_id, owner)

    metrics =
      sessions
      |> Enum.map(fn s -> measure_session(s, campaign_id) end)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.probelauf_finished(),
        "run_id" => run_id,
        "started_by" => started_by,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "sessions" => metrics,
        "settings_snapshot" => settings
      })

    # Cleanup: Cascade-Delete der Probelauf-Campaign (Materializer kaskadiert).
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.campaign_deleted(),
        "campaign_id" => campaign_id,
        "deleted_by" => "probelauf-cleanup"
      })

    Logger.info("Probelauf: run #{run_id} finished + cleaned up")
    send(parent, {:run_done, run_id})
  end

  # ─── Seed (3 Sessions, short/medium/long Prompts) ────────────────

  defp seed(campaign_id, owner) do
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.campaign_created(),
        "id" => campaign_id,
        "name" => "LLM-Probelauf #{String.slice(campaign_id, -8, 8)}",
        "icon_url" => nil,
        "theme_blurb" =>
          "Automatischer Smoke-Test (Issue #74). Wird nach Abschluss automatisch gelöscht.",
        "owner_discord_id" => owner,
        "owner_display_name" => "Probelauf",
        # Marker für Hub.Reader-Filter — Dashboards ignorieren Probelauf-Campaigns.
        "probelauf" => true
      })

    [
      seed_session(campaign_id, owner, 1, short_utterances()),
      seed_session(campaign_id, owner, 2, medium_utterances()),
      seed_session(campaign_id, owner, 3, long_utterances())
    ]
  end

  defp seed_session(campaign_id, owner, num, texts) do
    sid = UUIDv7.generate()

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_scheduled(),
        "id" => sid,
        "campaign_id" => campaign_id,
        "number" => num,
        "name" => "Probelauf-Session #{num} (#{length(texts)} Utterances)",
        "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Enum.with_index(texts, fn text, i ->
      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.utterance_appended(),
          "id" => "u-#{sid}-#{i}",
          "session_id" => sid,
          "discord_id" => owner,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "text" => text,
          "confidence" => 1.0,
          "status" => "confirmed"
        })
    end)

    %{number: num, session_id: sid, utterance_count: length(texts)}
  end

  # ─── Mess-Logik pro Session ──────────────────────────────────────

  defp measure_session(session, campaign_id) do
    Logger.info("Probelauf: triggering session #{session.number} (#{session.utterance_count} utts)")

    # Flush stale messages aus früheren Sessions
    flush_pipeline_messages()

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.regenerate_requested(),
        "scope" => "session_pipeline",
        "session_id" => session.session_id,
        "campaign_id" => campaign_id
      })

    stage_metrics = collect_stages(campaign_id, %{})

    %{
      number: session.number,
      session_id: session.session_id,
      utterance_count: session.utterance_count,
      stages: stage_metrics
    }
  end

  # Empfängt {:pipeline_stage, payload}-Messages aus dem Worker.PubSub
  # bis Stage 4 mit Status "ended" oder "failed" durchgegangen ist.
  # Pro Stage: timestamp-pair (started, ended), Outcome.
  defp collect_stages(campaign_id, acc) do
    receive do
      {:pipeline_stage,
       %{"campaign_id" => ^campaign_id, "stage" => stage, "status" => status, "ts" => ts_iso}} ->
        ts = parse_ts(ts_iso) || DateTime.utc_now()
        acc = record(acc, stage, status, ts)

        if stage == "stage4" and status in ["ended", "failed"] do
          finalize(acc, campaign_id)
        else
          collect_stages(campaign_id, acc)
        end

      {:pipeline_stage, _} ->
        # andere Campaign — ignorieren
        collect_stages(campaign_id, acc)
    after
      @stage_timeout_ms ->
        finalize(Map.put(acc, :__timeout__, true), campaign_id)
    end
  end

  defp record(acc, stage, "started", ts), do: Map.put(acc, {stage, :start}, ts)

  defp record(acc, stage, status, ts) when status in ["ended", "failed"] do
    acc
    |> Map.put({stage, :stop}, ts)
    |> Map.put({stage, :outcome_raw}, status)
  end

  defp record(acc, _stage, _status, _ts), do: acc

  defp finalize(acc, campaign_id) do
    timeout? = Map.get(acc, :__timeout__, false)

    Enum.into(["stage2", "stage3", "stage4"], %{}, fn stage ->
      {stage, stage_metric(acc, stage, timeout?, campaign_id)}
    end)
  end

  defp stage_metric(acc, stage, timeout?, campaign_id) do
    start = Map.get(acc, {stage, :start})
    stop = Map.get(acc, {stage, :stop})
    outcome_raw = Map.get(acc, {stage, :outcome_raw})

    duration_ms =
      if start && stop, do: DateTime.diff(stop, start, :millisecond), else: nil

    outcome = classify_outcome(stage, outcome_raw, timeout?, campaign_id)
    output_bytes = output_size(stage, campaign_id)

    %{
      duration_ms: duration_ms,
      outcome: Atom.to_string(outcome),
      output_bytes: output_bytes
    }
  end

  defp classify_outcome(_stage, nil, true, _cid), do: :timeout
  defp classify_outcome(_stage, nil, false, _cid), do: :other_error
  defp classify_outcome(_stage, "ended", _, _cid), do: :ok

  defp classify_outcome("stage4", "failed", _, cid) do
    # Stage 4 hat eigene Failure-Codes — wenn Chronik leer ist, ist es
    # :empty_output (siehe Pipeline.stage4_publish/2 für [] → :empty_chronik).
    if Repo.list_chronik_entries(cid) == [], do: :empty_output, else: :other_error
  end

  defp classify_outcome(_stage, "failed", _, _cid), do: :other_error

  defp output_size("stage2", cid) do
    cid
    |> Repo.list_session_summaries()
    |> Enum.map(&byte_size(&1.content_md || ""))
    |> Enum.sum()
  end

  defp output_size("stage3", cid) do
    case Repo.get_epos_entry(cid) do
      nil -> 0
      e -> byte_size(e.content_md || "")
    end
  end

  defp output_size("stage4", cid), do: Repo.list_chronik_entries(cid) |> length()

  # ─── Helpers ─────────────────────────────────────────────────────

  defp settings_snapshot do
    keys = ~w(model_stage2 model_stage3 model_stage4
              ctx_stage2 ctx_stage3 ctx_stage4
              http_timeout_ms local_endpoint)a

    Enum.into(keys, %{}, fn k -> {Atom.to_string(k), Settings.get(k)} end)
  end

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  defp flush_pipeline_messages do
    receive do
      {:pipeline_stage, _} -> flush_pipeline_messages()
    after
      0 -> :ok
    end
  end

  # ─── Seed-Texte (hartkodiert, fiktive deutsche RPG-Szenen) ───────

  defp short_utterances do
    [
      "Wir betreten die verlassene Schenke. Der Wirt sieht uns misstrauisch an.",
      "Ich frage ihn nach dem verschwundenen Karawanenboten.",
      "Er nuschelt etwas von Banditen im Schwarzen Wald.",
      "Mein Halbork zückt die Streitaxt und legt eine Goldmünze auf den Tresen.",
      "Der Wirt wird redseliger. Er nennt einen Namen: Gardal der Krummbein.",
      "Wir bedanken uns und ziehen nordwärts.",
      "Auf dem Weg sehe ich Hufabdrücke — vier Reiter, zwei Tage alt.",
      "Die Elfin schleicht voraus, kundschaftet die nächste Lichtung aus.",
      "Sie kommt zurück: drei Banditen am Lagerfeuer, schlafend.",
      "Wir schleichen uns an. Stille, dann ein scharfer Pfiff — die Elfin gibt das Zeichen."
    ]
  end

  defp medium_utterances do
    Enum.flat_map(1..3, fn ep -> Enum.map(short_utterances(), &"[Episode #{ep}] #{&1}") end)
  end

  defp long_utterances do
    Enum.flat_map(1..10, fn ep -> Enum.map(short_utterances(), &"[Tag #{ep}] #{&1}") end)
  end
end
