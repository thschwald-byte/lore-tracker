defmodule HubWeb.CampaignLive do
  @moduledoc """
  Mockup-2 campaign view: 4-column layout (Chronik / Resümee / Epos /
  Protokoll) + recording bar. Columns are currently mostly placeholders
  — Chronik/Sessions come in M6, Epos editor in M7, live transcript in M8.
  """

  use HubWeb, :live_view

  alias Hub.{EventLog, Reader}

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

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ~w(CampaignUpdated SessionScheduled SessionStarted SessionEnded) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_snapshot(socket)}

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

      {:ok, %{"campaign" => c, "sessions" => sessions, "members" => members}} ->
        socket
        |> assign(:waiting?, false)
        |> assign(:campaign, c)
        |> assign(:current_campaign, c)
        |> assign(:sessions, sessions)
        |> assign(:members, members)
        |> assign(:owner?, c["owner_discord_id"] == socket.assigns.current_user.discord_id)

      {:error, :no_worker} ->
        assign(socket,
          waiting?: true,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
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
          owner?: false
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.recording_bar owner?={@owner?} />

      <div class="flex-1 grid grid-cols-4 gap-px bg-bg-3/60 overflow-hidden">
        <.column title="Chronik" subtitle="">
          <%= if @waiting? do %>
            <.empty_col text="Warte auf Worker." />
          <% else %>
            <p class="text-ink-2 text-sm">Zeitstrahl (Stufe-4-LLM extrahiert In-Game-Daten). Kommt mit M8.</p>
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

      <%= if @members != [] do %>
        <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1">
          <span class="uppercase tracking-widest">Mitspieler</span>
          <%= for m <- @members do %>
            <span class={[
              "pill",
              m["role"] == "owner" && "pill-active"
            ]}>
              {m["discord_id"]}
            </span>
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
        <button class="btn" title="Worker herunterfahren">
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
