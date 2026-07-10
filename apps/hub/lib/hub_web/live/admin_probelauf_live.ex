defmodule HubWeb.AdminProbelaufLive do
  @moduledoc """
  Admin-LV (Issue #74): LLM-Probelauf — Smoke-Test der gesamten Pipeline
  auf einer dedizierten Probelauf-Kampagne mit Per-Stage-Messung und
  Heuristik-Empfehlung.

  Permission-Gate: nur globale Rolle `:admin` (analog `AdminUsersLive`).

  Flow:
  1. Admin klickt „Probelauf starten" → `Hub.Commands.request_probelauf_start/1`
     pingt den Owner-Worker, der `Worker.Probelauf.start/1` aufruft.
  2. Worker seedet eine Probelauf-Kampagne, schickt sie durch die
     Wahrheitsbild-Pipeline, misst pro Schritt (extract/verify/render/
     timeline/render_epos) Wall-Clock + Outcome + Verify-Trichter.
  3. Hub sieht den Fortschritt via `pipeline_status`-PubSub-Events und das
     finale `ProbelaufFinished`-Event über das `Hub.Events`-PubSub-Topic.
  4. LV holt den letzten Probelauf via Snapshot (`%{"kind" => "probelauf"}`)
     und rendert Heatmap + Trichter + Empfehlung.

  Issue #573: render/1 + Presentation-Helpers sind nach
  `HubWeb.AdminProbelaufLive.Render` extrahiert; Sweep-Form-Logik nach
  `HubWeb.AdminProbelaufLive.SweepForm`.
  """

  use HubWeb, :live_view

  alias HubWeb.Permissions

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
    perm_user =
      Permissions.admin_perm_user(user, socket.assigns[:current_user_role], is_member?: true)

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

  # Seit #786 (Wahrheitsbild-nativ): Extraktor-Modell-Sweep ohne Stage-/
  # Mode-Wahl — der Wahrheitsbild-Pfad hat genau einen LLM-Slot.
  def handle_event("start_sweep", params, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      models = SweepForm.parse_models(params)
      session_set = SweepForm.parse_session_set(params)

      # Form-State so persistieren wie der User ihn gerade abgesendet hat,
      # damit ein Re-Run nicht alles wieder ankreuzen muss.
      sweep_form = %{models: MapSet.new(models), session_set: MapSet.new(session_set)}
      socket = assign(socket, :sweep_form, sweep_form)

      cond do
        models == [] ->
          {:noreply, put_flash(socket, :error, "Mindestens ein Modell ankreuzen.")}

        session_set == [] ->
          {:noreply, put_flash(socket, :error, "Mindestens eine Eval-Session ankreuzen.")}

        true ->
          case Commands.request_probelauf_sweep(
                 socket.assigns.current_user.discord_id,
                 models,
                 session_set
               ) do
            0 ->
              {:noreply,
               put_flash(socket, :error, "Kein Worker verbunden — Sweep nicht startbar.")}

            n when n > 0 ->
              {:noreply,
               socket
               |> assign(:live_stages, %{})
               |> put_flash(
                 :info,
                 "Extraktor-Sweep angestoßen — #{length(models)} Modelle × #{length(session_set)} Eval-Sessions."
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
      models: MapSet.new(SweepForm.parse_models(params)),
      session_set: MapSet.new(SweepForm.parse_session_set(params))
    }

    {:noreply, assign(socket, :sweep_form, sweep_form)}
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

  # Issue #702: gebatchte Events durch die event_appended-Klauseln falten.
  def handle_info({:events_batch, events}, socket),
    do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)

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
        nil ->
          {nil, %{}}

        run ->
          # Issue #784: die Extraktor-Modell-Empfehlung schreibt auf den pro-
          # Backend-Key des aktiven backend_stage2 (Legacy-Keys entfernt).
          backend = to_string(get_in(run, ["settings_snapshot", "backend_stage2"]) || "local")
          Heuristik.build(run["sessions"] || [], available_models, backend)
      end

    sweep_summary = SweepAggregator.aggregate(last_sweep)

    {:noreply,
     assign(socket,
       no_worker?: false,
       running: running,
       last_run: last,
       last_sweep: last_sweep,
       sweep_summary: sweep_summary,
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
      available_models: [],
      recommendation_text: nil,
      recommendation_kv: %{}
    ]
  end

  # ─── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns), do: Render.render(assigns)
end
