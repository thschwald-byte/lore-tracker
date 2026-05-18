defmodule HubWeb.CampaignLive do
  @moduledoc """
  Mockup-2 campaign view: 4-column layout (Chronik / Resümee / Epos /
  Protokoll) + recording bar + owner controls (create invite, shutdown
  worker, list active invites). Full per-column content lands M6+M7+M8.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, EventLog, Reader}

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:campaign_id, campaign_id)
      |> assign(:active_nav, :campaign)
      |> assign(:invite_url, nil)
      |> load_snapshot()

    cond do
      socket.assigns[:forbidden?] ->
        {:ok, socket |> put_flash(:error, "Kein Zugriff") |> push_navigate(to: ~p"/")}

      socket.assigns[:not_found?] ->
        {:ok, socket |> put_flash(:error, "Kampagne nicht gefunden") |> push_navigate(to: ~p"/")}

      true ->
        {:ok, socket}
    end
  end

  # ─── Events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("create_invite", _, socket) do
    if socket.assigns.owner? do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.invite_created(),
            "token" => token,
            "campaign_id" => socket.assigns.campaign_id,
            "created_by_discord_id" => socket.assigns.current_user.discord_id,
            "expires_at" => nil
          },
          nil
        )

      url = HubWeb.Endpoint.url() <> "/invite/#{token}"
      {:noreply, assign(socket, :invite_url, url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_invite_url", _, socket), do: {:noreply, assign(socket, :invite_url, nil)}

  def handle_event("revoke_invite", %{"token" => token}, socket) do
    if socket.assigns.owner? do
      {:ok, _seq} =
        EventLog.append(
          %{"kind" => Shared.Events.invite_revoked(), "token" => token},
          nil
        )
    end

    {:noreply, socket}
  end

  def handle_event("shutdown_worker", _, socket) do
    if socket.assigns.owner? do
      n = Commands.shutdown_my_workers(socket.assigns.current_user.discord_id)

      socket =
        socket
        |> put_flash(:info, "Shutdown an #{n} Worker geschickt.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ~w(
        CampaignUpdated SessionScheduled SessionStarted SessionEnded
        InviteCreated InviteRevoked InviteRedeemed MemberRemoved
      ) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_snapshot(socket)}

  # ─── Snapshot ───────────────────────────────────────────────────

  defp load_snapshot(socket) do
    scope = %{
      "kind" => "campaign",
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }

    case Reader.read(scope) do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, %{"campaign" => c, "sessions" => sessions, "members" => members} = snap} ->
        socket
        |> assign(:waiting?, false)
        |> assign(:campaign, c)
        |> assign(:current_campaign, c)
        |> assign(:sessions, sessions)
        |> assign(:members, members)
        |> assign(:invites, Map.get(snap, "invites", []))
        |> assign(:owner?, c["owner_discord_id"] == socket.assigns.current_user.discord_id)

      {:error, :no_worker} ->
        assign(socket,
          waiting?: true,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          owner?: false
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(
          waiting?: false,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          owner?: false
        )
    end
  end

  # ─── Render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.recording_bar owner?={@owner?} />

      <%= if @invite_url do %>
        <div class="px-6 py-3 bg-accent/10 border-b border-accent/40 flex items-center gap-3">
          <span class="hero-link-mini w-4 h-4 text-accent"></span>
          <span class="text-sm text-ink-1">Einladungs-Link:</span>
          <input
            readonly
            value={@invite_url}
            onclick="this.select()"
            class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-sm text-accent font-mono"
          />
          <button phx-click="clear_invite_url" class="btn !py-1 !px-2">×</button>
        </div>
      <% end %>

      <div class="flex-1 grid grid-cols-4 gap-px bg-bg-3/60 overflow-hidden">
        <.column title="Chronik" subtitle="">
          <%= if @waiting? do %>
            <.empty_col text="Warte auf Worker." />
          <% else %>
            <p class="text-ink-2 text-sm">
              Zeitstrahl (Stufe-4-LLM extrahiert In-Game-Daten). Kommt mit M8.
            </p>
            <%= for s <- @sessions do %>
              <div class="mt-3 pl-3 border-l border-accent/40">
                <div class="text-xs text-ink-2 uppercase">#{s["number"]} {s["status"]}</div>
                <div class="text-ink-0 text-sm">{s["name"]}</div>
              </div>
            <% end %>
          <% end %>
        </.column>

        <.column title="Resümee" subtitle="Was letztes Mal geschah">
          <.empty_col text="Stufe-2-LLM verdichtet hier nach jeder Session. (M8)" />
        </.column>

        <.column title="The Epos" subtitle="Main Campaign Book">
          <.empty_col text="Buch + Markdown-Editor + Diff. (M7)" />
        </.column>

        <.column title="Protokoll" subtitle="Live Transkript">
          <.empty_col text="Whisper-Snippets während der Aufnahme. (M6/M8)" />
        </.column>
      </div>

      <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1">
        <span class="uppercase tracking-widest">Mitspieler</span>
        <%= for m <- @members do %>
          <span class={["pill", m["role"] == "owner" && "pill-active"]}>
            {m["discord_id"]}
          </span>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <button phx-click="create_invite" class="btn !py-1">
            <span class="hero-link-mini w-3 h-3"></span> Einladung
          </button>
        <% end %>
      </div>

      <%= if @owner? and @invites != [] do %>
        <div class="border-t border-bg-3/60 px-4 py-2 text-xs bg-bg-1">
          <div class="uppercase tracking-widest text-ink-2 mb-1">Offene Einladungen</div>
          <%= for inv <- @invites, inv["status"] == "active" do %>
            <div class="flex items-center gap-2 py-1">
              <span class="text-accent font-mono truncate">{inv["token"]}</span>
              <button
                phx-click="revoke_invite"
                phx-value-token={inv["token"]}
                class="ml-auto text-ink-2 hover:text-rec-soft"
              >
                Widerrufen
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <button class="btn btn-rec" disabled={not @owner?}>
        <span class="hero-stop-circle-solid w-4 h-4"></span> REC
      </button>
      <button class="btn" disabled={not @owner?}>
        <span class="hero-pause w-4 h-4"></span> Pause
      </button>
      <button class="btn" disabled={not @owner?}>
        <span class="hero-stop w-4 h-4"></span> Stopp
      </button>
      <button class="btn" disabled={not @owner?}>
        <span class="hero-bookmark w-4 h-4"></span> Marker
      </button>
      <div class="flex-1"></div>
      <span class="text-xs text-ink-2 font-mono">00:00:00</span>
      <%= if @owner? do %>
        <button
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          class="btn"
          title="Worker herunterfahren"
        >
          <span class="hero-power w-4 h-4"></span>
        </button>
      <% end %>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  slot :inner_block, required: true

  defp column(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col min-h-0">
      <div class="col-header">
        <span>{@title}</span>
        <%= if @subtitle != "" do %>
          <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">
            {@subtitle}
          </span>
        <% end %>
      </div>
      <div class="flex-1 overflow-y-auto p-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp empty_col(assigns) do
    ~H"""
    <p class="text-ink-2 text-sm italic">{@text}</p>
    """
  end
end
