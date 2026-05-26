defmodule HubWeb.AdminSpendLive do
  @moduledoc """
  Issue #177: Admin-Dashboard für Cloud-LLM-Spend.

  Listet `LLMCallBilled`-Events aggregiert pro Provider/Modell mit Total-Cost
  + Token-Counts. Default-Range: aktueller Monat. Filter: Datums-Range.

  Permission-Gate: nur :admin. Datenquelle: Worker-Snapshot via
  `Hub.Reader.read(%{"kind" => "llm_spend"})`.
  """

  use HubWeb, :live_view

  alias Hub.{Events, Reader}
  require Logger
  alias HubWeb.Permissions

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin_spend)
      |> assign(:current_campaign, nil)
      |> assign(:since, default_since())
      |> assign(:until, default_until())
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
  def handle_event("filter", %{"since" => since, "until" => until_str}, socket) do
    {:noreply,
     socket
     |> assign(:since, since)
     |> assign(:until, until_str)
     |> load_data()}
  end

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => "LLMCallBilled"}}}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  defp load_data(socket) do
    user = socket.assigns.current_user
    since_iso = since_iso(socket.assigns.since)
    until_iso = until_iso(socket.assigns.until)

    case Reader.read(%{
           "kind" => "llm_spend",
           "since" => since_iso,
           "until" => until_iso
         }) do
      {:ok, snap} ->
        viewer_role = resolve_viewer_role(user.discord_id)
        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        socket
        |> assign(
          no_worker?: false,
          rows: snap["rows"] || [],
          totals: snap["totals"] || %{},
          perm_user: perm_user,
          viewer_role: viewer_role
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          rows: [],
          totals: %{},
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )
    end
  end

  defp resolve_viewer_role(discord_id) do
    # Use all_users snapshot to derive role (same pattern as AdminUsersLive).
    case Reader.read(%{"kind" => "all_users"}) do
      {:ok, snap} ->
        snap["users"]
        |> Enum.find_value(:spieler, fn u ->
          if u["discord_id"] == discord_id, do: String.to_atom(u["role"]), else: nil
        end)

      _ ->
        :spieler
    end
  end

  defp default_since do
    now = DateTime.utc_now()
    "#{now.year}-#{pad(now.month)}-01"
  end

  defp default_until do
    now = DateTime.utc_now()
    "#{now.year}-#{pad(now.month)}-#{pad(now.day)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp since_iso(date_str), do: "#{date_str}T00:00:00Z"
  defp until_iso(date_str), do: "#{date_str}T23:59:59Z"

  defp format_cost(nil), do: "—"
  defp format_cost(c) when is_number(c), do: :erlang.float_to_binary(c * 1.0, decimals: 4)

  defp format_int(nil), do: "—"
  defp format_int(n) when is_integer(n), do: Integer.to_string(n)

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_ts(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> format_ts(dt)
      _ -> s
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-6xl mx-auto space-y-6">
      <header class="flex items-baseline justify-between">
        <h1 class="font-display text-2xl text-fg">LLM-Spend</h1>
        <p class="text-xs text-fg-muted">
          Cloud-LLM-Calls (heute: Anthropic; OpenAI/Google folgen via #174/#175)
        </p>
      </header>

      <%= if @no_worker? do %>
        <p class="panel p-4 text-fg-muted">Kein Worker verbunden — Spend nicht verfügbar.</p>
      <% else %>
        <form phx-change="filter" class="panel p-4 flex items-end gap-3">
          <label class="block">
            <span class="text-xs uppercase tracking-widest text-fg-muted">Von</span>
            <input
              type="date"
              name="since"
              value={@since}
              class="block bg-bg border border-border rounded px-2 py-1 text-sm text-fg"
            />
          </label>
          <label class="block">
            <span class="text-xs uppercase tracking-widest text-fg-muted">Bis</span>
            <input
              type="date"
              name="until"
              value={@until}
              class="block bg-bg border border-border rounded px-2 py-1 text-sm text-fg"
            />
          </label>
        </form>

        <div class="panel p-4 space-y-3">
          <h2 class="text-sm uppercase tracking-widest text-fg-muted">Übersicht</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div>
              <p class="text-xs text-fg-muted">Total USD</p>
              <p class="text-2xl font-display text-primary">${format_cost(@totals["total_cost_usd"])}</p>
            </div>
            <div>
              <p class="text-xs text-fg-muted">Calls</p>
              <p class="text-2xl font-display text-fg">{format_int(@totals["total_calls"])}</p>
            </div>
            <div>
              <p class="text-xs text-fg-muted">Input-Tokens</p>
              <p class="text-xl font-display text-fg">{format_int(@totals["total_input_tokens"])}</p>
            </div>
            <div>
              <p class="text-xs text-fg-muted">Output-Tokens</p>
              <p class="text-xl font-display text-fg">{format_int(@totals["total_output_tokens"])}</p>
            </div>
          </div>
        </div>

        <%= if map_size(@totals["by_model"] || %{}) > 0 do %>
          <div class="panel p-4 space-y-3">
            <h2 class="text-sm uppercase tracking-widest text-fg-muted">Pro Modell</h2>
            <table class="w-full text-sm">
              <thead class="text-xs uppercase tracking-widest text-fg-muted border-b border-border">
                <tr>
                  <th class="text-left px-2 py-1">Modell</th>
                  <th class="text-right px-2 py-1">Calls</th>
                  <th class="text-right px-2 py-1">Input</th>
                  <th class="text-right px-2 py-1">Output</th>
                  <th class="text-right px-2 py-1">USD</th>
                </tr>
              </thead>
              <tbody>
                <%= for {model, stats} <- Enum.sort_by(@totals["by_model"], fn {_m, s} -> -s["cost_usd"] end) do %>
                  <tr class="border-b border-border/30">
                    <td class="px-2 py-1 font-mono text-xs">{model}</td>
                    <td class="px-2 py-1 text-right">{format_int(stats["count"])}</td>
                    <td class="px-2 py-1 text-right">{format_int(stats["input_tokens"])}</td>
                    <td class="px-2 py-1 text-right">{format_int(stats["output_tokens"])}</td>
                    <td class="px-2 py-1 text-right">${format_cost(stats["cost_usd"])}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        <div class="panel p-4 space-y-3">
          <h2 class="text-sm uppercase tracking-widest text-fg-muted">
            Einzel-Calls (neueste oben, {length(@rows)} Einträge)
          </h2>
          <%= if @rows == [] do %>
            <p class="text-fg-muted text-sm italic">
              Keine Cloud-LLM-Calls im gewählten Zeitraum.
            </p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-xs">
                <thead class="text-fg-muted uppercase tracking-widest border-b border-border">
                  <tr>
                    <th class="text-left px-2 py-1">Zeit</th>
                    <th class="text-left px-2 py-1">Modell</th>
                    <th class="text-left px-2 py-1">Stage</th>
                    <th class="text-right px-2 py-1">in</th>
                    <th class="text-right px-2 py-1">out</th>
                    <th class="text-right px-2 py-1">ms</th>
                    <th class="text-right px-2 py-1">USD</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for r <- @rows do %>
                    <tr class="border-b border-border/30">
                      <td class="px-2 py-1 whitespace-nowrap">{format_ts(r["ts"])}</td>
                      <td class="px-2 py-1 font-mono">{r["model"]}</td>
                      <td class="px-2 py-1">{r["stage"]}</td>
                      <td class="px-2 py-1 text-right">{format_int(r["input_tokens"])}</td>
                      <td class="px-2 py-1 text-right">{format_int(r["output_tokens"])}</td>
                      <td class="px-2 py-1 text-right">{format_int(r["duration_ms"])}</td>
                      <td class="px-2 py-1 text-right">${format_cost(r["cost_usd"])}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
