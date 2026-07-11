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

  alias HubWeb.Permissions

  alias Hub.{Commands, Events, Reader}
  alias HubWeb.{KnownIssues, Permissions}
  alias Shared.Events, as: EventKinds
  require Logger

  # Issue #68 Phase 3: stage1 dazu (Whisper-Coverage).
  # #786: Filter auf die Wahrheitsbild-Schritte; historische Chain-Rows
  # (stage2/3/4) bleiben über "alle" sichtbar + behalten ihre Farben unten.
  @stage_options ["alle", "stage1", "extract", "verify", "render", "timeline", "render_epos"]

  # Issue #569: Modul-Attribut statt Remote-Call im handle_info-Guard
  # (Iron-Law #8 / #552 — Remote-Call in :when ist verboten).
  @pipeline_error_logged_kind EventKinds.pipeline_error_logged()

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    # Issue #474: Gate-first über die globale Rolle aus dem SidebarContext-
    # on_mount-Hook (current_user_role) — deterministisch fail-CLOSED. Vorher
    # leitete das LV perm_user aus dem eigenen sync-Reader-Read ab und gatete
    # darüber: bei nicht-erreichbarem Worker fiel die Rolle auf :spieler, das
    # no_worker?-cond umging dann den view_admin-Check und renderte den Admin-
    # Shell trotzdem (fail-degraded). Jetzt: keine Worker-Reachability mehr im
    # Gate; Non-Admins (inkl. „Rolle unbestimmbar" → :spieler) werden umgeleitet.
    perm_user = Permissions.admin_perm_user(user, socket.assigns[:current_user_role])

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      end

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:active_nav, :admin_errors)
       |> assign(:current_campaign, nil)
       |> assign(:expanded, MapSet.new())
       # Issue #68 (Phase 2): Filter-State. "alle" = kein Filter.
       |> assign(:filter_stage, "alle")
       |> assign(:filter_type, "alle")
       |> assign(:stage_options, @stage_options)
       |> assign_defaults()
       |> start_errors_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin-Bereich — kein Zugriff.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # Issue #430: vor den handle_event-Block gezogen (war dazwischen → Gruppierung).
  defp normalize_filter(nil), do: "alle"
  defp normalize_filter(""), do: "alle"
  defp normalize_filter(v) when is_binary(v), do: v

  @impl true
  def handle_event("toggle_context", %{"id" => id}, socket) do
    set = socket.assigns.expanded

    set =
      if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)

    {:noreply, assign(socket, :expanded, set)}
  end

  # Issue #68 (Phase 2): Filter-Form. Server-side filtering ist hier OK
  # weil der Snapshot ohnehin auf max 50 Errors gecapped ist.
  def handle_event("filter_change", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_stage, normalize_filter(params["stage"]))
     |> assign(:filter_type, normalize_filter(params["type"]))}
  end

  # Issue #68 Phase 3: Retry-Button. Triggert Session-Regenerate beim Owner-
  # Worker (Phase 1 von #104 — request_session_regenerate/3). Permission:
  # globaler :admin reicht; pre-aufgerufenes view_admin schützt das LV.
  def handle_event("retry_session", %{"session_id" => sid, "campaign_id" => cid}, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      case Commands.request_session_regenerate(
             socket.assigns.current_user.discord_id,
             cid,
             sid
           ) do
        n when n >= 1 ->
          {:noreply, put_flash(socket, :info, "Session #{sid}: Pipeline-Regenerate ausgelöst.")}

        _ ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Kein Owner-Worker online — Retry nicht zustellbar."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:event_appended, %{payload: %{"kind" => @pipeline_error_logged_kind}}},
        socket
      ) do
    {:noreply, start_errors_load(socket)}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}

  # Issue #702: gebatchte Events durch die event_appended-Klauseln falten.
  def handle_info({:events_batch, events}, socket),
    do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, start_errors_load(socket)}

  @impl true
  def handle_async(:load_errors, {:ok, {:ok, snap}}, socket) do
    {:noreply,
     assign(socket,
       no_worker?: false,
       errors: snap["errors"] || [],
       count: snap["count"] || 0
     )}
  end

  def handle_async(:load_errors, {:ok, {:error, :no_worker}}, socket) do
    {:noreply, assign(socket, no_worker?: true, errors: [], count: 0)}
  end

  def handle_async(:load_errors, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
     |> assign(no_worker?: false, errors: [], count: 0)}
  end

  def handle_async(:load_errors, {:exit, reason}, socket) do
    Logger.warning("admin_errors load_errors async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Issue #474: lädt NUR noch die Daten — perm_user/Rolle kommen aus dem Gate
  # (current_user_role), nicht mehr aus einem zweiten all_users-Read hier.
  # Issue #366: bevorzugt den eigenen Worker des Viewers (deterministisch).
  defp start_errors_load(socket) do
    did = socket.assigns.current_user.discord_id

    start_async(socket, :load_errors, fn ->
      Reader.read(%{"kind" => "errors"}, prefer_discord_id: did)
    end)
  end

  defp assign_defaults(socket) do
    assign(socket, no_worker?: false, errors: [], count: 0)
  end

  defp format_iso(nil), do: "—"
  defp format_iso(""), do: "—"

  defp format_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> iso
    end
  end

  defp format_iso(other), do: inspect(other)

  defp stage_color("stage1"), do: "bg-accent/20 text-accent"
  # #786: Wahrheitsbild-Schritte.
  defp stage_color("extract"), do: "bg-info/20 text-info"
  defp stage_color("verify"), do: "bg-warning/20 text-warning"
  defp stage_color("render"), do: "bg-success/20 text-success"
  defp stage_color("timeline"), do: "bg-accent/20 text-accent"
  defp stage_color("render_epos"), do: "bg-danger/20 text-danger"
  # Historische Chain-Rows (Retention — Producer sind seit #786 weg).
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
  # Issue #68 Phase 3.
  defp type_label("ollama_unreachable"), do: "Ollama nicht erreichbar"
  defp type_label("model_not_found"), do: "Ollama: Modell nicht installiert"
  defp type_label("spend_cap_exceeded"), do: "Cloud-LLM: Monats-Cap erreicht"
  defp type_label("no_worker_token"), do: "Worker nicht gepairt"
  defp type_label("whisper_binary_missing"), do: "Whisper-CLI nicht gefunden"
  defp type_label("whisper_model_missing"), do: "Whisper-Modell nicht gefunden"
  defp type_label("whisper_failed"), do: "Whisper-Prozess abgebrochen"
  defp type_label("whisper_empty"), do: "Whisper: kein Text"
  defp type_label("whisper_sidecar_offline"), do: "Diarisierungs-Sidecar offline"
  # Issue #716: Wahrheitsbild-Pfad (Phase C).
  defp type_label("sidecar_offline"), do: "Verify: NLI-Sidecar offline"
  defp type_label("no_facts"), do: "Wahrheitsbild: keine Fakten extrahiert"
  defp type_label("no_verified_facts"), do: "Wahrheitsbild: 0 verifizierte Fakten"
  defp type_label("extraction_empty"), do: "Extraktion: leerer Fakt-Output"
  defp type_label("all_chunks_failed"), do: "Extraktion: alle Chunks fehlgeschlagen"
  defp type_label(t) when is_binary(t), do: t
  defp type_label(_), do: "(unbekannt)"

  defp pretty_context(%{} = ctx) do
    case Jason.encode(ctx, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(ctx, pretty: true)
    end
  end

  defp pretty_context(other), do: inspect(other, pretty: true)

  # Issue #68 (Phase 2): Server-side Filter.
  defp apply_filters(errors, "alle", "alle"), do: errors

  defp apply_filters(errors, stage_filter, type_filter) do
    Enum.filter(errors, fn err ->
      (stage_filter == "alle" or err["stage"] == stage_filter) and
        (type_filter == "alle" or err["error_type"] == type_filter)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-5xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — Pipeline-Fehler</h1>
        <p class="text-ink-2 text-sm mt-1">
          Strukturiertes Fehler-Log aus den Worker-Pipeline-Stages. Issue #68 Phase 2 — Filter + Known-Issues-Hints.
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
          <% filtered = apply_filters(@errors, @filter_stage, @filter_type) %>

          <form phx-change="filter_change" class="panel p-3 mb-4 flex flex-wrap gap-4 text-sm">
            <label class="flex items-center gap-2 text-ink-1">
              <span class="text-ink-2 uppercase tracking-widest text-xs">Stage</span>
              <select name="stage" class="bg-bg-0 border border-bg-3 rounded px-2 py-1 text-ink-0">
                <%= for s <- @stage_options do %>
                  <option value={s} selected={s == @filter_stage}>{s}</option>
                <% end %>
              </select>
            </label>
            <label class="flex items-center gap-2 text-ink-1">
              <span class="text-ink-2 uppercase tracking-widest text-xs">Error-Type</span>
              <select name="type" class="bg-bg-0 border border-bg-3 rounded px-2 py-1 text-ink-0">
                <option value="alle" selected={@filter_type == "alle"}>alle</option>
                <%= for t <- KnownIssues.known_types() do %>
                  <option value={t} selected={t == @filter_type}>{t}</option>
                <% end %>
              </select>
            </label>
          </form>

          <p class="text-xs text-ink-2 mb-3">
            <%= if @filter_stage == "alle" and @filter_type == "alle" do %>
              {@count} Fehler · sortiert nach Zeitpunkt (neuester zuerst).
            <% else %>
              {length(filtered)} von {@count} Fehlern (Filter aktiv).
            <% end %>
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
                <%= for err <- filtered do %>
                  <% id = err["error_id"] %>
                  <% expanded? = MapSet.member?(@expanded, id) %>
                  <% hint = KnownIssues.hint(err["error_type"], err["context"] || %{}) %>
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
                        <%= if hint do %>
                          <div class="mb-3 panel p-3 bg-accent/5 border border-accent/30">
                            <p class="text-sm text-ink-0 font-semibold mb-1">
                              {hint.icon} {hint.title}
                            </p>
                            <p class="text-sm text-ink-1">{hint.body}</p>
                          </div>
                        <% end %>
                        <div class="text-xs text-ink-2 mb-1 flex items-center gap-3 flex-wrap">
                          <%= if err["session_id"] do %>
                            <span>session <code>{err["session_id"]}</code></span>
                          <% end %>
                          <%= if err["campaign_id"] do %>
                            <span>· campaign <code>{err["campaign_id"]}</code></span>
                          <% end %>
                          <span>· error_id <code>{id}</code></span>
                          <%= if err["session_id"] && err["campaign_id"] do %>
                            <button
                              type="button"
                              phx-click="retry_session"
                              phx-value-session_id={err["session_id"]}
                              phx-value-campaign_id={err["campaign_id"]}
                              class="text-xs text-accent hover:underline"
                              title="Pipeline-Stage 2-4 für diese Session neu starten"
                            >
                              🔄 Session-Pipeline retry
                            </button>
                          <% end %>
                        </div>
                        <pre class="text-xs text-ink-1 whitespace-pre-wrap"><%= pretty_context(err["context"] || %{}) %></pre>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <%= if filtered == [] do %>
            <p class="mt-4 text-xs text-ink-2 italic">
              Kein Fehler passt zum aktuellen Filter.
            </p>
          <% end %>

          <p class="mt-4 text-xs text-ink-2 italic">
            Vollständige Übersicht aller Error-Types + Recovery-Pfade: <a
              href="https://codeberg.org/tomloresys/lore-tracker/src/branch/master/docs/Troubleshooting.md"
              class="text-accent hover:underline"
              target="_blank"
            >docs/Troubleshooting.md</a>.
          </p>
        <% end %>
      <% end %>
    </div>
    """
  end
end
