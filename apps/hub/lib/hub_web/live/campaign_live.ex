defmodule HubWeb.CampaignLive do
  @moduledoc """
  Mockup-2 campaign view: 4-column layout (Chronik / Resümee / Epos /
  Protokoll) + recording bar + owner controls.

  Recording state lives in `session.status`
  (`:scheduled → :recording → (:paused ↔ :recording) → :completed`).
  UtteranceAppended events stream into the Protokoll column without a
  full snapshot reload.

  Epos column (M7): owner can edit a single per-campaign Markdown entry;
  every save appends `EposEntryEdited`, the materializer keeps current
  + history rows. Diff is a unified line-by-line view via
  `List.myers_difference/2`.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, EventBridge, Events, Reader}
  require Logger

  # Column-Keys für Collapse-Persistenz (Issue #8). Reihenfolge entspricht
  # dem Render-Layout — wichtig nur als kanonischer Whitelist-Check.
  @col_names ~w(chronik epos summaries protokoll)

  # Issue #399: Server-seitiger Stille-Watchdog (Spiegel des Client-Watchdogs
  # #391). Voice-Schwelle 0.33 = −40 dBFS (= VOICE_DB_THRESHOLD in record_mic.js
  # und der „zu leise"-Cut der #395-VU-Ampel). Ein noch streamender User, von dem
  # ≥ 5 min kein mic_level ≥ Schwelle kam, gilt als still → Banner.
  @voice_level_threshold 0.33
  @silence_limit_ms 5 * 60 * 1000
  @silence_tick_ms 10_000

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, "pipeline_status")
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
      # Issue #405: MicLive (sticky Capture-Owner) meldet Capture-Fehler zurück.
      Phoenix.PubSub.subscribe(Hub.PubSub, HubWeb.MicLive.mic_state_topic(user.discord_id))
      # Issue #400: transkribierte Mic-Setup-Phrasen-Clips kommen hier rein.
      Phoenix.PubSub.subscribe(Hub.PubSub, "mic_clip:#{user.discord_id}")
      # Issue #399: periodischer server-seitiger Stille-Check.
      Process.send_after(self(), :mic_silence_tick, @silence_tick_ms)
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:campaign_id, campaign_id)
      |> assign(:active_nav, :campaign)
      |> assign(:invite_url, nil)
      |> assign(:epos_mode, :view)
      |> assign(:epos_draft, "")
      |> assign(:epos_diff_seq, nil)
      |> assign(:busy_stages, MapSet.new())
      |> assign(:campaign_replay_running?, false)
      |> assign(:campaign_replay_state, nil)
      |> assign(:mic_on?, false)
      # Issue #415: nimmt DIESER Browser gerade auf? Browser-lokale Wahrheit aus
      # dem MicCapture-Hook (window-Event), nicht aus per-User-PubSub — steuert
      # den Drei-Wege-Button (stop / hier übernehmen / beitreten).
      |> assign(:recording_here?, false)
      |> assign(:mic_streamers, [])
      |> assign(:audio_consent, nil)
      |> assign(:pending_mic_source, nil)
      # Issue #405: gewähltes Device fürs Setup→MicLive-Handoff.
      |> assign(:pending_mic_device_id, nil)
      # Issue #391: Mic-Setup-Popup (Device-Auswahl + Voice-Test). Ein einziges
      # Modal vor der Aufnahme ersetzt das alte consent_modal — bei fehlendem
      # Consent wird das Häkchen mit-eingeblendet (mic_setup_consent_required?).
      # Pegel + Voice-Detection laufen rein client-side im record_mic.js-Hook.
      |> assign(:show_mic_setup?, false)
      |> assign(:mic_setup_consent_required?, false)
      |> assign(:mic_setup_consent_acked?, false)
      # Welcher Aufnahme-Modus hat das Setup getriggert? Bestimmt den Consent-
      # Text (Per-Spieler vs. Raummikro/Single-Source) + die Version, die bei
      # Akzeptanz gespeichert wird (Issue #317-Logik wandert hier rein).
      |> assign(:mic_setup_consent_mode, nil)
      |> assign(:mic_setup_devices, %{devices: [], preferred_id: nil})
      |> assign(:mic_setup_local_level, 0.0)
      # Issue #400: ASR-Phrasen-Test statt Pegel-Schwelle. Phrase wird beim
      # Öffnen des Setups gezogen; phrase_ok? ist das neue Finish-Gate.
      |> assign(:mic_setup_phrase, nil)
      |> assign(:mic_setup_checking?, false)
      |> assign(:mic_setup_last_transcript, nil)
      |> assign(:mic_setup_phrase_ok?, false)
      |> assign(:mic_setup_clip_req_id, nil)
      |> assign(:mic_setup_error, nil)
      |> assign(:pending_mic_session_id, nil)
      # Issue #391: Live-Pegel pro Streamer während der Aufnahme. Ephemer, kommt
      # 5×/s über den "pipeline_status"/mic_level-PubSub-Pfad.
      |> assign(:mic_levels, %{})
      # Issue #399: Stille-Watchdog-State. mic_loud_at: discord_id → monotonic ms
      # des letzten mic_level ≥ Schwelle (bzw. Join-Zeit); silent_streamers: die
      # aktuell als still geflaggten discord_ids (treiben den Banner).
      |> assign(:mic_loud_at, %{})
      |> assign(:silent_streamers, [])
      |> assign(:show_mic_silence_modal?, false)
      # Issue #114: source_refs UI-State.
      |> assign(:refs_popover, nil)
      |> assign(:utterance_refs_index, %{})
      |> assign(:sync_index_json, "{}")
      |> assign(:alias_mode, :view)
      |> assign(:alias_draft, "")
      |> assign(:summary_editing, nil)
      |> assign(:summary_draft, "")
      |> assign(:vocab_editing, false)
      |> assign(:vocab_draft, "")
      |> assign(:chronik_editing, nil)
      |> assign(:chronik_draft, %{})
      |> assign(:utterance_editing, nil)
      |> assign(:utterance_draft, "")
      |> assign(:utterance_adding, nil)
      |> assign(:utterance_add_speaker, nil)
      |> assign(:utterance_add_text, "")
      # Issue #19: Single-Source-Sprecher-Picker.
      |> assign(:speaker_assignments, %{})
      |> assign(:can_assign_speaker?, false)
      |> assign(:speaker_pick, nil)
      # Issue #302: Ein-Klick-Raummikro — true zwischen rec_single_start und
      # dem automatischen Mikro-Start sobald die Session aktiv ist.
      |> assign(:pending_single_source_mic?, false)
      # Issue #355: nach rec_stop-Klick gesetzt bis SessionEnded ankommt —
      # verhindert dass ein zwischenzeitlicher Snapshot-Reload die Session
      # als noch-aktiv zurückbringt (Transcribe-Queue kann minutenlang
      # blockieren, SessionEnded firet erst nach voller Transcribe-Stage).
      |> assign(:stopping_session_id, nil)
      |> assign(:flavor_editing?, false)
      |> assign(:flavor_drafts, %{})
      # Issue #313: Stil-Editor pro Stage (Reiter + Prompt-Vorschau).
      |> assign(:stil_stage, nil)
      |> assign(:preview_segments, [])
      |> assign(:preview_error, nil)
      |> assign(:vorgabe_drafts, %{})
      |> assign(:collapsed_cols, MapSet.new())
      |> assign(:delete_confirming?, false)
      |> assign(:delete_typed_name, "")
      |> assign(:remove_confirm_did, nil)
      |> assign(:demote_confirm_did, nil)
      |> assign(:faithfulness_expanded, MapSet.new())
      |> assign(:expanded_sessions, MapSet.new())
      # Issue #270: exklusiver Akkordeon-Reiter in der Top-Bar.
      |> assign(:open_tab, nil)
      # Issue #270: Member-Popup beim Klick auf Charakter-Pille.
      |> assign(:member_popup_open_for, nil)
      # Issue #321: Reload-Coalescing-State. :idle | :scheduled | :running;
      # reload_dirty? merkt sich Änderungen, die während eines laufenden
      # async-Reads reinkamen → Nachlauf-Reload.
      |> assign(:reload_state, :idle)
      |> assign(:reload_dirty?, false)
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

  # ─── Recording-bar events ───────────────────────────────────────

  @impl true
  def handle_event("rec_start", _, socket) do
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

  # Issue #19: Tisch-Raummikro. Wie rec_start, aber die Session läuft im
  # :single_source-Modus — eine kombinierte Spur, post-session diarisiert.
  def handle_event("rec_single_start", _, socket) do
    cond do
      not socket.assigns.owner? ->
        {:noreply, socket}

      socket.assigns.active_session ->
        {:noreply, socket}

      true ->
        n =
          Commands.request_recording_start(
            socket.assigns.current_user.discord_id,
            socket.assigns.campaign_id,
            :single_source
          )

        if n == 0 do
          {:noreply, put_flash(socket, :error, "Kein eigener Worker connected.")}
        else
          # Issue #302: Ein-Klick. Flag setzen → sobald die Session aktiv ist
          # (nächster Snapshot-Reload nach SessionStarted), startet die LiveView
          # das Mikro automatisch (maybe_autostart_single_source_mic/1). Kein
          # vergessener zweiter Klick mehr.
          {:noreply, assign(socket, :pending_single_source_mic?, true)}
        end
    end
  end

  def handle_event("rec_pause", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "paused")
    end

    {:noreply, socket}
  end

  def handle_event("rec_resume", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "recording")
    end

    {:noreply, socket}
  end

  def handle_event("rec_stop", _, socket) do
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

  def handle_event("rec_marker", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      bridge_publish(socket, %{
        "kind" => Shared.Events.marker_added(),
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

  def handle_event("rerun_pipeline", %{"session" => session_id}, socket) do
    campaign = perm_campaign(socket)
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
          Hub.Commands.request_session_regenerate(
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
  def handle_event("rerun_campaign", _params, socket) do
    campaign = perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :regenerate_campaign, campaign) ->
        {:noreply, socket}

      true ->
        n = Hub.Commands.request_campaign_replay(snap["owner_discord_id"], campaign.id)

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

  # ─── Speaker assignment (Issue #19) ─────────────────────────────

  def handle_event("speaker_pick_start", %{"label" => label, "session" => sid}, socket) do
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :assign_speaker, perm_campaign(socket)) do
      {:noreply, assign(socket, :speaker_pick, %{label: label, session_id: sid})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("speaker_pick_cancel", _, socket) do
    {:noreply, assign(socket, :speaker_pick, nil)}
  end

  def handle_event(
        "speaker_assign",
        %{"label" => label, "session" => sid, "discord_id" => did},
        socket
      ) do
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :assign_speaker, perm_campaign(socket)) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.speaker_assigned(),
        "campaign_id" => socket.assigns.campaign_id,
        "session_id" => sid,
        "speaker_label" => label,
        "discord_id" => did,
        "assigned_by" => socket.assigns.current_user.discord_id
      })

      {:noreply, assign(socket, :speaker_pick, nil)}
    else
      {:noreply, socket}
    end
  end

  # discord_id leer → Zuordnung aufheben.
  def handle_event("speaker_unassign", %{"label" => label, "session" => sid}, socket) do
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :assign_speaker, perm_campaign(socket)) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.speaker_assigned(),
        "campaign_id" => socket.assigns.campaign_id,
        "session_id" => sid,
        "speaker_label" => label,
        "discord_id" => "",
        "assigned_by" => socket.assigns.current_user.discord_id
      })

      {:noreply, assign(socket, :speaker_pick, nil)}
    else
      {:noreply, socket}
    end
  end

  # campaign-assign ist ein String-keyed Map vom Snapshot — Permissions
  # erwartet `:id` als Atom. Issue #140: Permission-Gating geht über
  # `user.campaign_role`, nicht mehr über owner_discord_id auf der Campaign.
  defp perm_campaign(socket) do
    c = socket.assigns[:campaign] || %{}
    %{id: c["id"]}
  end

  # ─── Mic events (M10-BMP: browser MediaRecorder) ────────────────

  def handle_event("mic_join", _, socket) do
    case socket.assigns.active_session do
      nil ->
        {:noreply, put_flash(socket, :error, "Keine aktive Session.")}

      %{id: sid} ->
        # Issue #391: Per-Spieler-Mikro → Setup-Popup (Device-Auswahl +
        # Voice-Test). Consent-Häkchen wird mit-eingeblendet falls nötig.
        # mic_on? bleibt false bis Voice-OK + Consent-OK (maybe_finish_mic_setup).
        #
        # Issue #396: ist das eine Übernahme von einem anderen Tab/Gerät desselben
        # Accounts (mic_button_state == :takeover), hält der alte Tab das Mikro
        # noch. Auf PipeWire/Firefox bekäme das Setup hier sonst NotReadableError
        # ("device in use") und das gesprochene Test-Zitat würde in der ALTEN
        # Aufnahme landen statt erkannt zu werden. Also erst dort superseden
        # (Mikro freigeben + Übernahme-Toast), dann das Setup öffnen.
        maybe_release_other_tab_for_takeover(socket)
        {:noreply, open_mic_setup(socket, sid, :per_player)}
    end
  end

  # Issue #396: beim Übernehmen die laufende Aufnahme der anderen Tabs/Geräte
  # desselben Accounts stoppen, damit das Mikro frei wird, bevor das Setup hier
  # den Voice-Test startet. Supersede (nicht stop) → der abgegebene Tab zeigt den
  # Hinweis. mic_button_state/3 ist die getestete Election-Logik (Issue #415).
  defp maybe_release_other_tab_for_takeover(socket) do
    did = socket.assigns.current_user.discord_id

    if mic_button_state(socket.assigns.recording_here?, did, socket.assigns.mic_streamers) ==
         :takeover do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        HubWeb.MicLive.mic_topic(did),
        {:supersede_capture, self()}
      )
    end

    :ok
  end

  # ─── Issue #391: Mic-Setup-Popup-Events (Hook ↔ LV) ─────────────

  # Hook hat enumerateDevices gemacht + meldet die Audio-Inputs zurück.
  def handle_event("mic_setup_devices_ready", %{"devices" => devices} = payload, socket) do
    normalized =
      devices
      |> List.wrap()
      |> Enum.map(fn d ->
        %{device_id: d["deviceId"] || d["device_id"] || "", label: d["label"] || "Mikrofon"}
      end)

    {:noreply,
     assign(socket, :mic_setup_devices, %{
       devices: normalized,
       preferred_id: payload["preferred_id"]
     })}
  end

  def handle_event("mic_setup_devices_ready", _, socket), do: {:noreply, socket}

  # User wählt im Modal-<select> ein anderes Mikrofon → Hook öffnet den Stream
  # auf dem Gerät + startet den Voice-Loop neu.
  def handle_event("mic_setup_select_device", %{"device_id" => device_id}, socket)
      when is_binary(device_id) and device_id != "" do
    {:noreply, push_event(socket, "mic:setup_select", %{device_id: device_id})}
  end

  def handle_event("mic_setup_select_device", _, socket), do: {:noreply, socket}

  # Lokaler Pegel im Setup-Modal (nur eigene Stimme). KEIN PubSub-Broadcast —
  # andere User sollen während des Setups nichts sehen.
  def handle_event("mic_setup_local_level", %{"level" => level}, socket)
      when is_number(level) do
    {:noreply, assign(socket, :mic_setup_local_level, clamp_level(level))}
  end

  def handle_event("mic_setup_local_level", _, socket), do: {:noreply, socket}

  # Issue #400: der Hook hat (auto, ohne Button) einen gesprochenen Phrasen-Clip
  # aufgenommen. An einen Member-Worker zum Transkribieren schicken; die Antwort
  # kommt async via {:clip_transcribed, …} auf "mic_clip:<did>".
  def handle_event("mic_setup_phrase_clip", %{"chunk" => chunk} = payload, socket)
      when is_binary(chunk) and chunk != "" do
    did = socket.assigns.current_user.discord_id
    cid = socket.assigns.campaign_id
    req_id = "clip-" <> Integer.to_string(System.unique_integer([:positive]))

    # Issue #405: das offene device_id mitnehmen (auch im Auto-Open-Reload-Pfad,
    # der kein select-Event feuert) — fürs Handoff an MicLive.
    socket = assign(socket, :pending_mic_device_id, payload["device_id"])

    case Hub.Commands.request_clip_transcribe(did, cid, req_id, chunk) do
      :ok ->
        Process.send_after(self(), {:clip_timeout, req_id}, 12_000)

        {:noreply,
         socket
         |> assign(:mic_setup_checking?, true)
         |> assign(:mic_setup_error, nil)
         |> assign(:mic_setup_clip_req_id, req_id)}

      {:error, :no_worker} ->
        # Hard-Block: kein Fallback auf den alten Pegel-Check. Setup schließt
        # NICHT; der User kann erneut sprechen sobald ein Worker verbunden ist.
        {:noreply,
         socket
         |> assign(:mic_setup_checking?, false)
         |> assign(
           :mic_setup_error,
           "Audio-Test nicht möglich — kein Worker verbunden. Bitte erneut versuchen."
         )
         |> push_event("mic:setup_listen_again", %{})}
    end
  end

  def handle_event("mic_setup_phrase_clip", _, socket), do: {:noreply, socket}

  # User klickt das Consent-Häkchen. Toggle + Finish-Check (Reihenfolge zu
  # Voice egal).
  def handle_event("mic_setup_consent_toggle", _, socket) do
    socket
    |> assign(:mic_setup_consent_acked?, not socket.assigns.mic_setup_consent_acked?)
    |> maybe_finish_mic_setup()
  end

  # Abbrechen-Button / Backdrop-Klick / Escape — Setup verwerfen, Stream im
  # Hook freigeben.
  def handle_event("mic_setup_cancel", _, socket) do
    {:noreply,
     socket
     |> assign(:show_mic_setup?, false)
     |> assign(:mic_on?, false)
     |> reset_mic_setup_state()
     |> push_event("mic:setup_abort", %{})}
  end

  # Live-Pegel während der Aufnahme (Hook → eigene LV → PubSub an alle
  # Campaign-Subscriber). sender_id-Logik analog audio_chunk.
  # Issue #405: mic_level + Silence-Watchdog leben jetzt in HubWeb.MicLive
  # (Capture-Owner). Das mic_level-Display (VU) kommt weiterhin via
  # pipeline_status-PubSub rein (handle_info unten), nur die Quelle ist MicLive.

  # ─── Issue #114: source_refs UI ─────────────────────────────────

  # Klick auf einen Eintrag (Resümee/Epos/Chronik) öffnet das Refs-Popover.
  def handle_event("show_refs", %{"kind" => kind, "id" => id}, socket) do
    refs = lookup_entry_refs(socket, kind, id)
    {:noreply, assign(socket, :refs_popover, %{kind: kind, entry_id: id, refs: refs})}
  end

  # Klick auf den Backward-Badge an einer Utterance: zeige Liste der
  # Einträge die diese Utterance referenzieren.
  def handle_event("show_utterance_refs", %{"id" => uid}, socket) do
    citing = Map.get(socket.assigns.utterance_refs_index, uid, [])
    {:noreply, assign(socket, :refs_popover, %{kind: "utterance", entry_id: uid, refs: citing})}
  end

  def handle_event("hide_refs", _, socket), do: {:noreply, assign(socket, :refs_popover, nil)}

  # Klick auf einen Eintrag im Refs-Popover: scroll-to-utterance via JS-Hook
  # + ggf. Cross-Session-Toggle (Protokoll-Spalte expandiert die Session
  # in der die Utterance liegt).
  def handle_event("goto_utterance", %{"id" => uid}, socket) do
    utterance =
      Enum.find(socket.assigns.utterances, fn u ->
        Map.get(u, "id") == uid or Map.get(u, :id) == uid
      end)

    session_id = utterance && (utterance["session_id"] || utterance[:session_id])

    socket =
      if session_id do
        # Cross-Session-Toggle: andere Sessions zuklappen, Ziel-Session offen.
        assign(socket, :expanded_sessions, MapSet.new([session_id]))
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:refs_popover, nil)
     |> push_event("scroll_to_utterance", %{id: uid})}
  end

  # Direkt-Sprung zu einem Eintrag der eine Utterance referenziert (aus
  # dem Backward-Popover). Keine Spalten-Logik — wir setzen einfach den
  # phx-click-Hash auf den DOM-Node-ID.
  def handle_event("goto_entry", %{"kind" => kind, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:refs_popover, nil)
     |> push_event("scroll_to_utterance", %{id: "#{kind}-#{id}"})}
  end

  defp lookup_entry_refs(socket, "summary", session_id) do
    case Enum.find(socket.assigns.summaries, &(&1["session_id"] == session_id)) do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(socket, "epos", _entry_id) do
    case socket.assigns.epos do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(socket, "chronik", entry_id) do
    case Enum.find(socket.assigns.chronik, &(&1["id"] == entry_id)) do
      %{"source_refs" => refs} when is_list(refs) -> refs
      _ -> []
    end
  end

  defp lookup_entry_refs(_, _, _), do: []

  # Issue #114: Backward-Index — pro utterance_id eine Liste der Einträge
  # (kind + entry_id + label), die sie als Quelle ausweisen. Wird einmal pro
  # load_snapshot berechnet und in :utterance_refs_index gecached.
  defp build_utterance_refs_index(summaries, epos, chronik) do
    summary_entries =
      summaries
      |> List.wrap()
      |> Enum.flat_map(fn s ->
        refs = Map.get(s, "source_refs", []) || []

        Enum.map(refs, fn uid ->
          {uid, %{kind: "summary", id: s["session_id"], label: "Resümee"}}
        end)
      end)

    epos_entries =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) ->
          Enum.map(refs, fn uid -> {uid, %{kind: "epos", id: id, label: "Epos"}} end)

        _ ->
          []
      end

    chronik_entries =
      chronik
      |> List.wrap()
      |> Enum.flat_map(fn c ->
        refs = Map.get(c, "source_refs", []) || []
        label = c["label"] || "Chronik"
        Enum.map(refs, fn uid -> {uid, %{kind: "chronik", id: c["id"], label: label}} end)
      end)

    (summary_entries ++ epos_entries ++ chronik_entries)
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, entry} -> entry end)
  end

  # Issue #10: Sync-Index für den ColumnSync-JS-Hook. Pro Spalte +
  # Entry-ID die zugeordneten Utterance-IDs und umgekehrt — beide
  # Richtungen, weil der Master beliebig die Spalte sein kann in der
  # gerade gescrollt wird. Wird beim Mount + bei jedem snapshot-Reload
  # als JSON in `data-sync-index` am LV-Root re-rendered; der Hook liest
  # es im `updated()`-Lifecycle neu.
  #
  # Fallback bei fehlenden `source_refs` (alte Pre-#114-Seeds wie Romeo-
  # Schlegel): pro Summary/Chronik mit `session_id` werden ALLE
  # Utterances dieser Session als implizite Refs gemappt. So funktioniert
  # der Sync auch ohne explizite #114-Refs, nur dann session-granular
  # statt utterance-granular.
  defp build_sync_index(summaries, epos, chronik, utterances) do
    utts_by_session =
      utterances
      |> List.wrap()
      |> Enum.group_by(&(&1["session_id"] || &1[:session_id]), &(&1["id"] || &1[:id]))

    # Refs pro Entry: vorhandene source_refs ODER Fallback auf alle utts
    # der Session (für Summary + Chronik). Epos ohne refs → leer (keine
    # session_id-Basis).
    summary_refs =
      List.wrap(summaries)
      |> Enum.map(fn s ->
        refs = Map.get(s, "source_refs", []) || []
        refs = if refs == [], do: Map.get(utts_by_session, s["session_id"], []), else: refs
        {{"summaries", s["session_id"]}, refs}
      end)

    epos_refs =
      case epos do
        %{"source_refs" => refs, "id" => id} when is_list(refs) and refs != [] ->
          [{{"epos", id}, refs}]

        _ ->
          []
      end

    chronik_refs =
      List.wrap(chronik)
      |> Enum.map(fn c ->
        refs = Map.get(c, "source_refs", []) || []
        refs = if refs == [], do: Map.get(utts_by_session, c["session_id"], []), else: refs
        {{"chronik", c["id"]}, refs}
      end)

    all_entries = summary_refs ++ epos_refs ++ chronik_refs

    entries_to_utts =
      all_entries
      |> Enum.into(%{}, fn {{col, id}, refs} -> {"#{col}:#{id}", refs} end)

    # Invertierte Map: utt-id → [{col, id}, ...]
    utts_to_entries =
      all_entries
      |> Enum.flat_map(fn {{col, id}, refs} ->
        Enum.map(refs, fn uid -> {uid, %{"col" => col, "id" => to_string(id)}} end)
      end)
      |> Enum.group_by(fn {uid, _} -> uid end, fn {_, e} -> e end)

    # Issue #370: utt → session-id Mapping. Der Hook nutzt es als Fallback
    # wenn scrollSlaveTo eine collapsed Session trifft → triggert dann
    # protokoll_session_toggle via .click() statt im DOM nichts zu finden.
    utt_to_session =
      utterances
      |> List.wrap()
      |> Enum.into(%{}, fn u ->
        {u["id"] || u[:id], u["session_id"] || u[:session_id]}
      end)

    %{
      "utts_to_entries" => utts_to_entries,
      "entries_to_utts" => entries_to_utts,
      "utt_sessions" => utt_to_session
    }
  end

  # Issue #317: hierarchische Consent-Versionen — pro Aufnahme-Modus die
  # mindestens nötige Version. "v2" ist strikt-superset von "v1" (deckt Per-
  # Spieler-Punkte mit ab + die Single-Source-spezifischen Zusätze: Aufnahme
  # Dritter, Diarisierung, SL-Verantwortung).
  defp consent_version_for(:single_source), do: "v2"
  defp consent_version_for(_), do: "v1"

  @consent_version_order ["v1", "v2"]
  defp version_rank(v) when is_binary(v) do
    case Enum.find_index(@consent_version_order, &(&1 == v)) do
      nil -> 0
      i -> i + 1
    end
  end

  defp version_rank(_), do: 0

  # True wenn der bestehende Consent die für `mode` nötige Version mindestens
  # erfüllt (v2 deckt v1 mit ab).
  defp consent_satisfies?(nil, _mode), do: false

  defp consent_satisfies?(%{"version" => v}, mode),
    do: version_rank(v) >= version_rank(consent_version_for(mode))

  defp consent_satisfies?(%{version: v}, mode),
    do: version_rank(v) >= version_rank(consent_version_for(mode))

  defp consent_satisfies?(_, _), do: false

  # ─── Issue #391: Mic-Setup-State-Helpers ────────────────────────

  # Pegel kommt als Float 0.0..1.0 vom Hook — defensiv clampen (kaputter
  # Client / Rundungsdrift soll die VU-Bar-Width-Rechnung nicht sprengen).
  @doc false
  def clamp_level(level) when is_number(level), do: min(1.0, max(0.0, level / 1))
  def clamp_level(_), do: 0.0

  # Setzt alle Setup-Modal-Felder auf den Ausgangszustand zurück. Wird beim
  # Cancel, beim erfolgreichen Finish, bei mic_error und beim SessionEnded-
  # Teardown gerufen — überall wo das Setup-Modal verschwindet.
  defp reset_mic_setup_state(socket) do
    socket
    |> assign(:mic_setup_consent_required?, false)
    |> assign(:mic_setup_consent_acked?, false)
    |> assign(:mic_setup_consent_mode, nil)
    |> assign(:mic_setup_devices, %{devices: [], preferred_id: nil})
    |> assign(:mic_setup_local_level, 0.0)
    |> assign(:mic_setup_phrase, nil)
    |> assign(:mic_setup_checking?, false)
    |> assign(:mic_setup_last_transcript, nil)
    |> assign(:mic_setup_phrase_ok?, false)
    |> assign(:mic_setup_clip_req_id, nil)
    |> assign(:mic_setup_error, nil)
    |> assign(:pending_mic_session_id, nil)
    |> assign(:pending_mic_source, nil)
    |> assign(:pending_mic_device_id, nil)
  end

  # Öffnet das Setup-Modal für den Mic-Pfad (source=="mic"). consent_mode
  # bestimmt, ob das Consent-Häkchen mit-eingeblendet wird (required? = wenn
  # der bestehende Consent die für den Modus nötige Version NICHT erfüllt).
  defp open_mic_setup(socket, sid, consent_mode) do
    consent_ok = consent_satisfies?(socket.assigns.audio_consent, consent_mode)

    socket
    |> assign(:show_mic_setup?, true)
    |> assign(:mic_setup_consent_required?, not consent_ok)
    |> assign(:mic_setup_consent_acked?, false)
    |> assign(:mic_setup_consent_mode, consent_mode)
    |> assign(:mic_setup_local_level, 0.0)
    |> assign(:mic_setup_devices, %{devices: [], preferred_id: nil})
    # Issue #400: Test-Phrase ziehen, ASR-Status zurücksetzen.
    |> assign(:mic_setup_phrase, HubWeb.TestPhrases.random())
    |> assign(:mic_setup_checking?, false)
    |> assign(:mic_setup_last_transcript, nil)
    |> assign(:mic_setup_phrase_ok?, false)
    |> assign(:mic_setup_clip_req_id, nil)
    |> assign(:mic_setup_error, nil)
    |> assign(:pending_mic_session_id, sid)
    |> assign(:pending_mic_source, "mic")
    |> push_event("mic:setup_start", %{session_id: sid, source: "mic"})
  end

  @doc """
  Issue #400: toleranter Wort-Overlap zwischen erwarteter Test-Phrase und
  dem ASR-Transkript. Gibt true, wenn mindestens 60 % der erwarteten Wörter
  (normalisiert: downcase, Satzzeichen weg, Reihenfolge egal) im Transkript
  vorkommen. Bewusst tolerant — strenger WER würde echte Sprecher an
  Eigennamen-/ASR-Slips scheitern lassen. Leeres Transkript ⇒ false.
  """
  @phrase_match_threshold 0.6
  @spec phrase_match?(String.t(), String.t()) :: boolean()
  def phrase_match?(expected, transcript)
      when is_binary(expected) and is_binary(transcript) do
    expected_words = normalize_phrase(expected)
    transcript_words = MapSet.new(normalize_phrase(transcript))

    case expected_words do
      [] ->
        false

      words ->
        hits = Enum.count(words, &MapSet.member?(transcript_words, &1))
        hits / length(words) >= @phrase_match_threshold
    end
  end

  def phrase_match?(_, _), do: false

  # Downcase, alles außer Buchstaben/Ziffern/Whitespace raus, in Wörter splitten.
  # Unicode-aware (deutsche Umlaute bleiben erhalten).
  defp normalize_phrase(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
  end

  # Prüft kombiniert Phrase-Erkennung UND Consent — beide ok ⇒ Aufnahme
  # starten. Phrase-OK und Häkchen sind orthogonal (Reihenfolge egal), deshalb
  # wird der Helper aus beiden Triggern (clip_transcribed-Treffer +
  # mic_setup_consent_toggle) gerufen.
  # Pure Entscheidungslogik für das Setup-Finish, extrahiert für Unit-Tests
  # (Issue #391). voice_ok + consent_ok + gültige sid ⇒ :start; sonst :wait
  # (Modal offen lassen) oder :abort_no_session (sid verloren → Eskalation).
  @doc false
  def mic_setup_finish_decision(voice_ok, consent_ok, sid) do
    sid_ok = is_binary(sid) and sid != ""

    cond do
      not (voice_ok and consent_ok) -> :wait
      not sid_ok -> :abort_no_session
      true -> :start
    end
  end

  defp maybe_finish_mic_setup(socket) do
    voice_ok = socket.assigns.mic_setup_phrase_ok?

    consent_ok =
      not socket.assigns.mic_setup_consent_required? or
        socket.assigns.mic_setup_consent_acked?

    # WICHTIG: sid + device_id VOR jedem reset binden — sonst liest ein späterer
    # Read den nach reset_mic_setup_state genullten Wert (session_id: nil →
    # stummes Recording).
    sid = socket.assigns.pending_mic_session_id
    device_id = socket.assigns.pending_mic_device_id

    case mic_setup_finish_decision(voice_ok, consent_ok, sid) do
      :wait ->
        # User hat erst eines erfüllt → still warten, Modal bleibt offen.
        {:noreply, socket}

      :abort_no_session ->
        # sid verloren (z.B. paralleles SessionEnded → reset, dann verspätetes
        # Voice-OK). Voice ist one-shot, ohne Eskalation säße der User im toten
        # Modal — hart abbrechen mit Flash statt stumm hängen.
        {:noreply,
         socket
         |> assign(:show_mic_setup?, false)
         |> reset_mic_setup_state()
         |> push_event("mic:setup_abort", %{})
         |> put_flash(:error, "Session-Kontext verloren — bitte Mikro erneut starten.")}

      :start ->
        case maybe_publish_consent_event(socket) do
          {:ok, socket} ->
            # Issue #412: Setup ist durch → den schon offenen Setup-Stream
            # browser-lokal an die sticky MicLive/MicCapture übergeben
            # (mic:setup_handoff → window-CustomEvent). KEIN zweites
            # getUserMedia (Mobile lehnt das fürs selbe Device ab) und KEIN
            # per-User-PubSub-Broadcast mehr (der hätte sonst jedes weitere
            # Gerät desselben Users mit-getriggert → device_gone). MicLive
            # setzt seinen Recording-State aus mic_capture_started.
            {:noreply,
             socket
             |> assign(:show_mic_setup?, false)
             |> assign(:mic_on?, true)
             |> reset_mic_setup_state()
             |> push_event("mic:setup_handoff", %{
               campaign_id: socket.assigns.campaign_id,
               session_id: sid,
               source: "mic",
               device_id: device_id
             })
             |> push_event("signal:play", %{kind: "mic_join"})}

          {:error, reason} ->
            # Compliance-Hard-Stop: ohne persistiertes AudioConsentRecorded
            # darf KEINE Aufnahme laufen. Häkchen zurücksetzen, Modal offen
            # lassen, damit der User es erneut versuchen kann.
            {:noreply,
             socket
             |> assign(:mic_setup_consent_acked?, false)
             |> put_flash(
               :error,
               "Audio-Einverständnis konnte nicht gespeichert werden: #{inspect(reason)} — Aufnahme nicht gestartet."
             )}
        end
    end
  end

  # Publisht AudioConsentRecorded nur wenn im Setup ein Consent nötig war.
  # Behält die Error-as-Hard-Stop-Semantik des alten consent_accept-Handlers
  # bei. Setzt audio_consent lokal optimistic mit, damit ein direktes
  # mic_leave → mic_join nicht erneut das Häkchen zeigt (Snapshot-Reload
  # zöge viewer_audio_consent sonst erst Sekunden später nach).
  defp maybe_publish_consent_event(socket) do
    if socket.assigns.mic_setup_consent_required? do
      now = DateTime.utc_now()
      version = consent_version_for(socket.assigns.mic_setup_consent_mode)

      payload = %{
        "kind" => Shared.Events.audio_consent_recorded(),
        "discord_id" => socket.assigns.current_user.discord_id,
        "version" => version,
        "accepted_at" => DateTime.to_iso8601(now)
      }

      case EventBridge.publish(payload) do
        :ok ->
          {:ok,
           assign(socket, :audio_consent, %{
             "version" => version,
             "accepted_at" => DateTime.to_iso8601(now)
           })}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, socket}
    end
  end

  def handle_event("mic_leave", _, socket) do
    # Issue #259: optimistic state update — Tracker-Roundtrip lässt sonst den
    # Stop-Button stehen bis das nächste mic_streamers-Event ankommt.
    current_did = socket.assigns.current_user.discord_id
    streamers = List.delete(socket.assigns.mic_streamers || [], current_did)

    # Issue #392: graceful Worker-Signal — der Owner-Worker nimmt den Streamer
    # sofort aus der Presence, damit ANDERE Viewer ihn instant verschwinden
    # sehen (statt erst nach dem ~4s-Chunk-Recency-Sweep). Nur sinnvoll bei
    # aktiver Session.
    case socket.assigns.active_session do
      %{"id" => sid} ->
        Hub.Commands.mic_leave(current_did, socket.assigns.campaign_id, sid)

      %{id: sid} ->
        Hub.Commands.mic_leave(current_did, socket.assigns.campaign_id, sid)

      _ ->
        :ok
    end

    # Issue #405: Capture in der sticky MicLive stoppen (statt push an einen
    # CampaignLive-Hook — die Capture lebt nicht mehr hier).
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      HubWeb.MicLive.mic_topic(current_did),
      {:stop_capture}
    )

    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> assign(:mic_streamers, streamers)
     |> assign(:mic_levels, Map.delete(socket.assigns.mic_levels || %{}, current_did))
     |> push_event("signal:play", %{kind: "mic_leave"})}
  end

  # Issue #405: audio_chunk + mic_started leben jetzt in HubWeb.MicLive
  # (Capture-Owner). CampaignLive empfängt keine Audio-Chunks mehr — die
  # MicCapture-Hook-Events gehen an MicLive, das via forward_audio_chunk
  # an den Worker weiterleitet.

  # Issue #415: der MicCapture-Hook (sticky MicLive) meldet browser-lokal, ob
  # DIESER Browser gerade aufnimmt. Steuert den Drei-Wege-Button — speziell ob
  # „Mein Mikro stoppen" (hier aktiv) oder „Hier übernehmen" (Account nimmt auf
  # einem anderen Gerät auf) gezeigt wird.
  def handle_event("mic_local_state", %{"recording" => recording}, socket) do
    {:noreply, assign(socket, :recording_here?, recording == true)}
  end

  def handle_event("mic_error", %{"reason" => reason}, socket) do
    # Issue #391: Fehler kann auch mitten im Setup-Popup auftreten
    # (permission_denied, device_gone) — Setup-State mit aufräumen.
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> assign(:show_mic_setup?, false)
     |> reset_mic_setup_state()
     |> put_flash(:error, "Mikro nicht verfügbar: #{reason}")}
  end

  # ─── Epos events ─────────────────────────────────────────────────

  # ─── Resümee / Chronik / Utterance edit events (Issue #3) ───────

  def handle_event("summary_edit_start", %{"session" => sid}, socket) do
    current =
      Enum.find_value(socket.assigns.summaries, "", fn s ->
        if s["session_id"] == sid, do: s["content_md"], else: nil
      end)

    {:noreply, assign(socket, summary_editing: sid, summary_draft: current || "")}
  end

  def handle_event("summary_edit_cancel", _, socket) do
    {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}
  end

  def handle_event("vocab_edit_start", _, socket) do
    hint = (socket.assigns.campaign || %{})["vocab_hint"] || ""
    {:noreply, assign(socket, vocab_editing: true, vocab_draft: hint)}
  end

  def handle_event("vocab_edit_cancel", _, socket) do
    # Issue #270: schließt auch das Akkordeon-Tab.
    {:noreply, assign(socket, vocab_editing: false, vocab_draft: "", open_tab: nil)}
  end

  def handle_event("vocab_edit_save", %{"vocab_hint" => text}, socket) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :edit_vocab, campaign) do
      Hub.EventBridge.publish(%{
        "kind" => Shared.Events.campaign_vocab_updated(),
        "campaign_id" => socket.assigns.campaign_id,
        "vocab_hint" => String.slice(text, 0, 2000),
        "by_discord_id" => user.discord_id
      })

      # Issue #270: nach erfolgreichem Save schließt das Akkordeon-Tab.
      {:noreply, assign(socket, vocab_editing: false, vocab_draft: "", open_tab: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # Issue #270: exklusiver Tab-Toggle. Click auf einen bereits offenen
  # Tab schließt ihn (nil). Sonst neuer Tab open, alter schließt.
  def handle_event("toggle_tab", %{"tab" => tab_str}, socket) do
    next_tab =
      case {to_string(socket.assigns.open_tab), tab_str} do
        {same, same} -> nil
        {_, "pipeline"} -> :pipeline
        {_, "flavor"} -> :flavor
        {_, "vocab"} -> :vocab
        _ -> nil
      end

    # Wenn ein Tab geöffnet wird, die jeweiligen Edit-States vorbereiten/zurücksetzen,
    # damit der Tab-Inhalt direkt im Edit-Modus startet wo das sinnvoll ist.
    socket =
      case next_tab do
        :flavor ->
          flavors = (socket.assigns.campaign && socket.assigns.campaign["flavors"]) || %{}

          assign(socket,
            open_tab: :flavor,
            flavor_drafts: flavors,
            stil_stage: nil,
            preview_segments: [],
            preview_error: nil
          )

        :vocab ->
          hint = (socket.assigns.campaign || %{})["vocab_hint"] || ""
          assign(socket, open_tab: :vocab, vocab_editing: true, vocab_draft: hint)

        _ ->
          assign(socket, open_tab: next_tab, vocab_editing: false, flavor_editing?: false)
      end

    {:noreply, socket}
  end

  def handle_event("faithfulness_toggle", %{"session" => sid}, socket) do
    expanded = socket.assigns.faithfulness_expanded

    new_expanded =
      if MapSet.member?(expanded, sid),
        do: MapSet.delete(expanded, sid),
        else: MapSet.put(expanded, sid)

    {:noreply, assign(socket, :faithfulness_expanded, new_expanded)}
  end

  def handle_event("summary_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.can_edit_meta? and socket.assigns.summary_editing do
      bridge_publish(socket, %{
        "kind" => Shared.Events.session_summary_edited(),
        "session_id" => socket.assigns.summary_editing,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}
  end

  def handle_event("chronik_edit_start", %{"id" => id}, socket) do
    entry =
      Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end) || %{}

    # Issue #385: Edit-Draft ist ein einziger Markdown-String. Existierende
    # markdown_body bevorzugt, sonst aus in_game_date + label + summary
    # zusammengesetzt (Lazy-Migration alter Einträge).
    draft = chronik_entry_to_markdown(entry)

    {:noreply, assign(socket, chronik_editing: id, chronik_draft: draft)}
  end

  def handle_event("chronik_edit_cancel", _, socket) do
    {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}
  end

  def handle_event("chronik_edit_save", %{"chronik" => attrs}, socket) do
    id = socket.assigns.chronik_editing
    existing = Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end)

    if socket.assigns.can_edit_meta? and existing do
      md = attrs["markdown_body"] || ""
      {date, label} = parse_chronik_headings(md, existing)

      bridge_publish(socket, %{
        "kind" => Shared.Events.chronik_entry_changed(),
        "id" => id,
        "campaign_id" => socket.assigns.campaign_id,
        # Issue #385: in_game_date + label sind aus dem Markdown derived
        # (erste H1 / erste H2). Fehlt eine → alter Wert bleibt
        # (nicht-destruktiv).
        "in_game_date" => date,
        "label" => label,
        # Issue #385: summary wird NICHT mit dem rohen Markdown überschrieben
        # — Plaintext-Vertrag der BC-Spalte wahren.
        "summary" => existing["summary"],
        # Verbatim — kein Roundtrip-Verlust beim Re-Edit.
        "markdown_body" => md,
        "session_id" => existing["session_id"],
        "edited_by" => socket.assigns.current_user.discord_id,
        "source" => "manual"
      })
    end

    {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}
  end

  def handle_event("utterance_edit_start", %{"id" => id}, socket) do
    current =
      Enum.find_value(socket.assigns.utterances, "", fn u ->
        if u["id"] == id, do: u["text"], else: nil
      end)

    {:noreply, assign(socket, utterance_editing: id, utterance_draft: current || "")}
  end

  def handle_event("utterance_edit_cancel", _, socket) do
    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def handle_event("utterance_edit_save", %{"text" => text}, socket) do
    id = socket.assigns.utterance_editing
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if existing && can_edit_utterance?(socket, existing) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.utterance_edited(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "new_text" => text,
        "edited_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def handle_event("utterance_delete", %{"id" => id}, socket) do
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if existing && can_edit_utterance?(socket, existing) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.utterance_deleted(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "deleted_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, socket}
  end

  def handle_event("utterance_add_start", %{"session" => sid}, socket) do
    {:noreply,
     assign(socket,
       utterance_adding: sid,
       utterance_add_speaker: socket.assigns.current_user.discord_id,
       utterance_add_text: ""
     )}
  end

  def handle_event("utterance_add_cancel", _, socket) do
    {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
  end

  def handle_event(
        "utterance_add_save",
        %{"speaker" => speaker, "text" => text},
        socket
      ) do
    sid = socket.assigns.utterance_adding
    cleaned = text |> to_string() |> String.trim()
    member_dids = Enum.map(socket.assigns.members || [], & &1["discord_id"])

    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}

      sid in [nil, ""] or cleaned == "" or speaker not in member_dids ->
        {:noreply, socket}

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.utterance_appended(),
          "id" => UUIDv7.generate(),
          "session_id" => sid,
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => speaker,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "text" => cleaned,
          "confidence" => nil,
          "status" => "manual"
        })

        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
    end
  end

  # ─── Stil / Vorgabe pro Stage (Issue #313) ─────────────────────

  # Reiter angeklickt: Drafts laden (Ton aus flavors, Vorgabe aus campaign)
  # + Prompt-Vorschau-Segmente synchron vom Worker holen.
  def handle_event("stil_stage", %{"stage" => stage}, socket)
      when stage in ["summary", "epos", "chronik"] do
    flavors = current_flavors(socket)
    campaign = socket.assigns.campaign || %{}
    vorgabe = get_in(campaign, ["vorgaben", stage]) || %{}

    {segments, error} =
      case Hub.PromptPreview.preview(socket.assigns.campaign_id, stage) do
        {:ok, segs} -> {segs, nil}
        {:error, reason} -> {[], reason}
      end

    flavor_drafts = %{
      "base" => Map.get(flavors, "base", ""),
      stage => Map.get(flavors, stage, "")
    }

    vorgabe_drafts = %{
      "name" => str_or_empty(vorgabe["name"]),
      "darstellungsform" => str_or_default(vorgabe["darstellungsform"], "fliesstext")
    }

    {:noreply,
     assign(socket,
       stil_stage: stage,
       preview_segments: segments,
       preview_error: error,
       flavor_drafts: flavor_drafts,
       vorgabe_drafts: vorgabe_drafts
     )}
  end

  def handle_event("stil_close", _, socket) do
    {:noreply, assign(socket, stil_stage: nil, preview_segments: [], preview_error: nil)}
  end

  # Issue #320: Live-Vorschau. phx-change beim Tippen — holt den echten Prompt
  # vom Worker mit den AKTUELLEN Entwürfen als `overrides`, damit man byte-genau
  # sieht wie der Prompt sich ändert (auch eine neu getippte Überschrift, die im
  # gespeicherten Stand noch fehlt). phx-debounce throttlet die Roundtrips.
  def handle_event("stil_preview", params, socket) when is_binary(socket.assigns.stil_stage) do
    stage = socket.assigns.stil_stage

    flavor_drafts = %{
      "base" => Map.get(params, "base", socket.assigns.flavor_drafts["base"] || ""),
      stage => Map.get(params, stage, Map.get(socket.assigns.flavor_drafts, stage, ""))
    }

    vorgabe_drafts = %{
      "name" => Map.get(params, "name", socket.assigns.vorgabe_drafts["name"] || ""),
      "darstellungsform" =>
        Map.get(
          params,
          "darstellungsform",
          socket.assigns.vorgabe_drafts["darstellungsform"] || "fliesstext"
        )
    }

    overrides = %{
      "flavors" => flavor_drafts,
      "vorgaben" => %{stage => vorgabe_drafts}
    }

    {segments, error} =
      case Hub.PromptPreview.preview(socket.assigns.campaign_id, stage, overrides) do
        {:ok, segs} -> {segs, nil}
        {:error, reason} -> {socket.assigns.preview_segments, reason}
      end

    {:noreply,
     assign(socket,
       flavor_drafts: flavor_drafts,
       vorgabe_drafts: vorgabe_drafts,
       preview_segments: segments,
       preview_error: error
     )}
  end

  def handle_event("stil_preview", _params, socket), do: {:noreply, socket}

  def handle_event("stil_save", %{"stage" => stage} = params, socket)
      when stage in ["summary", "epos", "chronik"] do
    if socket.assigns.can_edit_meta? do
      current = current_flavors(socket)
      did = socket.assigns.current_user.discord_id

      maybe_flavor_event(socket, "base", current, params["base"], did)
      maybe_flavor_event(socket, stage, current, params[stage], did)

      name = clean_flavor(params["name"])
      form = params["darstellungsform"] || "fliesstext"
      # Nur Default (kein Name + Fließtext) ⇒ Row löschen (name+form nil).
      {vname, vform} =
        if is_nil(name) and form == "fliesstext", do: {nil, nil}, else: {name, form}

      bridge_publish(socket, %{
        "kind" => Shared.Events.campaign_vorgabe_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "stage" => stage,
        "name" => vname,
        "darstellungsform" => vform,
        "set_by" => did
      })
    end

    {:noreply,
     socket
     |> assign(stil_stage: nil, preview_segments: [], preview_error: nil)
     |> put_flash(:info, "Stil gespeichert.")}
  end

  defp maybe_flavor_event(socket, slot, current, raw, did) do
    old = Map.get(current, slot)
    new = clean_flavor(raw)

    if old != new do
      bridge_publish(socket, %{
        "kind" => Shared.Events.campaign_flavor_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "slot" => slot,
        "flavor" => new,
        "edited_by" => did
      })
    end
  end

  defp str_or_empty(s) when is_binary(s), do: s
  defp str_or_empty(_), do: ""
  defp str_or_default(s, _d) when is_binary(s) and s != "", do: s
  defp str_or_default(_s, d), do: d

  # ─── Kampagne löschen (Issue #15) ────────────────────────────────

  def handle_event("campaign_delete_request", _, socket) do
    {:noreply, assign(socket, delete_confirming?: true, delete_typed_name: "")}
  end

  def handle_event("campaign_delete_cancel", _, socket) do
    {:noreply, assign(socket, delete_confirming?: false, delete_typed_name: "")}
  end

  def handle_event("campaign_delete_typing", %{"name" => typed}, socket) do
    {:noreply, assign(socket, delete_typed_name: typed)}
  end

  def handle_event("campaign_delete_confirm", %{"name" => typed}, socket) do
    expected = (socket.assigns.campaign || %{})["name"] || ""

    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply, put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen löschen.")}

      String.trim(typed) != expected ->
        {:noreply,
         put_flash(socket, :error, "Kampagnenname stimmt nicht — Löschung abgebrochen.")}

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.campaign_deleted(),
          "campaign_id" => socket.assigns.campaign_id,
          "deleted_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "Kampagne '#{expected}' gelöscht.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # Issue #294: Einzelne Session unwiderruflich löschen. Sicherheitsabfrage
  # passiert per `data-confirm` am Button — danach feuert dieses Event den
  # SessionDeleted-Cascade (Utterances + Marker + Resümee + Faithfulness +
  # Chronik-Einträge + Speaker-Zuordnungen + Session-Row).
  def handle_event("session_delete", %{"session" => sid}, socket) do
    campaign = perm_campaign(socket)

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :delete_session, campaign) ->
        {:noreply,
         put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Sessions löschen.")}

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.session_deleted(),
          "session_id" => sid,
          "campaign_id" => campaign.id,
          "deleted_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "Session gelöscht.")
         |> assign(:expanded_sessions, MapSet.delete(socket.assigns.expanded_sessions, sid))}
    end
  end

  # ─── Member-Popup (Issue #270) ──────────────────────────────────

  def handle_event("open_member_popup", %{"discord_id" => did}, socket) do
    {:noreply, assign(socket, :member_popup_open_for, did)}
  end

  def handle_event("close_member_popup", _, socket) do
    {:noreply, assign(socket, :member_popup_open_for, nil)}
  end

  # ─── Member entfernen (Issue #55 / 52A) ─────────────────────────

  def handle_event("member_remove_request", %{"discord_id" => did}, socket) do
    {:noreply, assign(socket, remove_confirm_did: did)}
  end

  def handle_event("member_remove_cancel", _, socket) do
    {:noreply, assign(socket, remove_confirm_did: nil)}
  end

  def handle_event("member_remove_confirm", %{"discord_id" => did}, socket) do
    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply,
         socket
         |> put_flash(:error, "Nur Spielleiter oder Admin dürfen Mitspieler entfernen.")
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}

      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Der letzte Spielleiter kann nicht entfernt werden. Befördere erst eine andere Mitspielerin."
         )
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}

      true ->
        display =
          display_for(did, socket.assigns.users, socket.assigns.character_names)

        bridge_publish(socket, %{
          "kind" => Shared.Events.member_removed(),
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => did,
          "removed_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "#{display} aus der Kampagne entfernt.")
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}
    end
  end

  # ─── Promote / Demote (Issue #140 Phase B) ──────────────────────

  def handle_event("member_promote", %{"discord_id" => did}, socket) do
    socket
    |> assign(:member_popup_open_for, nil)
    |> handle_role_change(did, :spielleiter)
  end

  def handle_event("member_demote_request", %{"discord_id" => did}, socket) do
    {:noreply, assign(socket, demote_confirm_did: did)}
  end

  def handle_event("member_demote_cancel", _, socket) do
    {:noreply, assign(socket, demote_confirm_did: nil)}
  end

  def handle_event("member_demote_confirm", %{"discord_id" => did}, socket) do
    cond do
      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Letzter Spielleiter — Demote würde die Kampagne führungslos lassen."
         )
         |> assign(demote_confirm_did: nil, member_popup_open_for: nil)}

      true ->
        socket
        |> assign(demote_confirm_did: nil, member_popup_open_for: nil)
        |> handle_role_change(did, :spieler)
    end
  end

  defp handle_role_change(socket, did, new_role)
       when new_role in [:spielleiter, :spieler] do
    cond do
      not HubWeb.Permissions.can?(
        socket.assigns.perm_user,
        :promote_member,
        socket.assigns.campaign
      ) ->
        {:noreply, put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Rollen ändern.")}

      true ->
        display = display_for(did, socket.assigns.users, socket.assigns.character_names)

        bridge_publish(socket, %{
          "kind" => Shared.Events.member_role_promoted(),
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => did,
          "new_role" => Atom.to_string(new_role),
          "promoted_by" => socket.assigns.current_user.discord_id
        })

        flash =
          case new_role do
            :spielleiter -> "#{display} ist jetzt Spielleiter dieser Kampagne."
            :spieler -> "#{display} ist jetzt Spieler dieser Kampagne."
          end

        {:noreply, put_flash(socket, :info, flash)}
    end
  end

  defp last_spielleiter?(members, did) do
    sls =
      Enum.filter(members, fn m ->
        m["role"] in ["spielleiter", "owner"]
      end)

    case sls do
      [%{"discord_id" => only_did}] -> only_did == did
      _ -> false
    end
  end

  defp member_sl?(m), do: m["role"] in ["spielleiter", "owner"]

  # Permission-Helper (Issue #36): Spieler darf nur eigene Utterances
  # ändern/löschen. Owner+Admin dürfen alle. Akzeptiert socket ODER
  # assigns-Map (für Template-Aufrufe).
  defp can_edit_utterance?(%{assigns: assigns}, utterance),
    do: can_edit_utterance?(assigns, utterance)

  defp can_edit_utterance?(assigns, utterance) when is_map(assigns) do
    assigns.can_edit_meta? or
      utterance["discord_id"] == assigns.current_user.discord_id
  end

  # Issue #313: Ausgabe-Überschrift pro Stage — aus der Vorgabe oder Default.
  defp default_output_label("summary"), do: "Resümee"
  defp default_output_label("epos"), do: "Epos"
  defp default_output_label("chronik"), do: "Chronik"
  defp default_output_label(_), do: ""

  defp output_label(campaign, stage) do
    case get_in(campaign || %{}, ["vorgaben", stage, "name"]) do
      n when is_binary(n) and n != "" -> n
      _ -> default_output_label(stage)
    end
  end

  # „gesetzt" = eigener Name ODER abweichende Darstellungsform (nicht default).
  defp vorgabe_set?(campaign, stage) do
    v = get_in(campaign || %{}, ["vorgaben", stage]) || %{}
    name_set = is_binary(v["name"]) and v["name"] != ""

    form_set =
      is_binary(v["darstellungsform"]) and v["darstellungsform"] not in ["", "fliesstext"]

    name_set or form_set
  end

  defp editable_slot_label("base", _stage), do: "Ton (allgemein)"
  defp editable_slot_label("name", _stage), do: "Überschrift"
  defp editable_slot_label(slot, _stage), do: "Ton (#{default_output_label(slot)})"

  # Issue #320: feste Farbe pro Stil-Feld — das Eingabefeld und die Live-
  # Einblendung im Prompt teilen dieselbe Farbe, damit man Feld↔Position im
  # Prompt zuordnen kann. base=cyan, Stage-Ton=grün, Überschrift=amber.
  # Klassen als Literale, damit Tailwinds JIT sie generiert.
  defp slot_field_class("base"),
    do: "text-primary border-primary/60 bg-primary/10 focus:border-primary"

  defp slot_field_class("name"),
    do: "text-warning border-warning/60 bg-warning/10 focus:border-warning"

  defp slot_field_class(_),
    do: "text-success border-success/60 bg-success/10 focus:border-success"

  defp slot_text_class("base"), do: "text-primary"
  defp slot_text_class("name"), do: "text-warning"
  defp slot_text_class(_), do: "text-success"

  defp slot_dim_class("base"), do: "text-primary/40"
  defp slot_dim_class("name"), do: "text-warning/40"
  defp slot_dim_class(_), do: "text-success/40"

  # Issue #291: Markdown → HTML für Resümee/Epos/Chronik-Anzeige.
  # LLM-Output ist intern → escape: false (Earmark gibt semantisches HTML).
  # Bei Parse-Warnings liefert Earmark trotzdem brauchbares HTML, daher
  # akzeptieren wir auch :error-Variante.
  defp render_md(nil), do: ""
  defp render_md(""), do: ""

  defp render_md(text) when is_binary(text) do
    case Earmark.as_html(text, escape: false) do
      {:ok, html, _} -> Phoenix.HTML.raw(html)
      {:error, html, _} -> Phoenix.HTML.raw(html)
    end
  end

  @doc """
  Issue #385: convertet einen Chronik-Eintrag in seine Markdown-Repräsentation
  für die Edit-Textarea. Konvention: `# in_game_date\\n## label\\n\\nBody`.
  H1 + H2 sind syntaktisch eindeutig getrennt — kein Delimiter-Konflikt.

  - `markdown_body` (neuer Eintrag) wird verbatim zurückgegeben.
  - Sonst aus den drei alten Feldern zusammengesetzt (Lazy-Migration-Start).
  - Leere Felder werden weggelassen.
  """
  @spec chronik_entry_to_markdown(map()) :: String.t()
  def chronik_entry_to_markdown(entry) do
    md = entry["markdown_body"]

    if is_binary(md) and md != "" do
      md
    else
      date = entry["in_game_date"] || ""
      label = entry["label"] || ""
      body = entry["summary"] || ""

      [
        if(date != "", do: "# #{date}", else: nil),
        if(label != "", do: "## #{label}", else: nil),
        if(body != "", do: "\n#{body}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  @doc """
  Issue #385: parsed die ersten H1 + H2 aus dem Edit-Textarea-Markdown
  und liefert das Tupel `{in_game_date, label}` zurück. Beide sind
  unabhängig parsbar (verschiedene Heading-Levels) — kein Mehrdeutigkeits-
  Risiko wie bei einem `: `-Delimiter.

  - Erste line-anchored H1 (`# Text`) → in_game_date
  - Erste line-anchored H2 (`## Text`) → label
  - Fehlt eine → alter Wert aus `existing` (nicht-destruktiv)
  """
  @spec parse_chronik_headings(String.t(), map()) :: {String.t() | nil, String.t() | nil}
  def parse_chronik_headings(md, existing) when is_binary(md) and is_map(existing) do
    date =
      case Regex.run(~r/^#\s+([^\n]+)/m, md) do
        [_, text] -> String.trim(text)
        _ -> existing["in_game_date"]
      end

    label =
      case Regex.run(~r/^##\s+([^\n]+)/m, md) do
        [_, text] -> String.trim(text)
        _ -> existing["label"]
      end

    {date, label}
  end

  @doc """
  Issue #385: Markdown → HTML für **user-editierten** Inhalt (Chronik-Body).
  Defense-in-Depth: `escape: true` neutralisiert literales HTML schon vor
  dem Sanitizer (z.B. `<script>` wird zu `&lt;script&gt;` bevor
  HtmlSanitizeEx es sieht), HtmlSanitizeEx.basic_html/1 ist die zweite
  Schicht.

  Wichtig: bewusst NICHT `render_md/1` benutzen — der nutzt `escape: false`
  für deterministischen LLM-Output, was bei User-Input gefährlich wäre.
  """
  def render_md_safe(nil), do: ""
  def render_md_safe(""), do: ""

  def render_md_safe(text) when is_binary(text) do
    html =
      case Earmark.as_html(text, escape: true) do
        {:ok, h, _} -> h
        {:error, h, _} -> h
      end

    html
    |> HtmlSanitizeEx.basic_html()
    |> Phoenix.HTML.raw()
  end

  # Issue #291: gestripptes Plain-Text für Vorschauen mit line-clamp (Chronik).
  # Überschriften/Listen-Marker/Inline-Marker raus, damit die 3-Zeilen-Vorschau
  # nicht „# …" oder „**…**" zeigt.
  defp strip_md(nil), do: ""

  defp strip_md(text) when is_binary(text) do
    text
    |> String.replace(~R/^\s*#{1,6}\s+/m, "")
    |> String.replace(~r/^\s*[->]\s+/m, "")
    |> String.replace(~r/^\s*[*+]\s+/m, "")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/\*([^*]+)\*/, "\\1")
    |> String.replace(~r/_([^_]+)_/, "\\1")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
  end

  # Issue #291: Tailwind-Arbitrary-Variants stylen das gerenderte Markdown
  # ohne @tailwindcss/typography-Plugin. Klassen sind literal → JIT erkennt sie.
  defp prose_classes do
    "[&_h1]:text-base [&_h1]:font-semibold [&_h1]:mt-3 [&_h1]:mb-1 " <>
      "[&_h2]:text-sm [&_h2]:font-semibold [&_h2]:mt-2 [&_h2]:mb-1 " <>
      "[&_h3]:text-sm [&_h3]:font-medium [&_h3]:mt-2 [&_h3]:mb-1 " <>
      "[&_p]:my-1 [&_strong]:font-semibold [&_em]:italic " <>
      "[&_ul]:list-disc [&_ul]:pl-5 [&_ul]:my-1 " <>
      "[&_ol]:list-decimal [&_ol]:pl-5 [&_ol]:my-1 " <>
      "[&_li]:my-0.5 " <>
      "[&_blockquote]:border-l-2 [&_blockquote]:border-bg-3/60 [&_blockquote]:pl-3 [&_blockquote]:italic [&_blockquote]:text-ink-2 [&_blockquote]:my-1 " <>
      "[&_code]:bg-bg-0/60 [&_code]:px-1 [&_code]:rounded [&_code]:text-[11px] " <>
      "[&_a]:text-accent [&_a]:underline"
  end

  defp current_flavors(socket) do
    case (socket.assigns.campaign || %{})["flavors"] do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp clean_flavor(nil), do: nil

  defp clean_flavor(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      text -> String.slice(text, 0, 2000)
    end
  end

  # ─── Alias events (Issue #2) ─────────────────────────────────────

  def handle_event("alias_edit_start", _, socket) do
    current =
      Map.get(socket.assigns.character_names, socket.assigns.current_user.discord_id, "")

    {:noreply,
     assign(socket, alias_mode: :edit, alias_draft: current, member_popup_open_for: nil)}
  end

  def handle_event("alias_edit_cancel", _, socket) do
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("alias_edit_reset", _, socket) do
    publish_alias(socket, nil)
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("alias_edit_save", %{"character_name" => name}, socket) do
    trimmed = String.trim(name)
    cleaned = if trimmed == "", do: nil, else: String.slice(trimmed, 0, 80)

    publish_alias(socket, cleaned)
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("epos_edit_start", _, socket) do
    if socket.assigns.is_member? do
      current = (socket.assigns.epos && socket.assigns.epos["content_md"]) || ""
      {:noreply, assign(socket, epos_mode: :edit, epos_draft: current)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("epos_edit_cancel", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.is_member? do
      bridge_publish(socket, %{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => socket.assigns.campaign_id,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id,
        "source" => "manual"
      })
    end

    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_diff_open", %{"seq" => seq_str}, socket) do
    seq = String.to_integer(seq_str)
    {:noreply, assign(socket, epos_mode: :diff, epos_diff_seq: seq)}
  end

  def handle_event("epos_diff_close", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_diff_seq: nil)}
  end

  # ─── Column collapse/restore (Issue #8) ─────────────────────────

  def handle_event("col_toggle", %{"col" => col}, socket) when col in @col_names do
    current = socket.assigns.collapsed_cols

    next =
      if MapSet.member?(current, col) do
        MapSet.delete(current, col)
      else
        candidate = MapSet.put(current, col)
        # Mindestens eine Spalte muss offen bleiben — sonst Toggle ignorieren.
        if MapSet.size(candidate) >= length(@col_names), do: current, else: candidate
      end

    {:noreply,
     socket
     |> assign(:collapsed_cols, next)
     |> push_event("persist_cols", %{collapsed: MapSet.to_list(next)})}
  end

  def handle_event("col_toggle", _, socket), do: {:noreply, socket}

  # Issue #207: Protokoll-Sessions kollabier-/aufklappbar. Toggle pro
  # session_id; mehrere parallel offen erlaubt.
  def handle_event("protokoll_session_toggle", %{"session" => sid}, socket) do
    current = socket.assigns.expanded_sessions

    next =
      if MapSet.member?(current, sid),
        do: MapSet.delete(current, sid),
        else: MapSet.put(current, sid)

    {:noreply, assign(socket, :expanded_sessions, next)}
  end

  def handle_event("col_restore", %{"collapsed" => list}, socket) when is_list(list) do
    valid = list |> Enum.filter(&(&1 in @col_names)) |> MapSet.new()
    # Falls aus LS alle vier kommen, droppe eine — Invariante „mind. 1 offen".
    valid =
      if MapSet.size(valid) >= length(@col_names),
        do: MapSet.delete(valid, "protokoll"),
        else: valid

    {:noreply, assign(socket, :collapsed_cols, valid)}
  end

  def handle_event("col_restore", _, socket), do: {:noreply, socket}

  # ─── Invite + shutdown events (unchanged) ───────────────────────

  def handle_event("create_invite", _, socket) do
    if socket.assigns.owner? do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      bridge_publish(socket, %{
        "kind" => Shared.Events.invite_created(),
        "token" => token,
        "campaign_id" => socket.assigns.campaign_id,
        "created_by_discord_id" => socket.assigns.current_user.discord_id,
        "expires_at" => nil
      })

      url = HubWeb.Endpoint.url() <> "/invite/#{token}"
      {:noreply, assign(socket, :invite_url, url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_invite_url", _, socket),
    do: {:noreply, assign(socket, :invite_url, nil)}

  def handle_event("revoke_invite", %{"token" => token}, socket) do
    if socket.assigns.owner? do
      bridge_publish(socket, %{
        "kind" => Shared.Events.invite_revoked(),
        "token" => token,
        "campaign_id" => socket.assigns.campaign_id
      })
    end

    {:noreply, socket}
  end

  def handle_event("shutdown_worker", _, socket) do
    if socket.assigns.owner? do
      n = Commands.shutdown_my_workers(socket.assigns.current_user.discord_id)
      {:noreply, put_flash(socket, :info, "Shutdown an #{n} Worker geschickt.")}
    else
      {:noreply, socket}
    end
  end

  # ─── Event stream ────────────────────────────────────────────────

  @impl true
  def handle_info(
        {:event_appended, %{payload: %{"kind" => "UtteranceAppended"} = payload}},
        socket
      ) do
    if session_in_campaign?(socket, payload["session_id"]) do
      utterance = %{
        "id" => payload["id"],
        "session_id" => payload["session_id"],
        "discord_id" => payload["discord_id"],
        "timestamp" => payload["timestamp"],
        "text" => payload["text"],
        "confidence" => payload["confidence"],
        "status" => payload["status"] || "confirmed"
      }

      {:noreply, update(socket, :utterances, &(&1 ++ [utterance]))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "MarkerAdded"} = payload}}, socket) do
    if session_in_campaign?(socket, payload["session_id"]) do
      {:noreply, update(socket, :markers, &(&1 ++ [payload]))}
    else
      {:noreply, socket}
    end
  end

  # UtteranceEdited / UtteranceDeleted eager auf die utterances-Liste anwenden
  # damit die geänderte Zeile sofort sichtbar ist — ohne auf den 150ms-Reload
  # (Race mit Worker-Materialisierung) zu warten. Der reguläre Snapshot-Reload
  # passiert trotzdem über den catch-all unten, das ist nur eine Beschleunigung.
  def handle_info({:event_appended, %{payload: %{"kind" => "UtteranceEdited"} = payload}}, socket) do
    if session_in_campaign?(socket, payload["session_id"]) do
      id = payload["id"]
      new_text = payload["new_text"] || ""

      updated =
        Enum.map(socket.assigns.utterances, fn u ->
          if u["id"] == id do
            u |> Map.put("text", new_text) |> Map.put("status", "edited")
          else
            u
          end
        end)

      Process.send_after(self(), :reload, 150)
      {:noreply, assign(socket, :utterances, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:event_appended, %{payload: %{"kind" => "UtteranceDeleted"} = payload}},
        socket
      ) do
    if session_in_campaign?(socket, payload["session_id"]) do
      id = payload["id"]
      updated = Enum.reject(socket.assigns.utterances, fn u -> u["id"] == id end)
      Process.send_after(self(), :reload, 150)
      {:noreply, assign(socket, :utterances, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "SessionEnded"} = payload}}, socket) do
    Process.send_after(self(), :reload, 150)

    # Issue #355 Bug-Fix: SessionEnded für die Session die der User gerade
    # stoppen wollte → stopping_session_id-Filter clearen, damit die nächste
    # Aufnahme nicht aus Versehen weiterhin unsichtbar wäre.
    sid = payload["id"]

    socket =
      if socket.assigns[:stopping_session_id] == sid do
        assign(socket, :stopping_session_id, nil)
      else
        socket
      end

    # Issue #391: genau EINEN Teardown-Pfad pushen — mic:stop fürs laufende
    # Recording, mic:setup_abort wenn der User noch im Setup-Modal steht
    # (Stream + AudioCtx offen, aber mic_on? noch false). Sonst hängt der
    # Setup-Stream wenn die Session während des Setups endet.
    # Issue #405: Recording-Capture stoppt MicLive selbst (es subscribt
    # SessionEnded). CampaignLive räumt nur seinen Display-State + den
    # Setup-Stream falls der User mitten im Setup-Popup stand.
    socket =
      cond do
        socket.assigns.mic_on? ->
          socket
          |> assign(:mic_on?, false)
          |> assign(:mic_streamers, [])
          |> assign(:mic_levels, %{})

        socket.assigns.show_mic_setup? ->
          socket
          |> assign(:show_mic_setup?, false)
          |> reset_mic_setup_state()
          |> push_event("mic:setup_abort", %{})

        true ->
          socket
      end

    {:noreply, push_event(socket, "signal:play", %{kind: "session_end"})}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "SessionStarted"} = payload}}, socket) do
    Process.send_after(self(), :reload, 150)

    # Issue #207: neue Session sofort expandieren, damit Live-Utterances
    # nicht in einer zugeklappten Sektion landen.
    socket =
      case payload["id"] do
        sid when is_binary(sid) ->
          assign(socket, :expanded_sessions, MapSet.put(socket.assigns.expanded_sessions, sid))

        _ ->
          socket
      end

    {:noreply, push_event(socket, "signal:play", %{kind: "session_start"})}
  end

  def handle_info(
        {:event_appended, %{payload: %{"kind" => "RecordingStateChanged", "state" => state}}},
        socket
      ) do
    Process.send_after(self(), :reload, 150)

    kind =
      case state do
        "recording" -> "rec_start"
        "idle" -> "rec_stop"
        _ -> nil
      end

    socket = if kind, do: push_event(socket, "signal:play", %{kind: kind}), else: socket
    {:noreply, socket}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ~w(
        CampaignUpdated SessionScheduled
        InviteCreated InviteRevoked InviteRedeemed
        MemberRemoved EposEntryEdited CampaignAliasSet UserUpserted
        SessionSummaryGenerated SessionSummaryEdited ChronikEntryChanged
        CampaignFlavorSet CampaignVorgabeSet CampaignVocabUpdated
        UserRoleSet AdminMemberAdded
        SpeakerAssigned SessionDeleted
      ) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  # Wenn die Kampagne gerade gelöscht wird, navigate weg statt zu reloaden
  # (Reload würde "kampagne nicht gefunden" werfen).
  def handle_info(
        {:event_appended, %{payload: %{"kind" => "CampaignDeleted", "campaign_id" => cid}}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      {:noreply,
       socket
       |> put_flash(:info, "Kampagne wurde gelöscht.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  # Issue #321: reaktive Reloads async + coalesced. Mehrere Stage-Events feuern
  # je ein :reload (send_after 150ms) → hier gebündelt: läuft schon ein Read
  # (:running), nur dirty markieren (kein Doppel-Start), sonst async starten.
  def handle_info(:reload, %{assigns: %{reload_state: :running}} = socket),
    do: {:noreply, assign(socket, :reload_dirty?, true)}

  def handle_info(:reload, socket), do: {:noreply, start_snapshot_load(socket)}

  # Issue #321: Ergebnis des async-Snapshot-Reads anwenden; danach Nachlauf,
  # falls während des Reads Events reinkamen (dirty).
  @impl true
  def handle_async(:reload_snapshot, {:ok, result}, socket) do
    socket =
      socket
      |> apply_snapshot(result)
      |> assign(:reload_state, :idle)

    socket =
      if socket.assigns.reload_dirty? do
        socket |> assign(:reload_dirty?, false) |> schedule_reload()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:reload_snapshot, {:exit, reason}, socket) do
    Logger.warning("CampaignLive: Snapshot-Reload abgebrochen: #{inspect(reason)}")
    {:noreply, assign(socket, :reload_state, :idle)}
  end

  # Issue #215: bridge_publish/2 schickt diese Self-Message bei :no_worker_online,
  # damit der User die fehlgeschlagene Aktion sieht (vorher silent fail).
  def handle_info({:bridge_publish_failed, _kind}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Aktion konnte gerade nicht ausgeführt werden — kein passender Worker für diese Kampagne online. Bitte gleich nochmal versuchen."
     )}
  end

  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, start_snapshot_load(socket)}

  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status} =
           payload},
        socket
      ) do
    handle_pipeline_stage(cid, stage, status, payload["error"], socket)
  end

  # Older pipeline_status payloads (no explicit "kind") — keep matching the
  # stage shape so existing emitters that didn't tag a kind still work.
  def handle_info(
        {:pipeline_status,
         %{"campaign_id" => cid, "stage" => stage, "status" => status} = payload},
        socket
      ) do
    handle_pipeline_stage(cid, stage, status, payload["error"], socket)
  end

  # Issue #405: MicLive (sticky Capture-Owner) meldet einen Capture-Fehler
  # zurück (Device weg, Permission, kein Codec). Button zurücksetzen + Flash.
  def handle_info({:mic_capture_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> put_flash(:error, "Mikro-Aufnahme fehlgeschlagen: #{reason}")}
  end

  # Issue #400: transkribierter Mic-Setup-Phrasen-Clip. Nur reagieren wenn das
  # Setup noch offen ist UND die request_id zur zuletzt geschickten passt
  # (verspätete Antworten alter Clips ignorieren).
  def handle_info({:clip_transcribed, req_id, text}, socket) do
    if socket.assigns.show_mic_setup? and req_id == socket.assigns.mic_setup_clip_req_id do
      phrase = socket.assigns.mic_setup_phrase
      transcript = String.trim(text || "")

      socket =
        socket
        |> assign(:mic_setup_checking?, false)
        |> assign(:mic_setup_clip_req_id, nil)
        |> assign(:mic_setup_last_transcript, transcript)

      if phrase && phrase_match?(phrase.text, transcript) do
        # Treffer → Finish-Gate erfüllt; maybe_finish prüft zusätzlich Consent.
        socket
        |> assign(:mic_setup_phrase_ok?, true)
        |> maybe_finish_mic_setup()
      else
        # Daneben → automatisch weiter lauschen (kein Button, keine User-Aktion).
        {:noreply, push_event(socket, "mic:setup_listen_again", %{})}
      end
    else
      {:noreply, socket}
    end
  end

  # Issue #400: ASR-Antwort blieb aus (Worker hängt / Whisper langsam). Setup
  # bleibt offen, erneut lauschen. Nur greifen wenn diese req_id noch die
  # aktuelle ist und noch kein Treffer kam.
  def handle_info({:clip_timeout, req_id}, socket) do
    if socket.assigns.show_mic_setup? and socket.assigns.mic_setup_checking? and
         req_id == socket.assigns.mic_setup_clip_req_id and
         not socket.assigns.mic_setup_phrase_ok? do
      {:noreply,
       socket
       |> assign(:mic_setup_checking?, false)
       |> assign(:mic_setup_clip_req_id, nil)
       |> assign(
         :mic_setup_error,
         "Zeitüberschreitung beim Audio-Test — bitte erneut sprechen."
       )
       |> push_event("mic:setup_listen_again", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:pipeline_status,
         %{"kind" => "mic_streamers", "campaign_id" => cid, "discord_ids" => dids}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      dids = dids || []

      # Issue #391: Pegel von Usern die nicht mehr streamen entfernen.
      keep = dids

      # Issue #405: Button-State (Join/Leave) aus der Worker-Truth ableiten —
      # so zeigt die Bar nach Re-Mount-während-Aufnahme korrekt "Leave", auch
      # wenn die Capture in der sticky MicLive läuft.
      mic_on? = socket.assigns.current_user.discord_id in dids

      # Issue #399: Watchdog-State an die aktuelle Streamer-Liste angleichen —
      # ausgeschiedene prunen, neu hinzugekommene mit „jetzt" seeden (5-min-Grace
      # ab Join, sonst würde ein gerade beigetretener stiller User sofort flaggen).
      now = now_ms()

      loud_at =
        (socket.assigns.mic_loud_at || %{})
        |> Map.take(keep)
        |> then(fn m -> Enum.reduce(dids, m, &Map.put_new(&2, &1, now)) end)

      silent = Enum.filter(socket.assigns.silent_streamers || [], &(&1 in dids))

      {:noreply,
       socket
       |> assign(:mic_streamers, dids)
       |> assign(:mic_on?, mic_on?)
       |> assign(:mic_levels, Map.take(socket.assigns.mic_levels || %{}, keep))
       |> assign(:mic_loud_at, loud_at)
       |> assign(:silent_streamers, silent)}
    else
      {:noreply, socket}
    end
  end

  # Issue #391: Live-Pegel pro Streamer während der Aufnahme. Ephemer, 5×/s.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "mic_level", "campaign_id" => cid, "discord_id" => did, "level" => lvl}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      levels = Map.put(socket.assigns.mic_levels || %{}, did, lvl)

      # Issue #399: jeder Pegel ≥ Voice-Schwelle ist „hörbares Signal" → loud-at
      # refreshen. Bleibt der Pegel darunter (oder kommt gar kein mic_level mehr,
      # z.B. eingefrorener Tab), altert loud_at und der Tick flaggt nach 5 min.
      loud_at =
        if is_number(lvl) and lvl >= @voice_level_threshold do
          Map.put(socket.assigns.mic_loud_at || %{}, did, now_ms())
        else
          socket.assigns.mic_loud_at || %{}
        end

      {:noreply, socket |> assign(:mic_levels, levels) |> assign(:mic_loud_at, loud_at)}
    else
      {:noreply, socket}
    end
  end

  # Issue #399: server-seitiger Stille-Watchdog-Tick. Wer noch streamt (in
  # @mic_streamers — Chunks fließen) aber seit ≥ 5 min kein hörbares Signal
  # geliefert hat, wird geflaggt → Banner. Reschedule sich selbst.
  def handle_info(:mic_silence_tick, socket) do
    Process.send_after(self(), :mic_silence_tick, @silence_tick_ms)

    silent =
      compute_silent_streamers(
        socket.assigns.mic_streamers || [],
        socket.assigns.mic_loud_at || %{},
        now_ms(),
        @silence_limit_ms
      )

    {:noreply, assign(socket, :silent_streamers, silent)}
  end

  # Issue #104: Campaign-Replay-Engine broadcastet ihren Fortschritt als
  # kind="campaign_replay" — Banner-Update + Buttons-disable.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "campaign_replay", "campaign_id" => cid, "status" => status} = payload},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      running? = status in ["started", "session_started", "session_done"]

      state =
        if running? do
          %{
            current: payload["current"] || 0,
            total: payload["total"] || 0,
            session_number: payload["session_number"],
            session_id: payload["session_id"]
          }
        else
          nil
        end

      socket =
        socket
        |> assign(:campaign_replay_running?, running?)
        |> assign(:campaign_replay_state, state)
        |> then(fn s ->
          if status == "finished",
            do: put_flash(s, :info, "Campaign-Replay durch — alle Sessions neu generiert."),
            else: s
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  defp handle_pipeline_stage(cid, stage, status, error_msg, socket) do
    if cid == socket.assigns.campaign_id do
      busy =
        case status do
          "started" -> MapSet.put(socket.assigns.busy_stages, stage)
          _ -> MapSet.delete(socket.assigns.busy_stages, stage)
        end

      socket =
        socket
        |> assign(:busy_stages, busy)
        |> maybe_flash_pipeline_error(stage, status, error_msg)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp maybe_flash_pipeline_error(socket, stage, "failed", msg)
       when is_binary(msg) and msg != "" do
    put_flash(socket, :error, "LLM-Pipeline #{stage} fehlgeschlagen: #{msg}")
  end

  defp maybe_flash_pipeline_error(socket, stage, "failed", _) do
    put_flash(socket, :error, "LLM-Pipeline #{stage} fehlgeschlagen — Logs prüfen.")
  end

  defp maybe_flash_pipeline_error(socket, _, _, _), do: socket

  # ─── Internal helpers ──────────────────────────────────────────

  defp session_in_campaign?(_socket, nil), do: false

  defp session_in_campaign?(socket, sid) do
    Enum.any?(socket.assigns.sessions || [], fn s -> s["id"] == sid end)
  end

  # Resolve a Discord-ID → display name using the snapshot's `users` map.
  # New shape (Issue #6): %{discord_id => %{"display_name" => name, "avatar_url" => url}}.
  # Falls back to raw id if no record exists yet (e.g. legacy campaigns
  # pre-dating the owner-upsert fix).
  defp display_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      # Issue #57: User wurde gelöscht (oder hat sich noch nie eingeloggt).
      # Audit-Trail bleibt erhalten, aber wir zeigen statt der Discord-ID
      # einen sichtbaren Placeholder-Text.
      %{"deleted" => true} -> "[gelöschter User]"
      %{"display_name" => name} when is_binary(name) -> name
      # Tolerate the old flat-string format during the deploy roll-over.
      name when is_binary(name) -> name
      _ -> discord_id
    end
  end

  defp display_for(discord_id, _), do: discord_id

  # Issue #399: pure Stille-Berechnung (testbar ohne LiveView). Ein Streamer gilt
  # als still, wenn er noch in der aktiven Streamer-Liste ist (Chunks fließen),
  # aber sein letztes hörbares Signal (loud_at) ≥ limit_ms zurückliegt. Ohne
  # loud_at-Eintrag (noch nicht geseedet) → nicht flaggen.
  @doc false
  def compute_silent_streamers(streamers, loud_at, now_ms, limit_ms)
      when is_list(streamers) and is_map(loud_at) do
    Enum.filter(streamers, fn did ->
      case Map.get(loud_at, did) do
        nil -> false
        last when is_integer(last) -> now_ms - last >= limit_ms
        _ -> false
      end
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ─── Speaker resolution (Issue #19) ─────────────────────────────

  # Wandelt die Snapshot-Liste in eine Lookup-Map
  # `%{"speaker:<sid>:<n>" => discord_id}` um.
  defp speaker_assignment_map(list) when is_list(list) do
    Enum.into(list, %{}, fn a -> {a["speaker_label"], a["discord_id"]} end)
  end

  defp speaker_assignment_map(_), do: %{}

  # True wenn die discord_id ein Diarisierungs-Pseudo-Label ist
  # (`speaker:<session_id>:<n>`), kein echter User.
  defp pseudo_speaker?(did) when is_binary(did), do: String.starts_with?(did, "speaker:")
  defp pseudo_speaker?(_), do: false

  # `speaker:<sid>:3` → "Sprecher 4" (1-basiert für die Anzeige).
  defp pseudo_speaker_label(did) do
    case did |> to_string() |> String.split(":") |> List.last() |> Integer.parse() do
      {n, _} -> "Sprecher #{n + 1}"
      :error -> "Sprecher ?"
    end
  end

  # Anzahl distinkter Pseudo-Sprecher in einer Utterance-Gruppe (= Session),
  # die noch keinem echten Mitglied zugeordnet sind. Treibt das Header-Badge.
  defp unassigned_speaker_count(group, assignments) do
    group
    |> Enum.map(& &1["discord_id"])
    |> Enum.filter(&pseudo_speaker?/1)
    |> Enum.uniq()
    |> Enum.count(fn label ->
      case Map.get(assignments, label) do
        did when is_binary(did) and did != "" -> false
        _ -> true
      end
    end)
  end

  # Auflösung eines Utterance-Sprechers für die Anzeige. Pseudo-Labels werden
  # über die Zuordnungs-Map zu echten Namen aufgelöst, sonst „Sprecher N".
  defp speaker_display(did, assignments, users, char_names) do
    if pseudo_speaker?(did) do
      case Map.get(assignments, did) do
        real when is_binary(real) and real != "" -> display_for(real, users, char_names)
        _ -> pseudo_speaker_label(did)
      end
    else
      display_for(did, users, char_names)
    end
  end

  # Issue #2: character-name takes precedence over both display_name and
  # raw discord_id. Used in places where the per-campaign alias should win:
  # mainly the Mitspieler-Pill + Protokoll/Mic-Streamer rendering.
  defp display_for(discord_id, users, char_names)
       when is_map(users) and is_map(char_names) do
    case Map.get(char_names, discord_id) do
      name when is_binary(name) and name != "" -> name
      _ -> display_for(discord_id, users)
    end
  end

  # Issue #154 (Etappe 4c.2): Hub-LV erzeugt Events nicht mehr direkt via
  # EventLog.append, sondern delegiert an einen online Worker via
  # Hub.EventBridge. Worker macht Worker-First-Apply + sync zurück. Cold-Fail
  # (kein Worker für die Campaign online) wird nur geloggt — Hub-LV bleibt
  # responsive, das Event ist halt vorerst nicht propagiert. Die Sichtbarkeit
  # im LV passiert async über das nachfolgende event_appended-Broadcast.
  defp bridge_publish(socket, payload) do
    cid = payload["campaign_id"] || socket.assigns[:campaign_id]

    case EventBridge.publish(cid, payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        require Logger

        Logger.warning(
          "CampaignLive.bridge_publish: kein Worker online (kind=#{payload["kind"]} campaign=#{cid})"
        )

        # Issue #215: Self-Message für Flash-Anzeige; vor #215 silent fail.
        send(self(), {:bridge_publish_failed, payload["kind"]})
        :ok
    end
  end

  # Publish a CampaignAliasSet event for the acting user. Permission:
  # only members of the current campaign may set their own alias (and
  # only their own — owner-override is intentionally not implemented per
  # Issue #2 locked decisions).
  defp publish_alias(socket, character_name) do
    me = socket.assigns.current_user.discord_id

    if is_binary(me) and Enum.any?(socket.assigns.members, fn m -> m["discord_id"] == me end) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.campaign_alias_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "discord_id" => me,
        "character_name" => character_name
      })
    end

    :ok
  end

  # On every mount/reload: if the viewer isn't in the workers' `users`
  # table yet (or has a stale display_name), append a UserUpserted event
  # so the next snapshot resolves their id → name. Idempotent — Materializer
  # preserves joined_at. Fixes legacy campaigns where the owner created
  # the campaign before owner-upsert existed.
  defp backfill_viewer_user(socket, users) do
    user = socket.assigns.current_user
    snap_display = display_for(user && user.discord_id, users)

    cond do
      is_nil(user) or is_nil(user.discord_id) or is_nil(user.display_name) ->
        socket

      snap_display == user.display_name ->
        socket

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.user_upserted(),
          "discord_id" => user.discord_id,
          "display_name" => user.display_name
        })

        socket
    end
  end

  defp append_state(socket, state) do
    bridge_publish(socket, %{
      "kind" => Shared.Events.recording_state_changed(),
      "session_id" => socket.assigns.active_session.id,
      "campaign_id" => socket.assigns.campaign_id,
      "state" => state
    })
  end

  # ─── Snapshot ──────────────────────────────────────────────────

  @doc """
  Issue #144: berechnet aus einem Campaign-Snapshot + viewer-discord_id die
  Permission-Assigns (campaign_role, perm_user, owner?, is_member? etc.).

  Wird vom `load_snapshot/1` der LV genutzt und vom `HubWeb.DebugController`
  für Admin-Debug-Dumps wiederverwendet — damit beide Pfade garantiert
  identische Werte berechnen (kein Drift bei künftigen Permission-Refactors).
  """
  @spec derive_assigns(map(), String.t() | nil) :: map()
  def derive_assigns(snap, viewer_did) do
    c = snap["campaign"]
    members = snap["members"] || []

    viewer_member =
      Enum.find(members, fn m -> m["discord_id"] == viewer_did end)

    is_member? = viewer_member != nil

    # Issue #140: per-Campaign-Rolle aus der Member-Liste ableiten.
    # `nil` wenn nicht Member; `:spielleiter` | `:spieler` sonst.
    # Backward-Compat: Worker auf Versionen <0.13.0 liefern noch die
    # alten Atoms `:owner` / `:player`.
    campaign_role =
      case viewer_member && viewer_member["role"] do
        "spielleiter" -> :spielleiter
        "owner" -> :spielleiter
        "spieler" -> :spieler
        "player" -> :spieler
        _ -> nil
      end

    role = parse_viewer_role(snap["viewer_role"])

    perm_user = %{
      discord_id: viewer_did,
      role: role,
      is_member?: is_member?,
      campaign_role: campaign_role
    }

    %{
      campaign: c,
      members: members,
      role: role,
      campaign_role: campaign_role,
      is_member?: is_member?,
      perm_user: perm_user,
      # Issue #140: `owner?` ist die Phase-A-Bezeichnung für „per-Campaign-
      # :spielleiter dieser Kampagne". Globaler :admin zählt auch hier als
      # GM, damit alle GM-Buttons-Gates konsistent mit Permissions.can?/3
      # (das :admin als Universal-Allow behandelt) bleiben.
      owner?: role == :admin or campaign_role == :spielleiter,
      can_edit_meta?: role == :admin or campaign_role == :spielleiter,
      can_regenerate_session?: HubWeb.Permissions.can?(perm_user, :regenerate_session, c),
      can_regenerate_campaign?: HubWeb.Permissions.can?(perm_user, :regenerate_campaign, c),
      can_assign_speaker?: HubWeb.Permissions.can?(perm_user, :assign_speaker, c)
    }
  end

  defp snapshot_scope(socket) do
    %{
      "kind" => "campaign",
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }
  end

  # Issue #321: synchroner Initial-Load — nur im mount. Alle reaktiven Reloads
  # laufen async über start_snapshot_load/1 + handle_async, damit die GUI
  # während des (bis 15s langen) Worker-Round-Trips nicht einfriert.
  defp load_snapshot(socket), do: apply_snapshot(socket, Reader.read(snapshot_scope(socket)))

  # Issue #321: Snapshot async vom Worker holen — die LV bleibt reagierbar.
  defp start_snapshot_load(socket) do
    scope = snapshot_scope(socket)

    socket
    |> assign(:reload_state, :running)
    |> start_async(:reload_snapshot, fn -> Reader.read(scope) end)
  end

  # Issue #321: Reload-Coalescing. Genutzt für den Nachlauf nach einem async-
  # Read, wenn währenddessen Events reinkamen (reload_dirty?). Schedult nur,
  # wenn keiner läuft/geplant ist; während :running wird nur dirty markiert.
  defp schedule_reload(%{assigns: %{reload_state: :idle}} = socket) do
    Process.send_after(self(), :reload, 150)
    assign(socket, :reload_state, :scheduled)
  end

  defp schedule_reload(%{assigns: %{reload_state: :running}} = socket),
    do: assign(socket, :reload_dirty?, true)

  defp schedule_reload(socket), do: socket

  defp apply_snapshot(socket, result) do
    case result do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, snap} ->
        # Issue #144: derive_assigns/2 zentral, damit DebugController
        # dieselbe Berechnung reproduzieren kann ohne LV-Mount.
        derived = derive_assigns(snap, socket.assigns.current_user.discord_id)

        # Issue #387: LocalStorage-Update für „letzte Kampagne". `prev` MUSS
        # VOR dem Assign-Update gelesen werden, sonst vergleicht der Guard
        # gegen sich selbst und der Push firet nie bei Kampagnen-Wechsel.
        prev_campaign = socket.assigns[:current_campaign]

        socket
        |> assign(:waiting?, false)
        |> assign(:campaign, derived.campaign)
        |> assign(:current_campaign, derived.campaign)
        |> maybe_push_last_campaign(prev_campaign, derived.campaign)
        |> assign(:sessions, snap["sessions"] || [])
        |> assign(:members, derived.members)
        |> assign(:invites, snap["invites"] || [])
        |> assign(
          :active_session,
          filter_stopping_session(
            deserialize_session(snap["active_session"]),
            socket.assigns[:stopping_session_id]
          )
        )
        |> assign(:utterances, snap["utterances"] || [])
        |> assign(:markers, snap["markers"] || [])
        |> assign(:epos, snap["epos"])
        |> assign(:epos_history, snap["epos_history"] || [])
        |> assign(:summaries, snap["summaries"] || [])
        |> assign(:faithfulness_by_session, faithfulness_index(snap["faithfulness"] || []))
        |> assign(:chronik, snap["chronik"] || [])
        # Issue #114: Forward-Index für "↑ zitiert in N"-Badges an Utterances.
        # Map %{utterance_id => [%{kind, entry_id, label}, ...]}.
        |> assign(
          :utterance_refs_index,
          build_utterance_refs_index(
            snap["summaries"] || [],
            snap["epos"],
            snap["chronik"] || []
          )
        )
        # Issue #10: ColumnSync-Index. Beide Richtungen (utt→entries +
        # entry→utts) als JSON-String fürs Data-Attribut am LV-Root.
        # Utterances als 4. Arg für Session-basierten Fallback wenn
        # source_refs leer sind (alte Seeds vor #114).
        |> assign(
          :sync_index_json,
          Jason.encode!(
            build_sync_index(
              snap["summaries"] || [],
              snap["epos"],
              snap["chronik"] || [],
              snap["utterances"] || []
            )
          )
        )
        |> assign(:users, snap["users"] || %{})
        |> assign(:character_names, snap["character_names"] || %{})
        |> assign(:speaker_assignments, speaker_assignment_map(snap["speaker_assignments"]))
        # Issue #392: Re-Mount-Fix — Streamer-Liste aus dem Worker-Snapshot
        # statt nur initial []. Worker liefert sie nur bei aktiver Session
        # (sonst absent → []). Hält die "🎙 N streamen"-Anzeige nach Page-
        # Wechsel sofort konsistent, ohne edge-getriggerten Replay.
        |> assign(:mic_streamers, snap["mic_streamers"] || [])
        # Issue #405: Button-State beim (Re-)Mount aus der Worker-Truth — zeigt
        # "Leave" wenn die eigene Aufnahme in der sticky MicLive weiterläuft
        # während man zurück auf die Kampagne navigiert.
        |> assign(
          :mic_on?,
          socket.assigns.current_user.discord_id in (snap["mic_streamers"] || [])
        )
        |> assign(:audio_consent, snap["viewer_audio_consent"])
        |> assign(:viewer_role, derived.role)
        |> assign(:perm_user, derived.perm_user)
        |> assign(:owner?, derived.owner?)
        |> assign(:is_member?, derived.is_member?)
        |> assign(:can_edit_meta?, derived.can_edit_meta?)
        |> assign(:can_regenerate_session?, derived.can_regenerate_session?)
        |> assign(:can_regenerate_campaign?, derived.can_regenerate_campaign?)
        |> assign(:can_assign_speaker?, derived.can_assign_speaker?)
        |> backfill_viewer_user(snap["users"] || %{})
        |> ensure_default_session_expanded()
        |> maybe_autostart_single_source_mic()

      {:error, :no_worker} ->
        # Issue #146: bei vorübergehendem no_worker NICHT die assigns
        # hart auf Defaults zurücksetzen — sonst verlieren Spielleiter
        # nach kurzem Worker-Aussetzer fälschlich ihre GM-Buttons. Wenn
        # ein früherer Snapshot-Lauf erfolgreich war, bleiben Campaign,
        # Members, Permissions etc. erhalten; nur `waiting?` wird
        # gesetzt, damit die UI einen Banner zeigen kann. Beim nächsten
        # workers_changed-Event triggert ein Re-Load, der die Werte
        # ohnehin frisch füllt.
        socket
        |> assign(:waiting?, true)
        |> merge_or_default_assigns(error_branch_defaults(socket))

      {:error, reason} ->
        # Wie oben: alte assigns überleben den Fehlerzustand, plus Flash
        # damit die Ursache (Timeout etc.) sichtbar wird.
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(:waiting?, true)
        |> merge_or_default_assigns(error_branch_defaults(socket))
    end
  end

  # Issue #146: Defaults nur dort einsetzen wo die assigns noch nie
  # belegt waren (= erster Mount, bevor je ein erfolgreicher Snapshot
  # kam). Vorhandene assigns bleiben unangetastet.
  defp merge_or_default_assigns(socket, defaults) do
    Enum.reduce(defaults, socket, fn {key, default}, acc ->
      case Map.fetch(acc.assigns, key) do
        {:ok, _existing} -> acc
        :error -> assign(acc, key, default)
      end
    end)
  end

  defp error_branch_defaults(socket) do
    %{
      campaign: nil,
      current_campaign: nil,
      sessions: [],
      members: [],
      invites: [],
      active_session: nil,
      utterances: [],
      markers: [],
      epos: nil,
      epos_history: [],
      summaries: [],
      faithfulness_by_session: %{},
      chronik: [],
      users: %{},
      character_names: %{},
      speaker_assignments: %{},
      viewer_role: :spieler,
      perm_user: %{
        discord_id: socket.assigns.current_user.discord_id,
        role: :spieler,
        is_member?: false,
        campaign_role: nil
      },
      owner?: false,
      is_member?: false,
      can_edit_meta?: false,
      can_regenerate_session?: false,
      can_regenerate_campaign?: false,
      can_assign_speaker?: false
    }
  end

  # Issue #387: LocalStorage-Pin der zuletzt besuchten Kampagne. Nur firen
  # wenn sich die Kampagne tatsächlich geändert hat — Tab-Toggles innerhalb
  # derselben Kampagne sollen keine redundanten LocalStorage-Writes
  # auslösen.
  defp maybe_push_last_campaign(socket, prev, %{"id" => id} = new) when prev != new,
    do: Phoenix.LiveView.push_event(socket, "save-last-campaign", %{id: id})

  defp maybe_push_last_campaign(socket, _prev, _new), do: socket

  # Issue #355 Bug-Fix: nach rec_stop-Klick zeigt der nächste Snapshot
  # die Session evtl. noch als aktiv (SessionEnded firet erst nach
  # Transcribe-Queue-Drain). Wenn die Stop-LV-ID stimmt, force nil.
  defp filter_stopping_session(nil, _), do: nil
  defp filter_stopping_session(session, nil), do: session

  defp filter_stopping_session(%{id: id} = _session, stopping_id) when id == stopping_id,
    do: nil

  defp filter_stopping_session(session, _stopping_id), do: session

  defp deserialize_session(nil), do: nil

  defp deserialize_session(%{} = m) do
    %{
      id: m["id"],
      campaign_id: m["campaign_id"],
      number: m["number"],
      name: m["name"],
      status: parse_session_status(m["status"]),
      scheduled_for: m["scheduled_for"],
      started_at: m["started_at"],
      ended_at: m["ended_at"]
    }
  end

  defp parse_viewer_role("admin"), do: :admin
  defp parse_viewer_role("spielleiter"), do: :spielleiter
  defp parse_viewer_role("spieler"), do: :spieler
  defp parse_viewer_role(_), do: :spieler

  defp parse_session_status("scheduled"), do: :scheduled
  defp parse_session_status("running"), do: :running
  defp parse_session_status("recording"), do: :recording
  defp parse_session_status("completed"), do: :completed
  defp parse_session_status("ended"), do: :ended
  defp parse_session_status(_), do: :scheduled

  # ─── Render ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" id="campaign-live-root" phx-hook="ScrollToUtterance">
      <div id="mic-controls" phx-hook="MicSetup" phx-update="ignore"></div>
      <.recording_bar
        owner?={@owner?}
        active_session={@active_session}
        mic_on?={@mic_on?}
        recording_here?={@recording_here?}
        mic_streamers={@mic_streamers}
        mic_levels={@mic_levels}
        current_discord_id={@current_user.discord_id}
        users={@users}
      />

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
          <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="clear_invite_url" title="Einladungs-Link ausblenden" />
        </div>
      <% end %>

      <%= if @campaign_replay_running? do %>
        <div class="px-6 py-2 bg-warning/10 border-b border-warning/40 flex items-center gap-3 text-sm">
          <span class="inline-block w-2 h-2 rounded-full bg-warning animate-pulse"></span>
          <span class="text-ink-1">
            Pipeline läuft: Session {(@campaign_replay_state && @campaign_replay_state[:current]) || "?"}
            von {(@campaign_replay_state && @campaign_replay_state[:total]) || "?"}
            <%= if @campaign_replay_state && @campaign_replay_state[:session_number] do %>
              <span class="text-ink-2">(#{@campaign_replay_state[:session_number]})</span>
            <% end %>
          </span>
          <%= if @perm_user && @perm_user.role == :admin do %>
            <.link navigate={~p"/admin/jobs"} class="text-xs text-accent hover:underline">
              GPU-Queue ansehen
            </.link>
          <% end %>
          <span class="ml-auto text-xs text-ink-2">
            ~2 min pro Session — Resümees / Epos / Chronik werden überschrieben
          </span>
        </div>
      <% end %>

      <%!-- Issue #399: server-seitiger Stille-Watchdog. Sichtbar für GM + alle
            Live-Viewer, auch wenn der Tab des stillen Users tot ist. --%>
      <%= if @silent_streamers != [] do %>
        <div class="px-6 py-2 bg-danger/10 border-b border-danger/40 flex items-center gap-3 text-sm">
          <span class="inline-block w-2 h-2 rounded-full bg-danger animate-pulse"></span>
          <span class="text-ink-0 font-medium">
            ⚠ Kein hörbares Audio von {@silent_streamers |> Enum.map(&display_for(&1, @users)) |> Enum.join(", ")}
          </span>
          <span class="ml-auto text-xs text-ink-2">
            seit über 5&nbsp;min — Mikro stumm/abgezogen oder Browser eingefroren? Gerät prüfen.
          </span>
        </div>
      <% end %>

      <%!-- Issue #270: Top-Bar als Akkordeon-Reiter. Exklusiv — nur ein Tab
           offen zur Zeit. Click auf bereits offenen Tab toggled ihn zu.
           Save/Cancel/Confirm im Tab-Body setzen :open_tab zurück auf nil.
           "Kampagne löschen" ist nicht mehr hier — wandert in die
           Dashboard-Card (DashboardLive). --%>

      <%!-- Excel-Style horizontale Tab-Bar. Tab-Headers in einer Reihe,
           aktiver Tab unterstrichen mit Accent-Border. Body unter den
           Headers. Klick auf aktiven Header → :open_tab = nil → Body
           verschwindet. --%>
      <% can_pipeline? = @can_regenerate_campaign?
         can_flavor? = @can_edit_meta?
         can_vocab? = HubWeb.Permissions.can?(@perm_user, :edit_vocab, @campaign)
         any_tab? = can_pipeline? or can_flavor? or can_vocab? %>

      <%= if any_tab? do %>
        <div class="border-b border-bg-3/40 bg-bg-1/30">
          <div class="flex items-center gap-1 px-4 pt-2">
            <%= if can_pipeline? do %>
              <.tab_header
                tab_id="pipeline"
                label="Pipeline neu starten"
                icon="hero-arrow-path"
                active?={@open_tab == :pipeline}
              />
            <% end %>
            <%= if can_flavor? do %>
              <.tab_header
                tab_id="flavor"
                label="Stil setzen"
                icon="hero-paint-brush"
                active?={@open_tab == :flavor}
              />
            <% end %>
            <%= if can_vocab? do %>
              <.tab_header
                tab_id="vocab"
                label="Vokabular bearbeiten"
                icon="hero-book-open"
                active?={@open_tab == :vocab}
              />
            <% end %>
          </div>

          <%= case @open_tab do %>
            <% :pipeline -> %>
              <div :if={can_pipeline?} class="px-6 py-4">
                <p class="text-sm text-fg-muted mb-3">
                  Alle Sessions dieser Kampagne werden erneut durch die LLM-Pipeline geschickt.
                  Läuft ~{length(@sessions)} × ~2 min = ~{length(@sessions) * 2} min.
                  Resumées / Epos / Chronik werden überschrieben.
                </p>
                <.btn
                  variant="primary"
                  icon="refresh"
                  phx-click="rerun_campaign"
                  disabled={@campaign_replay_running?}
                >
                  Jetzt neu starten
                </.btn>
              </div>

            <% :flavor -> %>
              <div :if={can_flavor?} class="px-6 py-4">
                <.flavor_editor
                  campaign={@campaign}
                  stil_stage={@stil_stage}
                  segments={@preview_segments}
                  preview_error={@preview_error}
                  flavor_drafts={@flavor_drafts}
                  vorgabe_drafts={@vorgabe_drafts}
                  is_member?={@can_edit_meta?}
                />
              </div>

            <% :vocab -> %>
              <div :if={can_vocab?} class="px-6 py-4">
                <%= if @vocab_editing do %>
                  <form phx-submit="vocab_edit_save">
                    <textarea
                      name="vocab_hint"
                      rows="3"
                      class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0"
                      placeholder="Eigennamen, Orte, NPCs — kommagetrennt. Hilft Whisper beim Erkennen."
                    ><%= @vocab_draft %></textarea>
                    <div class="flex justify-end gap-2 mt-2">
                      <.btn variant="ghost" phx-click="vocab_edit_cancel">Abbrechen</.btn>
                      <.btn variant="primary" icon="check" type="submit">Speichern</.btn>
                    </div>
                  </form>
                <% else %>
                  <div class="text-xs text-ink-1 whitespace-pre-wrap">
                    <%= if @campaign && @campaign["vocab_hint"] && @campaign["vocab_hint"] != "" do %>
                      <%= @campaign["vocab_hint"] %>
                    <% else %>
                      <span class="italic text-ink-2/50">Kein Vokabular-Hint gesetzt.</span>
                    <% end %>
                  </div>
                <% end %>
              </div>

            <% _ -> %>
          <% end %>
        </div>
      <% end %>

      <span
        id="persist-cols"
        phx-hook="PersistCols"
        phx-update="ignore"
        data-campaign-id={@campaign_id}
      >
      </span>
      <div id="column-sync-host" class="flex-1 flex gap-px bg-bg-3/60 overflow-hidden" phx-hook="ColumnSync" data-sync-index={@sync_index_json}>
        <.column
          name="chronik"
          title={output_label(@campaign, "chronik")}
          subtitle=""
          busy?={MapSet.member?(@busy_stages, "stage4")}
          collapsed?={MapSet.member?(@collapsed_cols, "chronik")}
          can_collapse?={can_collapse?(@collapsed_cols, "chronik")}
        >
          <%= cond do %>
            <% @waiting? and @chronik == [] -> %>
              <.empty_col text="Warte auf Worker." />
            <% @chronik == [] -> %>
              <.empty_col text="Noch keine In-Game-Einträge. (Stufe-4-LLM füllt das — bis dahin via /dev/event)" />
            <% true -> %>
              <ol class="space-y-3">
                <%= for entry <- @chronik do %>
                  <li class="pl-3 border-l border-accent/40 group" id={"chronik-#{entry["id"]}"} data-anchor-id={entry["id"]}>
                    <%= if @chronik_editing == entry["id"] do %>
                      <form phx-submit="chronik_edit_save" class="space-y-1">
                        <textarea
                          name="chronik[markdown_body]"
                          rows="10"
                          autofocus
                          placeholder="# Datum&#10;## Titel&#10;&#10;Body als Markdown…"
                          class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 font-mono focus:border-accent focus:ring-0"
                        ><%= @chronik_draft %></textarea>
                        <div class="flex items-center justify-between">
                          <p class="text-[10px] text-ink-2">
                            Erste <code class="text-accent"># Zeile</code> = Datum,
                            <code class="text-accent">## Zeile</code> = Titel, Rest = Body.
                          </p>
                          <div class="flex gap-1">
                            <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="chronik_edit_cancel" title="Abbrechen" />
                            <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
                          </div>
                        </div>
                      </form>
                    <% else %>
                      <div class="flex items-start justify-between gap-2">
                        <div class="flex-1 min-w-0">
                          <% md = entry["markdown_body"] %>
                          <%= cond do %>
                            <% is_binary(md) and md != "" -> %>
                              <%# Markdown enthält H1=Datum + H2=Titel + Body — kein separater Header nötig %>
                              <div class={"text-ink-0 text-xs " <> prose_classes()}>
                                {render_md_safe(md)}
                              </div>
                            <% true -> %>
                              <%# Backward-Compat: alter Eintrag mit getrennten Feldern %>
                              <div class="text-xs text-accent font-mono">{entry["in_game_date"]}</div>
                              <div class="text-ink-0 text-sm font-medium">{entry["label"]}</div>
                              <%= if entry["summary"] do %>
                                <div class="text-ink-2 text-xs mt-1 line-clamp-3">{strip_md(entry["summary"])}</div>
                              <% end %>
                          <% end %>
                        </div>
                        <div class="flex items-center gap-1">
                          <%= if length(entry["source_refs"] || []) > 0 do %>
                            <button
                              type="button"
                              phx-click="show_refs"
                              phx-value-kind="chronik"
                              phx-value-id={entry["id"]}
                              class="text-[10px] text-accent/70 hover:text-accent font-mono cursor-pointer"
                              title="Quell-Utterances ansehen"
                            >
                              📎 {length(entry["source_refs"])}
                            </button>
                          <% end %>
                          <%= if @can_edit_meta? do %>
                            <.ls_icon_btn_compat
                              kind={:edit}
                              phx-click="chronik_edit_start"
                              phx-value-id={entry["id"]}
                              title="Eintrag bearbeiten"
                            />
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </li>
                <% end %>
              </ol>
          <% end %>
        </.column>

        <.epos_column
          title={output_label(@campaign, "epos")}
          owner?={@owner?}
          can_edit?={@can_edit_meta?}
          waiting?={@waiting?}
          epos={@epos}
          epos_history={@epos_history}
          epos_mode={@epos_mode}
          epos_draft={@epos_draft}
          epos_diff_seq={@epos_diff_seq}
          busy?={MapSet.member?(@busy_stages, "stage3")}
          collapsed?={MapSet.member?(@collapsed_cols, "epos")}
          can_collapse?={can_collapse?(@collapsed_cols, "epos")}
        />

        <.column
          name="summaries"
          title={output_label(@campaign, "summary")}
          subtitle="Was letztes Mal geschah"
          busy?={MapSet.member?(@busy_stages, "stage2")}
          collapsed?={MapSet.member?(@collapsed_cols, "summaries")}
          can_collapse?={can_collapse?(@collapsed_cols, "summaries")}
        >
          <%= cond do %>
            <% @waiting? and @summaries == [] -> %>
              <.empty_col text="Warte auf Worker." />
            <% @summaries == [] -> %>
              <.empty_col text="Noch keine Session-Resümees. (Stufe-2-LLM erzeugt sie nach jeder Session — bis dahin via /dev/event)" />
            <% true -> %>
              <% sessions_by_id = Map.new(@sessions, &{&1["id"], &1}) %>
              <div class="space-y-4">
                <%= for s <- @summaries do %>
                  <article class="pb-3 border-b border-bg-3/60 last:border-0" data-anchor-id={s["session_id"]}>
                    <header class="grid grid-cols-3 items-baseline gap-2 mb-1">
                      <div class="flex items-baseline gap-2">
                        <span class="text-ink-2 text-xs font-mono">{format_ts(s["generated_at"])}</span>
                        <span class={["pill", source_pill(s["source"])]}>
                          {s["source"]}
                        </span>
                        <% fscore = @faithfulness_by_session[s["session_id"]] %>
                        <%= if fscore do %>
                          <button
                            type="button"
                            phx-click="faithfulness_toggle"
                            phx-value-session={s["session_id"]}
                            class={["pill text-[10px] cursor-pointer", faithfulness_pill_class(fscore["score"])]}
                            title="Faithfulness-Score (NLI) — klick für Claim-Details"
                          >
                            {faithfulness_label(fscore["score"])}
                          </button>
                        <% end %>
                      </div>
                      <div
                        class="text-center text-[10px] uppercase tracking-widest text-ink-2 truncate"
                        title={session_label(sessions_by_id[s["session_id"]], s["session_id"])}
                      >
                        {session_label(sessions_by_id[s["session_id"]], s["session_id"])}
                      </div>
                      <div class="flex items-baseline justify-end gap-2">
                        <%= if length(s["source_refs"] || []) > 0 do %>
                          <button
                            type="button"
                            phx-click="show_refs"
                            phx-value-kind="summary"
                            phx-value-id={s["session_id"]}
                            class="text-[10px] text-accent/70 hover:text-accent font-mono cursor-pointer"
                            title="Quell-Utterances ansehen"
                          >
                            📎 {length(s["source_refs"])}
                          </button>
                        <% end %>
                        <%= if @can_edit_meta? do %>
                          <.ls_icon_btn_compat
                            kind={:edit}
                            phx-click="summary_edit_start"
                            phx-value-session={s["session_id"]}
                            title="Resümee bearbeiten"
                          />
                        <% end %>
                        <%= if @can_regenerate_session? do %>
                          <.ls_icon_btn_compat
                            kind={:regenerate}
                            phx-click="rerun_pipeline"
                            phx-value-session={s["session_id"]}
                            disabled={@campaign_replay_running?}
                            data-confirm="Resümee/Epos/Chronik für diese Session neu generieren?"
                            title="Pipeline (Stages 2-4) für diese Session erneut ausführen"
                          />
                        <% end %>
                      </div>
                    </header>
                    <%= if @summary_editing == s["session_id"] do %>
                      <form phx-submit="summary_edit_save" class="space-y-2">
                        <textarea
                          name="content_md"
                          class="w-full h-32 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                          phx-update="ignore"
                          id={"summary-edit-#{s["session_id"]}"}
                        ><%= @summary_draft %></textarea>
                        <div class="flex justify-end gap-2">
                          <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="summary_edit_cancel" title="Abbrechen" />
                          <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
                        </div>
                      </form>
                    <% else %>
                      <div class={["text-ink-0 text-sm leading-relaxed", prose_classes()]}>{render_md(s["content_md"])}</div>
                      <%= if MapSet.member?(@faithfulness_expanded, s["session_id"]) and fscore do %>
                        <div class="mt-3 pt-2 border-t border-bg-3/40">
                          <div class="text-[10px] uppercase tracking-widest text-ink-2 mb-1">
                            Claims ({length(fscore["claims"] || [])})
                          </div>
                          <ul class="space-y-1 text-xs">
                            <%= for claim <- (fscore["claims"] || []) do %>
                              <li class="flex items-start gap-2">
                                <span class={["mt-0.5 flex-shrink-0 w-2 h-2 rounded-full", faithfulness_claim_dot(claim["label"])]}></span>
                                <span class="text-ink-1">{claim["text"]}</span>
                              </li>
                            <% end %>
                          </ul>
                        </div>
                      <% end %>
                    <% end %>
                  </article>
                <% end %>
              </div>
          <% end %>
        </.column>

        <.column
          name="protokoll"
          title="Protokoll"
          subtitle={protokoll_subtitle(@active_session)}
          busy?={MapSet.member?(@busy_stages, "stage1")}
          collapsed?={MapSet.member?(@collapsed_cols, "protokoll")}
          can_collapse?={can_collapse?(@collapsed_cols, "protokoll")}
        >
          <%= cond do %>
            <% @waiting? and @utterances == [] -> %>
              <.empty_col text="Warte auf Worker." />
            <% @utterances == [] -> %>
              <.empty_col text={"Noch keine Utterances. Klick REC und feuere `mix lore.fake_session " <> @campaign_id <> "` in einer Shell."} />
            <% true -> %>
              <ol class="space-y-2">
                <%= for {session_label, group} <- group_by_session(@utterances, @sessions) do %>
                  <% sid = List.first(group)["session_id"] %>
                  <% view_group = group %>
                  <% expanded? = MapSet.member?(@expanded_sessions, sid) %>
                  <% active? = !!(@active_session && @active_session.id == sid) %>
                  <% unassigned = unassigned_speaker_count(group, @speaker_assignments) %>
                  <li class="pt-3 first:pt-0">
                    <div class="text-[10px] uppercase tracking-widest text-ink-2 mb-1 border-t border-bg-3/60 pt-2 first:border-0 first:pt-0 flex items-center justify-between gap-2">
                      <button
                        type="button"
                        phx-click="protokoll_session_toggle"
                        phx-value-session={sid}
                        class="flex-1 flex items-center gap-1.5 text-left hover:text-ink-0 transition-colors"
                        title={if expanded?, do: "Session zuklappen", else: "Session aufklappen"}
                      >
                        <span class={[
                          "inline-block transition-transform duration-150 text-ink-1",
                          expanded? && "rotate-90"
                        ]}>▸</span>
                        <span>{session_label}</span>
                        <span class="text-ink-2/70 normal-case tracking-normal">({length(view_group)})</span>
                        <%= if active? and not expanded? do %>
                          <span class="text-accent normal-case tracking-normal animate-pulse">● live</span>
                        <% end %>
                        <span
                          :if={unassigned > 0}
                          class="text-rec-soft normal-case tracking-normal"
                          title="Diarisierte Sprecher ohne Zuordnung — auf einen Sprecher im Protokoll klicken"
                        >
                          ⚠ {unassigned} Sprecher nicht zugewiesen
                        </span>
                      </button>
                      <%= if expanded? and @can_edit_meta? and @utterance_adding != sid do %>
                        <.ls_icon_btn_compat
                          kind={:add}
                          phx-click="utterance_add_start"
                          phx-value-session={sid}
                          title="Manuellen Eintrag hinzufügen"
                        />
                      <% end %>
                      <%= if expanded? and @can_edit_meta? do %>
                        <.ls_icon_btn_compat
                          kind={:cascade_delete}
                          size={:sm}
                          phx-click="session_delete"
                          phx-value-session={sid}
                          data-confirm={"Session „" <> session_label <> "“ wirklich unwiderruflich löschen? Utterances, Marker, Resümee, Chronik-Einträge und Sprecher-Zuordnungen werden mitgelöscht."}
                          title="Session unwiderruflich löschen (Cascade)"
                        />
                      <% end %>
                    </div>
                    <ul :if={expanded?} class="space-y-2">
                      <%= for u <- view_group do %>
                        <li
                          class={[
                            "text-xs relative group/utt py-0.5 border-l-2 pl-1.5",
                            if(asr_uncertain?(u), do: "border-warning/50", else: "border-transparent")
                          ]}
                          data-utterance-id={u["id"]}
                        >
                          <%= if @utterance_editing == u["id"] do %>
                            <div class="flex items-baseline gap-1">
                              <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                              <span class="text-accent">{speaker_display(u["discord_id"], @speaker_assignments, @users, @character_names)}</span>
                              <form phx-submit="utterance_edit_save" class="flex-1 flex gap-1 items-start ml-1">
                                <textarea
                                  id={"utterance-edit-#{u["id"]}"}
                                  name="text"
                                  rows="2"
                                  phx-update="ignore"
                                  class="flex-1 bg-bg-0 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                                ><%= @utterance_draft %></textarea>
                                <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
                                <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="utterance_edit_cancel" title="Abbrechen" />
                              </form>
                            </div>
                          <% else %>
                            <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                            <%= cond do %>
                              <% pseudo_speaker?(u["discord_id"]) and @can_assign_speaker? -> %>
                                <button
                                  type="button"
                                  phx-click="speaker_pick_start"
                                  phx-value-label={u["discord_id"]}
                                  phx-value-session={sid}
                                  class={[
                                    "text-accent underline decoration-dotted underline-offset-2 hover:text-accent/80 cursor-pointer",
                                    not Map.has_key?(@speaker_assignments, u["discord_id"]) && "italic"
                                  ]}
                                  title="Sprecher zuordnen"
                                >
                                  {speaker_display(u["discord_id"], @speaker_assignments, @users, @character_names)}
                                </button>
                              <% true -> %>
                                <span class={[
                                  "text-accent",
                                  pseudo_speaker?(u["discord_id"]) and
                                    not Map.has_key?(@speaker_assignments, u["discord_id"]) && "italic"
                                ]}>
                                  {speaker_display(u["discord_id"], @speaker_assignments, @users, @character_names)}
                                </span>
                            <% end %>
                            <%= if dot_class = status_dot_class(u["status"]) do %>
                              <span
                                class={["inline-block w-2 h-2 rounded-sm align-middle ml-1", dot_class]}
                                title={status_label(u["status"])}
                              />
                            <% end %>
                            <span
                              :if={asr_uncertain?(u)}
                              class="text-warning/70 text-[10px] ml-0.5 align-middle"
                              title={uncertainty_tooltip(u)}
                            >
                              ⚠︎
                            </span>
                            <span class={[
                              "ml-1",
                              u["status"] == "pending" && "text-ink-2 italic",
                              u["status"] == "live" && "text-ink-1 italic",
                              u["status"] == "edited" && "text-ink-0",
                              u["status"] == "manual" && "text-ink-0"
                            ]}>
                              {u["text"]}
                            </span>
                            <% citing_count = Map.get(@utterance_refs_index, u["id"], []) |> length() %>
                            <span class="absolute right-0 top-0 flex gap-0.5 items-center px-1 py-0.5 rounded bg-bg-1/95 backdrop-blur shadow-sm
                                          opacity-0 transition-opacity
                                          group-hover/utt:opacity-100
                                          group-focus-within/utt:opacity-100
                                          [@media(hover:none)]:opacity-100">
                              <%= if citing_count > 0 do %>
                                <button
                                  type="button"
                                  phx-click="show_utterance_refs"
                                  phx-value-id={u["id"]}
                                  class="text-[10px] text-accent/70 hover:text-accent font-mono cursor-pointer"
                                  title="Wer zitiert diese Utterance"
                                >
                                  ↑{citing_count}
                                </button>
                              <% end %>
                              <%= if can_edit_utterance?(assigns, u) do %>
                                <.ls_icon_btn_compat
                                  kind={:edit}
                                  phx-click="utterance_edit_start"
                                  phx-value-id={u["id"]}
                                  title="Eintrag bearbeiten"
                                />
                                <.ls_icon_btn_compat
                                  kind={:delete}
                                  phx-click="utterance_delete"
                                  phx-value-id={u["id"]}
                                  data-confirm="Diesen Eintrag wirklich löschen?"
                                  title="Eintrag löschen"
                                />
                              <% end %>
                            </span>
                          <% end %>
                        </li>
                      <% end %>
                      <%= if @utterance_adding == sid do %>
                        <li class="text-xs">
                          <form
                            phx-submit="utterance_add_save"
                            class="flex flex-col gap-1 bg-bg-0 border border-accent/40 rounded p-2"
                          >
                            <div class="flex items-center gap-2">
                              <span class="text-[10px] uppercase tracking-widest text-ink-2">Sprecher</span>
                              <select
                                name="speaker"
                                class="bg-bg-1 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                              >
                                <%= for m <- @members do %>
                                  <option
                                    value={m["discord_id"]}
                                    selected={m["discord_id"] == @utterance_add_speaker}
                                  >
                                    {display_for(m["discord_id"], @users, @character_names)}
                                  </option>
                                <% end %>
                              </select>
                            </div>
                            <textarea
                              name="text"
                              rows="2"
                              autofocus
                              placeholder="Was wurde gesagt / passierte?"
                              class="w-full bg-bg-1 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                            ><%= @utterance_add_text %></textarea>
                            <div class="flex justify-end gap-1">
                              <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="utterance_add_cancel" title="Abbrechen" />
                              <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Eintrag hinzufügen" />
                            </div>
                          </form>
                        </li>
                      <% end %>
                    </ul>
                  </li>
                <% end %>
              </ol>
          <% end %>

        </.column>
      </div>

      <%!-- Issue #270: Mitspieler-Pillen sind klickbare Buttons. Click öffnet
           ein Popup mit den verfügbaren Aktionen — eigener User sieht
           "Charakter-Namen ändern", GM sieht Promote/Demote/Remove. --%>
      <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1 flex-wrap">
        <span class="uppercase tracking-widest">Mitspieler</span>
        <%= for m <- @members do %>
          <span class="inline-flex items-center relative">
            <button
              type="button"
              phx-click="open_member_popup"
              phx-value-discord_id={m["discord_id"]}
              class={[
                "pill cursor-pointer hover:bg-accent/20",
                member_sl?(m) && "pill-active"
              ]}
              title={
                if(member_sl?(m),
                  do: "Spielleiter dieser Kampagne · #{m["discord_id"]}",
                  else: m["discord_id"]
                )
              }
            >
              {display_for(m["discord_id"], @users, @character_names)}<%= if m["discord_id"] == @current_user.discord_id do %><span class="ml-1 opacity-60">✎</span><% end %>
            </button>

            <%= if @member_popup_open_for == m["discord_id"] do %>
              <div
                class="absolute z-30 left-0 bottom-full mb-1 w-60 panel p-2 space-y-1 shadow-glow"
                phx-click-away="close_member_popup"
                phx-window-keydown="close_member_popup"
                phx-key="escape"
              >
                <div class="text-[10px] text-ink-2 uppercase tracking-widest px-1 pb-1 border-b border-bg-3/40">
                  {display_for(m["discord_id"], @users, @character_names)}
                </div>

                <%= cond do %>
                  <% m["discord_id"] == @current_user.discord_id -> %>
                    <.btn
                      variant="ghost"
                      icon="pencil"
                      phx-click="alias_edit_start"
                      class="w-full justify-start"
                    >
                      Charakter-Namen ändern
                    </.btn>

                  <% @can_edit_meta? -> %>
                    <%= if member_sl?(m) do %>
                      <%= unless last_spielleiter?(@members, m["discord_id"]) do %>
                        <.btn
                          variant="ghost"
                          icon="user"
                          phx-click="member_demote_confirm"
                          phx-value-discord_id={m["discord_id"]}
                          data-confirm="Wirklich auf Spieler zurückstufen?"
                          class="w-full justify-start"
                        >
                          Auf Spieler zurückstufen
                        </.btn>
                      <% end %>
                    <% else %>
                      <.btn
                        variant="ghost"
                        icon="arrow-up"
                        phx-click="member_promote"
                        phx-value-discord_id={m["discord_id"]}
                        class="w-full justify-start"
                      >
                        Zum Spielleiter befördern
                      </.btn>
                    <% end %>
                    <%= unless last_spielleiter?(@members, m["discord_id"]) do %>
                      <.btn
                        variant="danger"
                        icon="user-minus"
                        phx-click="member_remove_confirm"
                        phx-value-discord_id={m["discord_id"]}
                        data-confirm="Wirklich aus der Kampagne entfernen?"
                        class="w-full justify-start"
                      >
                        Aus Kampagne entfernen
                      </.btn>
                    <% end %>

                  <% true -> %>
                    <span class="text-xs text-ink-2 px-1 block">Keine Aktionen verfügbar.</span>
                <% end %>
              </div>
            <% end %>
          </span>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <.ls_icon_btn_compat kind={:invite} size={:sm} phx-click="create_invite" title="Einladung erstellen" />
        <% end %>
      </div>

      <%= if @alias_mode == :edit do %>
        <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center">
          <div
            class="panel p-5 w-[420px] max-w-[90vw]"
            phx-click-away="alias_edit_cancel"
            phx-window-keydown="alias_edit_cancel"
            phx-key="escape"
          >
            <h2 class="font-display text-lg mb-2">Charakter-Name</h2>
            <p class="text-xs text-ink-2 mb-3">
              Wird statt deines Discord-Namens in Protokoll, Resümees,
              Epos und Chronik dieser Kampagne angezeigt. Leer = zurücksetzen.
            </p>
            <form phx-submit="alias_edit_save" class="space-y-3">
              <input
                type="text"
                name="character_name"
                value={@alias_draft}
                maxlength="80"
                autofocus
                placeholder="z.B. Tharion der Entdecker"
                class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 text-sm focus:border-accent focus:ring-0"
              />
              <div class="flex justify-end gap-2">
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="alias_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:reset} size={:md} phx-click="alias_edit_reset" title="Zurücksetzen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @owner? and Enum.any?(@invites, & &1["status"] == "active") do %>
        <div class="border-t border-bg-3/60 px-4 py-2 text-xs bg-bg-1">
          <div class="uppercase tracking-widest text-ink-2 mb-1">Offene Einladungen</div>
          <%= for inv <- @invites, inv["status"] == "active" do %>
            <div class="flex items-center gap-2 py-1">
              <span class="text-accent font-mono truncate">{inv["token"]}</span>
              <.ls_icon_btn_compat
                kind={:revoke}
                size={:sm}
                phx-click="revoke_invite"
                phx-value-token={inv["token"]}
                title="Einladung widerrufen"
                class="ml-auto"
              />
            </div>
          <% end %>
        </div>
      <% end %>

      <.mic_setup_modal
        :if={@show_mic_setup?}
        devices={@mic_setup_devices}
        consent_required={@mic_setup_consent_required?}
        consent_acked={@mic_setup_consent_acked?}
        consent_mode={@mic_setup_consent_mode}
        local_level={@mic_setup_local_level}
        phrase={@mic_setup_phrase}
        checking={@mic_setup_checking?}
        last_transcript={@mic_setup_last_transcript}
        phrase_ok={@mic_setup_phrase_ok?}
        error={@mic_setup_error}
      />

      <%!-- Issue #405: Silence-Modal lebt jetzt in HubWeb.MicLive (Capture-Owner). --%>

      <.refs_popover :if={@refs_popover} popover={@refs_popover} utterances={@utterances} users={@users} character_names={@character_names} />

      <.speaker_picker
        :if={@speaker_pick}
        pick={@speaker_pick}
        members={@members}
        users={@users}
        character_names={@character_names}
        assignments={@speaker_assignments}
      />
    </div>
    """
  end

  # Issue #19: Modal zum Zuordnen eines Diarisierungs-Pseudo-Sprechers zu
  # einem echten Kampagnen-Mitglied.
  attr(:pick, :map, required: true)
  attr(:members, :list, required: true)
  attr(:users, :map, required: true)
  attr(:character_names, :map, default: %{})
  attr(:assignments, :map, default: %{})

  defp speaker_picker(assigns) do
    assigns = assign(assigns, :current, Map.get(assigns.assignments, assigns.pick.label))

    ~H"""
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="speaker-picker-title"
      phx-window-keydown="speaker_pick_cancel"
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-center justify-center bg-bg-0/70 backdrop-blur-sm"
    >
      <div
        class="bg-bg-1 border border-bg-3 rounded-md shadow-2xl max-w-md w-full mx-4 p-5 flex flex-col gap-3"
        phx-click-away="speaker_pick_cancel"
      >
        <h3 id="speaker-picker-title" class="text-sm text-ink-0 font-semibold">
          {pseudo_speaker_label(@pick.label)} zuordnen
        </h3>
        <p class="text-xs text-ink-2">
          Wähle das Kampagnen-Mitglied, das hinter diesem Sprecher steckt. Die
          Zuordnung gilt für die ganze Session.
        </p>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto">
          <%= for m <- @members do %>
            <li>
              <button
                type="button"
                phx-click="speaker_assign"
                phx-value-label={@pick.label}
                phx-value-session={@pick.session_id}
                phx-value-discord_id={m["discord_id"]}
                class={[
                  "text-left w-full hover:bg-bg-2/50 rounded px-2 py-1.5 cursor-pointer flex items-center justify-between",
                  m["discord_id"] == @current && "bg-bg-2/40"
                ]}
              >
                <span>{display_for(m["discord_id"], @users, @character_names)}</span>
                <span :if={m["discord_id"] == @current} class="text-accent text-[10px]">✓ aktuell</span>
              </button>
            </li>
          <% end %>
        </ul>
        <div class="flex justify-between pt-2">
          <.btn
            :if={is_binary(@current) and @current != ""}
            variant="ghost"
            phx-click="speaker_unassign"
            phx-value-label={@pick.label}
            phx-value-session={@pick.session_id}
          >
            Zuordnung aufheben
          </.btn>
          <.btn variant="ghost" phx-click="speaker_pick_cancel">Schließen</.btn>
        </div>
      </div>
    </div>
    """
  end

  # Issue #114: Source-Refs-Popover. Zwei Modi:
  # - kind in ["summary", "epos", "chronik"]: refs ist [utterance_id, ...]
  #   → liste die Utterances + biete goto_utterance an.
  # - kind == "utterance": refs ist [%{kind, id, label}, ...] (Backward-Index)
  #   → liste die Einträge die diese Utterance zitieren + biete goto_entry an.
  attr(:popover, :map, required: true)
  attr(:utterances, :list, required: true)
  attr(:users, :map, required: true)
  attr(:character_names, :map, default: %{})

  defp refs_popover(%{popover: %{kind: "utterance"}} = assigns) do
    ~H"""
    <.lt_modal on_close="hide_refs" max_width="max-w-lg">
      <h3 class="text-sm text-ink-0 font-semibold">
        Diese Utterance wird zitiert in {length(@popover.refs)} Eintrag/Einträgen
      </h3>
      <%= if @popover.refs == [] do %>
        <p class="text-xs text-ink-2 mt-3">Niemand zitiert sie aktuell.</p>
      <% else %>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto mt-3">
          <%= for entry <- @popover.refs do %>
            <li>
              <button
                type="button"
                phx-click="goto_entry"
                phx-value-kind={entry.kind}
                phx-value-id={entry.id}
                class="text-left w-full hover:bg-bg-2/50 rounded px-2 py-1 cursor-pointer"
              >
                <span class="text-ink-2 uppercase tracking-wider text-[10px] mr-2">{entry.kind}</span>
                {entry.label}
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
      <div class="flex justify-end pt-3">
        <.btn variant="ghost" phx-click="hide_refs">Schließen</.btn>
      </div>
    </.lt_modal>
    """
  end

  defp refs_popover(assigns) do
    ~H"""
    <.lt_modal on_close="hide_refs" max_width="max-w-lg">
      <h3 class="text-sm text-ink-0 font-semibold">
        Quellen ({length(@popover.refs)} Utterance{if length(@popover.refs) == 1, do: "", else: "s"})
      </h3>
      <%= if @popover.refs == [] do %>
        <p class="text-xs text-ink-2 mt-3">
          Dieser Eintrag hat keine source_refs (Pre-#114-Stand oder LLM-JSON-Parse fehlgeschlagen).
        </p>
      <% else %>
        <ul class="text-xs text-ink-1 flex flex-col gap-1 max-h-80 overflow-y-auto mt-3">
          <%= for uid <- @popover.refs do %>
            <%
              utt = Enum.find(@utterances, &((&1["id"] || &1[:id]) == uid))
              speaker_did = utt && (utt["discord_id"] || utt[:discord_id])
              speaker_name = display_for(speaker_did, @users, @character_names)
              text_preview =
                case utt do
                  %{} = u -> u["text"] || u[:text] || ""
                  _ -> "(Quelle nicht mehr verfügbar)"
                end
            %>
            <li>
              <button
                type="button"
                phx-click="goto_utterance"
                phx-value-id={uid}
                class="text-left w-full hover:bg-bg-2/50 rounded px-2 py-1 cursor-pointer"
                disabled={is_nil(utt)}
              >
                <span class="text-accent font-mono text-[10px] mr-2">{String.slice(uid, 0, 8)}</span>
                <span :if={speaker_name} class="text-ink-2 mr-1">{speaker_name}:</span>
                <span class={if is_nil(utt), do: "text-rec-soft italic", else: ""}>
                  {text_preview |> to_string() |> String.slice(0, 120)}
                </span>
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
      <div class="flex justify-end pt-3">
        <.btn variant="ghost" phx-click="hide_refs">Schließen</.btn>
      </div>
    </.lt_modal>
    """
  end

  # Issue #64: Audio-Aufnahme-Consent-Modal. Erstaufnahme-Gate vor
  # getUserMedia/getDisplayMedia. Texte hardcoded auf Deutsch — TODO #18
  # (i18n) sobald das Übersetzungs-Framework steht, die vier Punkte +
  # Button-Labels extrahieren.
  #
  # Issue #317: mode-aware. Im :single_source-Modus (Raummikro) werden drei
  # zusätzliche Absätze gerendert, die die Aufnahme-Dritter-, Diarisierungs-
  # und SL-Verantwortungs-Punkte klarstellen. Akzeptieren in diesem Modus
  # speichert Version "v2", die auch den Per-Spieler-Pfad (v1) mit abdeckt.
  # `assigns.mode` ist :per_player | :single_source | nil — nil fällt auf den
  # Per-Spieler-Text zurück.
  # Issue #391/#400: Setup-Popup vor der Aufnahme. Ein einziges Modal — Device-
  # Auswahl + ASR-Phrasen-Test, und bei fehlendem Consent zusätzlich das Häkchen.
  # KEIN Aufnahme-Button und kein "Bestätigen": sobald ein Mikro offen ist
  # lauscht der Hook automatisch; sprich die angezeigte Phrase. Das Modal
  # schließt automatisch sobald die Phrase erkannt wurde UND (kein Consent
  # nötig ODER Häkchen gesetzt). Nur "Abbrechen" als bewusste Geste (auch
  # Backdrop/Escape via lt_modal-on_close).
  attr(:devices, :map, required: true)
  attr(:consent_required, :boolean, required: true)
  attr(:consent_acked, :boolean, required: true)
  attr(:consent_mode, :atom, default: nil)
  attr(:local_level, :float, default: 0.0)
  attr(:phrase, :map, default: nil)
  attr(:checking, :boolean, default: false)
  attr(:last_transcript, :string, default: nil)
  attr(:phrase_ok, :boolean, default: false)
  attr(:error, :string, default: nil)

  defp mic_setup_modal(assigns) do
    ~H"""
    <.lt_modal
      on_close="mic_setup_cancel"
      title="Mikrofon einrichten"
      max_width="max-w-lg"
      dismiss_on_outside={false}
    >
      <div class="flex flex-col gap-4">
        <%= if @consent_required do %>
          <div class="text-sm text-ink-1 flex flex-col gap-2 max-h-64 overflow-y-auto pr-1 border border-border rounded-md p-3 bg-surface-2/40">
            <p :if={@consent_mode == :single_source} class="text-ink-0">
              Du startest gleich den <strong>Raummikro-Modus</strong>: <strong>eine</strong>
              Audioquelle (dein Gerät) nimmt den ganzen Tisch auf — du nimmst damit
              auch andere Anwesende mit auf.
            </p>
            <p :if={@consent_mode != :single_source}>
              Bevor das Mikrofon aktiviert wird, möchten wir dich aufklären, was
              mit den Audiodaten passiert:
            </p>
            <ul class="list-disc list-inside space-y-1 text-ink-2">
              <li>
                Audio wird im Browser aufgezeichnet und in 500-ms-Chunks an den
                für diese Kampagne zuständigen Worker übertragen.
              </li>
              <li>
                Der Worker läuft auf der Hardware des Spielleiters (lokal oder
                auf seinem Server) und transkribiert mit Whisper – der
                loretracker-Hub selbst speichert keine Audiodaten.
              </li>
              <li>
                Audio-Chunks werden im Worker zwischengespeichert, solange die
                Session läuft und für mögliche Re-Transkriptionen verfügbar
                bleiben sollen. Eine zeitlich harte Retention-Vorgabe gibt es
                aktuell noch nicht – frag deinen Spielleiter wie er es hält.
              </li>
              <li :if={@consent_mode != :single_source}>
                Du kannst deine eigenen Utterances jederzeit in der
                Protokoll-Spalte editieren oder löschen. Eine ganze Session
                löscht der Spielleiter über die Kampagne.
              </li>
              <li :if={@consent_mode == :single_source}>
                Die Aufnahme wird im Worker <strong>post-session per Diarisierung
                automatisch nach Stimmen getrennt</strong>
                und Pseudo-Sprechern zugewiesen. Du als Spielleiter ordnest die
                Pseudo-Sprecher danach in der UI echten Kampagnen-Mitgliedern zu.
              </li>
              <li :if={@consent_mode == :single_source}>
                <strong>Du bist als Spielleiter dafür verantwortlich</strong>, das
                Einverständnis aller Mitspieler einzuholen, bevor du startest.
                Mitspieler ohne loretracker-Account können ihre Utterances nicht
                selbst editieren — Korrekturen und Löschungen musst du als SL
                übernehmen.
              </li>
            </ul>
          </div>

          <label class="flex items-start gap-2 text-sm text-ink-1 cursor-pointer">
            <input
              type="checkbox"
              phx-click="mic_setup_consent_toggle"
              checked={@consent_acked}
              class="mt-0.5 rounded border-border bg-bg text-primary focus:ring-primary"
            />
            <span :if={@consent_mode == :single_source}>
              Ich habe die Punkte gelesen, habe das Einverständnis der Mitspieler
              eingeholt und stimme der Aufnahme zu.
            </span>
            <span :if={@consent_mode != :single_source}>
              Ich habe die Punkte gelesen und stimme der Aufnahme zu.
            </span>
          </label>
        <% end %>

        <div class="flex flex-col gap-1">
          <label class="text-sm text-ink-1" for="mic-setup-device">Mikrofon wählen</label>
          <form phx-change="mic_setup_select_device">
            <select
              id="mic-setup-device"
              name="device_id"
              class="w-full bg-bg border border-border rounded px-2 py-1.5 text-sm text-ink-0"
            >
              <option :if={@devices.devices == []} value="" disabled selected>
                Mikrofone werden geladen …
              </option>
              <option
                :for={d <- @devices.devices}
                value={d.device_id}
                selected={d.device_id == @devices.preferred_id}
              >
                {d.label}
              </option>
            </select>
          </form>
        </div>

        <div class="flex flex-col gap-2">
          <p class="text-sm text-ink-1">
            Sprich bitte diesen Satz — sobald ein Mikro gewählt ist, wird automatisch
            zugehört und geprüft, ob dein Audio verständlich ankommt:
          </p>
          <blockquote class="text-base text-ink-0 font-medium italic border-l-2 border-primary pl-3 py-1">
            „{@phrase && @phrase.text}"
            <span :if={@phrase && @phrase.source != ""} class="block mt-1 text-xs text-ink-2 not-italic font-normal">
              — {@phrase.source}
            </span>
          </blockquote>
          <.vu_bar level={@local_level} class="w-full h-2" />

          <%!-- Status: lauscht / transkribiert / Treffer / daneben / Block-Fehler --%>
          <p :if={@error} class="text-xs text-danger">
            {@error}
          </p>
          <p :if={!@error and @checking} class="text-xs text-ink-2">
            Audio wird geprüft …
          </p>
          <p :if={!@error and not @checking and @phrase_ok} class="text-xs text-success">
            Phrase erkannt — Aufnahme startet …
          </p>
          <p
            :if={!@error and not @checking and not @phrase_ok and is_binary(@last_transcript)}
            class="text-xs text-warning"
          >
            <%= if @last_transcript == "" do %>
              Nichts verstanden — bitte etwas lauter und deutlicher noch einmal sprechen.
            <% else %>
              Erkannt: „{@last_transcript}" — passt noch nicht, sprich die Phrase bitte noch einmal.
            <% end %>
          </p>
          <p
            :if={!@error and not @checking and not @phrase_ok and is_nil(@last_transcript)}
            class="text-xs text-ink-2"
          >
            Höre zu … sprich die Phrase.
          </p>
          <p
            :if={@phrase_ok and @consent_required and not @consent_acked}
            class="text-xs text-warning"
          >
            Phrase erkannt — bitte oben erst die Audio-Aufnahme akzeptieren.
          </p>
        </div>

        <div class="flex justify-end pt-2">
          <.btn variant="ghost" type="button" phx-click="mic_setup_cancel">
            Abbrechen
          </.btn>
        </div>
      </div>
    </.lt_modal>
    """
  end

  # Issue #405: Silence-Watchdog-Modal nach HubWeb.MicLive verschoben.

  # Stil/Voice der LLM-Stages für diese Kampagne. 4 Slots: base (Welt/
  # Setting) + summary/epos/chronik (Voice/Persona pro Spalte). Member-
  # editierbar. Collapsed-View zeigt eine schmale Status-Zeile, Expanded
  # öffnet 4 Textareas als Akkordeon.
  # Issue #313: Stil-Editor pro Stage. Reiterleiste (Resümee/Epos/Chronik mit
  # default|gesetzt-Badge) + farbige Inline-Prompt-Vorschau: `vorgegeben`
  # (grau, read-only) vs. `editierbar` (amber Textareas, an flavor_drafts
  # gebunden). Speichern feuert CampaignFlavorSet (Ton) + CampaignVorgabeSet
  # (Name/Darstellung).
  attr(:campaign, :map, default: nil)
  attr(:stil_stage, :string, default: nil)
  attr(:segments, :list, default: [])
  attr(:preview_error, :any, default: nil)
  attr(:flavor_drafts, :map, default: %{})
  attr(:vorgabe_drafts, :map, default: %{})
  attr(:is_member?, :boolean, default: false)

  defp flavor_editor(assigns) do
    ~H"""
    <div class="px-6 py-3 border-b border-bg-3/60 bg-bg-1/50 text-xs">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-base">🎭</span>
        <span class="uppercase tracking-widest text-ink-2 text-[10px]">Stil &amp; Ausgabe pro Spalte</span>
      </div>

      <div class="flex flex-wrap gap-2 mb-3">
        <%= for stage <- ["chronik", "epos", "summary"] do %>
          <button
            type="button"
            phx-click="stil_stage"
            phx-value-stage={stage}
            class={[
              "px-3 py-1 rounded border text-[11px] transition-colors",
              (@stil_stage == stage) && "border-accent text-accent bg-accent/10" ||
                "border-bg-3 text-ink-2 hover:text-ink-1"
            ]}
          >
            {output_label(@campaign, stage)}
            <span class={[
              "ml-1 text-[9px] uppercase",
              vorgabe_set?(@campaign, stage) && "text-accent" || "text-ink-2/50"
            ]}>
              {if vorgabe_set?(@campaign, stage), do: "gesetzt", else: "default"}
            </span>
          </button>
        <% end %>
      </div>

      <%= if @stil_stage do %>
        <% name_set? = String.trim(to_string(@vorgabe_drafts["name"] || "")) != "" %>
        <% stage = @stil_stage %>
        <form phx-submit="stil_save" phx-change="stil_preview" class="flex flex-col gap-3">
          <input type="hidden" name="stage" value={stage} />

          <div class="grid gap-2 sm:grid-cols-2">
            <label class="flex flex-col gap-1">
              <span class={["text-[10px] uppercase tracking-widest", slot_text_class("base")]}>Ton (allgemein)</span>
              <textarea
                name="base"
                rows="2"
                maxlength="2000"
                phx-debounce="250"
                placeholder="Welt/Setting, Grundton — gilt für alle Spalten"
                class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class("base")]}
              ><%= @flavor_drafts["base"] %></textarea>
            </label>

            <label class="flex flex-col gap-1">
              <span class={["text-[10px] uppercase tracking-widest", slot_text_class(stage)]}>{editable_slot_label(stage, stage)}</span>
              <textarea
                name={stage}
                rows="2"
                maxlength="2000"
                phx-debounce="250"
                placeholder="Ton speziell für diese Spalte"
                class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class(stage)]}
              ><%= Map.get(@flavor_drafts, stage, "") %></textarea>
            </label>

            <label class="flex flex-col gap-1">
              <span class={["text-[10px] uppercase tracking-widest", slot_text_class("name")]}>Überschrift</span>
              <input
                type="text"
                name="name"
                value={@vorgabe_drafts["name"]}
                maxlength="60"
                phx-debounce="250"
                placeholder={default_output_label(stage)}
                class={["w-full rounded px-2 py-1 text-[11px] bg-bg-0 focus:ring-0 border", slot_field_class("name")]}
              />
            </label>

            <%= if stage == "epos" do %>
              <label class="flex flex-col gap-1">
                <span class="text-ink-2 text-[10px] uppercase tracking-widest">Darstellung</span>
                <select
                  name="darstellungsform"
                  class="bg-bg-0 border border-bg-3 rounded px-2 py-1 text-[11px] text-ink-0 focus:border-accent focus:ring-0"
                >
                  <option value="fliesstext" selected={@vorgabe_drafts["darstellungsform"] != "stichpunkte"}>
                    Fließtext
                  </option>
                  <option value="stichpunkte" selected={@vorgabe_drafts["darstellungsform"] == "stichpunkte"}>
                    Stichpunkte
                  </option>
                </select>
              </label>
            <% else %>
              <input type="hidden" name="darstellungsform" value="fliesstext" />
            <% end %>
          </div>

          <div class="text-ink-2/50 text-[10px]">
            Live-Prompt — deine Eingaben erscheinen unten <span class="text-ink-1">in der Farbe ihres Feldes</span>; grau ist fest vorgegeben.
          </div>

          <div class="border border-bg-3/60 rounded p-3 bg-bg-0/40 text-[11px] leading-relaxed whitespace-pre-wrap text-ink-2/55">
            <%= if @preview_error do %>
              <div class="text-ink-2/60 italic mb-2">
                Prompt-Vorschau nicht verfügbar ({inspect(@preview_error)}) — Felder lassen sich trotzdem speichern.
              </div>
            <% end %>
            <%= for seg <- @segments do %>
              <%= cond do %>
                <% seg["kind"] == "editable" -> %>
                  <% val = if seg["slot"] == "name", do: to_string(@vorgabe_drafts["name"] || ""), else: to_string(Map.get(@flavor_drafts, seg["slot"], "")) %>
                  <%= if String.trim(val) == "" do %>
                    <span class={["italic", slot_dim_class(seg["slot"])]}>[{editable_slot_label(seg["slot"], stage)}]</span>
                  <% else %>
                    <span class={["font-medium", slot_text_class(seg["slot"])]}>{val}</span>
                  <% end %>
                <% seg["kind"] == "heading_frame" -> %>
                  <span :if={name_set?}>{seg["text"]}</span>
                <% true -> %>
                  <span>{seg["text"]}</span>
              <% end %>
            <% end %>
          </div>

          <div class="flex justify-end gap-2">
            <.btn variant="ghost" type="button" phx-click="stil_close">Schließen</.btn>
            <%= if @is_member? do %>
              <.btn variant="primary" icon="check" type="submit">Speichern</.btn>
            <% end %>
          </div>
        </form>
      <% else %>
        <p class="text-ink-2/60 italic text-[11px]">
          Wähle oben eine Spalte: links die farbigen Eingabefelder (Ton, Überschrift,
          Darstellung), darunter der vollständige Prompt — deine Eingaben werden live
          in der Farbe ihres Feldes eingeblendet, grau ist fest vorgegeben.
        </p>
      <% end %>
    </div>
    """
  end

  # Owner-only Danger-Zone: Kampagne löschen mit Name-Bestätigung. Cascade
  # läuft im Worker-Materializer (CampaignDeleted-Event).
  attr(:campaign_name, :string, required: true)
  attr(:confirming?, :boolean, default: false)
  attr(:typed, :string, default: "")

  defp delete_zone(assigns) do
    ~H"""
    <div class="px-6 py-2 border-b border-bg-3/60 bg-bg-1/30 text-xs">
      <%= cond do %>
        <% @confirming? -> %>
          <form phx-submit="campaign_delete_confirm" phx-change="campaign_delete_typing" class="flex flex-col gap-2">
            <div class="flex items-center gap-2 text-rec-soft">
              <span class="text-base">⚠</span>
              <span class="uppercase tracking-widest text-[10px]">
                Kampagne unwiderruflich löschen
              </span>
              <span class="text-ink-2/70 text-[10px]">
                — alle Sessions, Protokolle, Resümees, Epos, Chronik werden mit gelöscht
              </span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-ink-2 text-[10px]">
                Tippe den Kampagnennamen zur Bestätigung: <code class="text-rec-soft">{@campaign_name}</code>
              </span>
            </div>
            <div class="flex gap-2 items-center">
              <input
                type="text"
                name="name"
                value={@typed}
                autocomplete="off"
                class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0 font-mono"
                placeholder={@campaign_name}
              />
              <.btn variant="ghost" phx-click="campaign_delete_cancel">Abbrechen</.btn>
              <.btn
                variant="danger"
                icon="trash"
                type="submit"
                disabled={String.trim(@typed) != @campaign_name}
              >
                Endgültig löschen
              </.btn>
            </div>
          </form>
        <% true -> %>
          <div class="flex items-center gap-2 justify-end">
            <.ls_icon_btn_compat
              kind={:cascade_delete}
              size={:md}
              phx-click="campaign_delete_request"
              title="Kampagne mit allen Einträgen unwiderruflich löschen"
            />
          </div>
      <% end %>
    </div>
    """
  end

  defp recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <%= case rec_state(@active_session) do %>
        <% :recording -> %>
          <.ls_icon_btn_compat kind={:rec_pause} size={:md} phx-click="rec_pause" disabled={not @owner?} title="Aufnahme pausieren" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-rec-soft text-xs uppercase tracking-widest">● Aufnahme läuft</span>
        <% :paused -> %>
          <.ls_icon_btn_compat kind={:rec_resume} size={:lg} phx-click="rec_resume" disabled={not @owner?} title="Aufnahme fortsetzen" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <.ls_icon_btn_compat
            kind={:rec_start}
            size={:lg}
            phx-click="rec_start"
            disabled={not @owner?}
            title="Aufnahme starten — pro Spieler eigenes Mikro"
          />
          <.btn
            :if={@owner?}
            phx-click="rec_single_start"
            title="Ein Raummikrofon für alle: startet Aufnahme UND Mikro in einem Klick. Sprecher werden nach der Session automatisch getrennt."
          >
            🎙 Raummikro starten
          </.btn>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">○ Keine aktive Session</span>
      <% end %>
      <div class="flex-1"></div>
      <.mic_controls
        active_session={@active_session}
        mic_on?={@mic_on?}
        recording_here?={@recording_here?}
        mic_streamers={@mic_streamers}
        mic_levels={@mic_levels}
        current_discord_id={@current_discord_id}
        users={@users}
      />
      <span class="text-xs text-ink-2 font-mono">{elapsed(@active_session)}</span>
      <button
        id="col-sync-toggle-btn"
        type="button"
        title="Referenzen"
        class="inline-flex items-center justify-center w-8 h-8 rounded-md border border-white/10 text-fg bg-transparent hover:bg-surface-2 hover:text-primary transition-colors duration-150 text-xs font-mono font-bold"
      >
        R
      </button>
      <%= if @owner? do %>
        <.ls_icon_btn_compat
          kind={:power}
          size={:sm}
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          title="Worker herunterfahren"
        />
      <% end %>
    </div>
    """
  end

  # Issue #415: Drei-Wege-Mikro-Button.
  #   :stop     — DIESER Browser nimmt gerade auf (recording_here?).
  #   :takeover — der Account nimmt auf einem ANDEREN Gerät auf (in Streamer-
  #               Liste, aber nicht hier) → „Hier übernehmen".
  #   :join     — niemand auf diesem Account nimmt auf → normal beitreten.
  # recording_here? hat Vorrang: lokales Recording schlägt die Streamer-Liste,
  # damit das aufnehmende Gerät nie fälschlich „übernehmen" zeigt.
  @doc false
  def mic_button_state(recording_here?, current_discord_id, mic_streamers) do
    cond do
      recording_here? -> :stop
      current_discord_id in (mic_streamers || []) -> :takeover
      true -> :join
    end
  end

  defp mic_controls(assigns) do
    ~H"""
    <%= if @active_session do %>
      <div class="flex items-center gap-2">
        <span class="text-xs text-ink-2 font-mono">
          🎙 {length(@mic_streamers)} streamen
        </span>
        <%!-- Issue #391: pro Streamer Name + Live-VU-Bar. --%>
        <span
          :for={did <- @mic_streamers}
          class="flex items-center gap-1 text-[10px] text-ink-2 font-mono"
          title={display_for(did, @users)}
        >
          <span class="truncate max-w-[8rem]">{display_for(did, @users)}</span>
          <.vu_bar level={Map.get(@mic_levels, did, 0.0)} class="w-10" />
        </span>
        <%!-- Issue #415: Drei-Wege. recording_here? = DIESER Browser nimmt auf
              (browser-lokal, MicCapture-Hook). Account in Streamer-Liste, aber
              nicht hier → Aufnahme läuft auf einem anderen Gerät → „Hier
              übernehmen" (mic_join; der Supersede-Broadcast stoppt das andere
              Gerät beim Start). --%>
        <%= case mic_button_state(@recording_here?, @current_discord_id, @mic_streamers) do %>
          <% :stop -> %>
            <.ls_icon_btn_compat kind={:mic_off} size={:md} phx-click="mic_leave" title="Mein Mikro stoppen" />
          <% :takeover -> %>
            <.btn phx-click="mic_join" title="Aufnahme von deinem anderen Gerät hierher übernehmen">
              ⇄ Hier übernehmen
            </.btn>
          <% :join -> %>
            <.ls_icon_btn_compat kind={:mic_on} size={:md} phx-click="mic_join" title="Mit Mikro beitreten" />
        <% end %>
      </div>
    <% end %>
    """
  end

  # ─── Epos column ───────────────────────────────────────────────

  defp epos_column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name="epos" title={@title} busy?={@busy?} />
    <% else %>
    <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
      <div class="col-header">
        <span class="flex items-center gap-2">
          {@title}
          <.busy_dot show?={@busy?} />
        </span>
        <span class="flex items-center gap-2">
        <%= cond do %>
          <% @can_edit? and @epos_mode == :view -> %>
            <.ls_icon_btn_compat kind={:edit} size={:sm} phx-click="epos_edit_start" title="Epos bearbeiten" />
          <% @epos_mode == :edit -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Bearbeitet…</span>
          <% true -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Main Campaign Book</span>
        <% end %>
          <.collapse_chevron name="epos" can_collapse?={@can_collapse?} direction={:close} />
        </span>
      </div>

      <div class="flex-1 overflow-y-auto p-4 scroll-smooth" data-col="epos">
        <%!-- Issue #370: 40vh Top-Spacer + Bottom-Spacer (siehe column-Component). --%>
        <div class="h-[40vh]" aria-hidden="true"></div>
        <%= cond do %>
          <% @waiting? and is_nil(@epos) -> %>
            <p class="text-ink-2 text-sm italic">Warte auf Worker.</p>
          <% @epos_mode == :diff -> %>
            <.epos_diff history={@epos_history} target_seq={@epos_diff_seq} current={@epos} />
          <% @epos_mode == :edit -> %>
            <form phx-submit="epos_edit_save" class="space-y-2">
              <textarea
                name="content_md"
                class="w-full h-72 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                phx-update="ignore"
                id="epos-textarea"
              ><%= @epos_draft %></textarea>
              <div class="flex justify-end gap-2">
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="epos_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
              </div>
            </form>
          <% @epos == nil or @epos["content_md"] in [nil, ""] -> %>
            <p class="text-ink-2 text-sm italic">
              Noch leer.<%= if @can_edit?, do: " Klick 'Bearbeiten' oben.", else: "" %>
            </p>
            <.epos_history_section history={@epos_history} />
          <% true -> %>
            <article class={["text-ink-0 text-sm leading-relaxed", prose_classes()]} data-anchor-id={@epos["id"]}>{render_md(@epos["content_md"])}</article>
            <.epos_history_section history={@epos_history} />
        <% end %>
        <div class="h-[40vh]" aria-hidden="true"></div>
      </div>
    </div>
    <% end %>
    """
  end

  defp epos_history_section(assigns) do
    ~H"""
    <%= if @history != [] do %>
      <div class="mt-6 pt-3 border-t border-bg-3/60">
        <div class="uppercase tracking-widest text-ink-2 text-[10px] mb-2">Versionen</div>
        <ul class="space-y-1">
          <%= for h <- @history do %>
            <li class="flex items-baseline gap-2 text-xs">
              <span class="font-mono text-ink-2">#{h["seq"]}</span>
              <span class="text-ink-1">{format_ts(h["edited_at"])}</span>
              <span class={["pill", source_pill(h["source"])]}>
                {h["source"] || "?"}
              </span>
              <.ls_icon_btn_compat
                kind={:diff}
                size={:sm}
                phx-click="epos_diff_open"
                phx-value-seq={h["seq"]}
                title="Diff zur aktuellen Version"
                class="ml-auto"
              />
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  defp epos_diff(assigns) do
    current_md = (assigns.current && assigns.current["content_md"]) || ""

    target =
      Enum.find(assigns.history, fn h -> h["seq"] == assigns.target_seq end)

    target_md = (target && target["content_md"]) || ""

    diff =
      List.myers_difference(
        String.split(target_md, "\n"),
        String.split(current_md, "\n")
      )

    assigns = assign(assigns, diff: diff, target: target)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-baseline justify-between">
        <h3 class="font-display text-sm tracking-wide">
          Diff: #{(@target && @target["seq"]) || "?"} → current
        </h3>
        <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="epos_diff_close" title="Zurück zur Epos-Ansicht" />
      </div>
      <div class="text-xs font-mono bg-bg-0 border border-bg-3 rounded p-3 overflow-x-auto whitespace-pre">
        <%= for {op, lines} <- @diff, line <- lines do %>
          <div class={diff_line_class(op)}>{diff_prefix(op)}{line}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp diff_line_class(:eq), do: "text-fg-muted"
  defp diff_line_class(:del), do: "text-danger bg-danger/10"
  defp diff_line_class(:ins), do: "text-success bg-success/10"

  defp diff_prefix(:eq), do: "  "
  defp diff_prefix(:del), do: "- "
  defp diff_prefix(:ins), do: "+ "

  defp source_pill("manual"), do: "pill-archived"
  defp source_pill("llm"), do: "pill-new"
  defp source_pill(_), do: ""

  # ─── Faithfulness (Issue #11 Phase 2) ─────────────────────────
  # Score-Map nach session_id für O(1)-Lookup im Template.
  defp faithfulness_index(list) when is_list(list) do
    Enum.into(list, %{}, fn entry -> {entry["session_id"], entry} end)
  end

  defp faithfulness_index(_), do: %{}

  defp faithfulness_label(score) when is_number(score) do
    pct = round(score * 100)
    "📊 #{pct}%"
  end

  defp faithfulness_label(_), do: "📊 –"

  defp faithfulness_pill_class(score) when is_number(score) and score >= 0.8,
    do: "bg-success/20 text-success border border-success/40"

  defp faithfulness_pill_class(score) when is_number(score) and score >= 0.5,
    do: "bg-warning/20 text-warning border border-warning/40"

  defp faithfulness_pill_class(score) when is_number(score),
    do: "bg-danger/20 text-danger border border-danger/40"

  defp faithfulness_pill_class(_), do: "bg-surface-2/40 text-fg-muted"

  defp faithfulness_claim_dot("entailment"), do: "bg-success"
  defp faithfulness_claim_dot("contradiction"), do: "bg-danger"
  defp faithfulness_claim_dot(_), do: "bg-warning"

  # ─── Helpers ──────────────────────────────────────────────────

  defp rec_state(nil), do: :idle
  defp rec_state(%{status: status}), do: status

  defp elapsed(%{started_at: started}) when not is_nil(started) do
    started_dt =
      case started do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %DateTime{} = dt ->
          dt
      end

    case started_dt do
      nil ->
        "00:00:00"

      dt ->
        secs = DateTime.diff(DateTime.utc_now(), dt)
        h = div(secs, 3600)
        m = rem(div(secs, 60), 60)
        s = rem(secs, 60)

        :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s])
        |> IO.iodata_to_binary()
    end
  end

  defp elapsed(_), do: "00:00:00"

  defp format_ts(nil), do: "--:--:--"

  defp format_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso
    end
  end

  defp protokoll_subtitle(nil), do: "Transkript"
  defp protokoll_subtitle(%{number: n}), do: "Session #{n} · Transkript"

  # Issue #8: ein Toggle ist erlaubt wenn die Spalte schon zu ist (Aufklappen
  # geht immer) oder wenn nach dem Einklappen noch mind. eine andere offen
  # bleibt.
  defp can_collapse?(collapsed_cols, name) do
    MapSet.member?(collapsed_cols, name) or
      MapSet.size(collapsed_cols) < length(@col_names) - 1
  end

  # Returns [{session_label, [utterance, ...]}, ...] preserving the order in
  # which session_ids first appear in `utterances` (i.e. chronological).
  defp group_by_session(utterances, sessions) do
    sess_by_id =
      Enum.into(sessions || [], %{}, fn s -> {s["id"], s} end)

    utterances
    |> Enum.chunk_by(& &1["session_id"])
    |> Enum.map(fn group ->
      sid = List.first(group)["session_id"]
      {session_label(sess_by_id[sid], sid), group}
    end)
  end

  defp session_label(nil, sid), do: "Session ?? · #{String.slice(sid || "", 0, 8)}"

  defp session_label(%{"number" => n, "name" => name}, _sid) when is_binary(name) and name != "",
    do: "Session #{n} · #{name}"

  defp session_label(%{"number" => n}, _sid), do: "Session #{n}"

  # Issue #302: Ein-Klick-Raummikro. Nach `rec_single_start` ist
  # `pending_single_source_mic?` gesetzt; sobald die Session im Snapshot aktiv
  # ist, startet die LiveView das Mikro automatisch — Consent-gated, Quelle
  # immer "mic" (Single-Source = echtes Raummikro, nie System-Audio). Damit
  # entfällt der separate Mikro-Klick. Idempotent: Flag wird sofort gelöscht.
  defp maybe_autostart_single_source_mic(socket) do
    # Issue #355: Map.get/3 statt Bracket-Access — beim ersten apply_snapshot
    # nach mount kann der assign rund um Recording-State-Broadcasts kurz nil
    # sein. `nil and ...` würde BadBooleanError raisen + LV crashen + Recording
    # Beenden-Klick nicht mehr ankommen.
    if socket.assigns[:pending_single_source_mic?] == true and
         socket.assigns[:active_session] and
         not (Map.get(socket.assigns, :mic_on?, false) == true) do
      sid = socket.assigns.active_session.id
      socket = assign(socket, :pending_single_source_mic?, false)

      # Issue #391: auch der Ein-Klick-Raummikro-Pfad geht durchs Setup-Popup
      # (Device-Auswahl + Voice-Test). consent_mode :single_source blendet bei
      # Bedarf das v2-Häkchen ein. mic_on? wird erst bei Voice-OK + Consent-OK
      # gesetzt (maybe_finish_mic_setup).
      open_mic_setup(socket, sid, :single_source)
    else
      socket
    end
  end

  # Sorgt dafür, dass beim ersten Snapshot-Load die höchste Session-Nummer
  # automatisch expanded ist (Issue #207). Nur wenn die User-State-MapSet
  # leer ist — User-Toggles bleiben sonst erhalten.
  defp ensure_default_session_expanded(socket) do
    expanded = socket.assigns.expanded_sessions
    sessions = socket.assigns.sessions || []

    if MapSet.size(expanded) == 0 and sessions != [] do
      top = highest_session(sessions)

      if top,
        do: assign(socket, :expanded_sessions, MapSet.put(expanded, top["id"])),
        else: socket
    else
      socket
    end
  end

  defp highest_session(sessions) do
    sessions
    |> Enum.reject(&is_nil(&1["number"]))
    |> Enum.max_by(& &1["number"], fn -> nil end)
  end

  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: "")
  attr(:busy?, :boolean, default: false)
  attr(:collapsed?, :boolean, default: false)
  attr(:can_collapse?, :boolean, default: true)
  slot(:inner_block, required: true)

  defp column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name={@name} title={@title} busy?={@busy?} />
    <% else %>
      <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
        <div class="col-header">
          <span class="flex items-center gap-2">
            {@title}
            <.busy_dot show?={@busy?} />
          </span>
          <span class="flex items-center gap-2">
            <%= if @subtitle != "" do %>
              <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">
                {@subtitle}
              </span>
            <% end %>
            <.collapse_chevron name={@name} can_collapse?={@can_collapse?} direction={:close} />
          </span>
        </div>
        <div class="flex-1 overflow-y-auto p-4 scroll-smooth" data-col={@name}>
          <%!-- Issue #370: 40vh Top/Bottom-Padding damit das erste/letzte
               Item bis in die Container-Mitte gescrollt werden kann
               (Sync-Anker greift auf Center-Y). --%>
          <div class="h-[40vh]" aria-hidden="true"></div>
          {render_slot(@inner_block)}
          <div class="h-[40vh]" aria-hidden="true"></div>
        </div>
      </div>
    <% end %>
    """
  end

  # Schmaler vertikaler Strip für eingeklappte Spalten (Issue #8).
  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:busy?, :boolean, default: false)

  defp collapsed_strip(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col items-center justify-between py-2 w-10 transition-all duration-200 border-l border-bg-3/40">
      <.ls_icon_btn_compat
        kind={:expand}
        size={:sm}
        phx-click="col_toggle"
        phx-value-col={@name}
        title="Spalte aufklappen"
      />
      <span class="flex-1 flex items-center justify-center">
        <span
          class="text-ink-1 text-xs uppercase tracking-widest font-display"
          style="writing-mode: vertical-rl; transform: rotate(180deg);"
        >
          {@title}
        </span>
      </span>
      <.busy_dot show?={@busy?} />
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:can_collapse?, :boolean, default: true)
  attr(:direction, :atom, values: [:close, :open], default: :close)

  defp collapse_chevron(assigns) do
    ~H"""
    <.ls_icon_btn_compat
      kind={if @direction == :close, do: :collapse, else: :expand}
      size={:sm}
      phx-click="col_toggle"
      phx-value-col={@name}
      disabled={not @can_collapse?}
      title={if @direction == :close, do: "Spalte einklappen", else: "Spalte aufklappen"}
    />
    """
  end

  attr(:show?, :boolean, default: false)

  defp busy_dot(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[10px] font-sans uppercase tracking-wide transition-opacity",
      not @show? && "opacity-0"
    ]}>
      <span class="relative flex h-2 w-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent opacity-75"></span>
        <span class="relative inline-flex rounded-full h-2 w-2 bg-accent"></span>
      </span>
      <span class="text-accent">LLM</span>
    </span>
    """
  end

  defp empty_col(assigns) do
    ~H"""
    <p class="text-ink-2 text-sm italic">{@text}</p>
    """
  end

  # ─── Issue #379/#381: Utterance-Status + ASR-Confidence-Helpers ───
  # Public defs damit Tests sie reflexiv aufrufen können.

  @uncertainty_threshold 0.5
  @low_token_fraction_threshold 0.2

  @doc """
  Issue #379/#381: flaggt eine Utterance als ASR-unsicher.

  ## Vier-Fälle-Matrix (Status × Confidence-Format × Origin)

  | Fall              | Confidence-Map                    | Schutzmechanismus          |
  |-------------------|-----------------------------------|----------------------------|
  | neu-real          | `low_token_fraction>0.2, n>0`     | Primary feuert             |
  | neu-Platzhalter   | `low_token_fraction=0, n=0`       | `n > 0`-Guard im Primary   |
  | alt-real          | nur `mean_p`+`min_p`, `min_p<0.5` | Fallback feuert via `p≠m`  |
  | alt-Platzhalter   | `mean_p == min_p`, kein neues Fld | Fallback `p != m` greift   |

  Drei verschiedene Schutzmechanismen — nicht zu einem vereinfachen,
  sonst kippt einer der vier Fälle. Status-Gate (`confirmed`/`live`)
  liegt unabhängig davon vor beiden Pfaden.

  ## Caveats

  - **Kurzes-Ende-Bias (v1):** bei sehr kleinem `token_count` (n<8) ist
    `low_token_fraction` grob (z.B. N=2 → nur 0/0.5/1.0 möglich) und
    über-sensitiv für Clip-Rand-Tokens. Adressierbar später via
    `n >= N_min`-Guard, sobald Real-Data zeigt wie oft das auftritt.
  - **Eingefrorenes Aggregat:** das Worker-Setting
    `:confidence_low_token_threshold` wird zur Transkriptionszeit
    eingelesen. Späteres Drehen wirkt nur auf neue Utterances.
  - **Zwei-dimensionales Tuning:** Per-Token (Worker, 0.5) × Fraction
    (Hub, 0.2) — beide im Blick haben beim Tunen.
  """
  @spec asr_uncertain?(map()) :: boolean

  # Primary: neue längen-normalisierte Metrik (Issue #381)
  def asr_uncertain?(%{
        "status" => s,
        "confidence" => %{"low_token_fraction" => f, "token_count" => n}
      })
      when s in ["confirmed", "live"] and is_number(f) and is_integer(n) and n > 0 do
    f > @low_token_fraction_threshold
  end

  # Fallback: alte Utts ohne low_token_fraction-Feld (vor #381)
  def asr_uncertain?(%{
        "status" => s,
        "confidence" => %{"min_p" => p, "mean_p" => m} = c
      })
      when s in ["confirmed", "live"] and is_number(p) and is_number(m) do
    not Map.has_key?(c, "low_token_fraction") and p < @uncertainty_threshold and p != m
  end

  def asr_uncertain?(_), do: false

  @doc """
  Tooltip-Text für den ASR-Unsicherheits-Flag. Framt bewusst als
  „Modell-Unsicherheit" (nicht „Fehler"), weil low-confidence-Tokens
  häufig seltene-aber-korrekte Eigennamen oder Schnitt-Ränder sind
  (siehe #376-Review-Diskussion). Zwei Varianten — Fraction-basiert
  (Issue #381) und Fallback (min_p, mit Längen-Bias-Caveat).
  """
  @spec uncertainty_tooltip(map()) :: String.t()

  # Issue #381: Fraction-basiert. Kurz-Ende-Caveat bei n<8.
  def uncertainty_tooltip(%{"confidence" => %{"low_token_fraction" => f, "token_count" => n}})
      when is_number(f) and is_integer(n) and n > 0 do
    short_caveat =
      if n < 8,
        do:
          " Hinweis: kurze Utterances (n<8) sind anfällig für Clip-Rand-Tokens — Fraction-Aussage hier grob.",
        else: ""

    "ASR-Unsicherheit — #{round(f * 100)}% der #{n} Tokens unter Konfidenz-Schwelle. " <>
      "Häufig bei seltenen Eigennamen, Schnitträndern oder leiser Sprache — kein Fehler-Marker." <>
      short_caveat
  end

  # Fallback (alte Utts ohne neue Felder): min_p mit Längen-Bias-Hinweis.
  def uncertainty_tooltip(%{"confidence" => %{"min_p" => p, "mean_p" => m}})
      when is_number(p) and is_number(m) do
    "ASR-Unsicherheit — niedrigste Token-Konfidenz #{Float.round(p, 2)} (mean #{Float.round(m, 2)}). " <>
      "Hinweis: alte Aggregation, lange Utts flaggen statistisch häufiger."
  end

  def uncertainty_tooltip(_), do: "ASR-Unsicherheit"

  @doc """
  Tooltip-Label pro Utterance-Status. Default-Fallback für unbekannte
  Status macht das Quadrat sichtbar grau statt stillem Verschwinden.
  """
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("confirmed"), do: "bestätigt"
  def status_label("live"), do: "live (Transkription läuft)"
  def status_label("edited"), do: "editiert"
  def status_label("manual"), do: "manuell hinzugefügt"
  def status_label(nil), do: "bestätigt"
  def status_label(other), do: "unbekannter Status: #{inspect(other)}"

  @doc """
  Theme-Token-Klasse für das Status-Quadrat. `deleted` returnt `nil`
  → Render-Logik filtert die Utterance ohnehin raus.
  """
  @spec status_dot_class(String.t() | nil) :: String.t() | nil
  def status_dot_class("confirmed"), do: "bg-success"
  def status_dot_class("live"), do: "bg-accent animate-pulse"
  def status_dot_class("edited"), do: "bg-warning"
  def status_dot_class("manual"), do: "bg-accent-soft"
  def status_dot_class("deleted"), do: nil
  def status_dot_class(nil), do: "bg-success"
  def status_dot_class(_), do: "bg-ink-2"
end
