defmodule HubWeb.CampaignLive.Mic do
  @moduledoc """
  Mikrofon-Domäne der CampaignLive (Issues #391/#400/#405/#412/#415/#317/#399,
  ausgelagert in #434 Cut 4): Mic-Setup-Popup (Device-Auswahl, Voice-/Phrasen-
  Test, Consent), Beitreten/Verlassen/Fehler, Live-Pegel + server-seitiger
  Stille-Watchdog, Ein-Klick-Raummikro-Autostart.

  Kontext-Modul mit Delegations-Pattern: Funktionen nehmen den LiveView-Socket
  und liefern `{:noreply, socket}` (Handler-/handle_info-Pfade) bzw. `socket`
  (Snapshot-Helfer). Läuft im LiveView-Prozess — `put_flash`/`push_event`/
  PubSub/`send(self(), …)` adressieren also die LiveView.

  Öffentliche, von außerhalb genutzte Funktionen:
  - `maybe_autostart_single_source_mic/1`, `reset_mic_setup_state/1`,
    `silence_tick_ms/0` — vom `HubWeb.CampaignLive` (Snapshot/Mount/Teardown).
  - `clamp_level/1`, `phrase_match?/2`, `mic_setup_finish_decision/3`,
    `compute_silent_streamers/4` — pure, von Tests reflexiv aufgerufen.

  ## credo:disable TimerWithoutCleanup (file-level, Issue #570)

  Zwei `Process.send_after`-Stellen, beide KEIN Leak:
  - `on_silence_tick/1` reschedult sich selbst (Stille-Watchdog, stirbt mit dem
    LV-Prozess).
  - `setup_phrase_clip/…` setzt einen bounded 12s-`{:clip_timeout, req_id}` —
    Einmal-Schuss, der via req_id-Abgleich in `on_clip_timeout/2` idempotent
    behandelt wird (ein nachträglich gefeuerter stale-Timeout ist ein No-op).
  Kein `cancel_timer` nötig → der file-level-Check-Hit ist ein False-Positive.
  """
  # credo:disable-for-this-file LoreTracker.Credo.Check.TimerWithoutCleanup

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Hub.{Commands, EventBridge}
  alias HubWeb.CampaignLive.Components
  alias Shared.Events

  # Issue #317: hierarchische Consent-Versionen. "v2" ist strikt-superset von "v1".
  @consent_version_order ["v1", "v2"]
  # Issue #400: toleranter Wort-Overlap-Schwellwert Phrase ↔ Transkript.
  @phrase_match_threshold 0.6
  # Issue #399: Voice-Schwelle (= −40 dBFS) + 5-min-Stille-Limit + Tick-Intervall.
  @voice_level_threshold 0.33
  @silence_limit_ms 5 * 60 * 1000
  @silence_tick_ms 10_000

  @doc "Tick-Intervall des Stille-Watchdogs — für den initialen Timer-Arm in mount."
  def silence_tick_ms, do: @silence_tick_ms

  # ─── Beitreten / Setup öffnen ───────────────────────────────────

  def join(socket) do
    case socket.assigns.active_session do
      nil ->
        {:noreply, put_flash(socket, :error, "Keine aktive Session.")}

      %{id: sid} ->
        # Issue #391/#396: Per-Spieler-Mikro → Setup-Popup. Bei Übernahme erst
        # das Mikro im alten Tab freigeben, dann das Setup öffnen.
        maybe_release_other_tab_for_takeover(socket)
        {:noreply, open_mic_setup(socket, sid, :per_player)}
    end
  end

  # Issue #396: beim Übernehmen die laufende Aufnahme anderer Tabs/Geräte
  # desselben Accounts superseden, damit das Mikro frei wird, bevor das Setup
  # den Voice-Test startet. mic_button_state/3 ist die getestete Election-Logik.
  defp maybe_release_other_tab_for_takeover(socket) do
    did = socket.assigns.current_user.discord_id

    if Components.mic_button_state(
         socket.assigns.recording_here?,
         did,
         socket.assigns.mic_streamers
       ) == :takeover do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        HubWeb.MicLive.mic_topic(did),
        {:supersede_capture, self()}
      )
    end

    :ok
  end

  # ─── Setup-Popup-Events (Hook ↔ LV, Issue #391) ─────────────────

  def setup_devices_ready(socket, payload) do
    normalized =
      payload["devices"]
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

  def setup_select_device(socket, device_id),
    do: {:noreply, push_event(socket, "mic:setup_select", %{device_id: device_id})}

  def setup_local_level(socket, level),
    do: {:noreply, assign(socket, :mic_setup_local_level, clamp_level(level))}

  # Issue #400: der Hook hat (auto) einen Phrasen-Clip aufgenommen → an einen
  # Member-Worker zum Transkribieren; Antwort kommt async via {:clip_transcribed}.
  def setup_phrase_clip(socket, payload) do
    did = socket.assigns.current_user.discord_id
    cid = socket.assigns.campaign_id
    req_id = "clip-" <> Integer.to_string(System.unique_integer([:positive]))

    # Issue #405: offenes device_id mitnehmen — fürs Handoff an MicLive.
    socket = assign(socket, :pending_mic_device_id, payload["device_id"])

    case Commands.request_clip_transcribe(did, cid, req_id, payload["chunk"]) do
      :ok ->
        Process.send_after(self(), {:clip_timeout, req_id}, 12_000)

        {:noreply,
         socket
         |> assign(:mic_setup_checking?, true)
         |> assign(:mic_setup_error, nil)
         |> assign(:mic_setup_clip_req_id, req_id)}

      {:error, :no_worker} ->
        # Hard-Block: kein Fallback. Setup schließt NICHT.
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

  def setup_consent_toggle(socket) do
    socket
    |> assign(:mic_setup_consent_acked?, not socket.assigns.mic_setup_consent_acked?)
    |> maybe_finish_mic_setup()
  end

  def setup_cancel(socket) do
    {:noreply,
     socket
     |> assign(:show_mic_setup?, false)
     |> assign(:mic_on?, false)
     |> reset_mic_setup_state()
     |> push_event("mic:setup_abort", %{})}
  end

  # ─── Verlassen / lokaler State / Fehler ─────────────────────────

  def leave(socket) do
    # Issue #259: optimistic state update.
    current_did = socket.assigns.current_user.discord_id
    streamers = List.delete(socket.assigns.mic_streamers || [], current_did)

    # Issue #392: graceful Worker-Signal — Streamer sofort aus der Presence.
    case socket.assigns.active_session do
      %{"id" => sid} -> Commands.mic_leave(current_did, socket.assigns.campaign_id, sid)
      %{id: sid} -> Commands.mic_leave(current_did, socket.assigns.campaign_id, sid)
      _ -> :ok
    end

    # Issue #405: Capture in der sticky MicLive stoppen.
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

  # Issue #415: MicCapture-Hook meldet browser-lokal, ob DIESER Browser aufnimmt.
  def local_state(socket, recording),
    do: {:noreply, assign(socket, :recording_here?, recording == true)}

  def error(socket, reason) do
    # Issue #391: Fehler kann auch mitten im Setup-Popup auftreten.
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> assign(:show_mic_setup?, false)
     |> reset_mic_setup_state()
     |> put_flash(:error, "Mikro nicht verfügbar: #{reason}")}
  end

  # ─── handle_info-Delegationen ───────────────────────────────────

  def on_capture_failed(socket, reason) do
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> put_flash(:error, "Mikro-Aufnahme fehlgeschlagen: #{reason}")}
  end

  # Issue #468: MicLive meldet, dass mehrere Audio-Chunks in Folge verworfen
  # wurden (kein Member-Worker erreichbar) — die Aufnahme läuft ins Leere. Den
  # User warnen, damit er nicht ahnungslos weiterredet. Kein Auto-Stop: der
  # Worker kann zurückkommen; der User entscheidet, ob er abbricht.
  def on_audio_dropping(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "⚠️ Aufnahme verliert Audio — kein Worker erreichbar. Läuft der Worker noch?"
     )}
  end

  # Issue #400: transkribierter Mic-Setup-Phrasen-Clip. Nur reagieren wenn Setup
  # offen ist UND die req_id zur zuletzt geschickten passt.
  def on_clip_transcribed(socket, req_id, text) do
    if socket.assigns.show_mic_setup? and req_id == socket.assigns.mic_setup_clip_req_id do
      phrase = socket.assigns.mic_setup_phrase
      transcript = String.trim(text || "")

      socket =
        socket
        |> assign(:mic_setup_checking?, false)
        |> assign(:mic_setup_clip_req_id, nil)
        |> assign(:mic_setup_last_transcript, transcript)

      if phrase && phrase_match?(phrase.text, transcript) do
        socket
        |> assign(:mic_setup_phrase_ok?, true)
        |> maybe_finish_mic_setup()
      else
        {:noreply, push_event(socket, "mic:setup_listen_again", %{})}
      end
    else
      {:noreply, socket}
    end
  end

  # Issue #400: ASR-Antwort blieb aus. Setup bleibt offen, erneut lauschen.
  def on_clip_timeout(socket, req_id) do
    if socket.assigns.show_mic_setup? and socket.assigns.mic_setup_checking? and
         req_id == socket.assigns.mic_setup_clip_req_id and
         not socket.assigns.mic_setup_phrase_ok? do
      {:noreply,
       socket
       |> assign(:mic_setup_checking?, false)
       |> assign(:mic_setup_clip_req_id, nil)
       |> assign(:mic_setup_error, "Zeitüberschreitung beim Audio-Test — bitte erneut sprechen.")
       |> push_event("mic:setup_listen_again", %{})}
    else
      {:noreply, socket}
    end
  end

  # Issue #391/#405: Streamer-Liste aus der Worker-Truth. Issue #399: Watchdog-
  # State (mic_loud_at/silent_streamers) an die Liste angleichen.
  def on_streamers(socket, cid, dids) do
    if cid == socket.assigns.campaign_id do
      dids = dids || []
      mic_on? = socket.assigns.current_user.discord_id in dids
      now = now_ms()

      loud_at =
        (socket.assigns.mic_loud_at || %{})
        |> Map.take(dids)
        |> then(fn m -> Enum.reduce(dids, m, &Map.put_new(&2, &1, now)) end)

      silent = Enum.filter(socket.assigns.silent_streamers || [], &(&1 in dids))

      {:noreply,
       socket
       |> assign(:mic_streamers, dids)
       |> assign(:mic_on?, mic_on?)
       |> assign(:mic_levels, Map.take(socket.assigns.mic_levels || %{}, dids))
       |> assign(:mic_loud_at, loud_at)
       |> assign(:silent_streamers, silent)}
    else
      {:noreply, socket}
    end
  end

  # Issue #391: Live-Pegel pro Streamer (ephemer, 5×/s). Issue #399: loud_at
  # refreshen sobald Pegel ≥ Voice-Schwelle.
  def on_level(socket, cid, did, lvl) do
    if cid == socket.assigns.campaign_id do
      levels = Map.put(socket.assigns.mic_levels || %{}, did, lvl)

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

  # Issue #399: client-seitiger (Voice-Activity-basierter) Stille-Watchdog-Tick.
  # Erkennt "still aber Browser pusht weiter" anhand der mic_level-Events.
  # Reschedule sich selbst.
  def on_silence_tick(socket) do
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

  # Issue #399: server-seitiger Stille-Watchdog. Worker meldet, dass keine
  # Audio-Chunks mehr ankommen (Browser-Crash, Tab eingefroren) — anders als
  # der Voice-Activity-Pfad oben, der die ankommenden mic_levels braucht.
  # Wir mergen den discord_id in dieselbe `silent_streamers`-Liste, damit die
  # UI einen einzigen Banner-Pfad hat.
  def on_streamer_silent(socket, cid, _sid, did, _silent_for_ms) do
    if cid == socket.assigns.campaign_id and did in (socket.assigns.mic_streamers || []) do
      current = socket.assigns.silent_streamers || []

      silent =
        if did in current do
          current
        else
          [did | current]
        end

      {:noreply, assign(socket, :silent_streamers, silent)}
    else
      {:noreply, socket}
    end
  end

  def on_streamer_recovered(socket, cid, _sid, did) do
    if cid == socket.assigns.campaign_id do
      silent = Enum.reject(socket.assigns.silent_streamers || [], &(&1 == did))
      {:noreply, assign(socket, :silent_streamers, silent)}
    else
      {:noreply, socket}
    end
  end

  # ─── Snapshot-/Teardown-Helfer (von CampaignLive gerufen) ───────

  # Issue #302: Ein-Klick-Raummikro. Nach rec_single_start ist
  # pending_single_source_mic? gesetzt; sobald die Session aktiv ist, startet
  # die LV das Mikro automatisch. Idempotent: Flag wird sofort gelöscht.
  def maybe_autostart_single_source_mic(socket) do
    # Issue #355/#438: gegen nil prüfen statt Map-als-Boolean (BadBooleanError).
    if socket.assigns[:pending_single_source_mic?] == true and
         socket.assigns[:active_session] != nil and
         not (Map.get(socket.assigns, :mic_on?, false) == true) do
      sid = socket.assigns.active_session.id
      socket = assign(socket, :pending_single_source_mic?, false)
      open_mic_setup(socket, sid, :single_source)
    else
      socket
    end
  end

  # Setzt alle Setup-Modal-Felder zurück. Public: auch der SessionEnded-Teardown
  # in CampaignLive ruft das.
  def reset_mic_setup_state(socket) do
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

  # ─── Setup-interne Helfer ───────────────────────────────────────

  defp open_mic_setup(socket, sid, consent_mode) do
    consent_ok = consent_satisfies?(socket.assigns.audio_consent, consent_mode)

    socket
    |> assign(:show_mic_setup?, true)
    |> assign(:mic_setup_consent_required?, not consent_ok)
    |> assign(:mic_setup_consent_acked?, false)
    |> assign(:mic_setup_consent_mode, consent_mode)
    |> assign(:mic_setup_local_level, 0.0)
    |> assign(:mic_setup_devices, %{devices: [], preferred_id: nil})
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

  defp maybe_finish_mic_setup(socket) do
    voice_ok = socket.assigns.mic_setup_phrase_ok?

    consent_ok =
      not socket.assigns.mic_setup_consent_required? or
        socket.assigns.mic_setup_consent_acked?

    # sid + device_id VOR jedem reset binden — sonst liest ein späterer Read den
    # genullten Wert (session_id: nil → stummes Recording).
    sid = socket.assigns.pending_mic_session_id
    device_id = socket.assigns.pending_mic_device_id

    case mic_setup_finish_decision(voice_ok, consent_ok, sid) do
      :wait ->
        {:noreply, socket}

      :abort_no_session ->
        {:noreply,
         socket
         |> assign(:show_mic_setup?, false)
         |> reset_mic_setup_state()
         |> push_event("mic:setup_abort", %{})
         |> put_flash(:error, "Session-Kontext verloren — bitte Mikro erneut starten.")}

      :start ->
        case maybe_publish_consent_event(socket) do
          {:ok, socket} ->
            # Issue #412: Setup-Stream browser-lokal an die sticky MicLive übergeben.
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
            # Compliance-Hard-Stop: ohne persistiertes AudioConsentRecorded keine Aufnahme.
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
  defp maybe_publish_consent_event(socket) do
    if socket.assigns.mic_setup_consent_required? do
      now = DateTime.utc_now()
      version = consent_version_for(socket.assigns.mic_setup_consent_mode)

      payload = %{
        "kind" => Events.audio_consent_recorded(),
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

  # ─── Consent-Versionen (Issue #317) ─────────────────────────────

  defp consent_version_for(:single_source), do: "v2"
  defp consent_version_for(_), do: "v1"

  defp version_rank(v) when is_binary(v) do
    case Enum.find_index(@consent_version_order, &(&1 == v)) do
      nil -> 0
      i -> i + 1
    end
  end

  defp version_rank(_), do: 0

  defp consent_satisfies?(nil, _mode), do: false

  defp consent_satisfies?(%{"version" => v}, mode),
    do: version_rank(v) >= version_rank(consent_version_for(mode))

  defp consent_satisfies?(%{version: v}, mode),
    do: version_rank(v) >= version_rank(consent_version_for(mode))

  defp consent_satisfies?(_, _), do: false

  # ─── Pure Helfer (von Tests reflexiv aufgerufen) ────────────────

  @doc false
  def clamp_level(level) when is_number(level), do: min(1.0, max(0.0, level / 1))
  def clamp_level(_), do: 0.0

  @doc """
  Issue #400: toleranter Wort-Overlap zwischen erwarteter Test-Phrase und ASR-
  Transkript. True wenn ≥ 60 % der erwarteten Wörter (normalisiert, Reihenfolge
  egal) im Transkript vorkommen. Leeres Transkript ⇒ false.
  """
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

  defp normalize_phrase(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/u, trim: true)
  end

  @doc """
  Pure Entscheidungslogik fürs Setup-Finish (Issue #391): voice_ok + consent_ok
  + gültige sid ⇒ :start; sonst :wait oder :abort_no_session.
  """
  def mic_setup_finish_decision(voice_ok, consent_ok, sid) do
    sid_ok = is_binary(sid) and sid != ""

    cond do
      not (voice_ok and consent_ok) -> :wait
      not sid_ok -> :abort_no_session
      true -> :start
    end
  end

  @doc """
  Issue #399: pure Stille-Berechnung (testbar ohne LiveView). Ein Streamer gilt
  als still, wenn er noch streamt aber sein letztes hörbares Signal (loud_at)
  ≥ limit_ms zurückliegt. Ohne loud_at-Eintrag → nicht flaggen.
  """
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
end
