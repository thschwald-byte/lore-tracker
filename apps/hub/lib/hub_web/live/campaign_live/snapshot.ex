defmodule HubWeb.CampaignLive.Snapshot do
  @moduledoc """
  Issue #570 (God-Module-Split aus `HubWeb.CampaignLive`): die Snapshot-/Reload-
  Schicht der Kampagnen-LiveView. Reine Socket-Transform-Funktionen (#434-Muster) —
  der LV-`handle_info`/`handle_async`/`mount` ruft sie als dünner Koordinator auf.

  Enthält:
  - `initial_assigns/1` — der statische mount-Default-Block.
  - `mount_load/1` (async Initial-Load, Issue #607 — vorher synchron, blockierte
    den mount) + `start_snapshot_load/1` / `start_scope_load/2` (async) +
    `schedule_reload/1` (das #321-Reload-Coalescing).
  - `apply_snapshot/2` (kanonischer Voll-Apply) + Helfer.
  - `handle_pipeline_stage/5` (Pipeline-Status → busy_stages) +
    `apply_campaign_replay/4` (Replay-Banner, Issue #104).

  `derive_assigns/2` bleibt bewusst in `HubWeb.CampaignLive` (öffentliche API, vom
  `DebugController` + `Updates` + Tests genutzt) — hier nur qualifiziert aufgerufen.

  ## credo:disable TimerWithoutCleanup (file-level)

  `schedule_reload/1` schedult einen 150ms-`:reload`-Timer. Das ist KEIN
  Leak: der `reload_state`-State-Automat (:idle→:scheduled→:running, Issue #321)
  garantiert genau EINEN ausstehenden :reload-Timer, selbst-reschedulend nach
  `handle_async`. Beim LV-Terminate stirbt der Timer mit dem Prozess. Kein
  `cancel_timer` nötig → der file-level-Check-Hit ist ein False-Positive.
  """

  # credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, start_async: 3]

  import HubWeb.CampaignLive.Components,
    only: [display_for: 2, highest_session: 1]

  alias HubWeb.CampaignLive
  alias HubWeb.CampaignLive.{Publisher, Refs}
  alias Hub.Reader

  # ─── mount-Defaults (Issue #570: aus mount/3 gezogen) ───────────

  @doc """
  Statischer Initial-Assign-Block der LV. `current_user`/`campaign_id` setzt der
  mount selbst (aus den Args), danach diese Defaults + `mount_load/1`.
  """
  def initial_assigns(socket) do
    socket
    |> assign(:active_nav, :campaign)
    # Issue #707: pro Session gerendertes Utterance-Fenster (session_id => count);
    # leer = Default-Fenster. "ältere anzeigen" bumpt den Eintrag.
    |> assign(:utterance_windows, %{})
    |> assign(:invite_url, nil)
    |> assign(:epos_mode, :view)
    |> assign(:epos_draft, "")
    |> assign(:epos_diff_seq, nil)
    # Issue #753: per-Kapitel-Edit (entry_id des Kapitels im Edit-Modus | nil).
    |> assign(:chapter_edit_id, nil)
    |> assign(:chapter_draft, "")
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
    |> assign(:summary_editing, nil)
    |> assign(:summary_draft, "")
    |> assign(:vocab_editing, false)
    |> assign(:vocab_draft, "")
    |> assign(:chronik_editing, nil)
    |> assign(:chronik_draft, %{})
    |> assign(:session_date_editing, nil)
    |> assign(:fact_date_editing, nil)
    |> assign(:utterance_editing, nil)
    |> assign(:utterance_draft, "")
    |> assign(:utterance_adding, nil)
    |> assign(:utterance_add_speaker, nil)
    |> assign(:utterance_add_text, "")
    # Issue #19: Single-Source-Sprecher-Picker.
    |> assign(:speaker_assignments, %{})
    |> assign(:can_assign_speaker?, false)
    # #720: vorberechnet statt Template-Check (heex Tab-Bar).
    |> assign(:can_vocab?, false)
    |> assign(:can_calendar?, false)
    |> assign(:calendar, %{})
    |> assign(:review_facts, [])
    # Issue #839 (Epic #829 Slice D3): Offene-Fäden-Panel.
    |> assign(:campaign_threads, [])
    # Issue #865 (Epic #861 Slice E): Lücken-Kurations-Panel.
    |> assign(:luecken, [])
    |> assign(:luecken_panel_open, false)
    |> assign(:luecke_editing, nil)
    # Issue #836 (Slice D2): aktiver Kurations-Edit ({key_canonical, "rename"|"merge"} | nil).
    |> assign(:thread_curate_editing, nil)
    # Issue #836: Panel-Offen-Zustand SERVER-verwaltet (überlebt LiveView-Patches;
    # ein natives <details> würde bei jeder Kurations-Aktion zuschnappen).
    |> assign(:threads_panel_open, false)
    |> assign(:speaker_pick, nil)
    # Issue #642: Routing-Typ des laufenden Mic-Setups (per_player|multi),
    # gesetzt beim Beitritt (open_mic_setup), genullt beim Reset.
    |> assign(:pending_mic_mode, nil)
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
    |> assign(:expanded_sessions, MapSet.new())
    # Issue #270: exklusiver Akkordeon-Reiter in der Top-Bar.
    |> assign(:open_tab, nil)
    # Issue #445: member_popup_open_for / alias_mode / alias_draft /
    # *_confirm_did sind jetzt LC-intern (MembersComponent), nicht mehr im
    # Parent-Assign-Namespace.
    # Issue #321: Reload-Coalescing-State. :idle | :scheduled | :running;
    # reload_dirty? merkt sich Änderungen, die während eines laufenden
    # async-Reads reinkamen → Nachlauf-Reload.
    |> assign(:reload_state, :idle)
    |> assign(:reload_dirty?, false)
  end

  # ─── Pipeline-Status (Issue #570: aus campaign_live gezogen) ─────

  @doc "Pipeline-Stage-Status → busy_stages + ggf. Fehler-Flash. Liefert {:noreply, socket}."
  def handle_pipeline_stage(cid, stage, status, error_msg, socket) do
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

  @doc """
  Issue #104: Campaign-Replay-Engine broadcastet ihren Fortschritt als
  kind="campaign_replay" — Banner-Update + Buttons-disable. Liefert {:noreply, socket}.
  """
  def apply_campaign_replay(socket, cid, status, payload) do
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

  # ─── Snapshot-Scope + Laden ─────────────────────────────────────

  defp snapshot_scope(socket) do
    %{
      "kind" => "campaign",
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }
  end

  # Issue #607: Initial-Load im mount. Früher synchron (`Reader.read` direkt im
  # mount, bis ~15s blockierend → GUI-Freeze beim Erst-Paint). Jetzt async wie
  # alle reaktiven Reloads: Safe-Defaults + `waiting?: true` (das Template zeigt
  # damit den Lade-Zustand statt zu crashen — dieselben `error_branch_defaults`,
  # die schon der #146-no_worker-Pfad nutzt), dann im connected mount ein
  # `start_snapshot_load` (start_async). `forbidden?`/`not_found?` werden danach
  # in `handle_async(:reload_snapshot)` aufgelöst, nicht mehr hier.
  #
  # Im disconnected (statischen) mount wird NICHT geladen — `start_async` braucht
  # einen connected Socket; der statische Erst-Render zeigt nur den Lade-Zustand.
  def mount_load(socket) do
    socket =
      socket
      |> assign(:waiting?, true)
      |> merge_or_default_assigns(error_branch_defaults(socket))

    if Phoenix.LiveView.connected?(socket) do
      start_snapshot_load(socket)
    else
      socket
    end
  end

  # Issue #321: Snapshot async vom Worker holen — die LV bleibt reagierbar.
  def start_snapshot_load(socket) do
    scope = snapshot_scope(socket)

    socket
    |> assign(:reload_state, :running)
    |> start_async(:reload_snapshot, fn -> Reader.read(scope) end)
  end

  # Issue #442 Stage 2: schmaler async Worker-Read für genau den Bereich eines
  # Tier-2-Events. Der scope_kind wird durch den Task durchgereicht (handle_async
  # braucht ihn fürs apply_scope). Unabhängig vom :reload_state-Coalescing der
  # Voll-Reloads — scoped Reads sind klein + idempotent; bei Fehler fällt
  # handle_async auf den (coalesceten) Voll-Reload zurück.
  def start_scope_load(socket, scope_kind) do
    scope = %{
      "kind" => scope_kind,
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }

    start_async(socket, :reload_scope, fn -> {scope_kind, Reader.read(scope)} end)
  end

  # Issue #321: Reload-Coalescing. Genutzt für den Nachlauf nach einem async-
  # Read, wenn währenddessen Events reinkamen (reload_dirty?). Schedult nur,
  # wenn keiner läuft/geplant ist; während :running wird nur dirty markiert.
  def schedule_reload(%{assigns: %{reload_state: :idle}} = socket) do
    Process.send_after(self(), :reload, 150)
    assign(socket, :reload_state, :scheduled)
  end

  def schedule_reload(%{assigns: %{reload_state: :running}} = socket),
    do: assign(socket, :reload_dirty?, true)

  def schedule_reload(socket), do: socket

  # ─── Apply ──────────────────────────────────────────────────────

  def apply_snapshot(socket, result) do
    case result do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, snap} ->
        # Issue #144: derive_assigns/2 zentral, damit DebugController
        # dieselbe Berechnung reproduzieren kann ohne LV-Mount.
        derived = CampaignLive.derive_assigns(snap, socket.assigns.current_user.discord_id)

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
        # Issue #752: per-Session-Epos-Kapitel (Wahrheitsbild) — koexistiert
        # mit dem Legacy-Buch (Mixed-State bei Bestandskampagnen).
        |> assign(:epos_chapters, snap["epos_chapters"] || [])
        |> assign(:epos_history, snap["epos_history"] || [])
        |> assign(:summaries, snap["summaries"] || [])
        |> assign(:chronik, snap["chronik"] || [])
        # Issue #724 Slice F2: aktueller Campaign-Kalender fürs Config-Formular.
        |> assign(:calendar, snap["calendar"] || %{})
        # Issue #746: Review-Queue — unplatzierbare Fakten.
        |> assign(:review_facts, snap["review_facts"] || [])
        # Issue #839 (Epic #829 Slice D3): Handlungsstränge fürs Offene-Fäden-Panel.
        |> assign(:campaign_threads, snap["campaign_threads"] || [])
        # Issue #865 (Epic #861 Slice E): Lücken-Kurations-Panel.
        |> assign(:luecken, snap["luecken"] || [])
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
        |> assign(:can_vocab?, derived.can_vocab?)
        |> assign(:can_calendar?, derived.can_calendar?)
        |> backfill_viewer_user(snap["users"] || %{})
        |> ensure_default_session_expanded()

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
      epos_chapters: [],
      epos_history: [],
      summaries: [],
      chronik: [],
      campaign_threads: [],
      luecken: [],
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
      can_assign_speaker?: false,
      can_vocab?: false,
      can_calendar?: false
    }
  end

  # Issue #387: LocalStorage-Pin der zuletzt besuchten Kampagne. Nur firen
  # wenn sich die Kampagne tatsächlich geändert hat — Tab-Toggles innerhalb
  # derselben Kampagne sollen keine redundanten LocalStorage-Writes
  # auslösen.
  defp maybe_push_last_campaign(socket, prev, %{"id" => id} = new) when prev != new,
    do: push_event(socket, "save-last-campaign", %{id: id})

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

  defp parse_session_status("scheduled"), do: :scheduled
  defp parse_session_status("running"), do: :running
  defp parse_session_status("recording"), do: :recording
  defp parse_session_status("completed"), do: :completed
  defp parse_session_status("ended"), do: :ended
  defp parse_session_status(_), do: :scheduled

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

  # ─── Speaker-Lookup-Map (Issue #570: aus campaign_live gezogen) ──
  # Die DISPLAY-Helfer (speaker_display/pseudo_speaker?/unassigned_speaker_count)
  # bleiben im LV — sie werden vom colocated Template direkt aufgerufen.

  # Wandelt die Snapshot-Liste in eine Lookup-Map
  # `%{"speaker:<sid>:<n>" => discord_id}` um.
  defp speaker_assignment_map(list) when is_list(list) do
    Enum.into(list, %{}, fn a -> {a["speaker_label"], a["discord_id"]} end)
  end

  defp speaker_assignment_map(_), do: %{}

  # ─── Viewer-Backfill ────────────────────────────────────────────

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
        # Issue #570: ruft Publisher direkt (der frühere bridge_publish/2-Delegate
        # im LV entfällt — einziger Caller war dieser Backfill).
        Publisher.publish(socket, %{
          "kind" => Shared.Events.user_upserted(),
          "discord_id" => user.discord_id,
          "display_name" => user.display_name
        })

        socket
    end
  end
end
