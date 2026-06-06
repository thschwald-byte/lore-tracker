defmodule HubWeb.CampaignLive.Recording do
  @moduledoc """
  Aufnahme-Steuerung der CampaignLive (Issue #434, Cut 4): Start/Pause/Resume/
  Stop (#259/#355/#405), Marker, Pipeline-Re-Run pro Session (#121) +
  Campaign-Replay (#104).

  Issue #642: „Session starten" öffnet nur die Session (modeless Container) —
  der Aufnahme-Typ (per-Spieler vs. Raummikro) wird erst beim Mikro-Beitritt
  pro Stream gewählt (s. `HubWeb.CampaignLive.Mic.join/1` + `join_multi/1`).
  Der frühere Ein-Klick-Raummikro-Start (`single_start/1`, #19/#302) entfällt.

  Kontext-Modul mit Delegations-Pattern: jede Funktion nimmt den LiveView-Socket
  und liefert `{:noreply, socket}`. Läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Hub.Commands
  alias HubWeb.CampaignLive.{Core, Publisher}
  alias Shared.Events

  def start(socket) do
    cond do
      not socket.assigns.owner? ->
        {:noreply, socket}

      socket.assigns.active_session ->
        # Already recording — UI Start is a no-op (Resume is a separate
        # button when state is :paused, see template).
        {:noreply, socket}

      true ->
        n =
          Commands.request_recording_start(
            socket.assigns.current_user.discord_id,
            socket.assigns.campaign_id
          )

        if n == 0 do
          {:noreply, put_flash(socket, :error, "Kein eigener Worker connected.")}
        else
          {:noreply, socket}
        end
    end
  end

  def pause(socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "paused")
    end

    {:noreply, socket}
  end

  def resume(socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "recording")
    end

    {:noreply, socket}
  end

  def stop(socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      stopping_sid = socket.assigns.active_session.id

      Commands.request_recording_stop(
        socket.assigns.current_user.discord_id,
        socket.assigns.campaign_id
      )

      # Issue #259: optimistic state-reset. Sonst hängt der Button ~2s
      # (ffmpeg + whisper + Pipeline-Bootstrap), bis SessionEnded zurückkommt.
      # Issue #355 Bug-Fix: zusätzlich `:stopping_session_id` setzen, damit
      # ein zwischenzeitlicher Snapshot-Reload die Session NICHT als aktiv
      # zurückbringt während der Worker noch transkribiert (kann Minuten
      # dauern bei voller GpuQueue). Cleared sobald SessionEnded ankommt
      # (siehe event_appended-Handler unten).
      # Issue #405: Capture in der sticky MicLive stoppen.
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        HubWeb.MicLive.mic_topic(socket.assigns.current_user.discord_id),
        {:stop_capture}
      )

      {:noreply,
       socket
       |> assign(:active_session, nil)
       |> assign(:stopping_session_id, stopping_sid)
       |> assign(:mic_on?, false)
       |> assign(:mic_streamers, [])
       |> assign(:mic_levels, %{})}
    else
      {:noreply, socket}
    end
  end

  def marker(socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      Publisher.publish(socket, %{
        "kind" => Events.marker_added(),
        "id" => UUIDv7.generate(),
        "session_id" => socket.assigns.active_session.id,
        "at_ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "marker_kind" => "plot",
        "label" => "Plot-Moment"
      })
    end

    {:noreply, socket}
  end

  # ─── Pipeline re-run ────────────────────────────────────────────

  def rerun_pipeline(socket, session_id) do
    campaign = Core.perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :regenerate_session, campaign) ->
        {:noreply, socket}

      true ->
        # Issue #121: kein RegenerateRequested-Event mehr — direkter
        # Channel-Push an den Owner-Worker, der dann Pipeline.run_for_session
        # callt. Kein Hub-Event-Roundtrip mehr für reinen Trigger.
        # Issue #140: `owner_discord_id` ist im Snapshot der erste
        # Spielleiter (Recording-Leader-Routing).
        n =
          Commands.request_session_regenerate(
            snap["owner_discord_id"],
            campaign.id,
            session_id
          )

        if n > 0 do
          {:noreply, put_flash(socket, :info, "Pipeline neu gestartet für Session.")}
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Owner-Worker nicht verbunden — Pipeline-Trigger fehlgeschlagen."
           )}
        end
    end
  end

  # Issue #104: Campaign-Level-Pipeline-Trigger. Engine läuft auf dem
  # Owner-Worker (Worker.Recording.CampaignReplay) — der aufrufende
  # Spielleiter ist möglicherweise nicht selbst Campaign-Owner.
  def rerun_campaign(socket) do
    campaign = Core.perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :regenerate_campaign, campaign) ->
        {:noreply, socket}

      true ->
        n = Commands.request_campaign_replay(snap["owner_discord_id"], campaign.id)

        # Issue #270: nach Confirm schließt das Akkordeon-Tab.
        socket = assign(socket, :open_tab, nil)

        if n > 0 do
          {:noreply,
           put_flash(
             socket,
             :info,
             "Pipeline für alle Sessions gestartet — läuft im Worker, Status oben."
           )}
        else
          {:noreply,
           put_flash(socket, :error, "Owner-Worker nicht verbunden — Replay nicht startbar.")}
        end
    end
  end

  defp append_state(socket, state) do
    Publisher.publish(socket, %{
      "kind" => Events.recording_state_changed(),
      "session_id" => socket.assigns.active_session.id,
      "campaign_id" => socket.assigns.campaign_id,
      "state" => state
    })
  end
end
