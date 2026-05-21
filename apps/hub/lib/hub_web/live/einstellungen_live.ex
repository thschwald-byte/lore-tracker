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

  alias Hub.{Commands, Reader}

  @backends [
    {"Local HTTP (Ollama / llama.cpp server)", "local"},
    {"Anthropic (Claude via Hub-Proxy)", "anthropic"}
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
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:active_nav, :settings)
     |> assign(:current_campaign, nil)
     |> assign(:backends, @backends)
     |> assign(:stages, @stages)
     |> assign(:dev?, Application.get_env(:hub, :env, :prod) != :prod)
     |> load_settings()}
  end

  @impl true
  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, load_settings(socket)}

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    kv =
      params
      |> Enum.into(%{}, fn {k, v} -> {k, normalize_value(k, v)} end)
      |> Map.reject(fn {_, v} -> v in [nil, ""] end)

    n = Commands.update_my_worker_settings(socket.assigns.current_user.discord_id, kv)

    {:noreply,
     socket
     |> put_flash(:info, "Settings gespeichert (#{n} Worker signalisiert).")
     |> load_settings()}
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
        assign(socket,
          waiting?: false,
          settings: snap["settings"] || %{},
          any_active_recording: snap["any_active_recording"] == true,
          available_models: snap["available_models"] || [],
          ollama_error: snap["ollama_error"]
        )

      {:error, :no_worker} ->
        assign(socket,
          waiting?: true,
          settings: %{},
          any_active_recording: false,
          available_models: [],
          ollama_error: nil
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Settings konnten nicht geladen werden: #{inspect(reason)}")
        |> assign(
          waiting?: false,
          settings: %{},
          any_active_recording: false,
          available_models: [],
          ollama_error: nil
        )
    end
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
        <form phx-submit="save" class="space-y-6">
          <.transcribe_mode_block
            mode={@settings["transcribe_mode"] || "batch"}
            locked?={@any_active_recording}
            dev?={@dev?}
          />

          <.whisper_block settings={@settings} />

          <%= if @ollama_error do %>
            <div class="panel p-3 text-xs text-ink-2 border-l-2 border-amber-500/60">
              Ollama unter <code>{@settings["local_endpoint"] || "http://localhost:11434"}</code>
              nicht erreichbar (<code>{@ollama_error}</code>) — Modellfeld bleibt frei tippbar.
            </div>
          <% end %>

          <datalist id="ollama-models">
            <%= for name <- @available_models do %>
              <option value={name}></option>
            <% end %>
          </datalist>

          <%= for {n, title, hint} <- @stages, n != 1 do %>
            <.stage_block
              n={n}
              title={title}
              hint={hint}
              backend={@settings["backend_stage#{n}"]}
              model={@settings["model_stage#{n}"]}
              backends={@backends}
              settings={@settings}
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
              Cloud-Backends (z.B. <code>anthropic</code>) brauchen einen API-Key
              unter <a href="/admin/cloud-keys" class="text-accent hover:underline">Admin → Cloud-Backends</a>.
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
            <button type="submit" class="btn btn-primary">Speichern</button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  attr :mode, :string, required: true
  attr :locked?, :boolean, required: true
  attr :dev?, :boolean, default: false

  defp transcribe_mode_block(assigns) do
    ~H"""
    <fieldset class="panel p-4">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage 1</legend>
      <h3 class="font-display text-base text-ink-0">
        Transkription (Audio → Text)
      </h3>
      <p class="text-xs text-ink-2 mb-3">
        <strong>Batch</strong>: nach Stopp wird das komplette Audio in einem Rutsch
        transkribiert (heutiges Verhalten — robust, höhere Qualität).
        <strong>Live</strong>: zusätzlich rollende Live-Transkription während der
        Aufnahme (VAD-gated; final wird trotzdem ein Batch-Re-Pass gefahren, damit
        Stages 2-4 die saubere Version sehen).
        <%= if @dev? do %>
          <strong>Listen</strong>: Tab-/System-Audio statt Mikrofon. Dev-only —
          zum reproduzierbaren Testen der Pipeline mit bekanntem Audio-Input.
        <% end %>
      </p>

      <div class="flex items-center gap-4 flex-wrap">
        <label class="flex items-center gap-2 cursor-pointer">
          <input
            type="radio"
            name="settings[transcribe_mode]"
            value="batch"
            checked={@mode == "batch"}
            disabled={@locked?}
          />
          <span class="text-sm text-ink-0">Batch (Default)</span>
        </label>
        <label class="flex items-center gap-2 cursor-pointer">
          <input
            type="radio"
            name="settings[transcribe_mode]"
            value="live"
            checked={@mode == "live"}
            disabled={@locked?}
          />
          <span class="text-sm text-ink-0">Live</span>
        </label>
        <%= if @dev? do %>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              name="settings[transcribe_mode]"
              value="listen"
              checked={@mode == "listen"}
              disabled={@locked?}
            />
            <span class="text-sm text-ink-0">Listen <span class="text-ink-2">(Dev — System-Audio)</span></span>
          </label>
        <% end %>

        <%= if @locked? do %>
          <span class="pill pill-archived text-[10px] ml-2">
            während laufender Aufnahme nicht änderbar
          </span>
        <% end %>
      </div>
    </fieldset>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :backend, :string, default: "local"
  attr :model, :string, default: nil
  attr :backends, :list, required: true
  attr :settings, :map, default: %{}

  defp stage_block(assigns) do
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

        <label class="block">
          <span class="text-xs text-ink-2">Modellname</span>
          <input
            type="text"
            name={"settings[model_stage#{@n}]"}
            value={@model || ""}
            list="ollama-models"
            placeholder="z.B. qwen2.5:0.5b"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">
            Dropdown zeigt nur Modelle die zum aktuellen Inhalt passen — Feld leeren + speichern, um die komplette Liste zu sehen (Issue #50).
          </span>
        </label>
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

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: ""
  attr :value, :any, default: nil
  attr :step, :string, default: "any"
  attr :info, :string, default: nil

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

  attr :settings, :map, required: true

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
            placeholder="~/.cache/whisper/ggml-base.bin"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-xs focus:border-accent focus:ring-0"
          />
          <span class="text-[10px] text-ink-2/70">Absoluter Pfad zur GGML-Modelldatei.</span>
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
