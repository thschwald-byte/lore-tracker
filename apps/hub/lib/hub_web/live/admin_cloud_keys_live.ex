defmodule HubWeb.AdminCloudKeysLive do
  @moduledoc """
  Admin-LV (Issue #27, Phase 1a): Cloud-LLM-Provider-API-Keys verwalten.

  Permission-Gate: nur globale Rolle `:admin`. Keys werden via `Hub.CloudKeys`
  AES-GCM-encrypted persistiert. Der Klartext-Key wird nie zurück an die UI
  geliefert — die UI zeigt nur „configured/empty" + Meta-Daten.

  Phase 1a: nur Anthropic. OpenAI/Google folgen, sobald deren Backend-Module
  existieren.
  """

  use HubWeb, :live_view

  alias Hub.{CloudKeys, EventLog, Reader}
  alias HubWeb.Permissions

  @providers [
    %{
      id: "anthropic",
      label: "Anthropic (Claude)",
      hint: "API-Key aus https://console.anthropic.com — beginnt mit `sk-ant-`."
    }
  ]

  @impl true
  def mount(_params, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:active_nav, :admin)
      |> assign(:current_campaign, nil)
      |> assign(:providers, @providers)
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
  def handle_event("save", %{"provider" => provider, "key" => key}, socket) do
    cond do
      not Permissions.can?(socket.assigns.perm_user, :view_admin) ->
        {:noreply, socket}

      String.trim(key) == "" ->
        {:noreply, put_flash(socket, :error, "Key darf nicht leer sein.")}

      true ->
        :ok = CloudKeys.put(provider, String.trim(key), socket.assigns.current_user.discord_id)

        {:noreply,
         socket
         |> put_flash(:info, "API-Key für #{provider} gespeichert (verschlüsselt at-rest).")
         |> load_data()}
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      :ok = CloudKeys.delete(provider)

      {:noreply,
       socket
       |> put_flash(:info, "API-Key für #{provider} gelöscht.")
       |> load_data()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("test", %{"provider" => provider}, socket) do
    if Permissions.can?(socket.assigns.perm_user, :view_admin) do
      case CloudKeys.test_connection(provider) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Verbindung zu #{provider} OK.")}

        {:error, :no_key_configured} ->
          {:noreply, put_flash(socket, :error, "Kein Key für #{provider} gespeichert.")}

        {:error, {:upstream, status, _body}} ->
          {:noreply,
           put_flash(socket, :error, "Provider antwortete mit Status #{status} — Key ungültig?")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Verbindungstest fehlgeschlagen: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info({:workers_changed, _, _}, socket), do: {:noreply, load_data(socket)}

  # ─── Data ────────────────────────────────────────────────────────

  defp load_data(socket) do
    user = socket.assigns.current_user

    # Get the user's role via the existing all_users-snapshot.
    case Reader.read(%{"kind" => "all_users"}) do
      {:ok, snap} ->
        users = snap["users"] || []

        viewer_role =
          Enum.find_value(users, :spieler, fn u ->
            if u["discord_id"] == user.discord_id, do: String.to_atom(u["role"]), else: nil
          end)

        perm_user = %{discord_id: user.discord_id, role: viewer_role, is_member?: true}

        provider_states =
          Enum.into(@providers, %{}, fn p ->
            {p.id, CloudKeys.info(p.id)}
          end)

        socket
        |> assign(
          no_worker?: false,
          perm_user: perm_user,
          viewer_role: viewer_role,
          provider_states: provider_states
        )

      {:error, :no_worker} ->
        socket
        |> assign(
          no_worker?: true,
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler,
          provider_states: %{}
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          no_worker?: false,
          perm_user: %{discord_id: user.discord_id, role: :spieler, is_member?: false},
          viewer_role: :spieler,
          provider_states: %{}
        )
    end
  end

  defp state_for(states, id) do
    case Map.get(states, id) do
      {:ok, meta} -> {:configured, meta}
      :error -> :empty
      _ -> :empty
    end
  end

  defp format_iso(nil), do: "—"
  defp format_iso(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_iso(_), do: "—"

  # ─── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-8 py-6 max-w-3xl">
      <header class="mb-6">
        <h1 class="font-display text-2xl tracking-wide">Admin — Cloud-Backends</h1>
        <p class="text-ink-2 text-sm mt-1">
          API-Keys für Cloud-LLM-Anbieter. AES-GCM-verschlüsselt at-rest.
          Issue #27 — Phase 1a (nur Anthropic).
        </p>
      </header>

      <%= if @no_worker? do %>
        <div class="panel p-8 text-center text-ink-2">
          Kein Worker connected — Snapshot nicht möglich.
        </div>
      <% else %>
        <div class="space-y-6">
          <%= for p <- @providers do %>
            <% state = state_for(@provider_states, p.id) %>
            <fieldset class="panel p-4">
              <legend class="text-xs uppercase tracking-widest text-ink-2 px-2">
                {p.label}
              </legend>

              <%= case state do %>
                <% {:configured, meta} -> %>
                  <p class="text-sm text-emerald-300 mb-2">
                    ✓ Key konfiguriert
                  </p>
                  <p class="text-xs text-ink-2">
                    Gesetzt: {format_iso(meta.created_at)} · Aktualisiert: {format_iso(meta.updated_at)}
                    <%= if meta.created_by_discord_id do %>
                      · von <code>{meta.created_by_discord_id}</code>
                    <% end %>
                  </p>
                <% _ -> %>
                  <p class="text-sm text-ink-2 mb-2">Kein Key hinterlegt.</p>
              <% end %>

              <p class="text-xs text-ink-2 mt-2 mb-3">{p.hint}</p>

              <form phx-submit="save" class="flex gap-2 items-end">
                <input type="hidden" name="provider" value={p.id} />
                <label class="block flex-1">
                  <span class="text-xs text-ink-2">Neuen Key setzen</span>
                  <input
                    type="password"
                    name="key"
                    placeholder="sk-ant-..."
                    autocomplete="off"
                    class="mt-1 block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 font-mono text-sm focus:border-accent focus:ring-0"
                  />
                </label>
                <.cyber_icon_button kind={:confirm} size={:md} type="submit" title="API-Key speichern" />
              </form>

              <div class="flex gap-2 mt-3">
                <.cyber_icon_button
                  kind={:test}
                  size={:md}
                  phx-click="test"
                  phx-value-provider={p.id}
                  disabled={match?(:empty, state)}
                  title="Verbindung testen"
                />
                <.cyber_icon_button
                  kind={:delete}
                  size={:md}
                  phx-click="delete"
                  phx-value-provider={p.id}
                  data-confirm={"Key für #{p.label} wirklich löschen?"}
                  disabled={match?(:empty, state)}
                  title={"Key für #{p.label} löschen"}
                />
              </div>
            </fieldset>
          <% end %>

          <div class="panel p-3 text-xs text-ink-2">
            Hinweis: Master-Key für Verschlüsselung kommt aus
            <code>LORE_CLOAK_KEY</code> (Base64, 32 Bytes). Ohne den ENV-Eintrag
            kann ein gespeicherter Key nach Hub-Restart nicht mehr dekriptiert
            werden — bei Setup-Schritt mit-pflegen, siehe CONTRIBUTING.md.
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
