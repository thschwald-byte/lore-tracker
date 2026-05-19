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
    {"Local HTTP (Ollama / llama.cpp server)", "local"}
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

  defp normalize_value(key, "") when key not in ["local_endpoint"], do: nil
  defp normalize_value(_key, value), do: value

  defp load_settings(socket) do
    case Reader.read(%{"kind" => "settings"}) do
      {:ok, snap} ->
        assign(socket,
          waiting?: false,
          settings: snap["settings"] || %{},
          any_active_recording: snap["any_active_recording"] == true
        )

      {:error, :no_worker} ->
        assign(socket, waiting?: true, settings: %{}, any_active_recording: false)

      {:error, reason} ->
        socket
        |> put_flash(:error, "Settings konnten nicht geladen werden: #{inspect(reason)}")
        |> assign(waiting?: false, settings: %{}, any_active_recording: false)
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
          />

          <%= for {n, title, hint} <- @stages do %>
            <.stage_block
              n={n}
              title={title}
              hint={hint}
              backend={@settings["backend_stage#{n}"]}
              model={@settings["model_stage#{n}"]}
              backends={@backends}
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
          </div>

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
      </p>

      <div class="flex items-center gap-4">
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

  defp stage_block(assigns) do
    ~H"""
    <fieldset class="panel p-4">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">Stage {@n}</legend>
      <h3 class="font-display text-base text-ink-0">{@title}</h3>
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
            placeholder="z.B. qwen2.5:0.5b"
            class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
          />
        </label>
      </div>
    </fieldset>
    """
  end
end
