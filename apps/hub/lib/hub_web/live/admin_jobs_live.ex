defmodule HubWeb.AdminJobsLive do
  @moduledoc """
  Issue #292 (Phase 1): Live-View für den `Worker.GpuQueue`-Stand.
  Zeigt den aktuell laufenden Job + die FIFO-Queue der wartenden Jobs.

  Permission-Gate: nur :admin. Datenquelle: Worker-Snapshot
  (`Hub.Reader.read(%{"kind" => "jobs"})`). Auto-Reload alle 1 s — die
  GpuQueue pusht keine Events, ein leichter Poll reicht für die Admin-
  Debug-Anzeige.
  """

  use HubWeb, :live_view

  require Logger

  alias Hub.{Commands, Reader}
  alias HubWeb.Permissions

  @poll_interval_ms 1_000

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    # Issue #474: Gate-first über current_user_role (SidebarContext-on_mount),
    # fail-closed. Vorher fail-degraded via sync-Read-abgeleiteter Rolle.
    perm_user = Permissions.admin_perm_user(user, socket.assigns[:current_user_role])

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket), do: schedule_poll()

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:active_nav, :admin_jobs)
       |> assign(:current_campaign, nil)
       |> assign_defaults()
       |> start_jobs_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("job_action", %{"action" => action, "job_id" => job_id}, socket)
      when action in ~w(move_up move_down cancel) and is_binary(job_id) and job_id != "" do
    if not Permissions.can?(socket.assigns.perm_user, :view_admin) do
      {:noreply, socket}
    else
      n = Commands.request_gpu_job_action(socket.assigns.current_user.discord_id, action, job_id)

      socket =
        if n == 0 do
          put_flash(socket, :error, "Kein Worker verbunden — Aktion nicht zustellbar.")
        else
          # Sofort neu laden, damit der UI-Effekt sichtbar ist auch wenn der
          # 1s-Poll noch nicht gefeuert hat.
          start_jobs_load(socket)
        end

      {:noreply, socket}
    end
  end

  # Fallback: ungültige Payload (z.B. job_id fehlt → catch-all statt Crash).
  def handle_event("job_action", _params, socket) do
    {:noreply, put_flash(socket, :error, "Ungültige Job-Aktion (ID fehlt?).")}
  end

  @impl true
  def handle_info(:poll, socket) do
    schedule_poll()
    {:noreply, start_jobs_load(socket)}
  end

  @impl true
  def handle_async(:load_jobs, {:ok, {:ok, snap}}, socket) do
    {:noreply,
     assign(socket,
       no_worker?: false,
       running: snap["running"],
       live_queue: snap["live_queue"] || [],
       bg_queue: snap["bg_queue"] || [],
       recording_active?: snap["recording_active?"] == true
     )}
  end

  def handle_async(:load_jobs, {:ok, {:error, :no_worker}}, socket) do
    {:noreply, assign(socket, no_worker?: true) |> reset_data()}
  end

  def handle_async(:load_jobs, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
     |> assign(:no_worker?, false)
     |> reset_data()}
  end

  def handle_async(:load_jobs, {:exit, reason}, socket) do
    Logger.warning("admin_jobs load_jobs async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Self-Reschedule-Periodik: ein :poll, der sich selbst neu schedult.
  # PID-targeted → BEAM räumt pending send_after beim Prozess-Tod auf
  # (https://www.erlang.org/doc/system/ref_man_processes.html), kein Leak.
  # credo:disable-for-next-line LoreTracker.Credo.Check.TimerWithoutCleanup
  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  # Issue #474: lädt NUR Daten — perm_user/Rolle kommen aus dem Gate.
  # Issue #366: bevorzugt den eigenen Worker des Viewers (deterministisch).
  defp start_jobs_load(socket) do
    did = socket.assigns.current_user.discord_id

    start_async(socket, :load_jobs, fn ->
      Reader.read(%{"kind" => "jobs"}, prefer_discord_id: did)
    end)
  end

  defp assign_defaults(socket) do
    assign(socket,
      no_worker?: false,
      running: nil,
      live_queue: [],
      bg_queue: [],
      recording_active?: false
    )
  end

  defp reset_data(socket) do
    assign(socket,
      running: nil,
      live_queue: [],
      bg_queue: [],
      recording_active?: false
    )
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms} ms"
  defp format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)} s"
  defp format_duration(_), do: "—"

  defp mode_color("sync"), do: "bg-info/20 text-info"
  defp mode_color("async"), do: "bg-accent/20 text-accent"
  defp mode_color(_), do: "bg-bg-3/40 text-ink-2"

  defp priority_color("live"), do: "bg-warning/20 text-warning"
  defp priority_color("background"), do: "bg-bg-3/40 text-ink-2"
  defp priority_color(_), do: "bg-bg-3/40 text-ink-2"

  # Issue #355: reusable Panel für Live- + Background-Queue. Move/Cancel-
  # Buttons bleiben pro Queue erhalten.
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: "")
  attr(:jobs, :list, required: true)
  attr(:lane_color, :string, default: "")

  defp queue_panel(assigns) do
    ~H"""
    <div class={"panel p-4 mb-4 border " <> @lane_color}>
      <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
        {@title}
        <span class="text-ink-2/70 normal-case font-normal ml-2">({length(@jobs)})</span>
      </h3>
      <%= if @jobs == [] do %>
        <p class="text-ink-2 text-sm italic">Keine wartenden Jobs.</p>
      <% else %>
        <% last_idx = length(@jobs) - 1 %>
        <ol class="text-sm text-ink-0 space-y-2">
          <%= for {job, idx} <- Enum.with_index(@jobs) do %>
            <li class="flex items-center gap-3">
              <span class="text-ink-2 text-xs w-6">{idx + 1}.</span>
              <span class={"px-2 py-1 rounded text-xs " <> mode_color(job["mode"])}>
                {job["mode"]}
              </span>
              <code class="flex-1">{job["label"]}</code>

              <div class="flex gap-1">
                <button
                  type="button"
                  phx-click="job_action"
                  phx-value-action="move_up"
                  phx-value-job_id={job["job_id"]}
                  class="px-2 py-1 text-xs rounded border border-bg-3 text-ink-1 hover:bg-bg-2 disabled:opacity-30 disabled:cursor-not-allowed"
                  disabled={idx == 0}
                  title="Nach oben"
                >
                  ↑
                </button>
                <button
                  type="button"
                  phx-click="job_action"
                  phx-value-action="move_down"
                  phx-value-job_id={job["job_id"]}
                  class="px-2 py-1 text-xs rounded border border-bg-3 text-ink-1 hover:bg-bg-2 disabled:opacity-30 disabled:cursor-not-allowed"
                  disabled={idx == last_idx}
                  title="Nach unten"
                >
                  ↓
                </button>
                <button
                  type="button"
                  phx-click="job_action"
                  phx-value-action="cancel"
                  phx-value-job_id={job["job_id"]}
                  data-confirm={"Job " <> job["label"] <> " wirklich abbrechen?"}
                  class="px-2 py-1 text-xs rounded border border-danger/40 text-danger hover:bg-danger/10"
                  title="Verwerfen"
                >
                  ✕
                </button>
              </div>
            </li>
          <% end %>
        </ol>
      <% end %>
      <%= if @subtitle != "" do %>
        <p class="mt-3 text-xs text-ink-2 italic">{@subtitle}</p>
      <% end %>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — GPU-Queue Jobs</h1>
        <p class="text-ink-2 text-sm mt-1">
          Strikt-serielle Job-Queue für GPU/CPU-schwere Operationen (Issue #292). Aktualisiert sich automatisch jede Sekunde.
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-4 text-ink-2 text-sm">
          Kein Worker verbunden — Queue-Status nicht abrufbar.
        </div>
      <% else %>
        <%= if @recording_active? do %>
          <div class="panel p-3 mb-4 border-warning/40 bg-warning/10 text-sm text-ink-1">
            <strong>Aufnahme aktiv</strong>
            — Background-Jobs starten erst nach Session-Ende (Issue #355). Live-Aufnahme-Jobs überholen die Background-Queue.
          </div>
        <% end %>

        <div class="panel p-4 mb-4">
          <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">Aktuell laufender Job</h3>
          <%= if @running do %>
            <div class="flex items-center gap-3 text-sm">
              <span class={"px-2 py-1 rounded text-xs " <> mode_color(@running["mode"])}>
                {@running["mode"]}
              </span>
              <span class={"px-2 py-1 rounded text-xs " <> priority_color(@running["priority"])}>
                {@running["priority"] || "background"}
              </span>
              <code class="text-ink-0">{@running["label"]}</code>
              <span class="text-ink-2 text-xs">läuft seit {format_duration(@running["duration_ms"])}</span>
            </div>
          <% else %>
            <p class="text-ink-2 text-sm italic">Idle — keine Last auf der GPU-Queue.</p>
          <% end %>
        </div>

        <.queue_panel
          title="Live-Queue (Aufnahme)"
          subtitle="Sub-Sekunden-Priorität. Überholt die Background-Queue."
          jobs={@live_queue}
          lane_color="bg-accent/10 border-accent/40"
        />

        <.queue_panel
          title="Background-Queue"
          subtitle={
            if(@recording_active?,
              do: "Pausiert — Aufnahme aktiv. Jobs warten bis alle Sessions beendet sind.",
              else: "FIFO — der oberste Job läuft als nächstes los, sobald der aktuelle fertig ist."
            )
          }
          jobs={@bg_queue}
          lane_color="bg-bg-1/50 border-bg-3/60"
        />

        <p class="mt-4 text-xs text-ink-2 italic">
          Der laufende Job lässt sich nicht abbrechen (würde Inferenz-Zeit verbrennen + Subprozess-Hänger riskieren).
        </p>
      <% end %>
    </div>
    """
  end
end
