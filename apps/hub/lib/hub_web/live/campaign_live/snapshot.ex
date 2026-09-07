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

  alias HubWeb.CampaignLive.Updates
  alias HubWeb.CampaignLive.GlattFenster
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
    # Issue #915 (Cut 1): Lesen|Bearbeiten-Modus. Default :lesen (Erfolgs-
    # Prüfstein); localStorage-Hydration im connected mount überschreibt.
    # ALLE Modus-/Flag-Assigns hier defaulten → der statische Dead-Mount-Render
    # (läuft VOR connected?) crasht nicht.
    |> assign(:view_mode, :lesen)
    |> assign(:active_cols, HubWeb.CampaignLive.ViewMode.columns_for_mode(:lesen))
    # Issue #915 (Cut 1): Falsifikations-Flags (Slice 6 füllt sie). flagged_keys
    # = MapSet "kind:id" für O(1)-heex-Marker-Checks.
    # Issue #1122: Stand des laufenden Pipeline-Durchgangs (Laufband).
    |> assign(:pipeline_lauf, nil)
    |> assign(:flags, [])
    |> assign(:flagged_keys, MapSet.new())
    # Issue #916 (Cut 2): editierbare Fakten-Spalte. facts_editing =
    # {session_id, anchor_hash, field}-Tripel im Inline-Edit | nil.
    |> assign(:facts, [])
    |> assign(:facts_editing, nil)
    |> assign(:facts_loaded?, false)
    # Issue #707: pro Session gerendertes Utterance-Fenster (session_id => count);
    # leer = Default-Fenster. "ältere anzeigen" bumpt den Eintrag.
    |> assign(:utterance_windows, %{})
    # Issue #1087: die Zustände des Ladefensters aus EINER Quelle — die
    # #1090-Lehre (zwei handgepflegte Assign-Listen driften auseinander, und
    # ein fehlendes Assign fällt nicht beim Kompilieren auf, sondern als
    # kaputte Ansicht).
    |> assign(utterance_window_defaults())
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
    # Issue #987: Dummy-Assign, den `Recording.on_elapsed_tick/1` jede Sekunde
    # anfasst — zwingt LiveViews Change-Tracking, `elapsed(@active_session,
    # @clock_tick)` neu auszuwerten (der Ausdruck hängt sonst NUR an
    # `@active_session`, das sich während einer laufenden Session gar nicht
    # ändert → die Uhr blieb ohne diesen zweiten Parameter stehen, echter
    # Live-Test-Fund).
    |> assign(:clock_tick, nil)
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
    # Issue #391/#401: Live-Pegel pro Streamer während der Aufnahme. Ephemer,
    # kommt 5×/s über den per-Campaign `pipeline_status:<cid>`/mic_level-PubSub-
    # Pfad (seit #401 nur noch die eigene Kampagne, kein Fremdverkehr).
    |> assign(:mic_levels, %{})
    # Issue #988: Discord-Voice-Präsenz (ephemer, 5 Hz vom Worker). Leer = kein
    # Discord-Bot im Kanal ODER kein Worker verbunden — beides zeigt schlicht
    # keine Icons, kein Sonderzustand nötig.
    |> assign(:discord_participants, [])
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
    # Issue #985 Slice 1: Discord-Config-Tab (Vorbereitung Voice-Capture-Bot).
    |> assign(:can_discord_config?, false)
    |> assign(:discord_config, %{})
    |> assign(:review_facts, [])
    # Issue #839 (Epic #829 Slice D3): Offene-Fäden-Panel.
    |> assign(:campaign_threads, [])
    # #905: Arc-Review-Register (verwaiste + gemergte Bögen), default leer/zu.
    |> assign(:arc_review, %{})
    |> assign(:arc_review_open, false)
    # #905: aufgeklappte Fakt-Liste (key_canonical | nil).
    |> assign(:thread_facts_open, nil)
    # Issue #871 (+ #865): geglättete Block-Spalte mit Inline-Kuration.
    |> assign(:smoothed, [])
    # Ansicht pro Session (einfach|kuratieren|alles); fehlender Eintrag =
    # Auto-Default (kuratieren, wenn es Kuratierbares gibt, sonst einfach).
    |> assign(:glatt_view, %{})
    # Issue #883: gleitendes #709-Fenster pro Session in der Geglättet-Spalte
    # (session_id => {offset, count} über die GEFILTERTE Ansicht-Liste);
    # fehlender Eintrag = Tail-Default.
    |> assign(:glatt_windows, %{})
    # Issue #1153 (C6): nachgeladene Block-Texte, `%{block_id => texte}`.
    # Getrennt von `smoothed` gehalten, nicht hineingemischt: der Scope-Reload
    # ersetzt `smoothed` komplett (jede Kuration löst einen aus), und ein
    # Hineinmischen verlöre bei jedem Reload alles Nachgeladene — der
    # Betrachter sähe seine gerade gelesenen Blöcke wieder leer werden.
    |> assign(:glatt_texte, %{})
    |> assign(:luecke_editing, nil)
    # Issue #836 (Slice D2): aktiver Kurations-Edit ({key_canonical, "rename"|"merge"} | nil).
    |> assign(:thread_curate_editing, nil)
    # Issue #836: Panel-Offen-Zustand SERVER-verwaltet (überlebt LiveView-Patches;
    # ein natives <details> würde bei jeder Kurations-Aktion zuschnappen).
    |> assign(:threads_panel_open, false)
    # #901: Rauschen-Unter-Register (Meta-/Tisch-Stränge), default zugeklappt.
    |> assign(:rauschen_panel_open, false)
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
    # Issue #1149: was steht gerade in der Lese-Schlange? %{kind => Position}.
    # Leer heißt „nichts wartet" — nicht „nichts läuft".
    |> assign(:reader_queue, %{})
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
      "viewer_discord_id" => socket.assigns.current_user.discord_id,
      # Issue #1151 (Epic #1146, C4): die geglätteten Blöcke sind 72 % des
      # Snapshots (2014 von 2791 KB an echten Daten) und werden beim Mount
      # nicht gebraucht — die Spalte lädt sie ohnehin über `campaign_luecken`
      # nach. Gemessen senkt das Weglassen den Prozessheap des Reads um 92 %
      # und die Lesedauer von 197 auf 55 ms.
      #
      # Der Anlass ist ein Prod-Kill: ein EINZELNER Seitenaufruf riss den Hub
      # von 41 % Grundlast über das Limit, neun Sekunden nach dem Mount. Die
      # Warteschlange (#1149) half dort nicht — bei einem Betrachter gibt es
      # nichts zu serialisieren.
      #
      # Ein Alt-Worker ignoriert das Flag und liefert `smoothed` weiterhin;
      # dann greift `nachlade_glatt?/1` nicht und alles bleibt wie bisher.
      "glatt" => "lazy"
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
      start_snapshot_load(socket, :mount)
    else
      socket
    end
  end

  # Issue #321: Snapshot async vom Worker holen — die LV bleibt reagierbar.
  #
  # Issue #1169: `anlass` (:mount | :reload | :workers_changed) reist in die
  # Messzeilen. Der Voll-Read läuft aus drei Stellen an, und nur eine davon ist
  # ein Mount — ein Worker-Rejoin bei 16 offenen Tabs erzeugte sonst 16 Zeilen,
  # die wie Mounts aussähen (der Reconnect-Sturm aus #1149). Die Spitze ist
  # jedes Mal dieselbe, nur der Name darf nicht lügen.
  def start_snapshot_load(socket, anlass \\ :reload) do
    scope = snapshot_scope(socket)

    # Issue #1149: `self()` MUSS hier stehen und nicht in der Closure — dort
    # wäre es die Pid des Async-Tasks, und die Warte-Meldungen der Lese-
    # Schlange gingen an einen Prozess, der gleich wieder verschwindet.
    lv = self()
    # Issue #1169: Messzeile VOR dem Read — sie steht auch dann im Log, wenn
    # der Hub den Read nicht überlebt. Der Anlass wird gemerkt, damit die
    # Zeile NACH dem Read denselben tragen kann.
    Hub.MemoryReporter.marke("voll_read_start", kind: scope["kind"], anlass: anlass)

    socket
    |> assign(:reload_state, :running)
    |> assign(:voll_read_anlass, anlass)
    |> start_async(:reload_snapshot, fn -> Reader.read(scope, notify: lv) end)
  end

  # Issue #442 Stage 2: schmaler async Worker-Read für genau den Bereich eines
  # Tier-2-Events. Der scope_kind wird durch den Task durchgereicht (handle_async
  # braucht ihn fürs apply_scope). Unabhängig vom :reload_state-Coalescing der
  # Voll-Reloads — scoped Reads sind klein + idempotent; bei Fehler fällt
  # handle_async auf den (coalesceten) Voll-Reload zurück.
  @doc """
  Issue #1151 (Epic #1146, C4): stößt den Nachlade-Read für die geglättete
  Spalte an — aber nur, wenn der Worker sie tatsächlich weggelassen hat.

  **Die Unterscheidung hängt am fehlenden Schlüssel, nicht an einem leeren
  Wert.** Ein Alt-Worker kennt das `"glatt" => "lazy"`-Flag nicht und liefert
  `smoothed` wie bisher mit — dann wäre ein zweiter Read reine Verschwendung.
  Genau dafür lässt der Worker den Key **weg**, statt ihn auf `[]` zu setzen:
  eine Kampagne ohne geglättete Blöcke liefert `[]`, und auch dort ist nichts
  nachzuladen. Beide Fälle wären mit `[]` nicht unterscheidbar.

  Der Nachlade-Read läuft durch dieselbe Warteschlange wie der Voll-Read
  (`campaign_luecken` steht in `Hub.Reader`s `@serialized_kinds`), also
  **hinter** ihm statt daneben.

  **Damit hängt die ganze Cut-Kette an dieser Umleitung**, und das steht
  sonst nirgends: das Text-Fenster aus C5 (#1152) sitzt am
  `campaign_luecken`-Scope (`luecken.ex`: `smoothed_for_campaign(id, fenster:
  sc["glatt"] == "fenster")`). Der Haupt-Snapshot ging bisher **daran vorbei**
  und rief `smoothed_for_campaign/1` ohne Option — ungefenstert. Erst weil C4
  den Mount über `campaign_luecken` schickt, wird das Fenster für den
  Mount-Fall überhaupt erreichbar; C6 (#1153) setzt dann das Flag.

      C4 ohne C6   Mount entlastet, Spalten-Aufruf holt die volle Masse
      C6 ohne C4   gar keine Wirkung auf den Mount
      C4 + C6      beides gedeckelt Aus einer Spitze werden zwei kleinere
  nacheinander — genau die Entzerrung, für die die Schlange gebaut wurde.

  **Benannte Degradation:** bis der Scope ankommt, ist die Geglättet-Spalte
  leer und die 🕳-Gap-Marker auf den Ableitungen fehlen. `rebuild_refs` beim
  Scope-Apply stellt beides her. Für den Betrachter sind das die Sekunden
  zwischen zwei Reads — gemessen 55 ms für den Voll-Read, der Scope folgt
  unmittelbar.
  """
  def nachlade_glatt(socket, %{"smoothed" => _}), do: socket
  def nachlade_glatt(socket, %{"forbidden" => true}), do: socket
  def nachlade_glatt(socket, %{"not_found" => true}), do: socket
  # Issue #1153 (C6): DAS FLAG IST HIER PFLICHT, nicht Kosmetik. Ohne es holt
  # dieser Read die vollen Bloecke — an seattleV4 gemessen 3146 KB, also MEHR
  # als der Mount-Read, den C4 gerade auf 1202 KB gedrueckt hat. Der Hub starb
  # am 2026-09-07 um 13:53 und 13:55 genau hier, neun Sekunden nach dem Mount.
  # Mit Flag: 1253 KB (-60 %).
  def nachlade_glatt(socket, _snap),
    do: start_scope_load(socket, "campaign_luecken", Updates.scope_extra("campaign_luecken"))

  def start_scope_load(socket, scope_kind, extra \\ %{}) do
    scope =
      Map.merge(
        %{
          "kind" => scope_kind,
          "id" => socket.assigns.campaign_id,
          "viewer_discord_id" => socket.assigns.current_user.discord_id
        },
        # Issue #1153: Zusatzfelder für verhandelte Scopes. `campaign_luecken`
        # bekommt darüber `"glatt" => "fenster"` — ohne das Feld liefert der
        # Worker unverändert alles (#1152), die Verhandlung ist also
        # abwärtskompatibel in BEIDE Richtungen: alter Worker ignoriert das
        # Feld, neuer Worker ohne Feld verhält sich wie der alte.
        extra
      )

    # Issue #1122: der Async-NAME trägt den Scope. `start_async/3` bricht einen
    # laufenden Task mit gleichem Namen ab — zwei Scope-Loads kurz nacheinander
    # (beim Mount: Flags und Pipeline-Stand) haben sich damit gegenseitig
    # abgeschossen, und der Verlierer setzte seine Assigns nie. Das fiel erst
    # auf, als der zweite Load dazukam: die Flags-Tests wurden rot, ohne dass
    # am Flags-Pfad etwas geändert worden wäre.
    # Issue #1149: siehe start_snapshot_load/1 — `self()` vor der Closure.
    lv = self()

    start_async(socket, {:reload_scope, scope_kind}, fn ->
      {scope_kind, Reader.read(scope, notify: lv)}
    end)
  end

  @doc """
  Issue #1153 (C6): fehlende Block-Texte nachladen, falls welche fehlen.

  Der Auslöser sitzt **nach** jeder Änderung, die die sichtbare Auswahl
  verschiebt: neuer `smoothed`-Stand, Fenster-Schritt, Ansichtswechsel. Nicht
  im Template — von dort ließe sich kein Read starten, und ein Render darf
  keine Seiteneffekte haben.

  **No-op, wenn nichts fehlt** — und das ist der Normalfall bei einem Worker
  ohne #1152 oder ohne gesetztes Flag. Deshalb kann der Aufrufer ihn
  bedingungslos anhängen.

  Der Read läuft über `campaign_luecken_slice` im **ids**-Modus: die
  Kuratieren-Ansicht wählt ihre Blöcke über ein Prädikat, ihre Treffer liegen
  über die ganze Sitzung verstreut, und ein Bereich `[from, count)` könnte sie
  nicht ausdrücken (#1152).
  """
  @spec nachlade_glatt_texte(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def nachlade_glatt_texte(socket) do
    do_nachladen(socket, socket.assigns[:campaign_id], socket.assigns[:current_user])
  end

  # Fehlt der Kampagnen-Kontext, wird nicht nachgeladen. Das ist die
  # best-effort-Zusage in ihrer strengsten Form: dieser Pfad darf die Ansicht
  # NIE zum Absturz bringen — ein fehlender Text ist ein Schönheitsfehler, ein
  # KeyError im Render-Pfad kostet die ganze Seite. In Prod sind beide Assigns
  # immer gesetzt; die Klausel greift für Teil-Sockets (Tests, Fehlerzweige,
  # ein Reload vor dem ersten erfolgreichen Snapshot).
  defp do_nachladen(socket, cid, user) when not is_binary(cid) or is_nil(user), do: socket

  defp do_nachladen(socket, cid, user) do
    # Issue #1181: ALLE fehlenden IDs auf einmal bestimmen (`:alle`, kein
    # 200er-Deckel mehr an dieser Stelle) — der Deckel gilt jetzt pro Read
    # innerhalb des Tasks, nicht pro Runde in der LiveView.
    fehlende =
      GlattFenster.fehlende_aus_ansicht(
        socket.assigns[:smoothed] || [],
        socket.assigns[:glatt_view] || %{},
        socket.assigns[:glatt_windows] || %{},
        socket.assigns[:glatt_texte] || %{},
        :alle
      )

    if fehlende == [] do
      socket
    else
      # `self()` VOR der Closure — darin wäre es die Pid des Tasks (#1149).
      lv = self()
      did = user.discord_id

      # Die ganze Schleife im Task: Read für Read bis leer, EIN Ergebnis, EIN
      # Render (#1181). Der C6-Vorgänger kettete hier in der LiveView und
      # renderte die Spalte pro Runde — vier Renders in unter einer Sekunde,
      # und der Prod-Hub starb bei jedem Mount.
      #
      # Die Closure bekommt NUR die ID-Liste, nicht `socket.assigns` und nicht
      # `smoothed`: alles, was hier gebunden wird, kopiert der BEAM in den
      # Task-Prozess — das Skelett (5317 Blöcke an seattleV4) wäre ein zweiter
      # voller Heap, im Moment, in dem der Speicher am knappsten ist. `lese`
      # steht deshalb IM Task (und der #544-Credo-Check sieht so, dass der
      # Reader.read nicht in der LiveView läuft).
      start_async(socket, :glatt_texte_load, fn ->
        lese = fn ids ->
          Reader.read(
            %{
              "kind" => "campaign_luecken_slice",
              "id" => cid,
              "viewer_discord_id" => did,
              "block_ids" => ids
            },
            notify: lv
          )
        end

        GlattFenster.lade_texte(fehlende, lese)
      end)
    end
  end

  # ─── Issue #1087: Utterance-Ladefenster ──────────────────────────

  # Gesamtzahl je Session. Ein Worker ohne #1087 liefert die volle Liste und
  # keinen Zähler — dann ist die Liste selbst die Wahrheit.
  defp utterance_counts(snap) do
    case snap["utterance_counts"] do
      %{} = counts when map_size(counts) > 0 ->
        counts

      _ ->
        (snap["utterances"] || [])
        |> Enum.frequencies_by(&(&1["session_id"] || &1[:session_id]))
    end
  end

  @doc """
  Issue #1087: ältere Protokollzeilen einer Session nachladen.

  `from`/`count` sind **absolute** Indizes in der Session, nicht Positionen in
  der geladenen Teilliste. Läuft bereits ein Ladevorgang für diese Session,
  passiert nichts — ein zweiter Scroll-Trigger während des Fluges würde sonst
  denselben Ausschnitt doppelt anhängen.
  """
  def start_utterance_load(socket, session_id, from, count) do
    if MapSet.member?(socket.assigns.utterances_loading, session_id) do
      socket
    else
      scope = %{
        "kind" => "campaign_utterances",
        "id" => socket.assigns.campaign_id,
        "viewer_discord_id" => socket.assigns.current_user.discord_id,
        "session_id" => session_id,
        "from" => from,
        "count" => count
      }

      socket
      |> assign(:utterances_loading, MapSet.put(socket.assigns.utterances_loading, session_id))
      |> start_async(:load_utterances, fn -> Reader.read(scope) end)
    end
  end

  @doc """
  Issue #1087: einzelne Utterances per ID holen (Refs-Popover, Sprungmarke).

  Landet in `utterance_lookup`, **nicht** in `utterances` — ein Einzelabruf
  würde sonst ein Loch in die Liste reißen und das Fenster ließe nicht
  benachbarte Zeilen benachbart aussehen.
  """
  def start_utterance_ids_load(socket, ids) do
    missing = Enum.reject(ids, &Map.has_key?(socket.assigns.utterance_lookup, &1))

    if missing == [] do
      socket
    else
      scope = %{
        "kind" => "campaign_utterances",
        "id" => socket.assigns.campaign_id,
        "viewer_discord_id" => socket.assigns.current_user.discord_id,
        "ids" => missing
      }

      start_async(socket, :load_utterances, fn -> Reader.read(scope) end)
    end
  end

  @doc """
  Issue #1087: Ergebnis eines Nachlade-Reads einarbeiten.

  Beim Slice-Modus wird das Render-Fenster um die Zahl der vorangestellten
  Zeilen verschoben und dann erst der Schritt nach oben ausgeführt — sonst
  spränge die Ansicht beim Nachladen an eine andere Stelle, weil dieselben
  Offsets plötzlich auf ältere Zeilen zeigen.
  """
  def apply_utterance_load(socket, %{"mode" => "ids", "utterances" => utts} = snap) do
    lookup =
      Enum.reduce(utts, socket.assigns.utterance_lookup, fn u, acc ->
        Map.put(acc, u["id"], u)
      end)

    socket
    |> assign(:utterance_lookup, lookup)
    |> assign(
      :utterance_indices,
      Map.merge(socket.assigns.utterance_indices, snap["indices"] || %{})
    )
  end

  def apply_utterance_load(socket, %{"mode" => "slice"} = snap) do
    alias HubWeb.CampaignLive.Components, as: C

    sid = snap["session_id"]
    fetched = snap["utterances"] || []
    known = MapSet.new(socket.assigns.utterances, &(&1["id"] || &1[:id]))
    fresh = Enum.reject(fetched, &MapSet.member?(known, &1["id"]))

    merged =
      (fresh ++ socket.assigns.utterances)
      |> Enum.sort_by(&(&1["timestamp"] || &1[:timestamp]))

    total = snap["total"] || socket.assigns.utterance_counts[sid] || length(merged)
    loaded_before = length(fresh)

    windows =
      case Map.get(socket.assigns.utterance_windows, sid) do
        nil ->
          # Tail-Modus: das Fenster hing am Ende und tut es weiter. Der
          # Schritt nach oben muss trotzdem passieren, sonst war das
          # Nachladen wirkungslos.
          loaded = Enum.count(merged, &((&1["session_id"] || &1[:session_id]) == sid))
          cur = C.resolve_window_public(nil, loaded)
          Map.put(socket.assigns.utterance_windows, sid, C.window_older(cur, loaded))

        {offset, count} ->
          loaded = Enum.count(merged, &((&1["session_id"] || &1[:session_id]) == sid))
          shifted = {offset + loaded_before, count}
          Map.put(socket.assigns.utterance_windows, sid, C.window_older(shifted, loaded))
      end

    socket
    |> assign(:utterances, merged)
    |> assign(:utterance_windows, windows)
    |> assign(:utterance_from, Map.put(socket.assigns.utterance_from, sid, snap["from"] || 0))
    |> assign(:utterance_counts, Map.put(socket.assigns.utterance_counts, sid, total))
    |> assign(:utterances_loading, MapSet.delete(socket.assigns.utterances_loading, sid))
  end

  def apply_utterance_load(socket, _other), do: socket

  @doc "Issue #1087: Lade-Markierung aufheben (Fehlerpfad)."
  def clear_utterance_loading(socket) do
    assign(socket, :utterances_loading, MapSet.new())
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

  # Issue #1169: die Messzeilen NACH dem Read stehen in den ZWEIGEN, nicht vor
  # dem `case` — `result` kann `{:error, :queue_timeout}` aus der #1149-Schlange
  # sein, und eine „ok"-Zeile mit `snapshot_words=5` für einen Timeout wäre die
  # schlimmste Form der Falschaussage: sie sähe aus wie ein kleiner,
  # erfolgreicher Read, und im Reconnect-Sturm stünden Dutzende davon.
  # (Review-Fund, PR #1180.) `forbidden`/`not_found` bekommen keine Zeile: das
  # ist keine Ladespitze, sondern eine Antwort mit fünf Schlüsseln.
  def apply_snapshot(socket, result) do
    case result do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, snap} ->
        # Issue #1169: der Snapshot liegt jetzt als Term im Prozess, das Apply
        # kommt noch dazu. `:erts_debug.size/1` traversiert ohne zu kopieren;
        # `term_to_binary` legte hier eine zweite Kopie des grössten Terms an,
        # den der Hub kennt. Liegt hier und nicht im handle_async-Zweig der
        # CampaignLive: die Datei steht seit C6 (#1153) bei 598 Code-Zeilen.
        lese_marke(socket, "voll_read_ok", snapshot_words: :erts_debug.size(snap))
        send(self(), {:voll_read_rendered, "campaign"})

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
        # Issue #1087: ein Worker ohne diese Keys (älter als #1087) liefert die
        # VOLLE Liste — dann sind Gesamtzahl und Startindex aus der Liste selbst
        # ableitbar, und alles verhält sich wie vorher. Deshalb Ableitung statt
        # Default-`%{}`: ein leeres `utterance_counts` würde sonst als „Session
        # hat 0 Zeilen" gelesen.
        |> assign(:utterance_counts, utterance_counts(snap))
        |> assign(:utterance_from, snap["utterance_from"] || %{})
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
        # Issue #985 Slice 1: Discord-Guild/Voice-Channel-Config fürs Config-
        # Formular. Keine funktionale Wirkung (der Bot existiert noch nicht).
        |> assign(:discord_config, snap["discord_config"] || %{})
        # Issue #746: Review-Queue — unplatzierbare Fakten.
        |> assign(:review_facts, snap["review_facts"] || [])
        # Issue #839 (Epic #829 Slice D3): Handlungsstränge fürs Offene-Fäden-Panel.
        |> assign(:campaign_threads, snap["campaign_threads"] || [])
        # #905: Arc-Review (Alt-Worker ohne Key → leeres Register).
        |> assign(:arc_review, snap["arc_review"] || %{})
        # Issue #871 (+ #865): geglättete Block-Spalte mit Inline-Kuration.
        |> assign(:smoothed, snap["smoothed"] || [])
        # Issue #114: Forward-Index für "↑ zitiert in N"-Badges an Utterances.
        # Map %{utterance_id => [%{kind, entry_id, label}, ...]}.
        |> assign(
          :utterance_refs_index,
          # Issue #1094: `smoothed` als 4. Argument — ohne es keyt der Index auf
          # Block-IDs und wird mit Utterance-IDs abgefragt (📎-Zähler dauerhaft 0).
          Refs.build_utterance_refs_index(
            snap["summaries"] || [],
            snap["epos"],
            snap["chronik"] || [],
            snap["smoothed"] || []
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
              snap["utterances"] || [],
              snap["smoothed"] || [],
              # Issue #1095: Fakten stehen NICHT im Haupt-Snapshot — sie kommen
              # über den lazy geladenen `campaign_facts`-Scope. Hier wird der
              # bereits geladene Stand aus dem Socket mitgegeben (er wird in
              # dieser Pipeline nicht angefasst); trifft er erst später ein,
              # baut `Updates.apply_scope/3` den Index neu.
              socket.assigns[:facts] || []
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
        # Issue #1090: EINE Übertragung statt einer handgepflegten Kette — hier
        # fehlte `can_record?`, und der REC-Knopf blieb dauerhaft gesperrt.
        |> HubWeb.CampaignLive.Derive.assign_permissions(derived)
        |> backfill_viewer_user(snap["users"] || %{})
        |> ensure_default_session_expanded()
        # Issue #1153 (C6): nach dem Voll-Snapshot fehlende Block-Texte holen.
        # Greift erst mit C4 (#1151) — bis dahin liefert der Haupt-Snapshot
        # `smoothed` ungefenstert, jeder Block trägt seinen Text, und das hier
        # ist ein No-op. Danach ist es der Pfad, der den Mount-Fall deckelt.
        |> nachlade_glatt_texte()

      {:error, :no_worker} ->
        lese_marke(socket, "voll_read_error", reason: "no_worker")

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
        lese_marke(socket, "voll_read_error", reason: String.slice(inspect(reason), 0, 80))

        # Wie oben: alte assigns überleben den Fehlerzustand, plus Flash
        # damit die Ursache (Timeout etc.) sichtbar wird.
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(:waiting?, true)
        |> merge_or_default_assigns(error_branch_defaults(socket))
    end
  end

  # Issue #1169: Messzeile mit dem Anlass des laufenden Voll-Reads (gesetzt in
  # `start_snapshot_load/2`; `nil` nur, wenn `apply_snapshot/2` ohne Start
  # aufgerufen wird — dann steht es auch so in der Zeile). `lv_heap_words` ist
  # der Heap DIESES LiveView-Prozesses im Moment der Marke — die Cgroup-Zahlen
  # kommen aus dem Reporter und sehen den ganzen Pod, nicht den Verursacher.
  defp lese_marke(socket, label, extra) do
    {:total_heap_size, heap} = Process.info(self(), :total_heap_size)

    Hub.MemoryReporter.marke(
      label,
      Keyword.merge(
        [kind: "campaign", anlass: socket.assigns[:voll_read_anlass], lv_heap_words: heap],
        extra
      )
    )
  end

  @doc """
  Issue #1169: die Marke NACH dem Render. `voll_read_ok` misst vor dem Apply —
  die Spitze, um die es geht, entsteht aber im Render danach (#1181: vier
  Renders der Geglättet-Spalte im Mount). Eine Marke direkt nach dem Render
  gibt es in LiveView nicht; `send(self(), {:voll_read_rendered, kind})` am
  Ende eines Apply wird erst NACH dem Render verarbeitet — die `handle_info`-
  Klausel in `CampaignLive` ruft dann diese Funktion, und `lv_heap_words`
  zeigt den Heap, den das Render hinterlassen hat.
  """
  @spec marke_gerendert(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def marke_gerendert(socket, kind) do
    lese_marke(socket, "voll_read_rendered", kind: kind)
    socket
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
      arc_review: %{},
      smoothed: [],
      users: %{},
      character_names: %{},
      speaker_assignments: %{},
      viewer_role: :spieler,
      perm_user: %{
        discord_id: socket.assigns.current_user.discord_id,
        role: :spieler,
        is_member?: false,
        campaign_role: nil
      }
    }
    # Issue #1090: die Sperr-Defaults kommen aus derselben Liste wie die
    # Übertragung — sonst driften Default-Satz und Apply-Satz auseinander, und
    # das fällt erst als toter Knopf auf.
    |> Map.merge(HubWeb.CampaignLive.Derive.default_permission_assigns())
    # Issue #1087: dasselbe Argument für die Zustände des Ladefensters. Fehlte
    # hier einer, rendert der Fehler-/Wartezweig in einen KeyError statt in
    # einen leeren Zustand — das Template liest `@utterance_from` und
    # `@utterance_lookup` unbedingt.
    |> Map.merge(utterance_window_defaults())
  end

  @doc """
  Issue #1087: die Anfangszustände des Protokoll-Ladefensters — EINE Quelle für
  den Mount und für den Fehler-/Wartezweig.

  - `utterance_counts` — Gesamtzahl je Session (der Snapshot liefert nur ein
    Fenster, ohne diese Karte wären alle Zählungen falsch).
  - `utterance_from` — absoluter Index, an dem die geladene Liste beginnt.
    Invariante: das Geladene ist immer ein zusammenhängendes Suffix
    `[from, total)`, sonst zeigte das Fenster nicht benachbarte Zeilen als
    benachbart an.
  - `utterance_lookup` / `utterance_indices` — Einzelabrufe für Sprungmarken
    und den Refs-Popover, bewusst NEBEN der Liste statt darin.
  - `utterances_loading` — pro Session ein laufender Nachlade-Read; verhindert,
    dass ein zweiter Scroll-Trigger denselben Ausschnitt doppelt anhängt.
  - `pending_focus` — aufgeschobenes Sprungziel; wird nach jedem Ergebnis
    erneut versucht und dabei zwingend abgebaut, sonst Nachlade-Schleife.
  """
  @spec utterance_window_defaults() :: map()
  def utterance_window_defaults do
    %{
      utterance_counts: %{},
      utterance_from: %{},
      utterance_lookup: %{},
      utterance_indices: %{},
      utterances_loading: MapSet.new(),
      pending_focus: nil
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
      ended_at: m["ended_at"],
      # Issue #987: "discord" | "browser" | nil (nil = noch keine Wahl getroffen).
      capture_mode: m["capture_mode"]
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
