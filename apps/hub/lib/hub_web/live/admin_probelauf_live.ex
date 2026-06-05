# Issue #573: God-Module-Split deferred — Sweep-Form + Heuristik-Render
# brauchen eigene Architektur-Diskussion (eigener Cut). credo:disable-for-
# this-file bis dahin.
# credo:disable-for-this-file LoreTracker.Credo.Check.ModuleTooLong
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
  """

  use HubWeb, :live_view

  alias Hub.{Commands, Events, Reader}
  alias HubWeb.{Permissions, Probelauf.Heuristik, Probelauf.SweepAggregator}
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
       |> assign(:sweep_form, default_sweep_form())
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
      kv = multi_stage_winners(socket.assigns.sweep_summaries || [])

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
      stage = parse_stage(params["stage"]) || 4
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
      stage = parse_stage(params["stage"])
      models = parse_models(params)
      session_set = parse_session_set(params)
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
      stage: parse_stage(params["stage"]) || socket.assigns.sweep_form.stage,
      models: MapSet.new(parse_models(params)),
      session_set: MapSet.new(parse_session_set(params)),
      stage_models: parse_stage_models(params, socket.assigns.sweep_form.stage_models)
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
      session_set = parse_session_set(params)
      isolated? = params["mode"] == "isolated"

      stage_models =
        parse_stage_models(params, socket.assigns.sweep_form.stage_models)

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

          case dispatch_sweep(isolated?, socket.assigns.current_user.discord_id,
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
        case dispatch_sweep(isolated?, socket.assigns.current_user.discord_id,
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

  defp parse_stage("2"), do: 2
  defp parse_stage("3"), do: 3
  defp parse_stage("4"), do: 4
  defp parse_stage(2), do: 2
  defp parse_stage(3), do: 3
  defp parse_stage(4), do: 4
  defp parse_stage(_), do: nil

  defp default_sweep_form,
    do: %{
      mode: "full",
      stage: 2,
      models: MapSet.new(),
      session_set: MapSet.new(["short", "medium", "long"]),
      # Issue #88 (Phase 2b): per-Stage Modellauswahl. Ein Multi-Stage-Sweep
      # läuft sequentiell N einzelne Single-Stage-Sweeps (eine pro Stage mit
      # nicht-leerer Modell-Liste), die LV hält sie im Anschluss in
      # `:pending_sweep_queue` und feuert den nächsten, sobald
      # `ProbelaufSweepFinished` für den laufenden eintrifft.
      stage_models: %{2 => MapSet.new(), 3 => MapSet.new(), 4 => MapSet.new()}
    }

  defp parse_session_set(params) do
    case params["session_set"] do
      list when is_list(list) ->
        list |> Enum.reject(&(&1 == "" or is_nil(&1))) |> Enum.filter(&(&1 in ["short", "medium", "long", "real"]))

      m when is_map(m) ->
        m
        |> Map.values()
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.filter(&(&1 in ["short", "medium", "long", "real"]))

      _ ->
        []
    end
  end

  defp parse_models(params) do
    case params["models"] do
      models when is_list(models) ->
        Enum.reject(models, &(&1 == "" or is_nil(&1)))

      models when is_map(models) ->
        models |> Map.values() |> Enum.reject(&(&1 == "" or is_nil(&1)))

      _ ->
        []
    end
  end

  # Issue #88 (Phase 2b): liest `params["stage_models"]` = %{"2" => [...], ...}
  # in den internen Stage→MapSet-Cache. Stages ohne Eintrag in `params`
  # bleiben beim alten Stand — das verhindert Aushaken aller Auswahlen
  # in Stages, die im aktuellen phx-change-Event nicht angefasst wurden.
  defp parse_stage_models(params, fallback) do
    raw =
      case params["stage_models"] do
        m when is_map(m) -> m
        _ -> %{}
      end

    for stage <- [2, 3, 4], into: %{} do
      key = Integer.to_string(stage)

      ms =
        case Map.fetch(raw, key) do
          {:ok, list} when is_list(list) ->
            list
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> MapSet.new()

          {:ok, m} when is_map(m) ->
            m
            |> Map.values()
            |> Enum.reject(&(&1 == "" or is_nil(&1)))
            |> MapSet.new()

          _ ->
            # Stage nicht im params → unverändert lassen.
            fallback |> Map.get(stage, MapSet.new())
        end

      {stage, ms}
    end
  end

  # Issue #88 (Phase 2c): aus einer Liste von SweepAggregator-Summaries die
  # `%{model_stageN: "winner"}`-Map ableiten. Pro Summary die Top-Row
  # nehmen, aber nur wenn success_rate ≥ 0.5 (Quality-Gate). Ein Modell,
  # das mehrfach für unterschiedliche Stages gewinnt, wird allen Stages
  # zugewiesen. Wenn keine Stage ein verwendbares Ergebnis hat, returnt
  # `%{}` und der Caller flashed eine Fehlermeldung.
  defp multi_stage_winners(summaries) when is_list(summaries) do
    summaries
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn summary, acc ->
      stage = summary[:stage]
      top = summary |> Map.get(:rows, []) |> List.first()

      cond do
        is_nil(stage) -> acc
        is_nil(top) -> acc
        top[:success_rate] == nil -> acc
        top.success_rate < 0.5 -> acc
        not is_binary(top[:model]) -> acc
        true -> Map.put(acc, :"model_stage#{stage}", top.model)
      end
    end)
  end

  defp dispatch_sweep(isolated?, did, stage, models, session_set) do
    dispatch_fn =
      if isolated?,
        do: &Commands.request_probelauf_sweep_isolated/4,
        else: &Commands.request_probelauf_sweep/4

    dispatch_fn.(did, stage, models, session_set)
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

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when is_number(ms) and ms < 1000, do: "#{round(ms)} ms"
  defp format_ms(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp outcome_color("ok"), do: "bg-success/20 text-success"
  defp outcome_color("timeout"), do: "bg-danger/20 text-danger"
  defp outcome_color("empty_output"), do: "bg-warning/20 text-warning"
  defp outcome_color("parse_error"), do: "bg-warning/20 text-warning"
  defp outcome_color(_), do: "bg-surface-2/40 text-fg-muted"

  # ─── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — LLM-Probelauf</h1>
        <p class="text-ink-2 text-sm mt-1">
          Smoke-Test der Pipeline mit aktueller Worker-Config. Issue #74.
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — Probelauf nicht möglich.
        </div>
      <% else %>
        <div class="space-y-6">
          <div class="panel p-4 flex items-center justify-between">
            <div>
              <%= if @running do %>
                <p class="text-ink-0">
                  <span class="inline-block w-2 h-2 rounded-full bg-warning animate-pulse mr-2">
                  </span>
                  Probelauf läuft (run_id: <code class="text-xs">{@running["run_id"]}</code>)
                </p>
                <p class="text-xs text-ink-2 mt-1">
                  Gestartet: {format_iso(@running["started_at"])} — Worker arbeitet 3 Sessions
                  sequentiell durch (~2–8 min je nach Hardware).
                </p>
                <p class="text-xs text-ink-2 mt-1">
                  Aktuell laufende GPU-Stage:
                  <.link navigate={~p"/admin/jobs"} class="text-accent hover:underline">/admin/jobs</.link>
                </p>
              <% else %>
                <p class="text-ink-0">Bereit für Probelauf.</p>
                <p class="text-xs text-ink-2 mt-1">
                  Seed 3 Sessions (10/30/100 Utterances) + Pipeline-Run + Cleanup.
                </p>
              <% end %>
            </div>
            <.btn
              variant="primary"
              icon="player-play"
              phx-click="start_probelauf"
              disabled={@running != nil}
            >
              Probelauf starten
            </.btn>
          </div>

          <%= if @running do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">Live-Status</h3>
              <%= if map_size(@live_stages) == 0 do %>
                <p class="text-ink-2 text-sm">
                  Warte auf erste Stage-Events vom Worker …
                </p>
              <% else %>
                <%= for {cid, stages} <- @live_stages do %>
                  <div class="mb-3">
                    <p class="text-xs text-ink-2">Campaign: <code>{cid}</code></p>
                    <div class="flex gap-2 mt-1 flex-wrap">
                      <%= for stage <- @stages do %>
                        <% cell = stages[stage] %>
                        <span class={"px-2 py-1 rounded text-xs " <> outcome_color(stage_state(cell && cell.status))}>
                          {stage}: {if(cell, do: cell.status, else: "—")}
                        </span>
                      <% end %>
                    </div>
                    <%= for stage <- @stages, cell = stages[stage], cell && cell.error do %>
                      <p class="mt-1 text-xs text-rose-300">
                        ✗ {stage}: {cell.error}
                      </p>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%= if @last_run do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                Letzter Probelauf
                <span class="text-ink-2/70 normal-case font-normal ml-2">
                  ({format_iso(@last_run["finished_at"])})
                </span>
              </h3>

              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                    <tr>
                      <th class="text-left px-3 py-2">Session</th>
                      <th class="text-left px-3 py-2">Utterances</th>
                      <%= for s <- @stages do %>
                        <th class="text-left px-3 py-2">{s}</th>
                      <% end %>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for sess <- @last_run["sessions"] || [] do %>
                      <tr class="border-b border-bg-3/30 last:border-0">
                        <td class="px-3 py-2 text-ink-0">#{sess["number"]}</td>
                        <td class="px-3 py-2 text-ink-2">{sess["utterance_count"]}</td>
                        <%= for stage <- @stages do %>
                          <td class="px-3 py-2">
                            <span class={"px-2 py-1 rounded text-xs " <> outcome_color(get_in(sess, ["stages", stage, "outcome"]))}>
                              {format_ms(get_in(sess, ["stages", stage, "duration_ms"]))} · {get_in(sess, ["stages", stage, "outcome"]) || "—"}
                            </span>
                          </td>
                        <% end %>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <div class="mt-4 panel p-4 bg-bg-1/50">
                <h4 class="text-sm uppercase tracking-widest text-ink-2 mb-2">Empfehlung</h4>
                <%= if @recommendation_text do %>
                  <div class="text-sm text-ink-0 whitespace-pre-line">
                    {@recommendation_text}
                  </div>
                  <div class="mt-3">
                    <.btn
                      variant="secondary"
                      icon="check"
                      phx-click="apply_recommendation"
                      disabled={@recommendation_kv == %{}}
                    >
                      Empfehlung übernehmen
                    </.btn>
                    <span class="text-xs text-ink-2 ml-2">
                      Setzt: <code>{inspect(@recommendation_kv)}</code>
                    </span>
                  </div>
                <% else %>
                  <p class="text-ink-2 text-sm italic">Keine Empfehlung verfügbar.</p>
                <% end %>
              </div>

              <details class="mt-4 text-xs">
                <summary class="cursor-pointer text-ink-2 hover:text-accent uppercase tracking-widest">
                  Settings-Snapshot zum Lauf
                </summary>
                <pre class="mt-2 panel p-3 text-ink-2 overflow-x-auto"><%= inspect(@last_run["settings_snapshot"], pretty: true) %></pre>
              </details>
            </div>
          <% end %>

          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Sweep — Modell-Vergleich pro Stage (Phase 2a)
            </h3>
            <p class="text-xs text-ink-2 mb-4">
              Variiert genau eine Stage durch mehrere Modelle. Die anderen zwei Stages bleiben auf dem aktuellen Default — nur die ausgewählte Stage wird gemessen. Dauer ≈ <code>Anzahl-Modelle × Single-Probelauf-Dauer</code>.
            </p>
            <form phx-submit="start_sweep" phx-change="sweep_form_change" class="space-y-4">
              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Sweep-Modus</p>
                <div class="flex gap-4">
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="full"
                      checked={@sweep_form.mode == "full"}
                      class="accent-accent"
                    />
                    Voll-Pipeline
                    <span class="text-ink-2/70 text-xs">(alle Stages laufen, Default-Modus)</span>
                  </label>
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="isolated"
                      checked={@sweep_form.mode == "isolated"}
                      class="accent-accent"
                    />
                    Stage-Isoliert
                    <span class="text-ink-2/70 text-xs">
                      (#262 — nur Ziel-Stage gegen Goldstandard, ~3-5× schneller)
                    </span>
                  </label>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Stage</p>
                <div class="flex gap-4">
                  <%= for s <- [2, 3, 4] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="radio"
                        name="stage"
                        value={s}
                        checked={@sweep_form.stage == s}
                        class="accent-accent"
                      />
                      Stage {s}
                      <span class="text-ink-2/70">
                        ({case s do
                          2 -> "Resümee"
                          3 -> "Epos"
                          4 -> "Chronik"
                        end})
                      </span>
                    </label>
                  <% end %>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Eval-Sessions (#284 / #286)
                </p>
                <div class="flex gap-4 flex-wrap">
                  <%= for {tag, label, utts} <- [
                        {"short", "kurz", "10"},
                        {"medium", "medium", "30"},
                        {"long", "lang", "100"},
                        {"real", "real", "~800"}
                      ] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="checkbox"
                        name="session_set[]"
                        value={tag}
                        checked={MapSet.member?(@sweep_form.session_set, tag)}
                        class="accent-accent"
                      />
                      {label}
                      <span class="text-ink-2/70 text-xs">({utts} utts)</span>
                    </label>
                  <% end %>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Modelle ({length(@available_models)} verfügbar)
                </p>
                <%= if @available_models == [] do %>
                  <p class="text-sm text-ink-2 italic">
                    Worker hat keine Modelle gemeldet — Ollama läuft? <code>ollama list</code> prüfen.
                  </p>
                <% else %>
                  <div class="grid grid-cols-2 gap-2">
                    <%= for m <- @available_models do %>
                      <label class="flex items-center gap-2 text-sm text-ink-0">
                        <input
                          type="checkbox"
                          name="models[]"
                          value={m}
                          checked={MapSet.member?(@sweep_form.models, m)}
                          class="accent-accent"
                        />
                        <code class="text-xs">{m}</code>
                      </label>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <.btn
                variant="primary"
                icon="player-play"
                type="submit"
                disabled={@running != nil or @available_models == []}
              >
                Sweep starten
              </.btn>
            </form>

            <%= if @running && @running["type"] == "sweep" do %>
              <div class="mt-4 panel p-3 bg-bg-1/50">
                <p class="text-xs text-ink-2">
                  Sweep läuft: sweep_id <code>{@running["sweep_id"]}</code>, Stage {@running["stage"]}, {length(@running["models"] || [])} Modelle.
                </p>
                <%= if @running["current_model"] do %>
                  <p class="text-sm text-ink-0 mt-1">
                    Aktuell: <code>{@running["current_model"]}</code>
                    <%= if @running["completed"] && @running["total"] do %>
                      <span class="text-xs text-ink-2 ml-2">
                        ({@running["completed"] + 1}/{@running["total"]})
                      </span>
                    <% end %>
                  </p>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Multi-Stage-Sweep (Phase 2b)
            </h3>
            <p class="text-xs text-ink-2 mb-4">
              Pro Stage eine eigene Modell-Liste ankreuzen — die LV feuert die Sweeps sequentiell ab, je ein Sweep pro Stage mit nicht-leerer Auswahl.
              <span class="text-ink-2/70">Modus + Eval-Sessions gelten für alle Stages gleich.</span>
            </p>
            <form phx-submit="start_sweep_multi" phx-change="sweep_form_change" class="space-y-4">
              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">Sweep-Modus</p>
                <div class="flex gap-4">
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="full"
                      checked={@sweep_form.mode == "full"}
                      class="accent-accent"
                    />
                    Voll-Pipeline
                  </label>
                  <label class="flex items-center gap-2 text-sm text-ink-0">
                    <input
                      type="radio"
                      name="mode"
                      value="isolated"
                      checked={@sweep_form.mode == "isolated"}
                      class="accent-accent"
                    />
                    Stage-Isoliert
                  </label>
                </div>
              </div>

              <div>
                <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                  Eval-Sessions
                </p>
                <div class="flex gap-4 flex-wrap">
                  <%= for {tag, label, utts} <- [
                        {"short", "kurz", "10"},
                        {"medium", "medium", "30"},
                        {"long", "lang", "100"},
                        {"real", "real", "~800"}
                      ] do %>
                    <label class="flex items-center gap-2 text-sm text-ink-0">
                      <input
                        type="checkbox"
                        name="session_set[]"
                        value={tag}
                        checked={MapSet.member?(@sweep_form.session_set, tag)}
                        class="accent-accent"
                      />
                      {label}
                      <span class="text-ink-2/70 text-xs">({utts} utts)</span>
                    </label>
                  <% end %>
                </div>
              </div>

              <%= for s <- [2, 3, 4] do %>
                <div>
                  <p class="text-xs uppercase tracking-widest text-ink-2 mb-2">
                    Stage {s} — <%= case s do
                      2 -> "Resümee"
                      3 -> "Epos"
                      4 -> "Chronik"
                    end %>
                    <span class="text-ink-2/70 normal-case font-normal ml-2">
                      ({MapSet.size(@sweep_form.stage_models[s])} angekreuzt)
                    </span>
                  </p>
                  <%= if @available_models == [] do %>
                    <p class="text-sm text-ink-2 italic">Keine Modelle verfügbar.</p>
                  <% else %>
                    <div class="grid grid-cols-2 gap-2">
                      <%= for m <- @available_models do %>
                        <label class="flex items-center gap-2 text-sm text-ink-0">
                          <input
                            type="checkbox"
                            name={"stage_models[#{s}][]"}
                            value={m}
                            checked={MapSet.member?(@sweep_form.stage_models[s], m)}
                            class="accent-accent"
                          />
                          <code class="text-xs">{m}</code>
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <.btn
                variant="primary"
                icon="player-play"
                type="submit"
                disabled={@running != nil or @available_models == []}
              >
                Multi-Stage-Sweep starten
              </.btn>

              <%= if @pending_sweep_queue != [] do %>
                <p class="text-xs text-ink-2 mt-2">
                  Queue: noch {length(@pending_sweep_queue)} Stages wartend ({@pending_sweep_queue |> Enum.map(& "Stage #{&1.stage}") |> Enum.join(", ")}).
                </p>
              <% end %>
            </form>

            <% multi_kv = multi_stage_winners(@sweep_summaries || []) %>
            <%= if multi_kv != %{} do %>
              <div class="mt-4 panel p-3 bg-bg-1/50">
                <h4 class="text-sm uppercase tracking-widest text-ink-2 mb-2">
                  Beste Multi-Stage-Empfehlung (Phase 2c)
                </h4>
                <p class="text-xs text-ink-2 mb-3">
                  Aus den letzten <%= length(@sweep_summaries || []) %> Sweeps abgeleitet — pro Stage der Top-Treffer (Quality-Gate: success_rate ≥ 50%).
                </p>
                <ul class="text-sm text-ink-0 mb-3 space-y-1">
                  <%= for {key, model} <- Enum.sort(multi_kv) do %>
                    <li>
                      <code class="text-xs">{key}</code> → <code class="text-xs">{model}</code>
                    </li>
                  <% end %>
                </ul>
                <.btn
                  variant="secondary"
                  icon="check"
                  phx-click="apply_multi_recommendation"
                  disabled={@running != nil}
                >
                  Multi-Stage-Empfehlung übernehmen
                </.btn>
                <p class="mt-2 text-xs text-ink-2/70 italic">
                  Schreibt {map_size(multi_kv)} Settings via <code>Worker.Settings.put_many/1</code>. Worker-Restart greift erst danach.
                </p>
              </div>
            <% end %>
          </div>

          <%!-- Issue #289 Phase 4: Param-Sweep (Temperature-Varianten). --%>
          <div class="panel p-4">
            <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
              Param-Sweep (Temperature)
            </h3>
            <p class="text-xs text-ink-2 mb-3">
              Variiert <code>temperature_stageN</code> über eine feste Werte-Liste
              bei aktuellem Default-Modell. Pro Temperatur eine Variante in der
              Sweep-Tabelle unten. Werte: <code>0.05, 0.10, 0.15, 0.20</code>
              (hardcoded für #289 Phase 4 — Settings-API folgt falls gewünscht).
            </p>
            <form phx-submit="start_sweep_param" class="space-y-3">
              <div class="flex items-center gap-3">
                <label class="text-sm text-ink-0">Stage:</label>
                <select name="stage" class="px-2 py-1 bg-bg-2 border border-bg-3 rounded text-sm">
                  <option value="2">Stage 2 (Resümee)</option>
                  <option value="3">Stage 3 (Epos)</option>
                  <option value="4" selected>Stage 4 (Chronik)</option>
                </select>
              </div>
              <.btn
                variant="primary"
                icon="adjustments"
                type="submit"
                disabled={@running != nil}
              >
                Param-Sweep starten (4 Temperaturen)
              </.btn>
            </form>
          </div>

          <% display = displayed_sweep_summary(assigns) %>
          <%= if display do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                <%= if display.in_progress? do %>
                  Sweep läuft — Stage {display.stage}
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    ({length(display.rows)}/{display.total_models} bewertet)
                  </span>
                <% else %>
                  Letzter Sweep — Stage {display.stage}
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    ({format_iso(display.finished_at)})
                  </span>
                <% end %>
                <%= if display[:session_set] && display.session_set != [] do %>
                  <span class="text-ink-2/70 normal-case font-normal ml-2">
                    — Sessions: {format_session_set(display.session_set)}
                  </span>
                <% end %>
              </h3>
              <p class="text-xs text-ink-2 mb-3">
                Default-Modell (vor Sweep): <code>{display.default_model}</code>.
                Sortiert nach Qualität ↓, Success-Rate ↓, Median-Dauer ↑ — beste Wahl oben.
              </p>

              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                    <tr>
                      <th class="text-left px-3 py-2 w-6"></th>
                      <th class="text-left px-3 py-2">Modell</th>
                      <th class="text-left px-3 py-2">Qualität</th>
                      <th class="text-left px-3 py-2">Median-Dauer (Stage {display.stage})</th>
                      <th class="text-left px-3 py-2">Success-Rate</th>
                      <th class="text-left px-3 py-2">Format</th>
                      <th class="text-left px-3 py-2">Timeout</th>
                      <th class="text-left px-3 py-2">Sessions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- display.rows do %>
                      <tr class="border-b border-bg-3/30 last:border-0">
                        <td class="px-3 py-2">
                          <span class={"inline-block w-2.5 h-2.5 rounded-full " <> status_dot_class(row[:status])} title={status_dot_label(row[:status])}></span>
                        </td>
                        <td class="px-3 py-2 text-ink-0">
                          <code class="text-xs">{row.model}</code>
                          <%= if row.model == display.default_model do %>
                            <span class="ml-2 text-xs text-ink-2/70">(Default)</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= if row[:faithfulness_avg] do %>
                            <span class={"px-2 py-1 rounded text-xs " <> faithfulness_color(row.faithfulness_avg)}>
                              {Float.round(row.faithfulness_avg * 100, 0) |> trunc()}%
                            </span>
                          <% else %>
                            <span class="text-ink-2/50">—</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2 text-ink-0">{format_ms(row.median_ms)}</td>
                        <td class="px-3 py-2">
                          <%= if row[:session_count] && row.session_count > 0 do %>
                            <span class={"px-2 py-1 rounded text-xs " <> success_rate_color(row.success_rate)}>
                              {Float.round(row.success_rate * 100, 0) |> trunc()}%
                            </span>
                          <% else %>
                            <span class="text-ink-2/50">—</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= cond do %>
                            <% row[:session_count] == nil or row.session_count == 0 -> %>
                              <span class="text-ink-2/50">—</span>
                            <% is_nil(row[:format_issue]) -> %>
                              <span class="text-success text-xs">ok</span>
                            <% true -> %>
                              <span class="px-2 py-1 rounded text-xs bg-warning/20 text-warning" title={row.format_issue}>
                                {row.format_issue}
                              </span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2">
                          <%= cond do %>
                            <% row[:session_count] == nil or row.session_count == 0 -> %>
                              <span class="text-ink-2/50">—</span>
                            <% row[:has_timeout] -> %>
                              <span class="px-2 py-1 rounded text-xs bg-danger/20 text-danger">ja</span>
                            <% true -> %>
                              <span class="text-ink-2 text-xs">nein</span>
                          <% end %>
                        </td>
                        <td class="px-3 py-2 text-ink-2">{row.session_count}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <p class="mt-3 text-xs text-ink-2 italic">
                Auto-Apply (das beste Modell mit einem Klick übernehmen) kommt in Phase 2c (#88).
                Manuell setzen via <code>/settings</code>.
              </p>
            </div>
          <% end %>

          <% history = Enum.drop(@sweep_summaries || [], 1) |> Enum.reject(&is_nil/1) %>
          <%= if history != [] do %>
            <div class="panel p-4">
              <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
                Sweep-Verlauf (Multi-Stage)
                <span class="text-ink-2/70 normal-case font-normal ml-2">
                  ({length(history)} zurückliegend)
                </span>
              </h3>
              <p class="text-xs text-ink-2 mb-3">
                Bei Multi-Stage-Sweeps zeigt der Verlauf die per-Stage-Tabellen aus den vorherigen Stages des aktuellen Multi-Stage-Laufs.
              </p>
              <%= for s <- history do %>
                <div class="mb-4 panel p-3 bg-bg-1/50">
                  <p class="text-xs text-ink-2 mb-2">
                    Stage {s.stage}
                    <span class="ml-2">({format_iso(s.finished_at)})</span>
                    — Default: <code>{s.default_model}</code>
                  </p>
                  <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                      <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                        <tr>
                          <th class="text-left px-3 py-2">Modell</th>
                          <th class="text-left px-3 py-2">Qualität</th>
                          <th class="text-left px-3 py-2">Median</th>
                          <th class="text-left px-3 py-2">Success</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- s.rows do %>
                          <tr class="border-b border-bg-3/30 last:border-0">
                            <td class="px-3 py-2 text-ink-0">
                              <code class="text-xs">{row.model}</code>
                              <%= if row.model == s.default_model do %>
                                <span class="ml-2 text-xs text-ink-2/70">(Default)</span>
                              <% end %>
                            </td>
                            <td class="px-3 py-2">
                              <%= if row[:faithfulness_avg] do %>
                                <span class={"px-2 py-1 rounded text-xs " <> faithfulness_color(row.faithfulness_avg)}>
                                  {Float.round(row.faithfulness_avg * 100, 0) |> trunc()}%
                                </span>
                              <% else %>
                                <span class="text-ink-2/50">—</span>
                              <% end %>
                            </td>
                            <td class="px-3 py-2 text-ink-0">{format_ms(row.median_ms)}</td>
                            <td class="px-3 py-2">
                              <span class={"px-2 py-1 rounded text-xs " <> success_rate_color(row.success_rate)}>
                                {Float.round(row.success_rate * 100, 0) |> trunc()}%
                              </span>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp success_rate_color(rate) when rate >= 1.0, do: "bg-success/20 text-success"
  defp success_rate_color(rate) when rate >= 0.5, do: "bg-warning/20 text-warning"
  defp success_rate_color(_), do: "bg-danger/20 text-danger"

  # Issue #288: Status-Dot pro Row.
  defp status_dot_class(:pending), do: "bg-warning animate-pulse"
  defp status_dot_class(:running), do: "bg-accent animate-pulse"
  defp status_dot_class(:done_ok), do: "bg-success"
  defp status_dot_class(:done_err), do: "bg-danger"
  defp status_dot_class(_), do: "bg-bg-3"

  defp status_dot_label(:pending), do: "wartet"
  defp status_dot_label(:running), do: "läuft"
  defp status_dot_label(:done_ok), do: "fertig (ok)"
  defp status_dot_label(:done_err), do: "fertig (Fehler)"
  defp status_dot_label(_), do: ""

  # Issue #284: macht aus ["short", "long"] → "kurz + lang"
  defp format_session_set(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      "short" -> "kurz"
      "medium" -> "medium"
      "long" -> "lang"
      other -> other
    end)
    |> Enum.join(" + ")
  end

  defp format_session_set(_), do: ""

  defp faithfulness_color(score) when is_number(score) and score >= 0.8,
    do: "bg-success/20 text-success"

  defp faithfulness_color(score) when is_number(score) and score >= 0.5,
    do: "bg-warning/20 text-warning"

  defp faithfulness_color(_), do: "bg-danger/20 text-danger"

  # Issue #281b: liefert die im UI angezeigte Sweep-Summary. Während ein
  # isolated Sweep läuft (running != nil + live_sweep_variants gefüllt) wird
  # die Tabelle live aus den per-Variant-Pushes aufgebaut; danach kommt das
  # finale @sweep_summary aus dem Worker-Snapshot.
  # Issue #288: Tabelle erscheint jetzt SOFORT beim Sweep-Start (auch wenn
  # noch keine Variant fertig ist) — Modelle als :pending-Rows angelegt.
  # Zusätzlich Status pro Row für Dots in der UI.
  defp displayed_sweep_summary(%{
         running: running,
         live_sweep_variants: live_variants
       } = assigns)
       when not is_nil(running) do
    total_models = running["models"] || []

    base =
      SweepAggregator.aggregate(%{
        "sweep_id" => running["sweep_id"],
        "stage" => running["stage"],
        "default_model" => running["default_model"],
        "started_at" => running["started_at"],
        "finished_at" => nil,
        "variants" => live_variants
      })

    rows =
      cond do
        # Sweep gerade gestartet — keine Variant fertig — alle Modelle als
        # :pending darstellen.
        base == nil ->
          Enum.map(total_models, &pending_row/1)

        true ->
          # Done-Rows + Pending-Rows für noch ausstehende Modelle mergen.
          done_models = MapSet.new(base.rows, & &1.model)

          pending_rows =
            total_models
            |> Enum.reject(&MapSet.member?(done_models, &1))
            |> Enum.map(&pending_row/1)

          base.rows ++ pending_rows
      end

    rows_with_status = Enum.map(rows, &with_row_status(&1, running))

    base_map =
      case base do
        nil ->
          %{
            sweep_id: running["sweep_id"],
            stage: running["stage"],
            stage_key: "stage#{running["stage"]}",
            default_model: running["default_model"],
            started_at: running["started_at"],
            finished_at: nil,
            session_set: []
          }

        m ->
          m
      end

    _ = assigns

    base_map
    |> Map.put(:rows, rows_with_status)
    |> Map.put(:in_progress?, true)
    |> Map.put(:total_models, length(total_models))
  end

  defp displayed_sweep_summary(%{sweep_summary: nil}), do: nil

  defp displayed_sweep_summary(%{sweep_summary: persisted}) do
    rows_with_status = Enum.map(persisted.rows || [], &with_row_status(&1, nil))

    persisted
    |> Map.put(:rows, rows_with_status)
    |> Map.put(:in_progress?, false)
    |> Map.put(:total_models, length(persisted.rows || []))
  end

  # Issue #288: Row-Skelett für noch nicht gemessene Modelle.
  defp pending_row(model) do
    %{
      model: model,
      median_ms: nil,
      success_rate: 0.0,
      faithfulness_avg: nil,
      run_count: 0,
      session_count: 0,
      format_issue: nil,
      has_timeout: false
    }
  end

  # Issue #288: leitet den Row-Status aus der Sweep-Progress + Row-Daten ab.
  # Reihenfolge der Klauseln matters — `:running` kommt vor `:done_*`.
  # Map.get statt Dot-Access wo Felder optional sind (alte persistierte
  # Sweeps vor #288 haben kein :has_timeout/:format_issue).
  defp with_row_status(row, running) do
    has_timeout = Map.get(row, :has_timeout, false)
    success_rate = Map.get(row, :success_rate, 0.0)
    session_count = Map.get(row, :session_count, 0)
    model = Map.get(row, :model)

    status =
      cond do
        running && model == running["current_model"] && session_count == 0 ->
          :running

        session_count == 0 && running != nil ->
          :pending

        has_timeout || (success_rate < 0.5 && session_count > 0) ->
          :done_err

        session_count > 0 ->
          :done_ok

        true ->
          :pending
      end

    Map.put(row, :status, status)
  end

  defp stage_state(nil), do: nil
  defp stage_state("started"), do: nil
  defp stage_state("ended"), do: "ok"
  defp stage_state("failed"), do: "timeout"
  defp stage_state(other), do: other

  defp format_iso(nil), do: "—"
  defp format_iso(s) when is_binary(s), do: s
  defp format_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso(_), do: "—"
end
