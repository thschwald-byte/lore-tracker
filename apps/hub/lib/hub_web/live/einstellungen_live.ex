defmodule HubWeb.EinstellungenLive do
  @moduledoc """
  Worker-Einstellungen: per Stage Backend + Modell + (für `:local`) URL.

  Settings sind **worker-lokal** (siehe `Worker.Settings`), nicht ins
  Event-Log repliziert. Mounted liest sie via Snapshot von einem
  verbundenen Worker; Speichern broadcastet via
  `Hub.Commands.update_my_worker_settings/2` an alle Worker, die zu
  diesem Admin gehören — so bleiben mehrere Instanzen (Laptop + Desktop)
  in Sync, ohne sie zur replizierten Domain-Daten zu machen.
  """

  use HubWeb, :live_view

  import LiveSelect

  alias Hub.{Commands, Reader, WorkerRegistry}

  @backends [
    {"Local HTTP (Ollama / llama.cpp server)", "local"},
    {"Anthropic (Claude direkt vom Worker)", "anthropic"},
    {"OpenAI (GPT-4o / o1)", "openai"},
    {"Google (Gemini 2.x)", "google"}
    # {"Bundled (Bumblebee + Nx)", "bundled"} — M9b
  ]

  @stages [
    {1, "Transcribe (Audio → Text)", "Stage 1 — kommt mit M10 (Discord-Bot)"},
    {2, "Resümee (Snippets → Was letztes Mal geschah)", "Stage 2"},
    {3, "Epos (Snippets + Resümee → Buch)", "Stage 3"},
    {4, "Chronik (Epos → In-Game-Timeline)", "Stage 4"}
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      # Issue #144: PubSub-Updates für Debug-Consent-Status.
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.DebugConsent.topic())
      # 1s-Tick für Countdown-Anzeige in der Debug-Box.
      :timer.send_interval(1_000, :debug_consent_tick)
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:active_nav, :settings)
     |> assign(:current_campaign, nil)
     |> assign(:backends, @backends)
     |> assign(:stages, @stages)
     |> assign(:dev?, Application.get_env(:hub, :env, :prod) != :prod)
     |> assign(:debug_consent, Hub.DebugConsent.status(user.discord_id))
     |> load_settings()}
  end

  @impl true
  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, load_settings(socket)}

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
    kv =
      params
      |> Enum.reject(fn {k, _} -> String.ends_with?(k, "_text_input") end)
      |> Enum.into(%{}, fn {k, v} -> {k, normalize_value(k, v)} end)
      |> Map.reject(fn {_, v} -> v in [nil, ""] end)

    n = Commands.update_my_worker_settings(socket.assigns.current_user.discord_id, kv)

    {:noreply,
     socket
     |> put_flash(:info, "Settings gespeichert (#{n} Worker signalisiert).")
     |> load_settings()}
  end

  # live_select feuert `phx-change` auf der Form bei jeder Selektion. Wir
  # haben keinen separaten Validate-Step — einfach durch, kein Update am
  # State (settings-Update passiert erst beim Submit via "save").
  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  # live_select-Component schickt diesen Event bei jedem Tippen im Combobox-
  # Text-Input. Wir filtern @available_models per Substring-Match und
  # pushen die gefilterte Option-Liste zurück via send_update.
  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    opts = model_options(socket.assigns.available_models, socket.assigns.worker_aggregate, text)
    send_update(LiveSelect.Component, id: id, options: opts)
    {:noreply, socket}
  end

  @numeric_float_keys ~w(
    temperature_stage2 temperature_stage3 temperature_stage4
    top_p_stage2 top_p_stage3 top_p_stage4
    repeat_penalty_stage2 repeat_penalty_stage3 repeat_penalty_stage4
  )
  @numeric_int_keys ~w(
    num_predict_stage2 num_predict_stage3 num_predict_stage4
    ctx_stage2 ctx_stage3 ctx_stage4
    http_timeout_ms
  )

  defp normalize_value(_key, ""), do: nil
  defp normalize_value(key, v) when key in @numeric_float_keys, do: parse_float(v)
  defp normalize_value(key, v) when key in @numeric_int_keys, do: parse_int(v)
  defp normalize_value(_key, value) when is_binary(value), do: String.trim(value)
  defp normalize_value(_key, value), do: value

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp load_settings(socket) do
    case Reader.read(%{"kind" => "settings"}) do
      {:ok, snap} ->
        settings = snap["settings"] || %{}
        available_models = snap["available_models"] || []
        worker_aggregate = aggregate_worker_models(socket.assigns.current_user.discord_id)

        assign(socket,
          waiting?: false,
          settings: settings,
          form: to_form(settings, as: "settings"),
          any_active_recording: snap["any_active_recording"] == true,
          available_models: available_models,
          worker_aggregate: worker_aggregate,
          ollama_error: snap["ollama_error"]
        )

      {:error, :no_worker} ->
        assign(socket,
          waiting?: true,
          settings: %{},
          form: to_form(%{}, as: "settings"),
          any_active_recording: false,
          available_models: [],
          worker_aggregate: %{total: 0, counts: %{}},
          ollama_error: nil
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Settings konnten nicht geladen werden: #{inspect(reason)}")
        |> assign(
          waiting?: false,
          settings: %{},
          form: to_form(%{}, as: "settings"),
          any_active_recording: false,
          available_models: [],
          worker_aggregate: %{total: 0, counts: %{}},
          ollama_error: nil
        )
    end
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

  # Baut die Options-Liste für live_select: pro Modell ein Map mit `label`
  # (inkl. Multi-Worker-Hint falls > 1 Worker connected ist) und `value`.
  defp model_options(available_models, worker_aggregate, filter_text \\ nil) do
    total = worker_aggregate.total

    available_models
    |> filter_by_text(filter_text)
    |> Enum.map(fn name ->
      count = Map.get(worker_aggregate.counts, name, total)

      label =
        if total > 1 and count < total do
          "#{name}  ·  nur auf #{count}/#{total} Workern"
        else
          name
        end

      %{label: label, value: name}
    end)
  end

  defp filter_by_text(models, nil), do: models
  defp filter_by_text(models, ""), do: models

  defp filter_by_text(models, text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.filter(models, fn name -> String.contains?(String.downcase(name), lower) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-3xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Einstellungen</h1>
        <p class="text-ink-2 text-sm mt-1">
          LLM-Backend pro Stage. Speichern broadcastet an alle deine
          verbundenen Worker — gilt nicht für Worker anderer Admins.
        </p>
      </header>

      <%= if @waiting? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — Settings nicht abrufbar.
        </div>
      <% else %>
        <.form
          for={@form}
          phx-submit="save"
          phx-change="form_change"
          class="space-y-6"
        >
          <.whisper_block settings={@settings} />

          <%= if @ollama_error do %>
            <div class="panel p-3 text-xs text-ink-2 border-l-2 border-amber-500/60">
              Ollama unter <code>{@settings["local_endpoint"] || "http://localhost:11434"}</code>
              nicht erreichbar (<code>{@ollama_error}</code>) — Modellfeld bleibt frei tippbar.
            </div>
          <% end %>

          <%= for {n, title, hint} <- @stages, n != 1 do %>
            <.stage_block
              n={n}
              title={title}
              hint={hint}
              form={@form}
              backend={@settings["backend_stage#{n}"]}
              model={@settings["model_stage#{n}"]}
              backends={@backends}
              settings={@settings}
              available_models={@available_models}
              worker_aggregate={@worker_aggregate}
            />
          <% end %>

          <div class="panel p-4 space-y-2">
            <label class="block">
              <span class="text-sm text-ink-1">Local-Endpoint URL</span>
              <input
                type="text"
                name="settings[local_endpoint]"
                value={@settings["local_endpoint"] || "http://localhost:11434"}
                placeholder="http://localhost:11434"
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
              wird. Default 600 000 ms (10 min) — 30B-Modelle bei langem Stage-3-Prompt
              brauchen das, kleine 7B-Modelle kommen mit 60 000 ms aus (Issue #75).
            </p>
          </div>

          <.system_paths_block settings={@settings} />

          <div class="flex justify-end gap-3">
            <.btn variant="primary" icon="check" type="submit">
              Einstellungen speichern
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

  attr(:n, :integer, required: true)
  attr(:title, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:backend, :string, default: "local")
  attr(:model, :string, default: nil)
  attr(:backends, :list, required: true)
  attr(:settings, :map, default: %{})
  attr(:form, :any, required: true)
  attr(:available_models, :list, default: [])
  attr(:worker_aggregate, :map, default: %{total: 0, counts: %{}})

  defp stage_block(assigns) do
    model_field = assigns.form[:"model_stage#{assigns.n}"]
    assigns = assign(assigns, :model_field, model_field)

    ~H"""
    <fieldset class="panel p-4">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage {@n}</legend>
      <h3 class="font-display text-base text-ink-0 flex items-center gap-2">
        {@title}
        <%= if info = stage_info(@n) do %>
          <HubWeb.CoreComponents.info_popover content={info} id={"info-stage-#{@n}"} />
        <% end %>
      </h3>
      <p class="text-xs text-ink-2 mb-3">{@hint}</p>

      <div class="grid grid-cols-2 gap-3">
        <label class="block">
          <span class="text-xs text-ink-2">Backend</span>
          <select
            name={"settings[backend_stage#{@n}]"}
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 text-sm focus:border-accent focus:ring-0"
          >
            <%= for {label, val} <- @backends do %>
              <option value={val} selected={@backend == val}>{label}</option>
            <% end %>
          </select>
        </label>

        <div class="block">
          <span class="text-xs text-ink-2">Modellname</span>
          <.live_select
            field={@model_field}
            options={model_options(@available_models, @worker_aggregate)}
            mode={:single}
            user_defined_options={true}
            keep_options_on_select={true}
            update_min_len={0}
            debounce={150}
            placeholder="z.B. qwen2.5:0.5b — klicken für alle Modelle"
            container_class="mt-1 relative"
            text_input_class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
            dropdown_class="absolute z-50 mt-1 max-h-64 overflow-y-auto bg-bg-0 border border-bg-3 rounded-md shadow-lg left-0 right-0"
            option_class="px-3 py-2 text-ink-0 text-sm font-mono cursor-pointer hover:bg-bg-1"
            active_option_class="bg-bg-1"
          />
          <%= if @model && @model != "" && @model not in @available_models do %>
            <p class="text-[10px] text-rose-400 mt-1">
              ⚠ <code>{@model}</code> ist auf diesem Worker nicht installiert.
              <code>ollama pull {@model}</code> oder anderes Modell wählen.
            </p>
          <% end %>
        </div>
      </div>

      <%= if @n in [2, 3, 4] do %>
        <details class="mt-3 text-sm">
          <summary class="cursor-pointer text-xs uppercase tracking-widest text-ink-2 hover:text-accent">
            Sampling-Parameter (Faktentreue / Halluzinations-Bremse)
          </summary>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mt-3">
            <.num_input
              name={"settings[ctx_stage#{@n}]"}
              label="num_ctx"
              hint="Kontext-Größe in Tokens"
              value={@settings["ctx_stage#{@n}"]}
              step="1"
              info={sampling_info("num_ctx")}
            />
            <.num_input
              name={"settings[temperature_stage#{@n}]"}
              label="temperature"
              hint="niedrig = sachlicher"
              value={@settings["temperature_stage#{@n}"]}
              step="0.05"
              info={sampling_info("temperature")}
            />
            <.num_input
              name={"settings[top_p_stage#{@n}]"}
              label="top_p"
              hint="0.7 = moderat"
              value={@settings["top_p_stage#{@n}"]}
              step="0.05"
              info={sampling_info("top_p")}
            />
            <.num_input
              name={"settings[num_predict_stage#{@n}]"}
              label="num_predict"
              hint="Token-Cap (leer = aus)"
              value={@settings["num_predict_stage#{@n}"]}
              step="1"
              info={sampling_info("num_predict")}
            />
            <.num_input
              name={"settings[repeat_penalty_stage#{@n}]"}
              label="repeat_penalty"
              hint="1.0 = aus, 1.1 = sanft"
              value={@settings["repeat_penalty_stage#{@n}"]}
              step="0.05"
              info={sampling_info("repeat_penalty")}
            />
          </div>
        </details>
      <% end %>
    </fieldset>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, default: "")
  attr(:value, :any, default: nil)
  attr(:step, :string, default: "any")
  attr(:info, :string, default: nil)

  defp num_input(assigns) do
    ~H"""
    <label class="block">
      <span class="text-xs text-ink-2 font-mono inline-flex items-center gap-1">
        {@label}
        <%= if @info do %>
          <HubWeb.CoreComponents.info_popover content={@info} id={"info-" <> @name} />
        <% end %>
      </span>
      <input
        type="number"
        name={@name}
        value={fmt_num(@value)}
        step={@step}
        class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-2 py-1 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
      />
      <span class="text-[10px] text-ink-2/70">{@hint}</span>
    </label>
    """
  end

  # Sampling-Parameter-Erklärungen für die Info-Popover (Issue #41).
  # Texte 1:1 aus dem Issue-Body. TODO #18 (i18n): gettext-wrap wenn
  # gettext-Setup landet — bisher plain DE inline.
  @sampling_info %{
    "num_ctx" =>
      "Wie viel Text das LLM auf einmal „im Kopf\" haben kann. Größer = mehr Material kann gleichzeitig berücksichtigt werden (z.B. längere Sessions), kostet aber mehr Rechenzeit und RAM.\n\nFaustregel: 1 Token ≈ ¾ Wort. Bei 8192 Tokens passen ungefähr 30 DIN-A4-Seiten Text rein.",
    "temperature" =>
      "Wie „kreativ\" das LLM antwortet.\n\n0 = streng formelhaft (gleicher Input → gleicher Output, hält sich eng ans Material).\n1 = locker (variiert die Formulierungen, erfindet aber auch eher mal was).\n\nFür Resümees willst du niedrig (0.1–0.3), damit das LLM nicht halluziniert. Für Epos/Chronik darf's etwas höher sein.\n\n(Konservativer Default wegen Halluzinations-Bremse — siehe Issue #11.)",
    "top_p" =>
      "Wie viele Wort-Alternativen das LLM überhaupt in Erwägung zieht, bevor es eines auswählt.\n\n1.0 = alle möglichen Wörter.\n0.7 = nur die wahrscheinlichsten 70%, der Rest fällt raus.\n\nNiedriger = vorhersagbarer + weniger ausgefallene Wortwahl. Wirkt zusammen mit temperature — beide gleichzeitig hochdrehen wird schnell zu Chaos.\n\n(Konservativer Default wegen Halluzinations-Bremse — siehe Issue #11.)",
    "num_predict" =>
      "Maximale Länge der LLM-Antwort in Tokens.\n\nLeer oder -1 = unbegrenzt (das LLM hört selbst auf, wenn es fertig ist). Sinnvoll als Notbremse: bei 400 Tokens ist nach ~300 Wörtern Schluss, egal was das LLM noch sagen wollte.\n\nFür Stage 4 (Chronik-JSON) lieber leer lassen — das LLM terminiert dort selbst sauber.",
    "repeat_penalty" =>
      "Wie stark das LLM bestraft wird, wenn es Wörter wiederholt, die es gerade erst geschrieben hat.\n\n1.0 = keine Bestrafung (kann hängenbleiben und „… der Held … der Held … der Held …\" produzieren).\n1.1–1.3 = leicht bis spürbar — schiebt das LLM zu mehr Variation.\n\nÜber 1.5 wird's künstlich, weil dann auch sinnvolle Wiederholungen (Eigennamen!) verdrängt werden."
  }

  defp sampling_info(key), do: Map.get(@sampling_info, key)

  # Was macht diese Stage? Popover am Stage-Header (Issue #41 Bonus).
  # Stage 1 hat ihren eigenen Block, deshalb hier nur 2/3/4.
  @stage_info %{
    2 =>
      "Resümee — der „Was letztes Mal geschah\"-Block für jede Session.\n\nDas LLM bekommt das Stage-1-Transkript einer Session und verdichtet es zu 3-6 Sätzen: nur die plot-relevanten Handlungen, Out-of-Game-Smalltalk (Pizza, Pausen, Regelfragen) wird gefiltert.\n\nLäuft automatisch nach jeder Session, manuell via 🔄 neu generieren.",
    3 =>
      "Epos — das laufende Kampagnen-Buch.\n\nDas LLM bekommt ALLE Session-Resümees chronologisch und webt daraus ein zusammenhängendes Markdown-Dokument (Kapitel-Überschriften, Erzähl-Form). Wird bei jeder neuen Session komplett neu erzeugt — falls du Texte manuell editierst, dienen sie beim nächsten Lauf als Referenz (Namen, Kontinuität).\n\nLäuft nach Stage 2.",
    4 =>
      "Chronik — die In-Game-Zeitlinie als Bullet-Liste.\n\nDas LLM extrahiert aus dem Epos eine sortierte Liste mit Datum + Label + 1-Satz-Zusammenfassung pro Ereignis. JSON-Format, deterministisch, von der Pipeline in einzelne Einträge zerlegt.\n\nLäuft nach Stage 3."
  }

  defp stage_info(n), do: Map.get(@stage_info, n)

  defp fmt_num(nil), do: ""
  defp fmt_num(v) when is_float(v) or is_integer(v), do: to_string(v)
  defp fmt_num(v), do: to_string(v)

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
            value={@settings["whisper_bin"] || "whisper-cli"}
            placeholder="whisper-cli"
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
            value={@settings["ffmpeg_bin"] || "ffmpeg"}
            placeholder="ffmpeg"
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
