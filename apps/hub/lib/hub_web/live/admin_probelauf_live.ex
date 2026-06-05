defmodule HubWeb.AdminProbelaufLive do
  @moduledoc """
  Admin-LV (Issue #74): LLM-Probelauf — Smoke-Test der gesamten Pipeline
  auf einer dedizierten Probelauf-Kampagne mit Per-Stage-Messung und
  Heuristik-Empfehlung.

  Permission-Gate: nur globale Rolle `:admin` (analog `AdminUsersLive`).

  Flow:
  1. Admin klickt „Probelauf starten" → `Hub.Commands.request_probelauf_start/1`
     pingt den Owner-Worker, der `Worker.Probelauf.start/1` aufruft.
  2. Worker seedet eine Probelauf-Kampagne, schickt sie durch die Pipeline,
     misst pro Stage Wall-Clock + Outcome.
  3. Hub sieht den Fortschritt via `pipeline_status`-PubSub-Events und das
     finale `ProbelaufFinished`-Event über das `Hub.Events`-PubSub-Topic.
  4. LV holt den letzten Probelauf via Snapshot (`%{"kind" => "probelauf"}`)
     und rendert Heatmap + Empfehlung.

  Issue #573: render/1 + Presentation-Helpers sind nach
  `HubWeb.AdminProbelaufLive.Render` extrahiert; Sweep-Form-Logik nach
  `HubWeb.AdminProbelaufLive.SweepForm`.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, Events, Reader}
  alias HubWeb.{Permissions, Probelauf.Heuristik, Probelauf.SweepAggregator}
  alias HubWeb.AdminProbelaufLive.{Render, SweepForm}
  alias Shared.Events, as: EventKinds
  require Logger

  @stages Heuristik.stages()

  # Issue #569: Modul-Attribute für event-kind-Matches im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard).
  @probelauf_sweep_finished_kind EventKinds.probelauf_sweep_finished()
  @probelauf_progress_kinds [
    EventKinds.probelauf_started(),
    EventKinds.probelauf_finished(),
    EventKinds.probelauf_sweep_started()
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    # Issue #569: Gate über current_user_role (SidebarContext-on_mount) wie
    # bei allen anderen Admin-LVs — vorher leitete die Permission aus dem
    # sync Reader.read ab (viewer_role/2, hardcoded :admin), was nach dem
    # Async-Umbau nicht zuverlässig zur mount-Zeit greift.
    perm_user = %{
      discord_id: user.discord_id,
      role: socket.assigns[:current_user_role] || :spieler,
      is_member?: true
    }

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
        Phoenix.PubSub.subscribe(Hub.PubSub, "pipeline_status")
      end

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:viewer_role, perm_user.role)
       |> assign(:active_nav, :admin)
       |> assign(:current_campaign, nil)
       |> assign(:stages, @stages)
       |> assign(:live_stages, %{})
       |> assign(:sweep_form, SweepForm.default_sweep_form())
       |> assign(:live_sweep_variants, [])
       # Issue #88 (Phase 2b): Queue der pending Multi-Stage-Sweeps. Ein
       # Eintrag pro Stage mit nicht-leerer Modell-Liste. Wird beim Klick
       # auf "Multi-Stage-Sweep starten" befüllt und Stück für Stück
       # abgearbeitet, sobald `ProbelaufSweepFinished` für den laufenden
       # Sweep eintrifft.
       |> assign(:pending_sweep_queue, [])
       |> assign_data_defaults()
       |> start_data_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("start_probelauf", _params, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      case Commands.request_probelauf_start(socket.assigns.current_user.discord_id) do
        0 ->
          {:noreply,
           put_flash(socket, :error, "Kein Worker verbunden — Probelauf nicht startbar.")}

        n when n > 0 ->
          {:noreply,
           socket
           |> assign(:live_stages, %{})
           |> put_flash(:info, "Probelauf angestoßen — läuft jetzt im Worker.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply_recommendation", _params, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) and
         socket.assigns.recommendation_kv != %{} do
      n =
        Commands.update_my_worker_settings(
          socket.assigns.current_user.discord_id,
          socket.assigns.recommendation_kv
        )

      {:noreply,
       put_flash(
         socket,
         :info,
         "Empfehlung übernommen — #{n} Worker signalisiert. Nach Worker-Restart greift die neue Config."
       )}
    else
      {:noreply, socket}
    end
  end

  # Issue #88 (Phase 2c): aus den per-Stage Multi-Stage-Sweep-Ergebnissen
  # die jeweils beste Modell-Empfehlung pro Stage in einem Rutsch
  # übernehmen. Quality-Gate: ein Stage wird nur dann angefasst, wenn der
  # Top-Treffer (erste Row nach Aggregator-Sortierung) mindestens
  # success_rate ≥ 0.5 hat. So bleibt der Worker nicht auf einem Modell
  # hängen, das alle Sessions getimeoutet hat.
  def handle_event("apply_multi_recommendation", _params, socket) do
    if not Permissions.can?(socket.assigns.perm_user, :view_admin) do
      {:noreply, socket}
    else
      kv = SweepForm.multi_stage_winners(socket.assigns.sweep_summaries || [])

      if kv == %{} do
        {:noreply,
         put_flash(socket, :error, "Keine verwendbaren Sieger pro Stage (success_rate < 0.5).")}
      else
        n =
          Commands.update_my_worker_settings(
            socket.assigns.current_user.discord_id,
            kv
          )

        summary =
          kv
          |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
          |> Enum.join(", ")

        {:noreply,
         put_flash(
           socket,
           :info,
           "Multi-Stage-Empfehlung übernommen (#{summary}) — #{n} Worker signalisiert. Nach Worker-Restart greift die neue Config."
         )}
      end
    end
  end

  # Issue #289 Phase 4: Param-Sweep über Temperature-Varianten.
  def handle_event("start_sweep_param", params, socket) do
    if not Permissions.can?(socket.assigns.perm_user, :view_admin) do
      {:noreply, socket}
    else
      stage = SweepForm.parse_stage(params["stage"]) || 4
      # Hardcoded für Phase 4 — Issue-Spec listet [0.05, 0.1, 0.15, 0.2].
      temperatures = [0.05, 0.1, 0.15, 0.2]
      # Param-Sweep mittelt aktuell über die gleichen Sessions wie der
      # Default-Modell-Sweep (alle short/medium/long). Real-Session
      # bewusst raus weil zu langsam für 4 Iterationen.
      session_set = ["short", "medium", "long"]

      case Commands.request_probelauf_sweep_isolated_param(
             socket.assigns.current_user.discord_id,
             stage,
             temperatures,
             session_set
           ) do
        1 ->
          {:noreply,
           socket
           |> assign(:live_sweep_variants, [])
           |> put_flash(:info, "Param-Sweep gestartet — Stage #{stage}, #{length(temperatures)} Temperaturen.")
           |> start_data_load()}

        0 ->
          {:noreply, put_flash(socket, :error, "Kein Worker online.")}
      end
    end
  end

  def handle_event("start_sweep", params, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      stage = SweepForm.parse_stage(params["stage"])
      models = SweepForm.parse_models(params)
      session_set = SweepForm.parse_session_set(params)
      isolated? = params["mode"] == "isolated"

      # Form-State so persistieren wie der User ihn gerade abgesendet hat,
      # damit ein Re-Run nicht alles wieder ankreuzen muss.
      sweep_form = %{
        mode: params["mode"] || "full",
        stage: stage || 2,
        models: MapSet.new(models),
        session_set: MapSet.new(session_set)
      }

      socket = assign(socket, :sweep_form, sweep_form)

      cond do
        is_nil(stage) ->
          {:noreply, put_flash(socket, :error, "Stage wählen (2 / 3 / 4).")}

        models == [] ->
          {:noreply, put_flash(socket, :error, "Mindestens ein Modell ankreuzen.")}

        session_set == [] ->
          {:noreply, put_flash(socket, :error, "Mindestens eine Eval-Session ankreuzen.")}

        true ->
          dispatch_fn =
            if isolated?,
              do: &Commands.request_probelauf_sweep_isolated/4,
              else: &Commands.request_probelauf_sweep/4

          case dispatch_fn.(
                 socket.assigns.current_user.discord_id,
                 stage,
                 models,
                 session_set
               ) do
            0 ->
              {:noreply,
               put_flash(socket, :error, "Kein Worker verbunden — Sweep nicht startbar.")}

            n when n > 0 ->
              mode_label = if isolated?, do: "stage-isolierter Sweep", else: "Voll-Sweep"

              {:noreply,
               socket
               |> assign(:live_stages, %{})
               |> assign(:live_sweep_variants, [])
               |> put_flash(
                 :info,
                 "#{mode_label} angestoßen — #{length(models)} Modelle × #{length(session_set)} Eval-Sessions für Stage #{stage}."
               )}
          end
      end
    else
      {:noreply, socket}
    end
  end

  # Issue #281b: Form-State live mitschreiben, damit die Auswahl nach Submit
  # nicht verschwindet (und damit nach Abschluss eines Sweeps die letzte
  # Auswahl noch sichtbar ist für direkten Re-Run).
  def handle_event("sweep_form_change", params, socket) do
    sweep_form = %{
      mode: params["mode"] || socket.assigns.sweep_form.mode,
      stage: SweepForm.parse_stage(params["stage"]) || socket.assigns.sweep_form.stage,
      models: MapSet.new(SweepForm.parse_models(params)),
      session_set: MapSet.new(SweepForm.parse_session_set(params)),
      stage_models: SweepForm.parse_stage_models(params, socket.assigns.sweep_form.stage_models)
    }

    {:noreply, assign(socket, :sweep_form, sweep_form)}
  end

  # Issue #88 (Phase 2b): Multi-Stage-Sweep. Pro Stage mit nicht-leerer
  # Modell-Liste wird ein separater Single-Stage-Sweep angestoßen,
  # sequentiell. Der erste Stage geht sofort raus, die übrigen wandern in
  # die Queue und werden beim Eintreffen von `ProbelaufSweepFinished` für
  # den vorherigen Sweep nachgereicht.
  def handle_event("start_sweep_multi", params, socket) do
    if not Permissions.can?(socket.assigns.perm_user, :view_admin) do
      {:noreply, socket}
    else
      session_set = SweepForm.parse_session_set(params)
      isolated? = params["mode"] == "isolated"

      stage_models =
        SweepForm.parse_stage_models(params, socket.assigns.sweep_form.stage_models)

      sweep_form = %{
        mode: params["mode"] || "full",
        stage: socket.assigns.sweep_form.stage,
        models: socket.assigns.sweep_form.models,
        session_set: MapSet.new(session_set),
        stage_models: stage_models
      }

      socket = assign(socket, :sweep_form, sweep_form)

      # Reihenfolge fest: Stage 2 → 3 → 4. Leere Stages skippen.
      jobs =
        for stage <- [2, 3, 4],
            models = stage_models |> Map.get(stage, MapSet.new()) |> MapSet.to_list() |> Enum.sort(),
            models != [],
            do: {stage, models}

      cond do
        jobs == [] ->
          {:noreply,
           put_flash(socket, :error, "Mindestens eine Stage mit Modellen ankreuzen.")}

        session_set == [] ->
          {:noreply, put_flash(socket, :error, "Mindestens eine Eval-Session ankreuzen.")}

        true ->
          [{first_stage, first_models} | rest] = jobs

          case SweepForm.dispatch_sweep(isolated?, socket.assigns.current_user.discord_id,
                              first_stage, first_models, session_set) do
            0 ->
              {:noreply,
               put_flash(socket, :error, "Kein Worker verbunden — Sweep nicht startbar.")}

            n when n > 0 ->
              total = length(jobs)

              mode_label =
                if isolated?, do: "stage-isolierte Multi-Stage-Sweeps", else: "Multi-Stage-Sweeps"

              {:noreply,
               socket
               |> assign(:live_stages, %{})
               |> assign(:live_sweep_variants, [])
               |> assign(:pending_sweep_queue,
                 Enum.map(rest, fn {s, m} -> %{stage: s, models: m, isolated?: isolated?, session_set: session_set} end))
               |> put_flash(
                 :info,
                 "#{total} #{mode_label} angestoßen — starte mit Stage #{first_stage} (#{length(first_models)} Modelle); übrige Stages laufen automatisch nach."
               )}
          end
      end
    end
  end

  # Issue #88 (Phase 2b): nach jedem `ProbelaufSweepFinished` versuchen, den
  # nächsten Sweep aus der Queue zu starten. Wenn der Worker noch beschäftigt
  # ist (Race zwischen Event-Append und GenServer-State-Reset), bleibt der
  # Job in der Queue und wird beim nächsten `:reload`-Cycle erneut versucht.
  defp drain_pending_sweep_queue(socket) do
    case socket.assigns.pending_sweep_queue do
      [] ->
        socket

      [%{stage: stage, models: models, isolated?: isolated?, session_set: session_set} | rest] ->
        case SweepForm.dispatch_sweep(isolated?, socket.assigns.current_user.discord_id,
                            stage, models, session_set) do
          0 ->
            socket
            |> assign(:pending_sweep_queue, [])
            |> put_flash(:error, "Worker getrennt — restliche Multi-Stage-Sweeps abgebrochen.")

          n when n > 0 ->
            socket
            |> assign(:pending_sweep_queue, rest)
            |> assign(:live_stages, %{})
            |> assign(:live_sweep_variants, [])
            |> put_flash(
              :info,
              "Multi-Stage-Sweep: starte nächste Stage #{stage} (#{length(models)} Modelle, #{length(rest)} weitere folgen)."
            )
        end
    end
  end

  @impl true
  def handle_info(
        {:event_appended, %{payload: %{"kind" => @probelauf_sweep_finished_kind}}},
        socket
      ) do
    # Issue #569: PID-targeted Debounce — BEAM räumt pending send_after beim
    # Prozess-Tod auf (https://www.erlang.org/doc/system/ref_man_processes.html).
    # credo:disable-for-next-line LoreTracker.Credo.Check.TimerWithoutCleanup
    Process.send_after(self(), :reload, 150)
    socket = drain_pending_sweep_queue(socket)
    {:noreply, socket}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in @probelauf_progress_kinds do
    # Issue #569: Debounce, siehe oben.
    # credo:disable-for-next-line LoreTracker.Credo.Check.TimerWithoutCleanup
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}

  # Issue #281b: Worker pusht pro fertig gemessener Variant das Ergebnis live
  # zum LV, damit die Sweep-Tabelle schon während des Laufs sichtbar aufbaut.
  def handle_info(
        {:pipeline_status, %{"kind" => "probelauf_sweep_variant_done"} = payload},
        socket
      ) do
    variant = payload["variant"]

    updated =
      socket.assigns.live_sweep_variants
      |> Enum.reject(&(&1["model"] == variant["model"]))
      |> Kernel.++([variant])

    {:noreply, assign(socket, :live_sweep_variants, updated)}
  end

  # Issue #279: Live-Progress beim Sweep-Modell-Wechsel. Worker pusht das
  # bei jedem Wechsel von Modell N → N+1; LV updated @running ohne reload.
  def handle_info(
        {:pipeline_status, %{"kind" => "probelauf_sweep_progress"} = payload},
        socket
      ) do
    running =
      case socket.assigns.running do
        nil ->
          nil

        r ->
          r
          |> Map.put("current_model", payload["current_model"])
          |> Map.put("completed", payload["completed"])
          |> Map.put("total", payload["total"])
      end

    {:noreply, assign(socket, :running, running)}
  end

  def handle_info({:pipeline_status, %{"campaign_id" => "probelauf-" <> _} = payload}, socket) do
    stage = payload["stage"]
    status = payload["status"]
    cid = payload["campaign_id"]
    error = payload["error"]

    cell = %{status: status, error: error}

    live_stages =
      socket.assigns.live_stages
      |> Map.update(cid, %{stage => cell}, fn m -> Map.put(m, stage, cell) end)

    socket =
      if status == "failed" and is_binary(error) and error != "" do
        put_flash(socket, :error, "Probelauf #{stage} fehlgeschlagen: #{error}")
      else
        socket
      end

    {:noreply, assign(socket, :live_stages, live_stages)}
  end

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  def handle_info(:reload, socket), do: {:noreply, start_data_load(socket)}

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, start_data_load(socket)}

  # ─── Data loading ─────────────────────────────────────────────────

  @impl true
  def handle_async(:load_data, {:ok, {:ok, snap}}, socket) do
    last = snap["last_run"]
    last_sweep = snap["last_sweep"]
    running = snap["running"]
    available_models = snap["available_models"] || []

    {recommendation_text, recommendation_kv} =
      case last do
        nil -> {nil, %{}}
        run -> Heuristik.build(run["sessions"] || [], available_models)
      end

    sweep_summary = SweepAggregator.aggregate(last_sweep)

    last_sweeps = snap["last_sweeps"] || []
    sweep_summaries = Enum.map(last_sweeps, &SweepAggregator.aggregate/1)

    {:noreply,
     assign(socket,
       no_worker?: false,
       running: running,
       last_run: last,
       last_sweep: last_sweep,
       sweep_summary: sweep_summary,
       last_sweeps: last_sweeps,
       sweep_summaries: sweep_summaries,
       available_models: available_models,
       recommendation_text: recommendation_text,
       recommendation_kv: recommendation_kv
     )}
  end

  def handle_async(:load_data, {:ok, {:error, :no_worker}}, socket) do
    {:noreply, assign(socket, Keyword.merge(data_defaults(), no_worker?: true))}
  end

  def handle_async(:load_data, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
     |> assign(data_defaults())}
  end

  def handle_async(:load_data, {:exit, reason}, socket) do
    Logger.warning("admin_probelauf load_data async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Issue #366: prefer_discord_id für Worker-lokales Probelauf-Routing.
  defp start_data_load(socket) do
    did = socket.assigns.current_user.discord_id

    start_async(socket, :load_data, fn ->
      Reader.read(%{"kind" => "probelauf"}, prefer_discord_id: did)
    end)
  end

  defp assign_data_defaults(socket), do: assign(socket, data_defaults())

  defp data_defaults do
    [
      no_worker?: false,
      running: nil,
      last_run: nil,
      last_sweep: nil,
      sweep_summary: nil,
      last_sweeps: [],
      sweep_summaries: [],
      available_models: [],
      recommendation_text: nil,
      recommendation_kv: %{}
    ]
  end


  # ─── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns), do: Render.render(assigns)

end
