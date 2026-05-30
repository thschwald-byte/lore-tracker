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

  alias Hub.Reader
  alias HubWeb.Permissions

  @poll_interval_ms 1_000

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket), do: schedule_poll()

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin_jobs)
      |> assign(:current_campaign, nil)
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
  def handle_info(:poll, socket) do
    schedule_poll()
    {:noreply, load_data(socket)}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  defp load_data(socket) do
    user = socket.assigns.current_user

    case Reader.read(%{"kind" => "jobs"}) do
      {:ok, snap} ->
        viewer_role = resolve_viewer_role(user.discord_id)
        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        socket
        |> assign(
          no_worker?: false,
          running: snap["running"],
          queue: snap["queue"] || [],
          perm_user: perm_user,
          viewer_role: viewer_role
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          running: nil,
          queue: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          no_worker?: false,
          running: nil,
          queue: [],
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )
    end
  end

  defp resolve_viewer_role(discord_id) do
    case Reader.read(%{"kind" => "all_users"}) do
      {:ok, snap} ->
        snap["users"]
        |> Enum.find_value(:spieler, fn u ->
          if u["discord_id"] == discord_id, do: parse_role(u["role"]), else: nil
        end)

      _ ->
        :spieler
    end
  end

  defp parse_role("admin"), do: :admin
  defp parse_role("spielleiter"), do: :spielleiter
  defp parse_role("spieler"), do: :spieler
  defp parse_role(_), do: :spieler

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms} ms"
  defp format_duration(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)} s"
  defp format_duration(_), do: "—"

  defp mode_color("sync"), do: "bg-info/20 text-info"
  defp mode_color("async"), do: "bg-accent/20 text-accent"
  defp mode_color(_), do: "bg-bg-3/40 text-ink-2"

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
        <div class="panel p-4 mb-4">
          <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">Aktuell laufender Job</h3>
          <%= if @running do %>
            <div class="flex items-center gap-3 text-sm">
              <span class={"px-2 py-1 rounded text-xs " <> mode_color(@running["mode"])}>
                {@running["mode"]}
              </span>
              <code class="text-ink-0">{@running["label"]}</code>
              <span class="text-ink-2 text-xs">läuft seit {format_duration(@running["duration_ms"])}</span>
            </div>
          <% else %>
            <p class="text-ink-2 text-sm italic">Idle — keine Last auf der GPU-Queue.</p>
          <% end %>
        </div>

        <div class="panel p-4">
          <h3 class="text-sm uppercase tracking-widest text-ink-2 mb-3">
            Wartende Jobs <span class="text-ink-2/70 normal-case font-normal ml-2">({length(@queue)})</span>
          </h3>
          <%= if @queue == [] do %>
            <p class="text-ink-2 text-sm italic">Keine wartenden Jobs.</p>
          <% else %>
            <ol class="text-sm text-ink-0 space-y-2">
              <%= for {job, idx} <- Enum.with_index(@queue, 1) do %>
                <li class="flex items-center gap-3">
                  <span class="text-ink-2 text-xs w-6">{idx}.</span>
                  <span class={"px-2 py-1 rounded text-xs " <> mode_color(job["mode"])}>
                    {job["mode"]}
                  </span>
                  <code>{job["label"]}</code>
                </li>
              <% end %>
            </ol>
          <% end %>
          <p class="mt-4 text-xs text-ink-2 italic">
            FIFO — der oberste Job läuft als nächstes los, sobald der aktuelle fertig ist.
          </p>
        </div>
      <% end %>
    </div>
    """
  end
end
