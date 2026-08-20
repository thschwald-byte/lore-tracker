defmodule Worker.Recording.CampaignReplay do
  @moduledoc """
  Campaign-Level Pipeline-Replay (Issue #104).

  Triggert für eine Campaign sequentiell `Worker.Recording.Pipeline.run_for_session/1`
  pro Session (direkter In-Process-Call, kein Hub-Roundtrip seit #121), wartet
  via `Pipeline`-State zwischen den Sessions bis idle, und broadcastet
  Progress als `pipeline_status`-Event (kind: `"campaign_replay"`, mit
  `current` / `total` / `session_id`) damit der Hub-LiveView einen Banner
  zeichnen kann.

  ## Locking-Modell (post-#292 / #354)

  Zwei orthogonale Locks, beide notwendig:

  - **Replay-Lock** (`state.running != nil`, hier im Modul): „nur ein
    Replay-Auftrag gleichzeitig". UI-Schutz gegen Doppel-Klicks auf
    „Pipeline für alle Sessions neu starten". Mehrfach-Replays wären
    sinnlos und würden Modell-Zeit verschwenden.
  - **GpuQueue-Lock** (`Worker.GpuQueue`, Issue #292): „nur ein
    GPU-schwerer Job gleichzeitig". Hardware-Schutz. Jede Pipeline-Stage
    die dieser Replay triggert läuft automatisch durch die Queue —
    dieses Modul interagiert nicht direkt mit der GpuQueue.

  Zweite Replay-Anfrage bei laufendem Replay → `{:error, {:already_running, run_id}}`.

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

  # Issue #1062: der Wächter misst **Stille**, nicht Gesamtdauer, und sein Wert
  # kommt aus den Settings (`replay_stage_timeout_ms`, Default 3 h) statt aus
  # einem Modul-Attribut.
  #
  # Vorher stand hier `30 * 60_000` mit der Begründung, das reiche für ein
  # langsames Modell. Es reichte nicht: eine echte Session braucht mit
  # qwen3.8:27b 80–110 min (gemessen 81), der Replay brach damit **strukturell**
  # nach der ersten Session ab — nicht gelegentlich, sondern immer. Für den
  # Nutzer sah das wie Erfolg aus: Session 1 hatte frische Artefakte, die
  # Oberfläche meldete nichts, und `running` war danach `nil` wie nach einem
  # sauberen Lauf.
  #
  # Der Wächter ist Avalanche-Schutz — er soll verhindern, dass sich
  # `Pipeline.running` aufstapelt und Ollama in eine Queue-Lawine läuft. Die
  # dafür richtige Frage ist „hängt die Pipeline?", nicht „wie lange läuft sie
  # schon?". Jede `pipeline_status`-Meldung dieser Kampagne setzt die Uhr
  # deshalb zurück; eine Session, die Fortschritt zeigt, läuft beliebig lange.
  defp stage_timeout_ms, do: Worker.Settings.get(:replay_stage_timeout_ms)

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

      # Issue #571: supervidiert, damit ein Crash im run_loop sichtbar im
      # Supervisor-Log landet (vorher Task.start: silent). Caveat: der
      # GenServer-State `running:` wird bei einem Task-Crash nicht
      # automatisch aufgeräumt — Process.monitor + DOWN-Handling ist
      # ein eigener Folge-Cut.
      Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
        run_loop(run_id, campaign_id, started_by, sessions, pid)
      end)

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

        case wait_pipeline_idle(session.id, campaign_id) do
          :ok ->
            notify(campaign_id, run_id, "session_done", %{
              "current" => idx,
              "total" => total,
              "session_id" => session.id,
              "session_number" => session.number
            })

            {:cont, :ok}

          {:error, {:stage_timeout, letzte_stufe}} ->
            # Avalanche-Schutz: die Session hat so lange KEINEN Fortschritt
            # gemeldet — weitere Sessions zu triggern würde nur
            # `Pipeline.running` aufstapeln und die Ollama-Queue vollmüllen.
            #
            # Issue #1062: die Meldung nennt die zuletzt gesehene Stufe statt
            # wie früher pauschal „vermutlich Stage 3". Der Zeitverbrauch kann
            # aus jedem Schritt kommen; real beobachtet war es Stage 1.1
            # (Gap-Fill), während die Meldung auf Stage 3 zeigte.
            stufe = letzte_stufe || "unbekannt (keine Statusmeldung gesehen)"

            Logger.error(
              "CampaignReplay: session=#{session.id} hat seit " <>
                "#{div(stage_timeout_ms(), 60_000)}min keinen Fortschritt gemeldet — " <>
                "Replay abgebrochen (Avalanche-Schutz). Zuletzt gesehene Stufe: " <>
                "#{stufe}. Frist drehbar über das Setting replay_stage_timeout_ms."
            )

            notify(campaign_id, run_id, "aborted", %{
              "current" => idx,
              "total" => total,
              "session_id" => session.id,
              "session_number" => session.number,
              "reason" => "stage_timeout",
              "last_stage" => stufe
            })

            # Issue #1062 (aus #1070 gefaltet): der Abbruch war bislang NUR
            # eine Logzeile. `running` ist danach `nil` wie nach einem sauberen
            # Lauf, Session 1 hat frische Artefakte, die Oberfläche meldet
            # nichts — von aussen nicht von Erfolg zu unterscheiden. Deshalb
            # zusätzlich ein Eintrag in /admin/errors.
            publish_abort_error(campaign_id, session, idx, total, stufe)

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

  # Issue #354: PubSub-basierter Wait (vorher 2s-Polling auf
  # `:sys.get_state(Pipeline)`). Pipeline broadcastet `{:pipeline_session_done,
  # session_id}` auf "pipeline_sessions" sobald die Stages für eine Session
  # durch sind.
  #
  # Issue #1062: zusätzlich `pipeline_status` — jede Stufenmeldung dieser
  # Kampagne ist der Beleg, dass sich etwas bewegt, und setzt die Frist neu.
  # Erst Stille über die volle Frist bricht ab.
  #
  # **Warum nach Kampagne gefiltert wird und nicht nach Session:** der
  # `pipeline_stage`-Payload trägt `campaign_id` und `stage`, aber **keine**
  # `session_id` (s. `Pipeline.notify_status/4`). Der Replay fährt die Sessions
  # streng nacheinander, eine Stufenmeldung dieser Kampagne gehört also zur
  # gerade laufenden Session. Käme parallel ein Einzel-Regenerate derselben
  # Kampagne dazu, verlängerte er die Frist — das wäre echter Fortschritt am
  # selben Modell, also kein Fehler, nur eine Ungenauigkeit, die hier benannt
  # gehört.
  defp wait_pipeline_idle(session_id, campaign_id) do
    # Edge-Case: Pipeline könnte das Done-Event publishen bevor wir
    # subscriben (kurze Stage). Daher zuerst State-Check, dann Subscribe,
    # dann nochmal State-Check (TOCTOU-frei).
    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_sessions")
    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")

    try do
      if not session_running?(session_id) do
        :ok
      else
        wait_done(session_id, campaign_id, stage_timeout_ms(), nil)
      end
    after
      Phoenix.PubSub.unsubscribe(Worker.PubSub, "pipeline_sessions")
      Phoenix.PubSub.unsubscribe(Worker.PubSub, "pipeline_status")
    end
  end

  defp session_running?(session_id) do
    state = :sys.get_state(Worker.Recording.Pipeline)
    state |> Map.get(:running, MapSet.new()) |> MapSet.member?(session_id)
  end

  # `timeout_ms` wird bei jedem Fortschritts-Signal komplett neu aufgesetzt
  # (rekursiver Aufruf mit voller Frist, nicht mit Restlaufzeit) — genau das
  # macht aus der Gesamtdauer-Uhr eine Stille-Uhr. `letzte_stufe` reist mit,
  # damit die Abbruchmeldung sagen kann, wo es zuletzt stand.
  @doc false
  # Public für Tests: die Schleife ist der Kern dieses Issues und lässt sich
  # sonst nur über einen echten Pipeline-Lauf prüfen. Sie läuft im Prozess des
  # Aufrufers, ein Test kann sich die Nachrichten also selbst schicken.
  def wait_done(session_id, campaign_id, timeout_ms, letzte_stufe) do
    schleife(session_id, campaign_id, timeout_ms, frist(timeout_ms), letzte_stufe)
  end

  # Gewartet wird gegen eine **Frist**, nicht gegen eine Dauer.
  #
  # Naheliegend wäre, bei jeder Nachricht rekursiv mit `timeout_ms` erneut
  # einzutreten. Das wäre falsch, und zwar auf eine Art, die sich nicht selbst
  # meldet: dann setzt JEDE Nachricht die Uhr zurück — auch eine, die gar kein
  # Fortschritt dieser Session ist. Eine fremde Kampagne oder der eigene
  # Replay-Banner könnten den Wächter damit unbegrenzt am Leben halten, und der
  # Avalanche-Schutz wäre still ausgehebelt.
  #
  # Deshalb: nur echter Fortschritt erneuert die Frist, alles andere wartet die
  # Restzeit ab.
  defp schleife(session_id, campaign_id, timeout_ms, frist, letzte_stufe) do
    rest = max(frist - System.monotonic_time(:millisecond), 0)

    receive do
      {:pipeline_session_done, ^session_id} ->
        :ok

      {:pipeline_session_done, _andere_session} ->
        schleife(session_id, campaign_id, timeout_ms, frist, letzte_stufe)

      {:pipeline_stage, %{"campaign_id" => ^campaign_id} = payload} ->
        case fortschritt(payload) do
          :kein_fortschritt ->
            schleife(session_id, campaign_id, timeout_ms, frist, letzte_stufe)

          {:ok, stufe} ->
            schleife(session_id, campaign_id, timeout_ms, frist(timeout_ms), stufe)
        end

      {:pipeline_stage, _fremde_kampagne} ->
        schleife(session_id, campaign_id, timeout_ms, frist, letzte_stufe)
    after
      rest -> {:error, {:stage_timeout, letzte_stufe}}
    end
  end

  defp frist(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # Der eigene `campaign_replay`-Banner läuft über denselben Topic. Ihn als
  # Fortschritt zu zählen wäre ein Selbstgespräch: der Wächter hielte sich mit
  # seiner eigenen Meldung am Leben.
  defp fortschritt(%{"kind" => "campaign_replay"}), do: :kein_fortschritt

  defp fortschritt(%{"stage" => stage, "status" => status}) when is_binary(stage),
    do: {:ok, "#{stage} (#{status})"}

  defp fortschritt(_payload), do: :kein_fortschritt

  # Issue #1062: Abbruch sichtbar machen (/admin/errors, Muster #716).
  defp publish_abort_error(campaign_id, session, idx, total, stufe) do
    payload = %{
      "kind" => Shared.Events.pipeline_error_logged(),
      "error_id" => UUIDv7.generate(),
      "session_id" => session.id,
      "campaign_id" => campaign_id,
      "stage" => "campaign_replay",
      "error_type" => "replay_stalled",
      "message" =>
        "Kampagnen-Replay bei Session #{session.number} (#{idx} von #{total}) abgebrochen: " <>
          "seit #{div(stage_timeout_ms(), 60_000)} min kein Fortschritt. Zuletzt gesehene " <>
          "Stufe: #{stufe}. Die folgenden Sessions wurden NICHT neu generiert.",
      "context" => %{
        "current" => idx,
        "total" => total,
        "last_stage" => stufe,
        "timeout_ms" => stage_timeout_ms()
      },
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Issue #430: Intents.publish/1 liefert immer {:ok, _}.
    {:ok, _} = Worker.Intents.publish(payload)
    :ok
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
