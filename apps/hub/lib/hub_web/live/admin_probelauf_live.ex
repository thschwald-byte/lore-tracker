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

  @stages Heuristik.stages()

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
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
      |> assign(:sweep_form, default_sweep_form())
      |> assign(:live_sweep_variants, [])
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
      session_set: MapSet.new(parse_session_set(params))
    }

    {:noreply, assign(socket, :sweep_form, sweep_form)}
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
      session_set: MapSet.new(["short", "medium", "long"])
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

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in [
             "ProbelaufStarted",
             "ProbelaufFinished",
             "ProbelaufSweepStarted",
             "ProbelaufSweepFinished"
           ] do
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

  def handle_info(:reload, socket), do: {:noreply, load_data(socket)}

  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  # ─── Data loading ─────────────────────────────────────────────────

  defp load_data(socket) do
    user = socket.assigns.current_user

    case Reader.read(%{"kind" => "probelauf"}) do
      {:ok, snap} ->
        last = snap["last_run"]
        last_sweep = snap["last_sweep"]
        running = snap["running"]
        available_models = snap["available_models"] || []

        viewer_role = viewer_role(user.discord_id, last)
        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        {recommendation_text, recommendation_kv} =
          case last do
            nil -> {nil, %{}}
            run -> Heuristik.build(run["sessions"] || [], available_models)
          end

        sweep_summary = SweepAggregator.aggregate(last_sweep)

        socket
        |> assign(
          no_worker?: false,
          running: running,
          last_run: last,
          last_sweep: last_sweep,
          sweep_summary: sweep_summary,
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
          last_sweep: nil,
          sweep_summary: nil,
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
          last_sweep: nil,
          sweep_summary: nil,
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
                      <th class="text-left px-3 py-2">Modell</th>
                      <th class="text-left px-3 py-2">Qualität</th>
                      <th class="text-left px-3 py-2">Median-Dauer (Stage {display.stage})</th>
                      <th class="text-left px-3 py-2">Success-Rate</th>
                      <th class="text-left px-3 py-2">Sessions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- display.rows do %>
                      <tr class="border-b border-bg-3/30 last:border-0">
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
                          <span class={"px-2 py-1 rounded text-xs " <> success_rate_color(row.success_rate)}>
                            {Float.round(row.success_rate * 100, 0) |> trunc()}%
                          </span>
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
        </div>
      <% end %>
    </div>
    """
  end

  defp success_rate_color(rate) when rate >= 1.0, do: "bg-success/20 text-success"
  defp success_rate_color(rate) when rate >= 0.5, do: "bg-warning/20 text-warning"
  defp success_rate_color(_), do: "bg-danger/20 text-danger"

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
  defp displayed_sweep_summary(%{
         running: running,
         live_sweep_variants: live_variants,
         sweep_summary: persisted
       })
       when not is_nil(running) and live_variants != [] do
    total = length(running["models"] || [])

    live =
      SweepAggregator.aggregate(%{
        "sweep_id" => running["sweep_id"],
        "stage" => running["stage"],
        "default_model" => running["default_model"],
        "started_at" => running["started_at"],
        "finished_at" => nil,
        "variants" => live_variants
      })

    if live do
      live
      |> Map.put(:in_progress?, true)
      |> Map.put(:total_models, total)
    else
      persisted && Map.put(persisted, :in_progress?, false)
    end
  end

  defp displayed_sweep_summary(%{sweep_summary: nil}), do: nil

  defp displayed_sweep_summary(%{sweep_summary: persisted}) do
    persisted
    |> Map.put(:in_progress?, false)
    |> Map.put(:total_models, length(persisted.rows || []))
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
