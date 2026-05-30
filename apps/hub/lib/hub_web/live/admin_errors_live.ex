defmodule HubWeb.AdminErrorsLive do
  @moduledoc """
  Issue #68 (Phase 1): Admin-Dashboard für strukturierte Pipeline-Fehler.

  Listet die letzten N `PipelineErrorLogged`-Events aus dem Worker-Snapshot.
  Permission-Gate: nur :admin. Datenquelle: `Hub.Reader.read(%{"kind" => "errors"})`.

  Phase 2 (#68 Folge-PR) bringt: Filter nach Stage / Error-Type + Known-Issues-
  Mapping mit Recovery-Hints.
  Phase 3: Retry-Buttons + docs/Troubleshooting.md.
  """

  use HubWeb, :live_view

  alias Hub.{Events, Reader}
  alias HubWeb.Permissions
  require Logger

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin_errors)
      |> assign(:current_campaign, nil)
      |> assign(:expanded, MapSet.new())
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
  def handle_event("toggle_context", %{"id" => id}, socket) do
    set = socket.assigns.expanded

    set =
      if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)

    {:noreply, assign(socket, :expanded, set)}
  end

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => "PipelineErrorLogged"}}}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  defp load_data(socket) do
    user = socket.assigns.current_user

    case Reader.read(%{"kind" => "errors"}) do
      {:ok, snap} ->
        viewer_role = resolve_viewer_role(user.discord_id)
        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        socket
        |> assign(
          no_worker?: false,
          errors: snap["errors"] || [],
          count: snap["count"] || 0,
          perm_user: perm_user,
          viewer_role: viewer_role
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          errors: [],
          count: 0,
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          no_worker?: false,
          errors: [],
          count: 0,
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

  defp format_iso(nil), do: "—"
  defp format_iso(""), do: "—"

  defp format_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> iso
    end
  end

  defp format_iso(other), do: inspect(other)

  defp stage_color("stage2"), do: "bg-info/20 text-info"
  defp stage_color("stage3"), do: "bg-warning/20 text-warning"
  defp stage_color("stage4"), do: "bg-danger/20 text-danger"
  defp stage_color(nil), do: "bg-bg-3/40 text-ink-2"
  defp stage_color(_), do: "bg-bg-3/40 text-ink-2"

  defp type_label("empty_chronik"), do: "Stage 4: keine Chronik-Einträge"
  defp type_label("no_key_configured"), do: "Cloud-LLM: API-Key fehlt"
  defp type_label("upstream_auth"), do: "Cloud-LLM: Auth abgelehnt (401/403)"
  defp type_label("upstream_rate_limit"), do: "Cloud-LLM: Rate-Limit (429)"
  defp type_label("network_error"), do: "Netzwerk-Fehler"
  defp type_label("upstream_error"), do: "Upstream 5xx"
  defp type_label("http_error"), do: "HTTP-Fehler"
  defp type_label("timeout"), do: "Timeout"
  defp type_label("no_summary"), do: "Stage 2: kein Resümee geparst"
  defp type_label("no_epos"), do: "Stage 3: kein Epos geparst"
  defp type_label("no_campaign"), do: "Kampagne nicht gefunden"
  defp type_label("no_session"), do: "Session nicht gefunden"
  defp type_label(t) when is_binary(t), do: t
  defp type_label(_), do: "(unbekannt)"

  defp pretty_context(%{} = ctx) do
    case Jason.encode(ctx, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(ctx, pretty: true)
    end
  end

  defp pretty_context(other), do: inspect(other, pretty: true)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — Pipeline-Fehler</h1>
        <p class="text-ink-2 text-sm mt-1">
          Strukturiertes Fehler-Log aus den Worker-Pipeline-Stages. Issue #68 Phase 1 — Read-only, ohne Filter.
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-4 text-ink-2 text-sm">
          Kein Worker verbunden — Fehler-Log nicht abrufbar.
        </div>
      <% else %>
        <%= if @errors == [] do %>
          <div class="panel p-4 text-ink-2 text-sm">
            Keine Pipeline-Fehler im Log.
            <span class="text-ink-2/70 ml-2">Wenn etwas schiefläuft, taucht der Eintrag hier nach ~1 Sekunde auf.</span>
          </div>
        <% else %>
          <p class="text-xs text-ink-2 mb-3">
            {@count} Fehler · sortiert nach Zeitpunkt (neuester zuerst).
          </p>

          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="text-ink-2 text-xs uppercase tracking-widest border-b border-bg-3/60">
                <tr>
                  <th class="text-left px-3 py-2">Zeitpunkt</th>
                  <th class="text-left px-3 py-2">Stage</th>
                  <th class="text-left px-3 py-2">Type</th>
                  <th class="text-left px-3 py-2">Message</th>
                  <th class="text-left px-3 py-2">Kontext</th>
                </tr>
              </thead>
              <tbody>
                <%= for err <- @errors do %>
                  <% id = err["error_id"] %>
                  <% expanded? = MapSet.member?(@expanded, id) %>
                  <tr class="border-b border-bg-3/30 last:border-0 align-top">
                    <td class="px-3 py-2 text-ink-2 whitespace-nowrap">{format_iso(err["occurred_at"])}</td>
                    <td class="px-3 py-2">
                      <span class={"px-2 py-1 rounded text-xs " <> stage_color(err["stage"])}>
                        {err["stage"] || "—"}
                      </span>
                    </td>
                    <td class="px-3 py-2 text-ink-0">{type_label(err["error_type"])}</td>
                    <td class="px-3 py-2 text-ink-2">
                      <span class="font-mono text-xs">{err["message"]}</span>
                    </td>
                    <td class="px-3 py-2">
                      <button
                        type="button"
                        phx-click="toggle_context"
                        phx-value-id={id}
                        class="text-xs text-accent hover:underline"
                      >
                        {if expanded?, do: "ausblenden", else: "anzeigen"}
                      </button>
                    </td>
                  </tr>

                  <%= if expanded? do %>
                    <tr class="border-b border-bg-3/30 last:border-0">
                      <td colspan="5" class="px-3 py-2 bg-bg-1/50">
                        <div class="text-xs text-ink-2 mb-1">
                          <%= if err["session_id"] do %>
                            session <code>{err["session_id"]}</code>
                          <% end %>
                          <%= if err["campaign_id"] do %>
                            · campaign <code>{err["campaign_id"]}</code>
                          <% end %>
                          · error_id <code>{id}</code>
                        </div>
                        <pre class="text-xs text-ink-1 whitespace-pre-wrap"><%= pretty_context(err["context"] || %{}) %></pre>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <p class="mt-4 text-xs text-ink-2 italic">
            Phase 2 (#68) bringt Filter (Stage, Error-Type) und Known-Issues-Hints („Ollama offline?", „API-Key fehlt"). Phase 3 bringt Retry-Buttons + Troubleshooting-Docs.
          </p>
        <% end %>
      <% end %>
    </div>
    """
  end
end
