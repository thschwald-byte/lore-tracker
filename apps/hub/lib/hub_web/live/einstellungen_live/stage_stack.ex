defmodule HubWeb.EinstellungenLive.StageStack do
  @moduledoc """
  Issue #451 (Track C): der Backend-Stack pro LLM-Stage (2/3/4) — das vom
  User per Mockup gewählte „Stack mit Radio"-Layout:

  - pro Backend (local/anthropic/openai/google) eine Box untereinander
  - Radio = welches Backend AKTIV ist (`backend_stage{n}`, sofortiger Save)
  - inaktive Boxen eingeklappt auf eine Zeile (zeigen ihr gemerktes Modell),
    ▸ klappt sie zum Editieren auf
  - jede Box ist eine EIGENE kleine Form mit eigenem Speichern-Button
    (granular — kein Form-Submit für alles); Modell-Key ist der
    pro-Backend-Key `model_stage{n}_{backend}`
  - Sampling-Parameter bleiben Stage-Level (Legacy-Keys) und rendern nur in
    der Box des AKTIVEN Backends (backend-aware Teilmenge wie vorher)

  Function-Components ohne eigenen State — expanded/save_status leben als
  Assigns im EinstellungenLive (Events: `set_active_backend`, `toggle_box`,
  `save_backend_box`, `live_select_change`).
  """

  use Phoenix.Component

  import LiveSelect

  alias HubWeb.EinstellungenLive.Options

  @backend_rows [
    {"local", "Local (Ollama)"},
    {"anthropic", "Anthropic (Claude)"},
    {"openai", "OpenAI (GPT)"},
    {"google", "Google (Gemini)"}
  ]

  attr(:n, :integer, required: true)
  attr(:title, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:settings, :map, default: %{})
  attr(:available_models, :list, default: [])
  attr(:worker_aggregate, :map, default: %{total: 0, counts: %{}})
  attr(:cloud_models, :map, default: %{})
  attr(:cloud_errors, :map, default: %{})
  attr(:expanded_boxes, :map, default: %{})
  attr(:save_status, :map, default: %{})

  def stage_block(assigns) do
    active = assigns.settings["backend_stage#{assigns.n}"] || "local"
    expanded = Map.get(assigns.expanded_boxes, assigns.n, active)

    assigns =
      assigns
      |> assign(:active_backend, active)
      |> assign(:expanded_backend, expanded)
      |> assign(:backend_rows, @backend_rows)

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

      <div class="space-y-2">
        <%= for {backend, label} <- @backend_rows do %>
          <.backend_box
            n={@n}
            backend={backend}
            label={label}
            active?={backend == @active_backend}
            expanded?={backend == @expanded_backend}
            settings={@settings}
            available_models={@available_models}
            worker_aggregate={@worker_aggregate}
            cloud_models={@cloud_models}
            cloud_errors={@cloud_errors}
            status={Map.get(@save_status, {@n, backend})}
          />
        <% end %>
      </div>
    </fieldset>
    """
  end

  attr(:n, :integer, required: true)
  attr(:backend, :string, required: true)
  attr(:label, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:expanded?, :boolean, required: true)
  attr(:settings, :map, required: true)
  attr(:available_models, :list, required: true)
  attr(:worker_aggregate, :map, required: true)
  attr(:cloud_models, :map, required: true)
  attr(:cloud_errors, :map, required: true)
  attr(:status, :atom, default: nil)

  defp backend_box(assigns) do
    model = Options.display_model(assigns.settings, assigns.n, assigns.backend)

    {models, cloud_error, placeholder} =
      Options.stage_model_options(assigns.backend, %{
        cloud_models: assigns.cloud_models,
        cloud_errors: assigns.cloud_errors,
        available_models: assigns.available_models
      })

    field_name = "model_stage#{assigns.n}_#{assigns.backend}"
    form = to_form(%{field_name => model}, as: "settings")

    assigns =
      assigns
      |> assign(:model, model)
      |> assign(:effective_models, models)
      |> assign(:cloud_error, cloud_error)
      |> assign(:placeholder, placeholder)
      |> assign(:is_cloud?, assigns.backend in ~w(anthropic openai google))
      |> assign(:model_field, form[String.to_atom(field_name)])

    ~H"""
    <div class={[
      "rounded-md border",
      if(@active?, do: "border-accent/60 bg-bg-0/40", else: "border-bg-3")
    ]}>
      <div class="flex items-center gap-2 px-3 py-2">
        <input
          type="radio"
          name={"active_backend_stage#{@n}"}
          checked={@active?}
          phx-click="set_active_backend"
          phx-value-stage={@n}
          phx-value-backend={@backend}
          class="accent-accent cursor-pointer"
          title="Dieses Backend für die Stage aktivieren"
        />
        <span class={["text-sm", if(@active?, do: "text-ink-0", else: "text-ink-2")]}>
          {@label}
        </span>
        <%= unless @expanded? do %>
          <span class="text-xs font-mono text-ink-2 truncate">
            · {@model || "(kein Modell gewählt)"}
          </span>
        <% end %>
        <span :if={@status == :saved} class="text-xs text-accent ml-auto">✓ gespeichert</span>
        <span :if={@status == :error} class="text-xs text-rose-400 ml-auto">
          ✗ Worker offline
        </span>
        <button
          type="button"
          phx-click="toggle_box"
          phx-value-stage={@n}
          phx-value-backend={@backend}
          class={[
            "text-ink-2 hover:text-accent text-xs px-1",
            if(@status in [:saved, :error], do: "", else: "ml-auto")
          ]}
          title={if @expanded?, do: "einklappen", else: "aufklappen"}
        >
          {if @expanded?, do: "▾", else: "▸"}
        </button>
      </div>

      <%= if @expanded? do %>
        <.form
          for={nil}
          as={nil}
          id={"box-form-#{@n}-#{@backend}"}
          phx-submit="save_backend_box"
          class="px-3 pb-3 space-y-3 border-t border-bg-3/60 pt-3"
        >
          <input type="hidden" name="stage" value={@n} />
          <input type="hidden" name="backend" value={@backend} />

          <div class="block">
            <span class="text-xs text-ink-2">Modellname</span>
            <.live_select
              field={@model_field}
              options={Options.model_options(@effective_models, @worker_aggregate)}
              mode={:single}
              user_defined_options={not @is_cloud?}
              keep_options_on_select={true}
              update_min_len={0}
              debounce={150}
              placeholder={@placeholder}
              container_class="mt-1 relative"
              text_input_class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
              dropdown_class="absolute z-50 mt-1 max-h-64 overflow-y-auto bg-bg-0 border border-bg-3 rounded-md shadow-lg left-0 right-0"
              option_class="px-3 py-2 text-ink-0 text-sm font-mono cursor-pointer hover:bg-bg-1"
              active_option_class="bg-bg-1"
            />
            <%= cond do %>
              <% @is_cloud? and @cloud_error -> %>
                <p class="text-[10px] text-amber-400 mt-1">
                  ⚠ Modell-Liste konnte nicht geladen werden: <code>{@cloud_error}</code>
                </p>
              <% @is_cloud? and @effective_models == [] -> %>
                <p class="text-[10px] text-ink-2 mt-1">
                  Kein API-Key auf dem Worker gesetzt — setze
                  <code>{Options.cloud_env_var(@backend)}</code> in der Worker-Start-Umgebung,
                  damit die Modell-Liste live geholt wird.
                </p>
              <% @is_cloud? -> %>
                <p class="text-[10px] text-ink-2 mt-1">
                  {length(@effective_models)} Modelle vom Provider geladen.
                </p>
              <% @model && @model != "" && @model not in @effective_models -> %>
                <p class="text-[10px] text-rose-400 mt-1">
                  ⚠ <code>{@model}</code> ist auf diesem Worker nicht installiert.
                  <code>ollama pull {@model}</code> oder anderes Modell wählen.
                </p>
              <% true -> %>
            <% end %>
          </div>

          <%= if @backend == "local" do %>
            <.local_endpoint_section n={@n} settings={@settings} />
          <% end %>

          <%= if @active? do %>
            <.sampling_section n={@n} is_cloud?={@is_cloud?} settings={@settings} />
          <% end %>

          <div class="flex justify-end">
            <button
              type="submit"
              class="text-xs px-3 py-1.5 rounded-md bg-accent/20 text-accent border border-accent/40 hover:bg-accent/30"
            >
              {@label} speichern
            </button>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

  # Issue #736: Ollama-Endpoint-Toggle pro Stage-Local-Backend.
  # Rendert nur in der Local-Backend-Box (Ollama-spezifisch, für Cloud-
  # Backends nicht relevant). Wert submitted mit dem Box-Save.
  attr(:n, :integer, required: true)
  attr(:settings, :map, required: true)

  defp local_endpoint_section(assigns) do
    current =
      case assigns.settings["model_stage#{assigns.n}_local_endpoint"] do
        v when v in [:chat, "chat"] -> "chat"
        _ -> "generate"
      end

    assigns = assign(assigns, :current_endpoint, current)

    ~H"""
    <details class="text-sm">
      <summary class="cursor-pointer text-xs uppercase tracking-widest text-ink-2 hover:text-accent">
        Ollama-Endpoint (für Reasoning-Modelle)
      </summary>
      <fieldset class="mt-3 space-y-1">
        <label class="flex items-baseline gap-2 cursor-pointer">
          <input
            type="radio"
            name={"settings[model_stage#{@n}_local_endpoint]"}
            value="generate"
            checked={@current_endpoint == "generate"}
            class="accent-accent cursor-pointer"
          />
          <span class="text-xs text-ink-0">
            <code>/api/generate</code>
            <span class="text-ink-2">(Standard — qwen2.5, command-r, mistral, ältere Modelle)</span>
          </span>
        </label>
        <label class="flex items-baseline gap-2 cursor-pointer">
          <input
            type="radio"
            name={"settings[model_stage#{@n}_local_endpoint]"}
            value="chat"
            checked={@current_endpoint == "chat"}
            class="accent-accent cursor-pointer"
          />
          <span class="text-xs text-ink-0">
            <code>/api/chat</code>
            <span class="text-ink-2">(für Reasoning-Modelle: gpt-oss, gemma4, qwen3-a3b)</span>
          </span>
        </label>
      </fieldset>
      <p class="text-[10px] text-ink-2/70 mt-2">
        Reasoning-Modelle liefern bei <code>/api/generate</code> mit JSON-Schema oft leere Antworten
        (Thinking-Tokens verdrängen den <code>response</code>-Slot). <code>/api/chat</code> trennt
        Reasoning und JSON-Payload sauber. Der Reasoning-Block wird verworfen (nicht persistiert).
      </p>
    </details>
    """
  end

  # Sampling-Parameter der Stage (Legacy-Keys, Stage-Level — NICHT pro
  # Backend). Rendert nur in der Box des aktiven Backends; die Werte
  # submitten mit dem Box-Save. Backend-aware Teilmenge wie vor Track C:
  # Cloud-Backends erhalten nur temperature + num_predict.
  attr(:n, :integer, required: true)
  attr(:is_cloud?, :boolean, required: true)
  attr(:settings, :map, required: true)

  defp sampling_section(assigns) do
    ~H"""
    <details class="text-sm">
      <summary class="cursor-pointer text-xs uppercase tracking-widest text-ink-2 hover:text-accent">
        Sampling-Parameter (Faktentreue / Halluzinations-Bremse)
      </summary>
      <div class={["grid gap-3 mt-3", if(@is_cloud?, do: "grid-cols-2", else: "grid-cols-2 md:grid-cols-5")]}>
        <%= unless @is_cloud? do %>
          <.num_input
            name={"settings[ctx_stage#{@n}]"}
            label="num_ctx"
            hint="Kontext-Größe in Tokens"
            value={@settings["ctx_stage#{@n}"]}
            step="1"
            info={sampling_info("num_ctx")}
          />
        <% end %>
        <.num_input
          name={"settings[temperature_stage#{@n}]"}
          label="temperature"
          hint="niedrig = sachlicher"
          value={@settings["temperature_stage#{@n}"]}
          step="0.05"
          info={sampling_info("temperature")}
        />
        <%= unless @is_cloud? do %>
          <.num_input
            name={"settings[top_p_stage#{@n}]"}
            label="top_p"
            hint="0.7 = moderat"
            value={@settings["top_p_stage#{@n}"]}
            step="0.05"
            info={sampling_info("top_p")}
          />
        <% end %>
        <.num_input
          name={"settings[num_predict_stage#{@n}]"}
          label="num_predict"
          hint="Token-Cap (leer = aus)"
          value={@settings["num_predict_stage#{@n}"]}
          step="1"
          info={sampling_info("num_predict")}
        />
        <%= unless @is_cloud? do %>
          <.num_input
            name={"settings[repeat_penalty_stage#{@n}]"}
            label="repeat_penalty"
            hint="1.0 = aus, 1.1 = sanft"
            value={@settings["repeat_penalty_stage#{@n}"]}
            step="0.05"
            info={sampling_info("repeat_penalty")}
          />
        <% end %>
      </div>
      <%= if @is_cloud? do %>
        <p class="text-[10px] text-ink-2/70 mt-2">
          Cloud-Backends erhalten nur <code>temperature</code> + <code>num_predict</code>.
          <code>num_ctx</code> und <code>repeat_penalty</code> sind Ollama-spezifisch;
          <code>top_p</code> wird aktuell nur an Ollama gesendet.
        </p>
      <% end %>
      <p class="text-[10px] text-ink-2/70 mt-1">
        Sampling gilt pro Stage (unabhängig vom Backend) und speichert mit dieser Box.
      </p>
    </details>
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
          <HubWeb.CoreComponents.info_popover content={@info} id={"info-" <> id_slug(@name)} />
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

  # Info-Popover ist Click-basiert und toggled per CSS-Selektor
  # (`JS.toggle(to: "##{id}")`). Der name der Form-Inputs ist im
  # `settings[foo]`-Bracket-Format — CSS-Selektor liest `#info-settings[foo]`
  # als „Element mit id=info-settings UND Attribute foo", was nie matcht.
  # Klammern raus, Klick wieder wirksam.
  defp id_slug(name) when is_binary(name),
    do: String.replace(name, ~r/[\[\]]/, "-")
end
