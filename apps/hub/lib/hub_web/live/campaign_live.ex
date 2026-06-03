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

  # Issue #434, Cut 2: View-Schicht (15 Function-Components + reine
  # Präsentations-/Formatierungs-Helfer) ausgelagert. Import macht sie im
  # colocated campaign_live.html.heex (`<.column>`, `display_for/2` …) und auf
  # der Logik-Seite (geteilte pure Helfer) verfügbar.
  import HubWeb.CampaignLive.Components

  # Issue #434, Cut 3 + Cut 4: Domänen-Kontext-Module + gemeinsamer Publish-Pfad.
  # Die handle_event/handle_info-Klauseln in diesem Modul delegieren in diese.
  alias HubWeb.CampaignLive.{
    Layout,
    Members,
    Meta,
    Publisher,
    Recording,
    Refs,
    Speakers,
    StageEdits,
    Stil,
    Utterances
  }

  alias Hub.{EventBridge, Events, Reader}
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
  def handle_event("rec_start", _, socket), do: Recording.start(socket)
  def handle_event("rec_single_start", _, socket), do: Recording.single_start(socket)
  def handle_event("rec_pause", _, socket), do: Recording.pause(socket)
  def handle_event("rec_resume", _, socket), do: Recording.resume(socket)
  def handle_event("rec_stop", _, socket), do: Recording.stop(socket)
  def handle_event("rec_marker", _, socket), do: Recording.marker(socket)

  def handle_event("rerun_pipeline", %{"session" => session_id}, socket),
    do: Recording.rerun_pipeline(socket, session_id)

  def handle_event("rerun_campaign", _params, socket), do: Recording.rerun_campaign(socket)

  # ─── Speaker assignment (Issue #19 → CampaignLive.Speakers) ─────

  def handle_event("speaker_pick_start", %{"label" => label, "session" => sid}, socket),
    do: Speakers.pick_start(socket, label, sid)

  def handle_event("speaker_pick_cancel", _, socket), do: Speakers.pick_cancel(socket)

  def handle_event(
        "speaker_assign",
        %{"label" => label, "session" => sid, "discord_id" => did},
        socket
      ),
      do: Speakers.assign_speaker(socket, label, sid, did)

  def handle_event("speaker_unassign", %{"label" => label, "session" => sid}, socket),
    do: Speakers.unassign(socket, label, sid)

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
  # ─── Refs-Popover + Navigation (Issue #114 → CampaignLive.Refs) ─────

  def handle_event("show_refs", %{"kind" => kind, "id" => id}, socket),
    do: Refs.show_refs(socket, kind, id)

  def handle_event("show_utterance_refs", %{"id" => uid}, socket),
    do: Refs.show_utterance_refs(socket, uid)

  def handle_event("hide_refs", _, socket), do: Refs.hide_refs(socket)

  def handle_event("goto_utterance", %{"id" => uid}, socket),
    do: Refs.goto_utterance(socket, uid)

  def handle_event("goto_entry", %{"kind" => kind, "id" => id}, socket),
    do: Refs.goto_entry(socket, kind, id)

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

  # ─── Resümee / Vokabular / Chronik / Epos (→ CampaignLive.StageEdits) ───

  def handle_event("summary_edit_start", %{"session" => sid}, socket),
    do: StageEdits.summary_edit_start(socket, sid)

  def handle_event("summary_edit_cancel", _, socket), do: StageEdits.summary_edit_cancel(socket)

  def handle_event("vocab_edit_start", _, socket), do: StageEdits.vocab_edit_start(socket)
  def handle_event("vocab_edit_cancel", _, socket), do: StageEdits.vocab_edit_cancel(socket)

  def handle_event("vocab_edit_save", %{"vocab_hint" => text}, socket),
    do: StageEdits.vocab_edit_save(socket, text)

  # Issue #270: exklusiver Tab-Toggle. Click auf einen bereits offenen
  # Tab schließt ihn (nil). Sonst neuer Tab open, alter schließt.
  # ─── Tab-/Panel-UI-State (Issue #8/#207/#270 → CampaignLive.Layout) ───

  def handle_event("toggle_tab", %{"tab" => tab_str}, socket),
    do: Layout.toggle_tab(socket, tab_str)

  def handle_event("faithfulness_toggle", %{"session" => sid}, socket),
    do: Layout.faithfulness_toggle(socket, sid)

  def handle_event("summary_edit_save", %{"content_md" => content_md}, socket),
    do: StageEdits.summary_edit_save(socket, content_md)

  def handle_event("chronik_edit_start", %{"id" => id}, socket),
    do: StageEdits.chronik_edit_start(socket, id)

  def handle_event("chronik_edit_cancel", _, socket), do: StageEdits.chronik_edit_cancel(socket)

  def handle_event("chronik_edit_save", %{"chronik" => attrs}, socket),
    do: StageEdits.chronik_edit_save(socket, attrs)

  # ─── Utterance-Edits (Issue #3/#36 → CampaignLive.Utterances) ───

  def handle_event("utterance_edit_start", %{"id" => id}, socket),
    do: Utterances.edit_start(socket, id)

  def handle_event("utterance_edit_cancel", _, socket), do: Utterances.edit_cancel(socket)

  def handle_event("utterance_edit_save", %{"text" => text}, socket),
    do: Utterances.edit_save(socket, text)

  def handle_event("utterance_delete", %{"id" => id}, socket),
    do: Utterances.delete(socket, id)

  def handle_event("utterance_add_start", %{"session" => sid}, socket),
    do: Utterances.add_start(socket, sid)

  def handle_event("utterance_add_cancel", _, socket), do: Utterances.add_cancel(socket)

  def handle_event("utterance_add_save", %{"speaker" => speaker, "text" => text}, socket),
    do: Utterances.add_save(socket, speaker, text)

  # ─── Stil / Vorgabe pro Stage (Issue #313/#320 → CampaignLive.Stil) ─────

  def handle_event("stil_stage", %{"stage" => stage}, socket)
      when stage in ["summary", "epos", "chronik"],
      do: Stil.stage(socket, stage)

  def handle_event("stil_close", _, socket), do: Stil.close(socket)

  def handle_event("stil_preview", params, socket)
      when is_binary(socket.assigns.stil_stage),
      do: Stil.preview(socket, params)

  def handle_event("stil_preview", _params, socket), do: {:noreply, socket}

  def handle_event("stil_save", %{"stage" => stage} = params, socket)
      when stage in ["summary", "epos", "chronik"],
      do: Stil.save(socket, params)

  # ─── Kampagne löschen (Issue #15) ────────────────────────────────

  # ─── Kampagne/Session löschen (Issue #15/#294 → CampaignLive.Meta) ──

  def handle_event("campaign_delete_request", _, socket), do: Meta.delete_request(socket)
  def handle_event("campaign_delete_cancel", _, socket), do: Meta.delete_cancel(socket)

  def handle_event("campaign_delete_typing", %{"name" => typed}, socket),
    do: Meta.delete_typing(socket, typed)

  def handle_event("campaign_delete_confirm", %{"name" => typed}, socket),
    do: Meta.delete_confirm(socket, typed)

  def handle_event("session_delete", %{"session" => sid}, socket),
    do: Meta.session_delete(socket, sid)

  # ─── Mitspieler-Verwaltung (Issue #434, Cut 4 → CampaignLive.Members) ───
  # Member-Popup (#270), Entfernen (#55/#52A), Promote/Demote (#140 Phase B).

  def handle_event("open_member_popup", %{"discord_id" => did}, socket),
    do: Members.open_popup(socket, did)

  def handle_event("close_member_popup", _, socket), do: Members.close_popup(socket)

  def handle_event("member_remove_request", %{"discord_id" => did}, socket),
    do: Members.remove_request(socket, did)

  def handle_event("member_remove_cancel", _, socket), do: Members.remove_cancel(socket)

  def handle_event("member_remove_confirm", %{"discord_id" => did}, socket),
    do: Members.remove_confirm(socket, did)

  def handle_event("member_promote", %{"discord_id" => did}, socket),
    do: Members.promote(socket, did)

  def handle_event("member_demote_request", %{"discord_id" => did}, socket),
    do: Members.demote_request(socket, did)

  def handle_event("member_demote_cancel", _, socket), do: Members.demote_cancel(socket)

  def handle_event("member_demote_confirm", %{"discord_id" => did}, socket),
    do: Members.demote_confirm(socket, did)

  defp member_sl?(m), do: m["role"] in ["spielleiter", "owner"]

  # ─── Eigener Alias (Issue #2 → CampaignLive.Members) ────────────

  def handle_event("alias_edit_start", _, socket), do: Members.alias_edit_start(socket)
  def handle_event("alias_edit_cancel", _, socket), do: Members.alias_edit_cancel(socket)
  def handle_event("alias_edit_reset", _, socket), do: Members.alias_edit_reset(socket)

  def handle_event("alias_edit_save", %{"character_name" => name}, socket),
    do: Members.alias_edit_save(socket, name)

  def handle_event("epos_edit_start", _, socket), do: StageEdits.epos_edit_start(socket)
  def handle_event("epos_edit_cancel", _, socket), do: StageEdits.epos_edit_cancel(socket)

  def handle_event("epos_edit_save", %{"content_md" => content_md}, socket),
    do: StageEdits.epos_edit_save(socket, content_md)

  def handle_event("epos_diff_open", %{"seq" => seq_str}, socket),
    do: StageEdits.epos_diff_open(socket, seq_str)

  def handle_event("epos_diff_close", _, socket), do: StageEdits.epos_diff_close(socket)

  # ─── Column collapse/restore (Issue #8) ─────────────────────────

  def handle_event("col_toggle", %{"col" => col}, socket) when col in @col_names,
    do: Layout.col_toggle(socket, col)

  def handle_event("col_toggle", _, socket), do: {:noreply, socket}

  def handle_event("protokoll_session_toggle", %{"session" => sid}, socket),
    do: Layout.protokoll_session_toggle(socket, sid)

  def handle_event("col_restore", %{"collapsed" => list}, socket) when is_list(list),
    do: Layout.col_restore(socket, list)

  def handle_event("col_restore", _, socket), do: {:noreply, socket}

  # ─── Invite + shutdown events (unchanged) ───────────────────────

  # ─── Einladungen (Issue #36/#52 → CampaignLive.Members) ─────────

  def handle_event("create_invite", _, socket), do: Members.create_invite(socket)
  def handle_event("clear_invite_url", _, socket), do: Members.clear_invite_url(socket)

  def handle_event("revoke_invite", %{"token" => token}, socket),
    do: Members.revoke_invite(socket, token)

  def handle_event("shutdown_worker", _, socket), do: Meta.shutdown_worker(socket)

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

  # Issue #154 (Etappe 4c.2): Hub-LV erzeugt Events nicht mehr direkt via
  # EventLog.append, sondern delegiert an einen online Worker via
  # Hub.EventBridge. Worker macht Worker-First-Apply + sync zurück. Cold-Fail
  # (kein Worker für die Campaign online) wird nur geloggt — Hub-LV bleibt
  # responsive, das Event ist halt vorerst nicht propagiert. Die Sichtbarkeit
  # im LV passiert async über das nachfolgende event_appended-Broadcast.
  # Issue #434, Cut 4: Logik in HubWeb.CampaignLive.Publisher ausgelagert, damit
  # die Domänen-Kontext-Module (Members, …) denselben Publish-/Fehlerpfad nutzen.
  # Bestehende Aufrufer bleiben über diesen dünnen Delegate unverändert.
  defp bridge_publish(socket, payload), do: Publisher.publish(socket, payload)

  # Publish a CampaignAliasSet event for the acting user. Permission:
  # only members of the current campaign may set their own alias (and
  # only their own — owner-override is intentionally not implemented per
  # Issue #2 locked decisions).
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
          Refs.build_utterance_refs_index(
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
            Refs.build_sync_index(
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
    # Issue #438: `active_session` ist eine Map (oder nil) — als roher Operand im
    # `and` raised es ebenfalls BadBooleanError, sobald `pending? == true` den
    # Short-Circuit aufhebt (= immer wenn das Ein-Klick-Raummikro lief). Explizit
    # gegen nil prüfen statt die Map als Boolean zu missbrauchen.
    if socket.assigns[:pending_single_source_mic?] == true and
         socket.assigns[:active_session] != nil and
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
end
