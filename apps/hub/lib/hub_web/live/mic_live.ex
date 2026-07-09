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

    - `{:start_capture, campaign_id, session_id, device_id, source}` — nur noch
      für den **System-/Listen-Pfad** (getDisplayMedia, kein Setup-Stream).
      Capture starten; läuft schon eine → erst stoppen (ein Mikro pro User).
    - `{:stop_capture}` — expliziter Leave / rec_stop.

  Für den **Mic-Pfad** läuft der Start seit Issue #412 NICHT mehr über dieses
  per-User-Topic, sondern als **browser-lokale Übergabe**: der `MicSetup`-Hook
  reicht den schon offenen MediaStream via window-CustomEvent an den
  `MicCapture`-Hook im selben Browser weiter (kein zweites getUserMedia — Mobile
  lehnt das fürs selbe Device ab — und kein Fan-out auf andere Geräte desselben
  Users). MicLive erfährt den Recording-State dann aus `mic_capture_started`
  (mit `campaign_id`).

  Stoppt zusätzlich automatisch bei `SessionEnded` der laufenden Session.
  """
  use HubWeb, :live_view

  alias Shared.Events, as: EventKinds

  # Issue #569: Modul-Attribut für event-kind-Match im handle_info-Head
  # (Iron-Law #8 — kein Remote-Call im Guard).
  @session_ended_kind EventKinds.session_ended()

  require Logger

  alias Hub.{Commands, Events}

  # Issue #468: ab so vielen aufeinanderfolgenden verworfenen Audio-Chunks
  # (kein Member-Worker erreichbar) wird der User einmalig gewarnt. 6 × 500ms
  # ≈ 3s verlorenes Audio — genug, um Flap-Rauschen zu vermeiden, aber schnell
  # genug, dass man nicht minutenlang ins Leere aufnimmt.
  @chunk_drop_warn_streak 6

  # Issue #772: Schwelle für den Wrong-Worker-NACK-Detektor. Getrennt vom
  # Sync-Streak oben — ein spät ankommender NACK kann den synchronen
  # delivered=true-Reset nicht überstimmen, also zählt dieser Pfad eigenständig.
  # Kleiner als der Streak: ein NACK = ein tatsächlich am falschen Worker
  # verworfener Chunk (nicht bloß „kein Worker"), also aussagekräftiger; 1–2
  # transiente NACKs beim Leader-Settling bleiben drunter, ein echtes Failover
  # (Halter offline → Fallback ohne Sink) überschreitet sie.
  @nack_warn_count 4

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
     # Issue #396: Toast „an anderem Tab/Gerät übernommen" nach Supersede.
     |> assign(:superseded?, false)
     # Issue #468: Zähler aufeinanderfolgender verworfener Audio-Chunks.
     |> reset_chunk_tracking()
     |> assign(:show_silence_modal?, false), layout: false}
  end

  @doc "Per-User-Command-Topic: CampaignLive → MicLive ({:start_capture}/{:stop_capture})."
  def mic_topic(discord_id), do: "user_mic:#{discord_id}"

  @doc "Per-User-State-Topic: MicLive → CampaignLive ({:mic_capture_failed, reason})."
  def mic_state_topic(discord_id), do: "user_mic_state:#{discord_id}"

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
     |> assign(:superseded?, false)
     |> reset_chunk_tracking()
     |> push_event("mic_capture:start", %{
       device_id: device_id,
       session_id: sid,
       source: source
     })}
  end

  def handle_info({:stop_capture}, socket) do
    {:noreply, stop_capture(socket)}
  end

  # Issue #415: ein anderes Gerät/Tab desselben Users hat die Aufnahme übernommen
  # → hier sauber abgeben. PID-Guard: das auslösende Gerät (from == self()) bleibt
  # unberührt, nur fremde laufende Captures stoppen.
  #
  # Issue #396: nicht mehr still abgeben. Der User soll wissen, dass seine
  # Aufnahme an einem anderen Tab/Gerät übernommen wurde — sonst steht er ratlos
  # da (Recording „verschwand") und macht im Zweifel seine eigene Aufnahme kaputt.
  # Toast via @superseded?; das Button-Reset im CampaignLive läuft weiter browser-
  # lokal über lore:mic-state.
  def handle_info({:supersede_capture, from}, socket) do
    if from != self() and socket.assigns.mic_on? do
      {:noreply, socket |> stop_capture() |> assign(:superseded?, true)}
    else
      {:noreply, socket}
    end
  end

  # Session zu Ende → Capture stoppen (nur wenn es die laufende ist).
  def handle_info(
        {:event_appended, %{payload: %{"kind" => @session_ended_kind, "id" => sid}}},
        socket
      ) do
    if sid == socket.assigns.recording_session_id do
      {:noreply, stop_capture(socket)}
    else
      {:noreply, socket}
    end
  end

  # Issue #702: gebatchte Events durch die event_appended-Klauseln falten —
  # zwingend VOR dem generischen Catch-all, sonst werden Batches verschluckt.
  def handle_info({:events_batch, events}, socket),
    do: HubWeb.Live.EventsBatch.fold(events, socket, &handle_info/2)

  # Issue #772: Wrong-Worker-Drop. Der Session-haltende Worker ging offline;
  # pick_leader fiel auf einen Member-Worker OHNE offenen Sink zurück, der den
  # Chunk still verwirft — forward_audio_chunk hat aber schon `1` (delivered)
  # gemeldet, der Sync-Streak greift also nicht. Der verwerfende Worker meldet
  # den Drop stattdessen per `audio_nack`. EIGENER Zähler (NICHT der Sync-Streak:
  # dessen synchroner delivered=true-Reset würde den spät ankommenden NACK
  # überstimmen → Oszillation 0↔1). Erst ab @nack_warn_count NACKs derselben
  # laufenden Session warnen (transiente Reconfiguration bleibt drunter),
  # einmalig, gleiche `:mic_audio_dropping`-Warnung wie der No-Worker-Pfad.
  def handle_info({:audio_nack, sid}, socket) do
    cond do
      sid != socket.assigns.recording_session_id ->
        {:noreply, socket}

      socket.assigns[:nack_warned?] ->
        {:noreply, socket}

      true ->
        count = (socket.assigns[:nack_count] || 0) + 1

        if count >= @nack_warn_count do
          Logger.warning(
            "MicLive: #{count} Audio-Chunks am falschen Worker verworfen " <>
              "(Session-Halter offline?) für session=#{sid}"
          )

          broadcast_dropping(socket)
          {:noreply, socket |> assign(:nack_count, count) |> assign(:nack_warned?, true)}
        else
          {:noreply, assign(socket, :nack_count, count)}
        end
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
    |> reset_chunk_tracking()
    |> assign(:show_silence_modal?, false)
  end

  # ─── Events vom MicCapture-Hook ─────────────────────────────────

  @impl true
  def handle_event("audio_chunk", %{"session_id" => sid, "chunk" => chunk} = payload, socket)
      when is_binary(sid) and sid != "" and is_binary(chunk) and chunk != "" do
    cid = socket.assigns.recording_campaign_id

    # Issue #642: `mic_mode` ("per_player" | "multi") vom MicCapture-Hook;
    # getrennt vom Capture-`source` ("mic"|"system"). nil bei altem Hook →
    # Worker defaultet :per_player.
    mic_mode = payload["mic_mode"]

    # forward_audio_chunk == 1 → an einen Member-Worker zugestellt; == 0 → kein
    # Member-Worker erreichbar.
    #
    # Issue #468 Cut 3: Reply mit `delivered`-Flag an den MicCapture-Hook,
    # der bei false den Chunk in eine kleine Client-Queue puffert und bei
    # nächstem erfolgreichen Push nachsendet. Damit überbrückt der Browser
    # einen kurzen Worker-Outage ohne Audio-Verlust — Hub-Stop bei
    # max_buffered_chunks-Limit (Memory begrenzt).
    delivered? =
      with true <- is_binary(cid),
           did when is_binary(did) <- sender_did(socket) do
        Commands.forward_audio_chunk(cid, sid, did, mic_mode, chunk) == 1
      else
        _ -> false
      end

    {:reply, %{delivered: delivered?}, track_chunk_delivery(socket, delivered?)}
  end

  def handle_event("audio_chunk", _payload, socket),
    do: {:reply, %{delivered: false}, socket}

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

  # Issue #468 Cut 3: MicCapture meldet aktuelle Client-Buffer-Größe (Chunks
  # die der Hub nicht zustellen konnte und im Browser-RAM puffern). Wir
  # broadcasten den Zustand auf `mic_state_topic(did)`, damit CampaignLive
  # einen "puffert N Chunks"-Indikator zeigen kann — Recording läuft, aber
  # die Daten warten auf Worker-Reconnect.
  def handle_event(
        "mic_chunks_buffered",
        %{"pending" => pending, "dropped" => dropped} = _payload,
        socket
      )
      when is_integer(pending) and is_integer(dropped) do
    if did = current_did(socket) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        mic_state_topic(did),
        {:mic_chunks_buffered, %{pending: pending, dropped: dropped}}
      )
    end

    {:noreply, socket}
  end

  def handle_event("mic_chunks_buffered", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_silence_dismiss", _payload, socket) do
    {:noreply,
     socket
     |> assign(:show_silence_modal?, false)
     |> push_event("mic_capture:silence_ack", %{})}
  end

  # Issue #396: Übernahme-Hinweis weg-klicken.
  def handle_event("dismiss_superseded", _payload, socket) do
    {:noreply, assign(socket, :superseded?, false)}
  end

  # Issue #412: beim browser-lokalen Mic-Handoff (kein server-seitiges
  # {:start_capture}) setzt MicCapture den Recording-State hier — campaign_id
  # ist dann dabei. Der System-/Listen-Pfad meldet campaign_id=nil (State schon
  # aus {:start_capture} gesetzt) → unten der No-op-Klausel.
  def handle_event(
        "mic_capture_started",
        %{"campaign_id" => cid, "session_id" => sid} = payload,
        socket
      )
      when is_binary(cid) and cid != "" and is_binary(sid) and sid != "" do
    # Issue #415: Ein-Klick-Übernahme. Dieses Gerät hat gerade eine Aufnahme
    # gestartet → alle ANDEREN Geräte desselben Users sollen ihre laufende
    # Aufnahme abgeben (ein Mikro pro User). Broadcast aufs per-User-Topic; der
    # PID-Guard im handle_info verhindert Selbst-Stopp.
    if did = current_did(socket) do
      Phoenix.PubSub.broadcast(Hub.PubSub, mic_topic(did), {:supersede_capture, self()})
    end

    {:noreply,
     socket
     |> assign(:recording_campaign_id, cid)
     |> assign(:recording_session_id, sid)
     |> assign(:capture_source, payload["source"] || "mic")
     |> assign(:mic_on?, true)
     |> assign(:show_silence_modal?, false)
     |> assign(:superseded?, false)
     |> reset_chunk_tracking()}
  end

  def handle_event("mic_capture_started", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_capture_error", %{"reason" => reason}, socket) do
    # Capture fehlgeschlagen → Campaign-View informieren (Flash + Button-Reset),
    # lokalen State leeren.
    if did = current_did(socket) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        mic_state_topic(did),
        {:mic_capture_failed, reason}
      )
    end

    {:noreply, stop_capture(socket)}
  end

  def handle_event(_event, _payload, socket), do: {:noreply, socket}

  # Issue #468: aufeinanderfolgende verworfene Audio-Chunks zählen und den User
  # EINMALIG warnen (via CampaignLive-Flash über mic_state_topic), sobald die
  # Strähne @chunk_drop_warn_streak erreicht — sonst nimmt er ahnungslos ins
  # Leere auf. Bei der ersten erfolgreichen Zustellung Strähne zurücksetzen
  # (Worker zurück → erneutes Abbrechen würde wieder warnen).
  defp track_chunk_delivery(socket, true) do
    if (socket.assigns[:chunk_drop_streak] || 0) > 0 do
      assign(socket, :chunk_drop_streak, 0)
    else
      socket
    end
  end

  defp track_chunk_delivery(socket, false) do
    streak = (socket.assigns[:chunk_drop_streak] || 0) + 1

    if streak == @chunk_drop_warn_streak do
      Logger.warning(
        "MicLive: #{streak} aufeinanderfolgende Audio-Chunks verworfen (kein Member-Worker erreichbar) für session=#{socket.assigns.recording_session_id}"
      )

      broadcast_dropping(socket)
    end

    assign(socket, :chunk_drop_streak, streak)
  end

  # Issue #468/#772: dieselbe „Audio wird nicht aufgezeichnet"-Warnung an
  # CampaignLive (Flash + Button-Reset), egal ob No-Worker-Streak (#468) oder
  # Wrong-Worker-NACK (#772) sie ausgelöst hat.
  defp broadcast_dropping(socket) do
    if did = current_did(socket) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        mic_state_topic(did),
        {:mic_audio_dropping, socket.assigns.recording_session_id}
      )
    end
  end

  # Issue #772: NACK-Zähler zusammen mit dem #468-Sync-Streak zurücksetzen —
  # beide sind per-Recording und dürfen nicht über Sessions hinweg leaken.
  defp reset_chunk_tracking(socket) do
    socket
    |> assign(:chunk_drop_streak, 0)
    |> assign(:nack_count, 0)
    |> assign(:nack_warned?, false)
  end

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

  # handle_event/3 gated auf `is_number(level)` (mic_live.ex:182), damit ist der
  # Aufruf hier immer number → catch-all wäre unerreichbar (Elixir 1.19 warnt
  # das jetzt hart).
  defp clamp_level(level) when is_number(level), do: max(0.0, min(1.0, level / 1))

  # ─── Render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mic-live-root">
      <div id="mic-capture" phx-hook="MicCapture" phx-update="ignore"></div>

      <%!-- Issue #396: Aufnahme wurde an einem anderen Tab/Gerät desselben
            Accounts übernommen → hier sauber abgegeben + sichtbarer Hinweis,
            statt still zu verschwinden. --%>
      <%= if @superseded? do %>
        <div
          role="status"
          class="fixed top-4 left-1/2 -translate-x-1/2 z-50 panel px-4 py-3 shadow-2xl flex items-center gap-3 w-full max-w-md mx-4"
        >
          <span class="inline-block w-2 h-2 rounded-full bg-warning shrink-0"></span>
          <span class="text-ink-1 text-sm">
            Deine Aufnahme läuft jetzt an einem anderen Tab oder Gerät — hier wurde sie beendet.
          </span>
          <button
            type="button"
            phx-click="dismiss_superseded"
            class="ml-auto px-2.5 py-1 text-xs rounded bg-accent text-accent-fg hover:bg-accent/80 shrink-0"
          >
            OK
          </button>
        </div>
      <% end %>

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
