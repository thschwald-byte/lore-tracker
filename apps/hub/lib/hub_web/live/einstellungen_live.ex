defmodule HubWeb.EinstellungenLive do
  @moduledoc """
  Worker-Einstellungen: Backend + Modell + (für `:local`) URL.

  Settings sind **worker-lokal** (siehe `Worker.Settings`), nicht ins
  Event-Log repliziert. Mounted liest sie via Snapshot vom ausgewählten
  Worker (Track B); Speichern schickt gezielt an diesen Worker.

  Jeder LLM-Schritt (Extraktion/Verify/Render-Resümee/Render-Epos) rendert
  einen eigenen **Backend-Stack** (`HubWeb.EinstellungenLive.StageStack`): pro
  Backend eine Config-Box mit eigenem Modell (`model_stage{n}_{backend}`) und
  eigenem Speichern-Button; ein Radio wählt das aktive Backend
  (`backend_stage{n}`, sofortiger Save). Bis #786/#783 Phase 2 teilten sich
  Extraktion/Verify/Render EINEN Slot (Stage 2); #783 Phase 2 trennte
  Extraktion/Verify/Render (Stage 2/3/4). Nachtrag: Resümee und Epos-Kapitel
  liefen anfangs noch zusammen auf Stage 4 — jetzt hat auch das Epos-Kapitel
  sein eigenes Backend + Modell (Stage 5), weil ein Epos (länger,
  literarischer) andere Modell-Anforderungen hat als ein Resümee (kurz,
  faktentreu). Der globale Speichern-Button unten gilt nur noch für Whisper/
  Endpoint/Timeout/System-Pfade.

  Options-/Normalisierungs-Helfer: `HubWeb.EinstellungenLive.Options`.
  """

  use HubWeb, :live_view

  import HubWeb.EinstellungenLive.StageStack, only: [stage_block: 1]

  alias Hub.{Commands, Reader, WorkerRegistry}
  require Logger
  alias HubWeb.EinstellungenLive.Options
  alias HubWeb.Permissions

  @stages [
    {1, "Transcribe (Audio → Text)", "Stage 1 — kommt mit M10 (Discord-Bot)"},
    {2, "Extraktion (Wahrheitsbild)", "strukturierte Fakten aus dem Transkript"},
    {3, "Verify (Grounding + Attribution)",
     "Quell-Grounding + Sprecher-Zuordnung auf den Fakten — darf stärker sein als der Extraktor"},
    {4, "Render — Resümee", "kurzes, faktentreues Prosa-Resümee aus den verifizierten Fakten"},
    {5, "Render — Epos-Kapitel",
     "literarisches Kapitel aus den verifizierten Fakten — eigenes Modell, unabhängig vom Resümee"}
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    # Issue #451 (Track A): /settings ist Admin-only. Die globale Rolle steht
    # via HubWeb.SidebarContext-on_mount-Hook (Issue #387) als
    # `current_user_role`-assign zur Verfügung — wir bauen den perm_user
    # daraus und gaten mit `:view_admin`. Non-Admins werden auf "/" geschickt
    # (analog AdminUsersLive/AdminProbelaufLive).
    perm_user = Permissions.admin_perm_user(user, socket.assigns[:current_user_role])

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
        # Issue #144: PubSub-Updates für Debug-Consent-Status.
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.DebugConsent.topic())
        # 1s-Tick für Countdown-Anzeige in der Debug-Box.
        :timer.send_interval(1_000, :debug_consent_tick)
      end

      # Issue #451 (Track B): Worker-Selector. Liste der eigenen Worker des
      # aktuellen Admins; Default-Auswahl = der frischeste (höchster
      # applied_seq via list_for_admin/1).
      my_workers = WorkerRegistry.list_for_admin(user.discord_id)
      selected = List.first(my_workers)

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:active_nav, :settings)
       |> assign(:current_campaign, nil)
       |> assign(:stages, @stages)
       |> assign(:my_workers, my_workers)
       |> assign(:selected_worker_id, selected && selected.id)
       |> assign(:expanded_boxes, %{})
       |> assign(:save_status, %{})
       |> assign(:status_timers, %{})
       |> assign(:dev?, Application.get_env(:hub, :env, :prod) != :prod)
       |> assign(:debug_consent, Hub.DebugConsent.status(user.discord_id))
       |> assign(default_settings_assigns(true))
       |> start_settings_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Einstellungen sind Admin-only.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:workers_changed, _joins, _leaves}, socket) do
    # Issue #451 (Track B): Worker-Liste neu laden, Auswahl beibehalten wenn
    # der Worker noch da ist — sonst auf den frischesten zurückfallen.
    my_workers = WorkerRegistry.list_for_admin(socket.assigns.current_user.discord_id)
    current = socket.assigns[:selected_worker_id]
    still_online? = current && Enum.any?(my_workers, &(&1.id == current))

    selected =
      cond do
        still_online? ->
          current

        true ->
          my_workers
          |> List.first()
          |> case do
            nil -> nil
            w -> w.id
          end
      end

    {:noreply,
     socket
     |> assign(:my_workers, my_workers)
     |> assign(:selected_worker_id, selected)
     |> start_settings_load()}
  end

  # Issue #144: Debug-Consent-Status-Updates.
  def handle_info({:granted, did, expires_at}, socket) do
    if did == socket.assigns.current_user.discord_id do
      {:noreply, assign(socket, :debug_consent, %{expires_at: expires_at})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({kind, did}, socket) when kind in [:revoked, :expired] do
    if did == socket.assigns.current_user.discord_id do
      {:noreply, assign(socket, :debug_consent, nil)}
    else
      {:noreply, socket}
    end
  end

  # Tick triggert nur Re-Render — der Countdown-Wert wird im HEEx aus
  # `@debug_consent.expires_at - now` berechnet.
  def handle_info(:debug_consent_tick, socket), do: {:noreply, socket}

  # #451 Track C: verzögerter Snapshot-Reload nach einem Box-Save (statt
  # sleep — der Worker braucht einen Moment, den send zu applyen).
  def handle_info(:reload_settings, socket), do: {:noreply, start_settings_load(socket)}

  def handle_info({:clear_save_status, n, b}, socket) do
    {:noreply,
     socket
     |> assign(:save_status, Map.delete(socket.assigns.save_status, {n, b}))
     |> assign(:status_timers, Map.delete(socket.assigns.status_timers, {n, b}))}
  end

  @impl true
  def handle_event("debug_grant", %{"duration" => duration}, socket) do
    seconds =
      case Integer.parse(duration) do
        {n, _} when n in [300, 900, 3600] -> n
        _ -> 900
      end

    :ok = Hub.DebugConsent.grant(socket.assigns.current_user.discord_id, seconds)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Debug-Zugriff für #{div(seconds, 60)} min aktiviert. Läuft automatisch ab."
     )}
  end

  def handle_event("debug_revoke", _, socket) do
    :ok = Hub.DebugConsent.revoke(socket.assigns.current_user.discord_id)
    {:noreply, put_flash(socket, :info, "Debug-Zugriff widerrufen.")}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    kv = Options.normalize_settings_params(params)

    # Issue #451 (Track B): gezielt an den ausgewählten Worker schicken.
    # Bei Single-Worker-Setup ist das funktional identisch zum alten
    # Fan-out-Pfad (`update_my_worker_settings/2`), bei Multi-Worker macht
    # der User pro Worker individuelle Settings — siehe Worker-Selector.
    {flash_kind, flash_msg} =
      case Commands.update_one_worker_settings(socket.assigns.selected_worker_id, kv) do
        :ok ->
          {:info, "Settings gespeichert."}

        {:error, :worker_offline} ->
          {:error, "Worker offline — Settings nicht gespeichert."}
      end

    {:noreply,
     socket
     |> put_flash(flash_kind, flash_msg)
     |> start_settings_load()}
  end

  # #451 Track C: Save-Button EINER Backend-Box — granular, nur die Keys
  # dieser Box (pro-Backend-Modell + bei der aktiven Box die Stage-Sampling-
  # Keys). Optimistisches Settings-Merge, damit die UI sofort den
  # gespeicherten Stand zeigt; der verzögerte Reload (`:reload_settings`)
  # holt danach den persistierten Worker-Stand (kein sleep — #720-Muster).
  def handle_event("save_backend_box", %{"stage" => n, "backend" => b} = params, socket) do
    kv = Options.normalize_settings_params(params["settings"] || %{})
    {:noreply, push_box_save(socket, parse_stage!(n), b, kv)}
  end

  # #451 Track C: Radio — Backend der Stage aktivieren. Schreibt sofort
  # `backend_stage{n}` an den Worker und expandiert die Box.
  def handle_event("set_active_backend", %{"stage" => n, "backend" => b}, socket) do
    n = parse_stage!(n)

    socket =
      if Options.display_model(socket.assigns.settings, n, b) do
        socket
      else
        put_flash(
          socket,
          :info,
          "Backend aktiv, aber noch kein Modell gewählt — Modell in der Box setzen + speichern."
        )
      end

    {:noreply,
     socket
     |> assign(:expanded_boxes, Map.put(socket.assigns.expanded_boxes, n, b))
     |> push_box_save(n, b, %{"backend_stage#{n}" => b})}
  end

  # #451 Track C: ▸/▾ — Box auf-/zuklappen. Zuklappen fällt auf die Box des
  # aktiven Backends zurück (es ist immer genau eine expanded).
  def handle_event("toggle_box", %{"stage" => n, "backend" => b}, socket) do
    n = parse_stage!(n)
    active = socket.assigns.settings["backend_stage#{n}"] || "local"
    current = Map.get(socket.assigns.expanded_boxes, n, active)
    next = if current == b, do: active, else: b

    {:noreply, assign(socket, :expanded_boxes, Map.put(socket.assigns.expanded_boxes, n, next))}
  end

  # Issue #451 (Track B): User wechselt zwischen seinen eigenen Workern.
  # Re-load der Settings vom neuen Worker, ohne Mount-Round-Trip.
  def handle_event("select_worker", %{"worker_id" => worker_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_worker_id, worker_id)
     |> start_settings_load()}
  end

  # live_select-Component schickt diesen Event bei jedem Tippen im Combobox-
  # Text-Input. #451 Track C: die `id` trägt Backend + Stage direkt
  # (`settings_model_stage{n}_{backend}_live_select_component`) — jede Box
  # hat ihr festes Backend, kein Settings-Lookup nötig.
  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    models = effective_models_for_id(id, socket.assigns)
    opts = Options.model_options(models, socket.assigns.worker_aggregate, text)
    send_update(LiveSelect.Component, id: id, options: opts)
    {:noreply, socket}
  end

  defp effective_models_for_id(id, assigns) when is_binary(id) do
    case Regex.run(~r/model_stage\d_(local|anthropic|openai|google)/, id) do
      [_, backend] ->
        {models, _err, _placeholder} = Options.stage_model_options(backend, assigns)
        models

      _ ->
        assigns.available_models
    end
  end

  defp effective_models_for_id(_, assigns), do: assigns.available_models

  # #451 Track C: gemeinsamer Box-Save-Pfad (Radio + Speichern-Button).
  # `update_one_worker_settings/2` ist ein nicht-blockierender send (kein
  # Worker-Roundtrip) — der anschließende Snapshot-Reload läuft verzögert
  # via send_after statt sleep (#720), damit der LV-Prozess nie blockiert.
  # Vorherige Timer derselben Box werden gecancelt — sonst räumt der Timer
  # eines ÄLTEREN Saves den Status-Badge eines neueren vorzeitig ab.
  defp push_box_save(socket, n, b, kv) do
    status =
      case socket.assigns.selected_worker_id do
        nil ->
          :error

        wid ->
          case Commands.update_one_worker_settings(wid, kv) do
            :ok -> :saved
            {:error, :worker_offline} -> :error
          end
      end

    timers = socket.assigns.status_timers

    if ref = Map.get(timers, :reload), do: Process.cancel_timer(ref)
    if ref = Map.get(timers, {n, b}), do: Process.cancel_timer(ref)

    reload_ref = if status == :saved, do: Process.send_after(self(), :reload_settings, 400)
    clear_ref = Process.send_after(self(), {:clear_save_status, n, b}, 4_000)

    timers =
      timers
      |> Map.put({n, b}, clear_ref)
      |> then(fn t -> if reload_ref, do: Map.put(t, :reload, reload_ref), else: t end)

    socket
    |> assign(:settings, optimistic_merge(socket.assigns.settings, kv))
    |> assign(:save_status, Map.put(socket.assigns.save_status, {n, b}, status))
    |> assign(:status_timers, timers)
  end

  # Optimistisches UI-Update: gespeicherte Werte sofort in die Settings-
  # Assigns mergen (String-Keys wie im Snapshot), der Reload überschreibt
  # danach mit dem persistierten Worker-Stand.
  defp optimistic_merge(settings, kv) do
    Enum.reduce(kv, settings, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)
  end

  defp parse_stage!(n) when is_integer(n) and n == 2, do: n

  defp parse_stage!(n) when is_binary(n) do
    case Integer.parse(n) do
      {2, _} -> 2
      _ -> raise ArgumentError, "unbekannte Stage #{inspect(n)}"
    end
  end

  @impl true
  def handle_async(:load_settings, {:ok, {:ok, snap}}, socket) do
    settings = snap["settings"] || %{}
    available_models = snap["available_models"] || []
    worker_aggregate = aggregate_worker_models(socket.assigns.current_user.discord_id)

    {:noreply,
     assign(socket,
       waiting?: false,
       settings: settings,
       form: to_form(settings, as: "settings"),
       any_active_recording: snap["any_active_recording"] == true,
       available_models: available_models,
       worker_aggregate: worker_aggregate,
       ollama_error: snap["ollama_error"],
       cloud_models: snap["cloud_models"] || %{},
       cloud_errors: snap["cloud_errors"] || %{},
       # Issue #865 (Slice E): N für die merge_gap-Warnung.
       luecken_kuration_count: snap["luecken_kuration_count"] || 0
     )}
  end

  def handle_async(:load_settings, {:ok, {:error, :no_worker}}, socket) do
    {:noreply, assign(socket, default_settings_assigns(true))}
  end

  def handle_async(:load_settings, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Settings konnten nicht geladen werden: #{inspect(reason)}")
     |> assign(default_settings_assigns(false))}
  end

  def handle_async(:load_settings, {:exit, reason}, socket) do
    Logger.warning("einstellungen load_settings async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Issue #451 (Track B): gezielter Snapshot-Read vom ausgewählten Worker
  # via Reader-`:worker_id`-Opt. Ohne selected_worker_id (= kein eigener
  # Worker connected) erbt Reader.read den Default-Fallback-Pfad — der
  # liefert dann {:error, :no_worker}, was korrekt im `waiting?`-Branch
  # landet.
  defp start_settings_load(socket) do
    opts =
      case socket.assigns[:selected_worker_id] do
        nil -> []
        wid -> [worker_id: wid]
      end

    start_async(socket, :load_settings, fn ->
      Reader.read(%{"kind" => "settings"}, opts)
    end)
  end

  defp default_settings_assigns(waiting?) do
    [
      waiting?: waiting?,
      settings: %{},
      form: to_form(%{}, as: "settings"),
      any_active_recording: false,
      available_models: [],
      worker_aggregate: %{total: 0, counts: %{}},
      ollama_error: nil,
      cloud_models: %{},
      cloud_errors: %{},
      luecken_kuration_count: 0
    ]
  end

  # Issue #50: union der `models_available`-Listen aller connected Worker
  # des current_user. Pro Modell zählen wir auf wie vielen Workers es
  # installiert ist — die Settings-LV rendert das als Dropdown-Option-Hint
  # ("auf 1/2 Workern") und im "nicht installiert"-Badge.
  defp aggregate_worker_models(discord_id) when is_binary(discord_id) do
    workers =
      WorkerRegistry.list()
      |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)

    counts =
      workers
      |> Enum.flat_map(fn {_id, meta} ->
        Map.get(meta, :models_available, MapSet.new()) |> MapSet.to_list()
      end)
      |> Enum.frequencies()

    %{total: length(workers), counts: counts}
  end

  defp aggregate_worker_models(_), do: %{total: 0, counts: %{}}

  # Issue #451 (Track B): kompakte Worker-Bezeichnung im Selector. Workers
  # tragen heute weder einen User-gegebenen Namen noch ein Hostname-Feld in
  # ihrem Tracker-Meta — daher die letzten 8 Zeichen der worker_id + ein
  # Modell-Count-Hint. Sobald Worker eine echte Display-Identität liefern,
  # wird das hier sauber.
  defp short_worker_label(%{id: id, models_count: n}) do
    suffix = id |> String.slice(-8..-1) |> String.upcase()
    "Worker …#{suffix} (#{n} Modelle)"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-3xl">
      <header class="mb-6">
        <div class="flex items-center gap-3">
          <h1 class="font-display text-2xl tracking-wide">Einstellungen</h1>
          <%= if length(@my_workers) > 1 do %>
            <%!-- Issue #451 (Track B): Worker-Selector — nur wenn der Admin
                  mehrere eigene Worker hat. Bei Single-Worker bleibt das UI
                  unverändert. --%>
            <form phx-change="select_worker" class="ml-auto">
              <label class="text-xs text-ink-2 mr-2">Worker:</label>
              <select
                name="worker_id"
                class="bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0"
              >
                <%= for w <- @my_workers do %>
                  <option value={w.id} selected={w.id == @selected_worker_id}>
                    {short_worker_label(w)}
                  </option>
                <% end %>
              </select>
            </form>
          <% end %>
        </div>
        <p class="text-ink-2 text-sm mt-1">
          <%= if length(@my_workers) > 1 do %>
            LLM-Backend pro Stage. Speichern wirkt **nur** auf den oben
            gewählten Worker (Issue #451). Wechsle den Worker für separate
            Konfiguration.
          <% else %>
            LLM-Backend pro Stage. Speichern wirkt auf deinen verbundenen
            Worker — gilt nicht für Worker anderer Admins.
          <% end %>
        </p>
      </header>

      <%= if @waiting? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — Settings nicht abrufbar.
        </div>
      <% else %>
        <%= if @ollama_error do %>
          <div class="panel p-3 text-xs text-ink-2 border-l-2 border-amber-500/60 mb-6">
            Ollama unter <code>{@settings["local_endpoint"] || "(nicht konfiguriert)"}</code>
            nicht erreichbar (<code>{@ollama_error}</code>) — Modellfeld bleibt frei tippbar.
          </div>
        <% end %>

        <%!-- #755 Reopen (Tom-Kernanforderung aus #812): Config-Reihenfolge
             = Pipeline-Reihenfolge, Stage 1 ZUERST. Whisper + System-Pfade
             (whisper_bin/ffmpeg_bin/audio_dir) SIND die Stage-1-Config —
             eigene Form (der generische "save"-Handler nimmt Teil-Forms),
             weil die LLM-Stage-Boxen darunter ihre eigenen Forms haben. --%>
        <.form for={@form} phx-submit="save" class="mb-6">
          <fieldset class="panel p-4">
            <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage 1</legend>
            <h3 class="font-display text-base text-ink-0">Transcribe (Audio → Text)</h3>
            <p class="text-xs text-ink-2 mb-3">Whisper-Transkription + Aufnahme-Pfade</p>

            <div class="space-y-6">
              <.whisper_block settings={@settings} />
              <.system_paths_block settings={@settings} />

              <div class="flex justify-end">
                <.btn variant="primary" icon="check" type="submit">
                  Stage 1 speichern
                </.btn>
              </div>
            </div>
          </fieldset>
        </.form>

        <%!-- #451 Track C: Backend-Stack pro Stage — jede Box speichert
             granular für sich (eigene kleine Forms in stage_stack.ex),
             deshalb AUSSERHALB der globalen Form (Forms nesten nicht). --%>
        <div class="space-y-6 mb-6">
          <%= for {n, title, hint} <- @stages, n != 1 do %>
            <.stage_block
              n={n}
              title={title}
              hint={hint}
              settings={@settings}
              available_models={@available_models}
              worker_aggregate={@worker_aggregate}
              cloud_models={@cloud_models}
              cloud_errors={@cloud_errors}
              expanded_boxes={@expanded_boxes}
              save_status={@save_status}
            />
          <% end %>
        </div>

        <.form
          for={@form}
          phx-submit="save"
          class="space-y-6"
        >

          <%!-- Issue #865 (Epic #861 Slice E): Stage-1.1-Knöpfe. --%>
          <div class="panel p-4 space-y-2">
            <h3 class="text-sm font-semibold text-ink-0">Stage 1.1 — Transkript-Glättung</h3>
            <label class="block">
              <span class="text-sm text-ink-1">Sprecher-Merge-Gap (Sekunden)</span>
              <input
                type="number"
                name="settings[merge_gap_seconds]"
                value={@settings["merge_gap_seconds"] || 8}
                min="0"
                step="1"
                class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
              />
            </label>
            <p class="text-xs text-ink-2">
              Max. Pause, über die aufeinanderfolgende Utterances desselben Sprechers zu
              einem Block verschmelzen. Wirkt erst beim nächsten Glätten (Regenerate).
            </p>
            <p :if={@luecken_kuration_count > 0} class="text-xs text-warning">
              ⚠ Änderung berührt {@luecken_kuration_count} Kuration(en) (Review nötig) —
              bestehende Kurationen werden nicht verworfen, sondern nach dem nächsten
              Glätten zur Neu-Bestätigung vorgelegt.
            </p>

            <label class="block mt-3">
              <span class="text-sm text-ink-1">Gap-Fill-Modell (lokal)</span>
              <input
                type="text"
                name="settings[gapfill_model]"
                value={@settings["gapfill_model"]}
                placeholder="z.B. gemma3n:e4b — leer = Feature aus"
                list="gapfill-model-options"
                class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
              />
              <datalist id="gapfill-model-options">
                <option :for={m <- @available_models} value={m}>{m}</option>
              </datalist>
            </label>
            <p class="text-xs text-ink-2">
              Kleines lokales Modell für Lücken-Füll-Vorschläge (nur Vorschlag — Fakten an
              uncurierten Lücken bleiben bis zur menschlichen Bestätigung unverifiziert).
              Leer lassen schaltet die Vorschlags-Generierung ab.
            </p>
          </div>

          <div class="panel p-4 space-y-2">
            <label class="block">
              <span class="text-sm text-ink-1">Local-Endpoint URL</span>
              <input
                type="text"
                name="settings[local_endpoint]"
                value={@settings["local_endpoint"]}
                placeholder="http://localhost:11434 (nicht konfiguriert)"
                class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
              />
            </label>
            <p class="text-xs text-ink-2">
              Wird für jedes Stage genutzt, dessen Backend auf <code>local</code> steht.
              Erwartet Ollama-API (<code>POST /api/generate</code>).
            </p>
            <p class="text-xs text-ink-2 mt-2">
              Cloud-Backends (z.B. <code>anthropic</code>) brauchen einen API-Key als
              Env-Var auf der Worker-Maschine (z.B. <code>ANTHROPIC_API_KEY=sk-ant-...</code>).
              Siehe <code>docs/Worker-Setup.md</code>.
            </p>

            <label class="block mt-3">
              <span class="text-sm text-ink-1">HTTP-Timeout (ms)</span>
              <input
                type="number"
                name="settings[http_timeout_ms]"
                value={@settings["http_timeout_ms"] || 600_000}
                min="10000"
                step="10000"
                class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
              />
            </label>
            <p class="text-xs text-ink-2">
              Wie lange ein einzelner LLM-Call maximal dauern darf, bevor abgebrochen
              wird. Default 600 000 ms (10 min) — 30B-Modelle bei langen Extraktions-
              Chunks brauchen das, kleine 7B-Modelle kommen mit 60 000 ms aus.
            </p>

          </div>

          <div class="flex justify-end gap-3">
            <.btn variant="primary" icon="check" type="submit">
              Glättung + Endpoint + Timeout speichern
            </.btn>
          </div>
        </.form>
      <% end %>

      <.debug_consent_block consent={@debug_consent} />
    </div>
    """
  end

  # Issue #144: Block zum Aktivieren von Admin-Debug-Zugriff. Der User
  # entscheidet selbst (5/15/60min), ein Admin darf solange seinen
  # Snapshot + Permission-Matrix via /admin/debug/campaign/:id einsehen.
  defp debug_consent_block(assigns) do
    ~H"""
    <div class="mt-8 border-t border-bg-3/60 pt-6">
      <h2 class="text-sm font-semibold text-ink-0 uppercase tracking-wider mb-2">
        Debug-Zugriff
      </h2>
      <p class="text-xs text-ink-2 mb-3">
        Erlaubt einem Admin, deinen LV-State + deine Permissions in einer Kampagne
        zur Fehlerdiagnose einzusehen (Issue #144). Läuft automatisch ab.
      </p>

      <%= if @consent do %>
        <div class="flex items-center gap-3 text-xs">
          <span class="text-accent">⚡ aktiv</span>
          <span class="text-ink-2 font-mono">
            noch {debug_consent_remaining(@consent)}
          </span>
          <.btn variant="ghost" phx-click="debug_revoke">widerrufen</.btn>
        </div>
      <% else %>
        <div class="flex items-center gap-2">
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="300">
            5 min
          </.btn>
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="900">
            15 min
          </.btn>
          <.btn variant="ghost" phx-click="debug_grant" phx-value-duration="3600">
            1 h
          </.btn>
        </div>
      <% end %>
    </div>
    """
  end

  defp debug_consent_remaining(%{expires_at: %DateTime{} = at}) do
    diff = DateTime.diff(at, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> "—"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp debug_consent_remaining(_), do: "—"

  attr(:settings, :map, required: true)

  defp whisper_block(assigns) do
    ~H"""
    <fieldset class="panel p-4 space-y-3">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage 1</legend>
      <h3 class="font-display text-base text-ink-0">Whisper (Audio → Text)</h3>
      <p class="text-xs text-ink-2 mb-3">
        Lokale whisper.cpp-Pipeline. Pfade gelten pro Worker — auf deinem Laptop kann
        ein anderes Modell liegen als auf dem Desktop.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <label class="block">
          <span class="text-xs text-ink-2">whisper_bin</span>
          <input
            type="text"
            name="settings[whisper_bin]"
            value={@settings["whisper_bin"]}
            placeholder="whisper-cli (nicht konfiguriert)"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">Pfad zur whisper.cpp-CLI (oder Name in $PATH).</span>
        </label>

        <label class="block">
          <span class="text-xs text-ink-2">whisper_model</span>
          <input
            type="text"
            name="settings[whisper_model]"
            value={@settings["whisper_model"] || ""}
            placeholder="~/.cache/whisper/ggml-large-v3-turbo.bin"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">
            Absoluter Pfad zur GGML-Modelldatei.
            Empfohlen: <code class="font-mono">ggml-large-v3-turbo.bin</code> (~1,6 GB, 0,5 % WER auf deutschen Texten).
            Download:
            <code class="font-mono select-all">bash models/download-ggml-model.sh large-v3-turbo</code>
            im whisper.cpp-Verzeichnis, oder direkt von
            <code class="font-mono">https://huggingface.co/ggerganov/whisper.cpp</code>.
          </span>
          <%= if @settings["whisper_model"] == nil or @settings["whisper_model"] == "" or
                (is_binary(@settings["whisper_model"]) and
                   not String.contains?(@settings["whisper_model"], "large")) do %>
            <div class="mt-1 rounded bg-yellow-900/30 border border-yellow-600/40 px-2 py-1 text-[10px] text-yellow-300">
              Kein large-Modell konfiguriert — WER kann 15–25 % höher sein als mit large-v3-turbo.
            </div>
          <% end %>
        </label>

        <label class="block">
          <span class="text-xs text-ink-2">whisper_lang</span>
          <input
            type="text"
            name="settings[whisper_lang]"
            value={@settings["whisper_lang"] || "auto"}
            placeholder="auto"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">ISO-Code, „auto" oder leer.</span>
        </label>

        <label class="block">
          <span class="text-xs text-ink-2">whisper_vad_model</span>
          <input
            type="text"
            name="settings[whisper_vad_model]"
            value={@settings["whisper_vad_model"] || ""}
            placeholder="(leer = kein VAD, Live-Modus geht in Batch zurück)"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">Pfad zu silero-v5.1.2.bin (nur für Live-Modus).</span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp system_paths_block(assigns) do
    ~H"""
    <details class="panel p-4">
      <summary class="cursor-pointer text-xs uppercase tracking-widest text-ink-2 hover:text-accent">
        System-Pfade (selten ändern)
      </summary>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mt-3">
        <label class="block">
          <span class="text-xs text-ink-2">ffmpeg_bin</span>
          <input
            type="text"
            name="settings[ffmpeg_bin]"
            value={@settings["ffmpeg_bin"]}
            placeholder="ffmpeg (nicht konfiguriert)"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">Pfad zu ffmpeg (oder Name in $PATH).</span>
        </label>

        <label class="block">
          <span class="text-xs text-ink-2">audio_dir</span>
          <input
            type="text"
            name="settings[audio_dir]"
            value={@settings["audio_dir"] || "/tmp/lore_audio"}
            placeholder="/tmp/lore_audio"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">Wo pro Session WAV-Chunks und Transkripte liegen.</span>
        </label>
      </div>
    </details>
    """
  end
end
