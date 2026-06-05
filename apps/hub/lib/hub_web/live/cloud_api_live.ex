defmodule HubWeb.CloudApiLive do
  @moduledoc """
  Issue #510: Cloud-API-Keys pro Worker verwalten. Admin-only.

  Drei Backends (Anthropic / OpenAI / Google), pro Backend ein Save-/Delete-
  Block. Save schreibt direkt in `Worker.Settings` des ausgewählten Workers
  via `Hub.Commands.update_one_worker_settings/2` (analog #451 Track B).
  Der Worker fragt den Key bei nächstem `Worker.LLM.<Backend>.complete/2`
  über `Worker.LLM.ApiKey.get/1` — Settings-first, ENV-Fallback.

  **Key-Werte werden nie ins Hub übertragen außer beim Save-Submit-POST.**
  Snapshot-Read liefert nur Status pro Backend (`set_via_settings` /
  `set_via_env` / `unset`) — siehe `Worker.LLM.ApiKey.status/1`.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, Reader, WorkerRegistry}
  alias HubWeb.Permissions
  require Logger

  @backends [
    %{
      id: "anthropic",
      title: "Anthropic (Claude)",
      env: "ANTHROPIC_API_KEY",
      setting: :anthropic_api_key,
      hint: "Format: sk-ant-..."
    },
    %{
      id: "openai",
      title: "OpenAI (GPT-4o / o1)",
      env: "OPENAI_API_KEY",
      setting: :openai_api_key,
      hint: "Format: sk-proj-... oder sk-..."
    },
    %{
      id: "google",
      title: "Google Gemini",
      env: "GEMINI_API_KEY",
      setting: :gemini_api_key,
      hint: "Format: AIza... (siehe ai.google.dev)"
    }
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    perm_user = %{
      discord_id: user.discord_id,
      role: socket.assigns[:current_user_role] || :spieler,
      is_member?: false
    }

    if Permissions.can?(perm_user, :view_admin) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      end

      my_workers = WorkerRegistry.list_for_admin(user.discord_id)
      selected = List.first(my_workers)

      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:perm_user, perm_user)
       |> assign(:active_nav, :cloud_api)
       |> assign(:current_campaign, nil)
       |> assign(:backends, @backends)
       |> assign(:my_workers, my_workers)
       |> assign(:selected_worker_id, selected && selected.id)
       |> assign(:reveal, %{})
       |> assign(:save_status, %{})
       |> assign(waiting?: true, cloud_api_keys: %{}, cloud_models: %{}, cloud_errors: %{})
       |> start_snapshot_load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Cloud-API-Verwaltung ist Admin-only.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:workers_changed, _joins, _leaves}, socket) do
    my_workers = WorkerRegistry.list_for_admin(socket.assigns.current_user.discord_id)
    current = socket.assigns[:selected_worker_id]
    still_online? = current && Enum.any?(my_workers, &(&1.id == current))

    selected =
      cond do
        still_online? -> current
        my_workers != [] -> hd(my_workers).id
        true -> nil
      end

    {:noreply,
     socket
     |> assign(:my_workers, my_workers)
     |> assign(:selected_worker_id, selected)
     |> start_snapshot_load()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_worker", %{"worker_id" => worker_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_worker_id, worker_id)
     |> assign(:save_status, %{})
     |> start_snapshot_load()}
  end

  def handle_event("toggle_reveal", %{"backend" => backend_id}, socket) do
    current = Map.get(socket.assigns.reveal, backend_id, false)
    {:noreply, assign(socket, :reveal, Map.put(socket.assigns.reveal, backend_id, not current))}
  end

  def handle_event("save_key", %{"backend" => backend_id, "key" => raw}, socket) do
    backend = Enum.find(@backends, &(&1.id == backend_id))
    worker_id = socket.assigns[:selected_worker_id]
    key = String.trim(raw)

    cond do
      is_nil(backend) ->
        {:noreply, put_flash(socket, :error, "Unbekanntes Backend: #{backend_id}")}

      is_nil(worker_id) ->
        {:noreply, put_flash(socket, :error, "Kein Worker ausgewählt.")}

      key == "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Key ist leer. Zum Löschen den ‚Löschen'-Button benutzen.")}

      not plausible_key?(key) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Das sieht nicht nach einem API-Key aus (Whitespace / zu kurz / Großbuchstaben am Anfang). Bitte den Key vom Provider-Dashboard kopieren."
         )}

      true ->
        case Commands.update_one_worker_settings(worker_id, %{backend.setting => key}) do
          :ok ->
            # Sofortige Verifikation via list_models-Read auf den selben Worker.
            # Status aus dem Snapshot zeigt :set_via_settings; cloud_models
            # liste nicht-leer wäre der Erfolgs-Indikator beim nächsten
            # snapshot. Wir reloaden + zeigen Save-Status pro Backend.
            Process.sleep(150)

            {:noreply,
             socket
             |> assign(:save_status, Map.put(socket.assigns.save_status, backend_id, :saved))
             |> assign(:reveal, Map.put(socket.assigns.reveal, backend_id, false))
             |> start_snapshot_load()}

          {:error, :worker_offline} ->
            {:noreply, put_flash(socket, :error, "Worker offline — Save fehlgeschlagen.")}
        end
    end
  end

  def handle_event("delete_key", %{"backend" => backend_id}, socket) do
    backend = Enum.find(@backends, &(&1.id == backend_id))
    worker_id = socket.assigns[:selected_worker_id]

    cond do
      is_nil(backend) ->
        {:noreply, put_flash(socket, :error, "Unbekanntes Backend: #{backend_id}")}

      is_nil(worker_id) ->
        {:noreply, put_flash(socket, :error, "Kein Worker ausgewählt.")}

      true ->
        case Commands.update_one_worker_settings(worker_id, %{backend.setting => ""}) do
          :ok ->
            Process.sleep(150)

            {:noreply,
             socket
             |> assign(:save_status, Map.put(socket.assigns.save_status, backend_id, :deleted))
             |> assign(:reveal, Map.put(socket.assigns.reveal, backend_id, false))
             |> start_snapshot_load()}

          {:error, :worker_offline} ->
            {:noreply, put_flash(socket, :error, "Worker offline — Delete fehlgeschlagen.")}
        end
    end
  end

  @impl true
  def handle_async(:load_snapshot, {:ok, {:ok, snap}}, socket) do
    {:noreply,
     assign(socket,
       waiting?: false,
       cloud_api_keys: snap["cloud_api_keys"] || %{},
       cloud_models: snap["cloud_models"] || %{},
       cloud_errors: snap["cloud_errors"] || %{}
     )}
  end

  def handle_async(:load_snapshot, {:ok, {:error, :no_worker}}, socket) do
    {:noreply,
     assign(socket,
       waiting?: true,
       cloud_api_keys: %{},
       cloud_models: %{},
       cloud_errors: %{}
     )}
  end

  def handle_async(:load_snapshot, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Snapshot konnte nicht geladen werden: #{inspect(reason)}")
     |> assign(
       waiting?: false,
       cloud_api_keys: %{},
       cloud_models: %{},
       cloud_errors: %{}
     )}
  end

  def handle_async(:load_snapshot, {:exit, reason}, socket) do
    Logger.warning("cloud_api load_snapshot async exit: #{inspect(reason)}")
    {:noreply, socket}
  end

  defp start_snapshot_load(socket) do
    opts =
      case socket.assigns[:selected_worker_id] do
        nil -> []
        wid -> [worker_id: wid]
      end

    start_async(socket, :load_snapshot, fn -> Reader.read(%{"kind" => "settings"}, opts) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6 space-y-6">
      <div class="flex items-baseline justify-between gap-4 flex-wrap">
        <div>
          <h1 class="font-display text-2xl text-ink-0">Cloud-API-Keys</h1>
          <p class="text-xs text-ink-2 mt-1">
            Pro Worker. Speichern testet den Key sofort gegen die Provider-API.
          </p>
        </div>

        <%= if length(@my_workers) > 1 do %>
          <form phx-change="select_worker" class="ml-auto">
            <label class="text-xs text-ink-2 block">Worker</label>
            <select
              name="worker_id"
              class="mt-1 bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
            >
              <%= for w <- @my_workers do %>
                <option value={w.id} selected={@selected_worker_id == w.id}>
                  {String.slice(w.id, 0..7)}…  ·  seq {w.applied_seq}
                </option>
              <% end %>
            </select>
          </form>
        <% end %>
      </div>

      <%= if @waiting? do %>
        <div class="panel p-6 text-center text-ink-2">
          <p>Kein Worker online — Snapshot kann nicht geladen werden.</p>
          <p class="text-xs mt-2">
            Verbinde deinen Worker, dann lade diese Seite neu.
          </p>
        </div>
      <% else %>
        <div class="panel p-3 text-xs text-ink-2 border-l-2 border-accent/40">
          Keys werden im ausgewählten Worker (<code>{short_worker(@selected_worker_id)}</code>) als
          Mnesia-State gespeichert. Sie sind nur auf diesem Worker verfügbar — bei Multi-Worker-
          Setup für jeden Worker einzeln pflegen. Backup-Verantwortung beim User
          (Mnesia-Dir ist nicht hub-replicated).
        </div>

        <%= for backend <- @backends do %>
          <.backend_block
            backend={backend}
            status={Map.get(@cloud_api_keys, backend.id, "unset")}
            models_count={length(Map.get(@cloud_models, backend.id, []))}
            error={Map.get(@cloud_errors, backend.id)}
            reveal={Map.get(@reveal, backend.id, false)}
            save_status={Map.get(@save_status, backend.id)}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:backend, :map, required: true)
  attr(:status, :string, required: true)
  attr(:models_count, :integer, required: true)
  attr(:error, :any, default: nil)
  attr(:reveal, :boolean, default: false)
  attr(:save_status, :atom, default: nil)

  defp backend_block(assigns) do
    ~H"""
    <fieldset class="panel p-4 space-y-3">
      <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">{@backend.title}</legend>

      <.status_badge status={@status} models_count={@models_count} error={@error} />

      <form phx-submit="save_key" class="space-y-2">
        <input type="hidden" name="backend" value={@backend.id} />
        <label class="block">
          <span class="text-xs text-ink-2">
            API-Key
            <span class="text-ink-2/60 font-mono ml-2">({@backend.hint})</span>
          </span>
          <div class="mt-1 flex gap-2">
            <input
              type={if @reveal, do: "text", else: "password"}
              name="key"
              placeholder={placeholder_for(@status)}
              autocomplete="off"
              spellcheck="false"
              class="flex-1 bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
            />
            <button
              type="button"
              phx-click="toggle_reveal"
              phx-value-backend={@backend.id}
              class="px-3 py-2 border border-bg-3 rounded-md text-ink-2 hover:text-ink-0 text-xs"
              title="Klartext-Anzeige umschalten"
            >
              {if @reveal, do: "verstecken", else: "anzeigen"}
            </button>
          </div>
        </label>

        <div class="flex gap-2 justify-end">
          <button
            type="button"
            phx-click="delete_key"
            phx-value-backend={@backend.id}
            data-confirm={"Key für #{@backend.title} wirklich löschen?"}
            class="px-3 py-2 border border-bg-3 rounded-md text-rose-300 hover:text-rose-200 hover:border-rose-400/60 text-xs"
          >
            Löschen
          </button>
          <button
            type="submit"
            class="px-4 py-2 bg-accent text-bg-0 rounded-md hover:bg-accent/90 text-sm font-medium"
          >
            Speichern + testen
          </button>
        </div>
      </form>

      <%= case @save_status do %>
        <% :saved -> %>
          <p class="text-[11px] text-emerald-300">
            Gespeichert. Verbindungstest oben aktualisiert.
          </p>
        <% :deleted -> %>
          <p class="text-[11px] text-amber-300">
            Key gelöscht.
          </p>
        <% _ -> %>
      <% end %>
    </fieldset>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <%= case @status do %>
      <% "set_via_settings" -> %>
        <%= cond do %>
          <% @error -> %>
            <p class="text-xs text-rose-300">
              ● Key gespeichert, aber Verbindung fehlgeschlagen: <code>{@error}</code>
            </p>
          <% @models_count > 0 -> %>
            <p class="text-xs text-emerald-300">
              ● Key gespeichert, <strong>{@models_count} Modelle</strong> verfügbar.
            </p>
          <% true -> %>
            <p class="text-xs text-amber-300">
              ● Key gespeichert — noch keine Modell-Liste geladen.
            </p>
        <% end %>
      <% "set_via_env" -> %>
        <p class="text-xs text-ink-2">
          ● Key kommt aus Env-Var ({@models_count} Modelle verfügbar). Hier eingegebener Key überschreibt die Env.
        </p>
      <% _ -> %>
        <p class="text-xs text-ink-2">
          ● Kein Key konfiguriert.
        </p>
    <% end %>
    """
  end

  defp placeholder_for("set_via_settings"), do: "•••••••• (Key gespeichert — überschreiben?)"
  defp placeholder_for("set_via_env"), do: "•••••••• (Env-Var gesetzt — überschreiben?)"
  defp placeholder_for(_), do: "Key einfügen"

  defp short_worker(nil), do: "—"
  defp short_worker(id) when is_binary(id), do: String.slice(id, 0..7) <> "…"

  # Issue #510: leichte Format-Validierung um häufige Versehen abzufangen
  # (Status-Text-Paste statt Key, "echte Sätze" mit Leerzeichen). Provider-
  # Keys sind typisch ≥20 chars, ohne Whitespace, mit Kleinbuchstaben-Prefix
  # oder Ziffern am Anfang (sk-…, AIza…). Strikte Pattern-Matches werden
  # NICHT gemacht — Provider können Prefix-Conventions ändern.
  defp plausible_key?(key) when is_binary(key) do
    String.length(key) >= 20 and
      not String.contains?(key, [" ", "\t", "\n"]) and
      not Regex.match?(~r/^[A-ZÄÖÜ]/u, key)
  end

  defp plausible_key?(_), do: false
end
