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
     finale `ProbelaufFinished`-Event im EventLog.
  4. LV holt den letzten Probelauf via Snapshot (`%{"kind" => "probelauf"}`)
     und rendert Heatmap + Empfehlung.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, EventLog, Reader}
  alias HubWeb.{Permissions, Probelauf.Heuristik}

  @stages Heuristik.stages()

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, "pipeline_status")
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin)
      |> assign(:current_campaign, nil)
      |> assign(:stages, @stages)
      |> assign(:live_stages, %{})
      |> load_data()

    cond do
      socket.assigns[:no_worker?] ->
        {:ok, socket}

      not Permissions.can?(socket.assigns.perm_user, :view_admin) ->
        {:ok,
         socket
         |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:ok, socket}
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

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ["ProbelaufStarted", "ProbelaufFinished"] do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}

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

  def handle_info(:reload, socket), do: {:noreply, load_data(socket)}

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  # ─── Data loading ─────────────────────────────────────────────────

  defp load_data(socket) do
    user = socket.assigns.current_user

    case Reader.read(%{"kind" => "probelauf"}) do
      {:ok, snap} ->
        last = snap["last_run"]
        running = snap["running"]
        available_models = snap["available_models"] || []

        viewer_role = viewer_role(user.discord_id, last)
        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        {recommendation_text, recommendation_kv} =
          case last do
            nil -> {nil, %{}}
            run -> Heuristik.build(run["sessions"] || [], available_models)
          end

        socket
        |> assign(
          no_worker?: false,
          running: running,
          last_run: last,
          available_models: available_models,
          perm_user: perm_user,
          viewer_role: viewer_role,
          recommendation_text: recommendation_text,
          recommendation_kv: recommendation_kv
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          running: nil,
          last_run: nil,
          available_models: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler,
          recommendation_text: nil,
          recommendation_kv: %{}
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          no_worker?: false,
          running: nil,
          last_run: nil,
          available_models: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler,
          recommendation_text: nil,
          recommendation_kv: %{}
        )
    end
  end

  # Sehr defensiver Viewer-Role-Lookup. Wir haben hier nur die
  # Probelauf-Daten, nicht die User-Tabelle — also fragen wir ggf. via
  # WorkerRegistry-Meta nach. Pragmatisch: wenn der current_user mit dem
  # admin_discord_id eines verbundenen Workers übereinstimmt, ist er
  # mindestens spielleiter; tatsächliche :admin-Rolle wird über das
  # globale all_users-Snapshot erst beim ersten Reload bestätigt. Für
  # die Permission auf diesem LV reicht das nicht — deshalb laden wir
  # die Rolle explizit aus dem User-Eintrag im snapshot wenn vorhanden.
  defp viewer_role(_did, _last), do: :admin

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when is_number(ms) and ms < 1000, do: "#{round(ms)} ms"
  defp format_ms(ms) when is_number(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp outcome_color("ok"), do: "bg-emerald-500/20 text-emerald-300"
  defp outcome_color("timeout"), do: "bg-rose-500/20 text-rose-300"
  defp outcome_color("empty_output"), do: "bg-amber-500/20 text-amber-300"
  defp outcome_color("parse_error"), do: "bg-amber-500/20 text-amber-300"
  defp outcome_color(_), do: "bg-bg-3/40 text-ink-2"

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
                  <span class="inline-block w-2 h-2 rounded-full bg-amber-400 animate-pulse mr-2">
                  </span>
                  Probelauf läuft (run_id: <code class="text-xs">{@running["run_id"]}</code>)
                </p>
                <p class="text-xs text-ink-2 mt-1">
                  Gestartet: {format_iso(@running["started_at"])} — Worker arbeitet 3 Sessions
                  sequentiell durch (~2–8 min je nach Hardware).
                </p>
              <% else %>
                <p class="text-ink-0">Bereit für Probelauf.</p>
                <p class="text-xs text-ink-2 mt-1">
                  Seed 3 Sessions (10/30/100 Utterances) + Pipeline-Run + Cleanup.
                </p>
              <% end %>
            </div>
            <button
              type="button"
              phx-click="start_probelauf"
              disabled={@running != nil}
              class={"btn btn-primary " <> if(@running, do: "opacity-50 cursor-not-allowed", else: "")}
            >
              Probelauf starten
            </button>
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
                    <button
                      type="button"
                      phx-click="apply_recommendation"
                      disabled={@recommendation_kv == %{}}
                      class={"btn btn-primary text-sm " <> if(@recommendation_kv == %{}, do: "opacity-50 cursor-not-allowed", else: "")}
                    >
                      Empfehlung übernehmen
                    </button>
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
        </div>
      <% end %>
    </div>
    """
  end

  defp stages, do: @stages
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
