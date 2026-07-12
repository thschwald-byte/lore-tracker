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

  # Issue #570: alle :reload-/Watchdog-Timer hier sind via Issue-#321-Coalescing
  # (genau ein ausstehender Timer, selbst-reschedulend) bzw. lifecycle-gebunden
  # (Stille-Watchdog, stirbt mit dem LV-Prozess) — kein Leak, kein cancel_timer
  # nötig. Der file-level-Check-Hit wäre ein False-Positive.
  # credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup

  # Issue #434, Cut 2: View-Schicht (Function-Components + reine Präsentations-/
  # Formatierungs-Helfer) ausgelagert. Issue #570: die großen Modals/Editoren
  # liegen in `Editors`. Beide Imports machen die Komponenten im colocated
  # campaign_live.html.heex (`<.column>`, `<.flavor_editor>` …) + die geteilten
  # pure Helfer auf der Logik-Seite verfügbar.
  import HubWeb.CampaignLive.Components
  import HubWeb.CampaignLive.Editors

  # Issue #434, Cut 3 + Cut 4: Domänen-Kontext-Module + gemeinsamer Publish-Pfad.
  # Die handle_event/handle_info-Klauseln in diesem Modul delegieren in diese.
  # Issue #570: Snapshot/Reload-Schicht in `Snapshot` ausgelagert.
  alias HubWeb.CampaignLive.{
    Layout,
    Members,
    Meta,
    Mic,
    Recording,
    Refs,
    Snapshot,
    Speakers,
    StageEdits,
    Stil,
    Updates,
    Utterances
  }

  alias Hub.Events
  require Logger

  # Column-Keys für Collapse-Persistenz (Issue #8). Reihenfolge entspricht
  # dem Render-Layout — wichtig nur als kanonischer Whitelist-Check.
  @col_names ~w(chronik epos summaries protokoll)

  # Issue #570: Event-Kind-SSoT. Die Receiver-handle_info-Heads matchen über
  # diese Compile-Zeit-Attribute (= String-Literale, im Pattern-Head erlaubt)
  # statt hardcodierter Strings → kein Drift gegen Shared.Events.
  @utterance_appended Shared.Events.utterance_appended()
  @marker_added Shared.Events.marker_added()
  @utterance_edited Shared.Events.utterance_edited()
  @utterance_deleted Shared.Events.utterance_deleted()
  @session_ended Shared.Events.session_ended()
  @session_started Shared.Events.session_started()
  @recording_state_changed Shared.Events.recording_state_changed()
  @member_role_promoted Shared.Events.member_role_promoted()
  @member_removed Shared.Events.member_removed()
  @campaign_alias_set Shared.Events.campaign_alias_set()
  @speaker_assigned Shared.Events.speaker_assigned()
  @campaign_deleted Shared.Events.campaign_deleted()

  # Issue #442/#570: Kind-Listen für die Dispatch-Guards (Attribute inlinen zu
  # Literalen → im `in`-Guard erlaubt, drift-sicher gegen Shared.Events).
  @inplace_kinds [
    Shared.Events.invite_created(),
    Shared.Events.invite_revoked(),
    Shared.Events.session_scheduled()
  ]
  @scope_reload_kinds [
    Shared.Events.session_summary_generated(),
    Shared.Events.session_summary_edited(),
    Shared.Events.chronik_entry_changed(),
    Shared.Events.epos_entry_edited(),
    Shared.Events.campaign_flavor_set(),
    Shared.Events.campaign_vorgabe_set(),
    Shared.Events.campaign_vocab_updated(),
    Shared.Events.campaign_updated(),
    Shared.Events.invite_redeemed(),
    Shared.Events.admin_member_added(),
    Shared.Events.user_upserted(),
    Shared.Events.user_role_set(),
    # Issue #724 Slice F: Review-Queue-Fakt-Korrektur — ohne diesen Kind würde
    # der Catch-all das Event ignorieren, kein Reload nach Speichern/Dismiss.
    Shared.Events.session_fact_date_set()
  ]
  @full_reload_kinds [Shared.Events.session_deleted()]

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
      Process.send_after(self(), :mic_silence_tick, Mic.silence_tick_ms())
    end

    # Issue #570: der statische Default-Assign-Block lebt in Snapshot.initial_assigns/1
    # (mount bleibt dünner Koordinator). current_user/campaign_id kommen aus den Args.
    # Issue #607: mount_load lädt den Snapshot async (kein blockierender Worker-
    # Roundtrip mehr im mount) — forbidden?/not_found? werden in
    # handle_async(:reload_snapshot) aufgelöst, nicht mehr hier.
    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:campaign_id, campaign_id)
      |> Snapshot.initial_assigns()
      |> Snapshot.mount_load()

    {:ok, socket}
  end

  # ─── Recording-bar events ───────────────────────────────────────

  @impl true
  def handle_event("rec_start", _, socket), do: Recording.start(socket)
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

  # ─── Mikro-Domäne (Issue #391/#400/#405/#412/#415/#317/#399 → CampaignLive.Mic) ───

  def handle_event("mic_join", _, socket), do: Mic.join(socket)

  # Issue #642: Raummikro-Beitritt (mehrere Sprecher, eine diarisierte Spur).
  def handle_event("mic_join_multi", _, socket), do: Mic.join_multi(socket)

  def handle_event("mic_setup_devices_ready", %{"devices" => _} = payload, socket),
    do: Mic.setup_devices_ready(socket, payload)

  def handle_event("mic_setup_devices_ready", _, socket), do: {:noreply, socket}

  def handle_event("mic_setup_select_device", %{"device_id" => device_id}, socket)
      when is_binary(device_id) and device_id != "",
      do: Mic.setup_select_device(socket, device_id)

  def handle_event("mic_setup_select_device", _, socket), do: {:noreply, socket}

  def handle_event("mic_setup_local_level", %{"level" => level}, socket)
      when is_number(level),
      do: Mic.setup_local_level(socket, level)

  def handle_event("mic_setup_local_level", _, socket), do: {:noreply, socket}

  def handle_event("mic_setup_phrase_clip", %{"chunk" => chunk} = payload, socket)
      when is_binary(chunk) and chunk != "",
      do: Mic.setup_phrase_clip(socket, payload)

  def handle_event("mic_setup_phrase_clip", _, socket), do: {:noreply, socket}

  def handle_event("mic_setup_consent_toggle", _, socket), do: Mic.setup_consent_toggle(socket)

  def handle_event("mic_setup_cancel", _, socket), do: Mic.setup_cancel(socket)

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

  def handle_event("mic_leave", _, socket), do: Mic.leave(socket)

  def handle_event("mic_local_state", %{"recording" => recording}, socket),
    do: Mic.local_state(socket, recording)

  def handle_event("mic_error", %{"reason" => reason}, socket), do: Mic.error(socket, reason)

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

  # ─── Session-In-Game-Datum-Anker (Issue #724 Slice F) ───────────

  def handle_event("session_date_edit_start", %{"session" => sid}, socket),
    do: StageEdits.session_date_edit_start(socket, sid)

  def handle_event("session_date_edit_cancel", _, socket),
    do: StageEdits.session_date_edit_cancel(socket)

  def handle_event("session_date_edit_save", %{"session" => sid, "in_game_date" => raw}, socket),
    do: StageEdits.session_date_edit_save(socket, sid, raw)

  # ─── Review-Queue-Fakt-Korrektur (Issue #724 Slice F) ───────────

  def handle_event("fact_date_edit_start", %{"session" => sid, "fact" => fid}, socket),
    do: StageEdits.fact_date_edit_start(socket, sid, fid)

  def handle_event("fact_date_edit_cancel", _, socket),
    do: StageEdits.fact_date_edit_cancel(socket)

  def handle_event(
        "fact_date_edit_save",
        %{
          "session" => sid,
          "fact" => fid,
          "extraction_event_id" => ext,
          "in_game_date" => raw
        },
        socket
      ),
      do: StageEdits.fact_date_edit_save(socket, sid, fid, ext, raw)

  def handle_event(
        "fact_dismiss",
        %{"session" => sid, "fact" => fid, "extraction_event_id" => ext},
        socket
      ),
      do: StageEdits.fact_dismiss(socket, sid, fid, ext)

  # ─── Kampagnen-Kalender (Issue #724 Slice F2) ───────────────────

  def handle_event("calendar_edit_save", %{"epoch_label" => epoch, "months" => months}, socket),
    do: StageEdits.calendar_edit_save(socket, epoch, months)

  def handle_event("calendar_reset", _, socket),
    do: StageEdits.calendar_reset(socket)

  # ─── Stil / Vorgabe pro Stage (Issue #313/#320 → CampaignLive.Stil) ─────

  # #787: summary/epos = Render-Prompt-Slots; chronik setzt nur die Spalten-
  # Überschrift (Timeline deterministisch, kein Prompt).
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

  # ─── Mitspieler-Verwaltung + Alias ──────────────────────────────
  # Issue #445: Member-Popup (#270), Promote/Demote (#140), Entfernen (#55),
  # Charakter-Name (#2) leben jetzt im `HubWeb.CampaignLive.MembersComponent`
  # (erstes LiveComponent). Die zugehörigen handle_events tragen dort
  # `phx-target={@myself}`. Hier bleibt nur der Flash-Bridge (handle_info
  # {:lc_flash, …} weiter unten) + die Einladungs-Events (invite_url ist
  # Parent-State, siehe `create_invite` unten).

  def handle_event("epos_edit_start", _, socket), do: StageEdits.epos_edit_start(socket)
  def handle_event("epos_edit_cancel", _, socket), do: StageEdits.epos_edit_cancel(socket)

  def handle_event("epos_edit_save", %{"content_md" => content_md}, socket),
    do: StageEdits.epos_edit_save(socket, content_md)

  def handle_event("epos_diff_open", %{"seq" => seq_str}, socket),
    do: StageEdits.epos_diff_open(socket, seq_str)

  def handle_event("epos_diff_close", _, socket), do: StageEdits.epos_diff_close(socket)

  # Issue #753: per-Kapitel-Edit (Ep_n).
  def handle_event("chapter_edit_start", %{"entry_id" => entry_id}, socket),
    do: StageEdits.chapter_edit_start(socket, entry_id)

  def handle_event("chapter_edit_cancel", _, socket), do: StageEdits.chapter_edit_cancel(socket)

  def handle_event("chapter_edit_save", %{"entry_id" => entry_id, "content_md" => md}, socket),
    do: StageEdits.chapter_edit_save(socket, entry_id, md)

  # ─── Column collapse/restore (Issue #8) ─────────────────────────

  def handle_event("col_toggle", %{"col" => col}, socket) when col in @col_names,
    do: Layout.col_toggle(socket, col)

  def handle_event("col_toggle", _, socket), do: {:noreply, socket}

  def handle_event("protokoll_session_toggle", %{"session" => sid}, socket),
    do: Layout.protokoll_session_toggle(socket, sid)

  # Issue #709: gleitendes Fenster — ältere/neuere Zeilen laden (Scroll-Sentinel
  # oder no-JS-Button), Gegenrand wird evincd (count ≤ window_max).
  def handle_event("utterance_load_older", %{"session" => sid}, socket),
    do: Layout.utterance_window_step(socket, sid, :older)

  def handle_event("utterance_load_newer", %{"session" => sid}, socket),
    do: Layout.utterance_window_step(socket, sid, :newer)

  # Issue #709: ColumnSync/Jump auf eine evincte Utterance — Session expandieren
  # + Fenster um sie herum setzen, dann scroll_to_utterance pushen.
  def handle_event("focus_utterance", %{"id" => id}, socket),
    do: Refs.focus_utterance(socket, id)

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
        {:event_appended, %{payload: %{"kind" => @utterance_appended} = payload}},
        socket
      ) do
    if session_in_campaign?(socket, payload["session_id"]) do
      {:noreply, update(socket, :utterances, &(&1 ++ [utterance_row(payload)]))}
    else
      {:noreply, socket}
    end
  end

  # Issue #702: Batch-Pfad für den Transkriptions-Backlog. UtteranceAppended
  # wird HIER gesondert behandelt statt über EventsBatch.fold, weil der
  # Per-Event-Fold gegen die (potenziell tausende Einträge lange)
  # :utterances-Liste O(n·m)-Listen-Kopien machen würde — ein Batch hängt
  # alle neuen Rows in EINEM update an. Restliche Kinds laufen durch die
  # bestehenden event_appended-Klauseln; ein handle_info = ein Diff.
  def handle_info({:events_batch, events}, socket) do
    {utts, rest} =
      Enum.split_with(events, &(&1.payload["kind"] == @utterance_appended))

    new_rows =
      utts
      |> Enum.filter(&session_in_campaign?(socket, &1.payload["session_id"]))
      |> Enum.map(&utterance_row(&1.payload))

    socket =
      if new_rows == [],
        do: socket,
        else: update(socket, :utterances, &(&1 ++ new_rows))

    HubWeb.Live.EventsBatch.fold(rest, socket, &handle_info/2)
  end

  def handle_info({:event_appended, %{payload: %{"kind" => @marker_added} = payload}}, socket) do
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
  def handle_info({:event_appended, %{payload: %{"kind" => @utterance_edited} = payload}}, socket) do
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
        {:event_appended, %{payload: %{"kind" => @utterance_deleted} = payload}},
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

  def handle_info({:event_appended, %{payload: %{"kind" => @session_ended} = payload}}, socket) do
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
          |> Mic.reset_mic_setup_state()
          |> push_event("mic:setup_abort", %{})

        true ->
          socket
      end

    {:noreply, push_event(socket, "signal:play", %{kind: "session_end"})}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => @session_started} = payload}}, socket) do
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
        {:event_appended, %{payload: %{"kind" => @recording_state_changed, "state" => state}}},
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

  # ─── Issue #442 Stage 1: Membership Tier-1 (In-Place, kein Worker-Roundtrip) ───
  # Payload-exakte Events → nur betroffene Assigns aktualisieren statt Voll-
  # Snapshot (der 2–3 s kostet). Perms re-derived via derive_assigns/2.

  def handle_info({:event_appended, %{payload: %{"kind" => @member_role_promoted} = p}}, socket),
    do: {:noreply, Updates.apply_member_role(socket, p)}

  def handle_info(
        {:event_appended, %{payload: %{"kind" => @member_removed, "discord_id" => did} = p}},
        socket
      ) do
    # Selbst-Removal → Voll-Reload: der forbidden/navigate-Pfad lebt nur im
    # Snapshot-Apply (apply_snapshot forbidden?), nicht im In-Place-Update.
    if did == socket.assigns.current_user.discord_id do
      Process.send_after(self(), :reload, 150)
      {:noreply, socket}
    else
      {:noreply, Updates.apply_member_removed(socket, p)}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => @campaign_alias_set} = p}}, socket),
    do: {:noreply, Updates.apply_alias(socket, p)}

  def handle_info({:event_appended, %{payload: %{"kind" => @speaker_assigned} = p}}, socket),
    do: {:noreply, Updates.apply_speaker(socket, p)}

  # Issue #442 Stage 2: Tier-2 scoped Reloads — nur den betroffenen Bereich vom
  # Worker holen (schmaler Read) statt Voll-Snapshot. scope_for_event/1 mappt
  # den kind auf den Worker-Scope; start_scope_load holt ihn async.
  # Issue #442 Final Cut: payload-exakte Tier-1 In-Place (kein Worker-Roundtrip,
  # kein Reconcile) für Invites + geplante Sessions. Variable+when-Form (wie die
  # scoped/bulk-Klauseln) statt Literal-im-Pattern → kein hardcoded-event-kind-
  # Drift; der kind-Dispatch lebt in Updates.apply_inplace/3.
  def handle_info({:event_appended, %{payload: %{"kind" => kind} = p}}, socket)
      when kind in @inplace_kinds do
    {:noreply, Updates.apply_inplace(socket, kind, p)}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in @scope_reload_kinds do
    {:noreply, Snapshot.start_scope_load(socket, Updates.scope_for_event(kind))}
  end

  # Voll-Reload bleibt BEWUSST für strukturelle Tier-3-Events (Issue #442):
  # SessionDeleted entfernt eine Session + alle ihre Utterances → rippt über
  # mehrere Assigns + die Refs-/Sync-Indizes; SessionStarted/SessionEnded
  # (eigene Klauseln oben) sind Recording-Lifecycle. Diese sind niederfrequent
  # und strukturell — ein scoped/in-place-Pfad lohnt nicht. (Issue #321 coalesced.)
  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in @full_reload_kinds do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  # Wenn die Kampagne gerade gelöscht wird, navigate weg statt zu reloaden
  # (Reload würde "kampagne nicht gefunden" werfen).
  def handle_info(
        {:event_appended, %{payload: %{"kind" => @campaign_deleted, "campaign_id" => cid}}},
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

  def handle_info(:reload, socket), do: {:noreply, Snapshot.start_snapshot_load(socket)}

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

  # Issue #445: Flash-Bridge aus dem MembersComponent. `put_flash/3` ist in
  # LiveComponents verboten — `Members.flash/3` sendet im LC-Kontext stattdessen
  # diese Self-Message an den Parent-LV, der hier flasht.
  def handle_info({:lc_flash, kind, msg}, socket),
    do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, Snapshot.start_snapshot_load(socket)}

  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status} =
           payload},
        socket
      ) do
    Snapshot.handle_pipeline_stage(cid, stage, status, payload["error"], socket)
  end

  # Older pipeline_status payloads (no explicit "kind") — keep matching the
  # stage shape so existing emitters that didn't tag a kind still work.
  def handle_info(
        {:pipeline_status,
         %{"campaign_id" => cid, "stage" => stage, "status" => status} = payload},
        socket
      ) do
    Snapshot.handle_pipeline_stage(cid, stage, status, payload["error"], socket)
  end

  # Issue #405: MicLive (sticky Capture-Owner) meldet einen Capture-Fehler
  # zurück (Device weg, Permission, kein Codec). Button zurücksetzen + Flash.
  # ─── Mic-PubSub (Issue #391/#399/#400/#405 → CampaignLive.Mic) ──────

  def handle_info({:mic_capture_failed, reason}, socket),
    do: Mic.on_capture_failed(socket, reason)

  def handle_info({:mic_audio_dropping, _sid}, socket),
    do: Mic.on_audio_dropping(socket)

  def handle_info({:clip_transcribed, req_id, text}, socket),
    do: Mic.on_clip_transcribed(socket, req_id, text)

  def handle_info({:clip_timeout, req_id}, socket), do: Mic.on_clip_timeout(socket, req_id)

  def handle_info(
        {:pipeline_status,
         %{"kind" => "mic_streamers", "campaign_id" => cid, "discord_ids" => dids}},
        socket
      ),
      do: Mic.on_streamers(socket, cid, dids)

  def handle_info(
        {:pipeline_status,
         %{"kind" => "mic_level", "campaign_id" => cid, "discord_id" => did, "level" => lvl}},
        socket
      ),
      do: Mic.on_level(socket, cid, did, lvl)

  def handle_info(:mic_silence_tick, socket), do: Mic.on_silence_tick(socket)

  # Issue #399: server-side Stille-Watchdog. Worker meldet, dass ein
  # Streamer >silence_alert_threshold_ms keinen Audio-Chunk mehr geschickt
  # hat (Browser-Crash, eingefrorener Tab) — bzw. die Recovery, wenn ein
  # Chunk wieder ankommt. CampaignLive zeigt das im UI als prominent
  # Banner, nicht nur als Capture-side Modal (das überlebt den Crash nicht).
  def handle_info(
        {:pipeline_status,
         %{
           "kind" => "streamer_silent",
           "campaign_id" => cid,
           "session_id" => sid,
           "discord_id" => did,
           "silent_for_ms" => silent_for_ms
         }},
        socket
      ),
      do: Mic.on_streamer_silent(socket, cid, sid, did, silent_for_ms)

  def handle_info(
        {:pipeline_status,
         %{
           "kind" => "streamer_recovered",
           "campaign_id" => cid,
           "session_id" => sid,
           "discord_id" => did
         }},
        socket
      ),
      do: Mic.on_streamer_recovered(socket, cid, sid, did)

  # Issue #104: Campaign-Replay-Engine broadcastet ihren Fortschritt als
  # kind="campaign_replay" — Banner-Update + Buttons-disable.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "campaign_replay", "campaign_id" => cid, "status" => status} = payload},
        socket
      ),
      do: Snapshot.apply_campaign_replay(socket, cid, status, payload)

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  # Issue #321/#430: async-Snapshot-Read-Ergebnis anwenden (hinter den
  # handle_info-Block gezogen — Klausel-Gruppierung).
  @impl true
  def handle_async(:reload_snapshot, {:ok, result}, socket) do
    socket =
      socket
      |> Snapshot.apply_snapshot(result)
      |> assign(:reload_state, :idle)

    # Issue #607: forbidden?/not_found? werden seit dem async-mount hier aufgelöst
    # (vorher im sync mount). Greift auch, wenn man den Zugriff mitten in der
    # Session verliert (Self-Removal → Reload liefert forbidden) → sauberer
    # Redirect statt einer toten Seite.
    cond do
      socket.assigns[:forbidden?] ->
        {:noreply, socket |> put_flash(:error, "Kein Zugriff") |> push_navigate(to: ~p"/")}

      socket.assigns[:not_found?] ->
        {:noreply,
         socket |> put_flash(:error, "Kampagne nicht gefunden") |> push_navigate(to: ~p"/")}

      socket.assigns.reload_dirty? ->
        {:noreply, socket |> assign(:reload_dirty?, false) |> Snapshot.schedule_reload()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_async(:reload_snapshot, {:exit, reason}, socket) do
    Logger.warning("CampaignLive: Snapshot-Reload abgebrochen: #{inspect(reason)}")
    {:noreply, assign(socket, :reload_state, :idle)}
  end

  # Issue #442 Stage 2: scoped Read fertig. Saubere Daten → nur betroffene
  # Assigns mergen (Updates.apply_scope). error/forbidden/not_found ODER alter
  # Worker (`unknown_scope` aus dem Catch-all) → kanonischer Voll-Reload als
  # Fallback (schedule_reload, coalesced).
  def handle_async(:reload_scope, {:ok, {scope_kind, {:ok, snap}}}, socket)
      when is_map(snap) do
    # `||` statt `or`: `forbidden`/`not_found` fehlen im sauberen Scoped-Snapshot
    # → Map.get liefert nil, und `or` verlangt links einen Boolean → sonst
    # BadBooleanError, die den LV bei JEDEM erfolgreichen Scoped-Reload crasht
    # (Silent-Fallback auf Voll-Remount; bei Free Seattle = Crash-Loop). Issue #710.
    if Map.has_key?(snap, "error") || snap["forbidden"] || snap["not_found"] do
      {:noreply, Snapshot.schedule_reload(socket)}
    else
      {:noreply, Updates.apply_scope(socket, scope_kind, snap)}
    end
  end

  def handle_async(:reload_scope, {:ok, {_scope_kind, _other}}, socket),
    do: {:noreply, Snapshot.schedule_reload(socket)}

  def handle_async(:reload_scope, {:exit, reason}, socket) do
    Logger.warning("CampaignLive: scoped Reload abgebrochen (#{inspect(reason)}) — Voll-Reload")
    {:noreply, Snapshot.schedule_reload(socket)}
  end

  # ─── Internal helpers ──────────────────────────────────────────

  # Payload → Anzeige-Row für die :utterances-Liste (Einzel- + Batch-Pfad, #702).
  defp utterance_row(payload) do
    %{
      "id" => payload["id"],
      "session_id" => payload["session_id"],
      "discord_id" => payload["discord_id"],
      "timestamp" => payload["timestamp"],
      "text" => payload["text"],
      "confidence" => payload["confidence"],
      "status" => payload["status"] || "confirmed"
    }
  end

  defp session_in_campaign?(_socket, nil), do: false

  defp session_in_campaign?(socket, sid) do
    Enum.any?(socket.assigns.sessions || [], fn s -> s["id"] == sid end)
  end

  # ─── Speaker resolution (Issue #19) ─────────────────────────────
  # Display-Helfer (vom colocated Template direkt aufgerufen → bleiben hier).
  # `speaker_assignment_map/1` wanderte nach #570 in CampaignLive.Snapshot.

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

  # ─── Snapshot ──────────────────────────────────────────────────
  # Issue #570: bridge_publish/2 + backfill_viewer_user/2 wanderten nach
  # CampaignLive.Snapshot (backfill ruft Publisher.publish/2 jetzt direkt).

  @doc """
  Issue #144: berechnet aus einem Campaign-Snapshot + viewer-discord_id die
  Permission-Assigns (campaign_role, perm_user, owner?, is_member? etc.).

  Wird vom Snapshot-Apply (`apply_snapshot/2`) der LV genutzt und vom
  `HubWeb.DebugController` für Admin-Debug-Dumps wiederverwendet — damit beide
  Pfade garantiert identische Werte berechnen (kein Drift bei künftigen
  Permission-Refactors).
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

    role = HubWeb.Permissions.parse_role(snap["viewer_role"])

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
      # Issue #140/#464: `owner?` = „per-Campaign-GM" (per-Campaign-:spielleiter
      # ODER globaler :admin), `can_edit_meta?` = „darf Campaign-Inhalte editieren".
      # Issue #464: NICHT mehr die Regel `role == :admin or campaign_role ==
      # :spielleiter` von Hand nachbauen (Drift-Risiko gegenüber Permissions) —
      # stattdessen über Permissions.can?/3 ableiten, sodass die GM-Regel an genau
      # EINER Stelle lebt. `:delete_campaign` ist die repräsentative GM-only-Action
      # (owner?), `:edit_summary` die repräsentative Edit-Action (can_edit_meta?);
      # beide reduzieren in Permissions auf dieselbe Bedingung.
      owner?: HubWeb.Permissions.can?(perm_user, :delete_campaign, c),
      can_edit_meta?: HubWeb.Permissions.can?(perm_user, :edit_summary, c),
      can_regenerate_session?: HubWeb.Permissions.can?(perm_user, :regenerate_session, c),
      can_regenerate_campaign?: HubWeb.Permissions.can?(perm_user, :regenerate_campaign, c),
      can_assign_speaker?: HubWeb.Permissions.can?(perm_user, :assign_speaker, c),
      # #720: vorher als einziger Permission-Check im Template (heex Z. 75)
      # bei jedem Re-Render neu berechnet — jetzt vorberechnet wie alle can_*.
      can_vocab?: HubWeb.Permissions.can?(perm_user, :edit_vocab, c),
      # Issue #724 Slice F2: Kampagnen-Kalender editieren.
      can_calendar?: HubWeb.Permissions.can?(perm_user, :edit_calendar, c)
    }
  end
end
