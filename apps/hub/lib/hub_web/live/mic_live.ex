defmodule HubWeb.MicLive do
  @moduledoc """
  Issue #405: sticky nested LiveView, die die laufende Audio-Capture besitzt.

  Gemountet im persistenten Root-Layout via
  `live_render(@conn, HubWeb.MicLive, sticky: true)` — überlebt dadurch
  `live_redirect`-Navigation innerhalb der `live_session :default`. Das eigene
  Mikro nimmt weiter auf während der User aufs Dashboard / in die Einstellungen
  wechselt (Split-Architektur: das Setup-Popup bleibt in `CampaignLive`, nur die
  Capture ist sticky).

  Koordination mit `CampaignLive` über das per-User-PubSub-Topic
  `"user_mic:<discord_id>"`:

    - `{:start_capture, campaign_id, session_id, device_id, source}` — Setup ist
      durch (oder Listen-Modus), Capture starten. Läuft schon eine Aufnahme für
      ein anderes Paar → erst stoppen (ein Mikro pro User).
    - `{:stop_capture}` — expliziter Leave / rec_stop.

  Stoppt zusätzlich automatisch bei `SessionEnded` der laufenden Session.
  """
  use HubWeb, :live_view

  alias Hub.{Commands, Events}

  @impl true
  def mount(_params, session, socket) do
    user = session["current_user"]

    if connected?(socket) and user do
      Phoenix.PubSub.subscribe(Hub.PubSub, mic_topic(user.discord_id))
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:recording_campaign_id, nil)
     |> assign(:recording_session_id, nil)
     |> assign(:capture_source, nil)
     |> assign(:mic_on?, false)
     |> assign(:show_silence_modal?, false),
     layout: false}
  end

  @doc "Per-User-Command-Topic. CampaignLive broadcastet darauf, MicLive konsumiert."
  def mic_topic(discord_id), do: "user_mic:#{discord_id}"

  # ─── Commands von CampaignLive ──────────────────────────────────

  @impl true
  def handle_info({:start_capture, cid, sid, device_id, source}, socket) do
    {:noreply,
     socket
     |> assign(:recording_campaign_id, cid)
     |> assign(:recording_session_id, sid)
     |> assign(:capture_source, source)
     |> assign(:mic_on?, true)
     |> assign(:show_silence_modal?, false)
     |> push_event("mic_capture:start", %{
       device_id: device_id,
       session_id: sid,
       source: source
     })}
  end

  def handle_info({:stop_capture}, socket) do
    {:noreply, stop_capture(socket)}
  end

  # Session zu Ende → Capture stoppen (nur wenn es die laufende ist).
  def handle_info(
        {:event_appended, %{payload: %{"kind" => "SessionEnded", "id" => sid}}},
        socket
      ) do
    if sid == socket.assigns.recording_session_id do
      {:noreply, stop_capture(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp stop_capture(socket) do
    socket
    |> push_event("mic_capture:stop", %{})
    |> assign(:recording_campaign_id, nil)
    |> assign(:recording_session_id, nil)
    |> assign(:capture_source, nil)
    |> assign(:mic_on?, false)
    |> assign(:show_silence_modal?, false)
  end

  # ─── Events vom MicCapture-Hook ─────────────────────────────────

  @impl true
  def handle_event("audio_chunk", %{"session_id" => sid, "chunk" => chunk}, socket)
      when is_binary(sid) and sid != "" and is_binary(chunk) and chunk != "" do
    cid = socket.assigns.recording_campaign_id

    with true <- is_binary(cid),
         did when is_binary(did) <- sender_did(socket) do
      Commands.forward_audio_chunk(cid, sid, did, chunk)
    end

    {:noreply, socket}
  end

  def handle_event("audio_chunk", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_level", %{"level" => level}, socket) when is_number(level) do
    cid = socket.assigns.recording_campaign_id

    with true <- is_binary(cid),
         did when is_binary(did) <- sender_did(socket) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        "pipeline_status",
        {:pipeline_status,
         %{
           "kind" => "mic_level",
           "campaign_id" => cid,
           "discord_id" => did,
           "level" => clamp_level(level)
         }}
      )
    end

    {:noreply, socket}
  end

  def handle_event("mic_level", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_silence_warning", _payload, socket) do
    {:noreply, assign(socket, :show_silence_modal?, true)}
  end

  def handle_event("mic_silence_dismiss", _payload, socket) do
    {:noreply,
     socket
     |> assign(:show_silence_modal?, false)
     |> push_event("mic_capture:silence_ack", %{})}
  end

  def handle_event("mic_capture_started", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_capture_error", %{"reason" => reason}, socket) do
    # Capture fehlgeschlagen → Campaign-View informieren (Flash + Button-Reset),
    # lokalen State leeren.
    if did = current_did(socket) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        mic_topic(did),
        {:mic_capture_failed, reason}
      )
    end

    {:noreply, stop_capture(socket)}
  end

  def handle_event(_event, _payload, socket), do: {:noreply, socket}

  # Sender-ID fürs Worker-Routing: Listen/System-Audio läuft unter dem
  # Pseudo-Sender "__listen__" (analog CampaignLive), sonst die eigene
  # discord_id.
  defp sender_did(socket) do
    case socket.assigns.capture_source do
      "system" -> "__listen__"
      _ -> current_did(socket)
    end
  end

  defp current_did(socket) do
    case socket.assigns.current_user do
      %{discord_id: did} -> did
      _ -> nil
    end
  end

  defp clamp_level(level) when is_number(level), do: max(0.0, min(1.0, level / 1))
  defp clamp_level(_), do: 0.0

  # ─── Render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mic-live-root">
      <div id="mic-capture" phx-hook="MicCapture" phx-update="ignore"></div>

      <%= if @show_silence_modal? do %>
        <div
          role="dialog"
          aria-modal="true"
          class="fixed inset-0 z-50 flex items-center justify-center bg-bg-0/70 backdrop-blur-sm"
        >
          <div class="panel p-6 w-full max-w-md mx-4 shadow-2xl">
            <h3 class="font-display text-lg text-ink-0 mb-3">Mikro prüfen?</h3>
            <p class="text-ink-1 text-sm mb-4">
              Seit 5 Minuten kam kein hörbares Audio von deinem Mikro. Falls du
              sprichst aber nichts ankommt: Mute-Status, Device-Auswahl oder
              Anschluss prüfen. Die Aufnahme läuft weiter.
            </p>
            <div class="flex justify-end">
              <button
                type="button"
                phx-click="mic_silence_dismiss"
                class="px-3 py-1.5 text-xs rounded bg-accent text-accent-fg hover:bg-accent/80"
              >
                Verstanden
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
