defmodule Worker.Discord.VoiceSession do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage D: per-Kampagne
  GenServer, der den Discord-Voice-Channel-Beitritt und -Austritt hält. Erste
  dynamische Prozess-Instanz in `apps/worker` (gestartet/gestoppt über
  `Worker.Discord.BotSupervisor`, ein `DynamicSupervisor`).

  Join-Sequenz + Nostrum-API-Signaturen sind am tatsächlichen #941-Spike-Code
  verifiziert (`Voice.join_channel/4` mit `self_mute=true, self_deaf=FALSE` —
  self_deaf MUSS false sein, sonst liefert Discord keine eingehenden Pakete;
  fixe Settle-Zeit vor `start_listen_async/1` statt einer Readiness-API, weil
  der Spike-Autor die für instabil auf nostrum-main hielt).

  **Crash-Semantik ist die Silent-Failure-Achse dieser Stage** (Plan-Review
  zu #985): stirbt dieser Prozess mitten in einer Aufnahme, läuft die
  Recording-Session unbemerkt ohne Discord-Audio weiter. `restart: :transient`
  (nur bei abnormalem Exit neu gestartet, nie bei explizitem `stop_for_campaign`)
  + `terminate/2` publisht bei abnormalem Exit ein `PipelineErrorLogged`-Event
  (Stage `"discord_voice"`) — sichtbar in `/admin/errors`, dieselbe Fehler-
  Taxonomie wie die Wahrheitsbild-Pipeline (`classify_pipeline_error/1`s
  generischer Atom-Fallback).

  **Bekannte Grenzen (v1, dokumentiert statt gelöst):**
  - Kein aktiver Liveness-Check ("kommen wirklich noch Pakete an") — nur
    Prozess-Crashes werden erkannt, ein stiller Discord-seitiger Verbindungs-
    abbruch ohne BEAM-Crash bliebe unbemerkt.
  - Ein fehlgeschlagener Join selbst (falscher Channel, fehlende Rechte) wird
    von Nostrums Fire-and-Forget-`join_channel/4` nicht synchron signalisiert —
    dieser Fall ist NICHT robust erkannt, nur ein daraus resultierender
    späterer Prozess-Crash würde über `terminate/2` sichtbar.
  - Eine Discord-Gateway-Session kann pro Guild nur einem Voice-Channel
    gleichzeitig beitreten — zwei Kampagnen auf derselben Guild mit
    gleichzeitiger Aufnahme können nicht beide bedient werden. Issue #987
    (echter Live-Test-Fund): der Registry-Eintrag trägt die BESITZENDE
    Kampagne als Wert (`{:via, Registry, {Registry, guild_id, campaign_id}}`)
    — `Worker.Discord.BotSupervisor` nutzt das, um einen Konflikt LAUT zu
    machen statt die fremde Session unbemerkt zu übernehmen oder zu killen.
  - RAM-only: ein Worker-Neustart mitten in der Aufnahme verliert die Session
    ohne Re-Attach (kein Sync-Mechanismus wie bei Mnesia-State).
  """

  use GenServer

  require Logger

  alias Nostrum.Voice
  alias Worker.Discord.{AnnounceQueue, Presence}

  @join_settle_ms 3_000

  # Issue #989: Poll-Intervall der Ansage-Kette (ready? → play → playing?) und
  # der harte Deckel darüber. Ohne Deckel würde ein `playing?`, das nie false
  # wird (oder eine Voice-Verbindung, die nie bereit wird), die Aufnahme
  # dauerhaft blockieren — dann lieber ohne Ansage aufzeichnen als nicht.
  @announce_poll_ms 500
  @announce_max_ms 30_000

  # Issue #1002: die Version des Einwilligungs-Wortlauts lebt bei
  # `Worker.Discord.ConsentGate` (sie gehört zum WORTLAUT) — hier NICHT
  # zweitschreiben, sonst driften Schreib- und Prüfseite auseinander. Sie ist
  # bewusst identisch zur Browser-Pfad-Version: dieselbe Einwilligung in
  # dieselbe Sache, nur anders erteilt.

  @type cfg :: %{
          campaign_id: String.t(),
          session_id: String.t(),
          guild_id: non_neg_integer(),
          voice_channel_id: non_neg_integer()
        }

  @typedoc """
  Registry-Wert: besitzende Kampagne + der tatsächlich belegte Voice-Channel.

  Issue #1005: zusätzlich die `session_id`. Damit kann ein Button-Klick allein
  aus dem Registry geprüft werden (gehört er zur laufenden Sitzung? kommt er aus
  unserem Kanal?), **ohne** den GenServer zu kontaktieren — ein `GenServer.call`
  wäre hier riskant, weil eine Discord-Interaction nach 3 Sekunden verfällt und
  die Session zwischenzeitlich blockieren kann (TTS läuft synchron).

  Additiv: `BotSupervisor` matcht partiell (`%{campaign_id: id}`), ein
  zusätzlicher Schlüssel bricht dort nichts.
  """
  @type owner :: %{
          campaign_id: String.t(),
          voice_channel_id: non_neg_integer(),
          session_id: String.t()
        }

  # Issue #987: der Registry-WERT ist die besitzende Kampagne + der belegte
  # Voice-Channel (nicht nur ein leerer Platzhalter) — das ist die einzige
  # Quelle, die `BotSupervisor` zur Konflikt-Erkennung zwischen zwei
  # Kampagnen auf derselben Guild braucht, UND für eine präzise
  # Fehlermeldung ("Guild X ist mit Channel Y belegt", nicht nur "belegt").
  @spec via(non_neg_integer(), owner()) ::
          {:via, Registry, {Worker.Discord.Registry, non_neg_integer(), owner()}}
  def via(guild_id, owner), do: {:via, Registry, {Worker.Discord.Registry, guild_id, owner}}

  @spec start_link(cfg()) :: GenServer.on_start()
  def start_link(cfg) do
    owner = %{
      campaign_id: cfg.campaign_id,
      voice_channel_id: cfg.voice_channel_id,
      session_id: cfg.session_id
    }

    GenServer.start_link(__MODULE__, cfg, name: via(cfg.guild_id, owner))
  end

  @doc """
  Issue #1005: der Registry-Kontext einer laufenden Voice-Session einer Guild —
  `{pid, owner}` oder `nil`. Erlaubt es, einen Button-Klick zu prüfen, ohne den
  GenServer zu kontaktieren (s. `owner`-Typ).
  """
  @spec lookup(non_neg_integer()) :: {pid(), owner()} | nil
  def lookup(guild_id) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, owner}] -> {pid, owner}
      [] -> nil
    end
  end

  @doc """
  Issue #1005: ein Consent-Klick ist eingetroffen. Der Zeitstempel wird HIER
  genommen — mit derselben lokalen monotonen Uhr wie `arrival_ms` der Frames,
  nicht mit dem Discord-Zeitstempel der Interaction (ein Vergleich über
  Uhrengrenzen wäre bei Skew genau an der Kante falsch).
  """
  @spec consent_click(pid(), :grant | :revoke, String.t()) :: :ok
  def consent_click(pid, action, discord_id)
      when action in [:grant, :revoke] and is_binary(discord_id) do
    GenServer.cast(
      pid,
      {:consent_click, action, discord_id, System.monotonic_time(:millisecond)}
    )
  end

  # restart: :transient — nur bei abnormalem Exit neu gestartet (Gateway-
  # Disconnect, Decode-Crash), NIE nach einem geplanten `stop_for_campaign`
  # (das ruft GenServer.stop/1 mit `:normal`, kein Restart).
  def child_spec(cfg) do
    %{
      id: {__MODULE__, cfg.guild_id},
      start: {__MODULE__, :start_link, [cfg]},
      restart: :transient
    }
  end

  @doc "Best-effort Forward eines empfangenen (bereits dave_decrypt'd) Opus-Frames."
  @spec incoming_packet(non_neg_integer(), non_neg_integer(), binary(), non_neg_integer() | nil) ::
          :ok
  def incoming_packet(guild_id, ssrc, opus, speaker_id \\ nil) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, _}] ->
        GenServer.cast(
          pid,
          {:packet, ssrc, opus, System.monotonic_time(:millisecond), speaker_id}
        )

      [] ->
        :ok
    end
  end

  @doc """
  Issue #988: jemand hat einen Voice-Channel dieser Guild betreten/verlassen.
  Ob es UNSER Kanal ist, entscheidet die Session selbst — der Consumer kennt
  die Kampagnen-Konfiguration nicht.

  Issue #1013: `display_name` reist mit (aus dem `member`-Objekt des Events,
  s. Consumer) — `nil` ist zulässig, der Namens-Cache der Session behält dann
  den letzten bekannten Namen.
  """
  @spec voice_state_update(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          String.t() | nil
        ) :: :ok
  def voice_state_update(guild_id, user_id, channel_id, display_name \\ nil) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, _}] -> GenServer.cast(pid, {:voice_state, user_id, channel_id, display_name})
      [] -> :ok
    end
  end

  @impl true
  def init(cfg) do
    # Bug (echter Live-Test-Fund, #987-Nacharbeit): OHNE trap_exit killt
    # `DynamicSupervisor.terminate_child/2` (Standard-Shutdown-Signal
    # `exit(pid, :shutdown)`) diesen Prozess HART — `terminate/2` läuft dann
    # NIE, der Bot verlässt den Voice-Channel nie. Per `Process.monitor`
    # empirisch verifiziert: der Prozess stirbt mit reason=:shutdown, aber
    # KEIN terminate/2-Zweig feuert, solange dieses Flag fehlt. Einzige
    # Verlinkung dieses Prozesses ist der DynamicSupervisor selbst (Nostrums
    # Voice-Infrastruktur läuft in eigenen, nicht gelinkten Prozessen) —
    # trap_exit hat hier keine Nebenwirkungen auf andere Signale.
    Process.flag(:trap_exit, true)

    Logger.info(
      "Worker.Discord.VoiceSession: join campaign=#{cfg.campaign_id} " <>
        "guild=#{cfg.guild_id} channel=#{cfg.voice_channel_id}"
    )

    # Issue #989: self_mute ist jetzt FALSE. Bis hierher jointe der Bot
    # selbst-gemutet („sendet nie eigene Audio") — ein gemuteter Client kann
    # aber auch die Consent-Ansage nicht sprechen. Bewusst DAUERHAFT
    # nicht-gemutet statt nach der Ansage zurückzuschalten: ein zweiter
    # `join_channel/4` mitten in der Session wäre ein Voice-State-Update auf
    # einer laufenden Verbindung (Risiko für den Empfangspfad, den #941 als
    # fragil beschreibt) — und ein sprechfähiger Bot ist beim Transparenz-Ziel
    # ohnehin das ehrlichere Signal. self_deaf=false bleibt zwingend
    # (#941-Spike-Erkenntnis), sonst liefert Discord keine eingehenden Pakete.
    Voice.join_channel(cfg.guild_id, cfg.voice_channel_id, false, false)
    timer_ref = Process.send_after(self(), :start_listen, @join_settle_ms)

    # Issue #1060: BEIDE Uhren im selben Atemzug erheben — die monotone trägt die
    # Frame-Zeitachse (springt nicht bei NTP-Korrekturen), die Wall-Clock macht
    # aus einem Fenster-Offset einen echten Zeitpunkt für den Sidecar-Anker. Der
    # Versatz zwischen ihnen muss einmal am Sessionanfang festgehalten werden;
    # ihn später erneut zu bestimmen brächte genau den Fehler zurück, den der
    # Anker beseitigt.
    state =
      initial_state(
        cfg,
        timer_ref,
        System.monotonic_time(:millisecond),
        System.system_time(:millisecond)
      )

    # Issue #988: die EFFEKTBEHAFTETEN Teile der Präsenz — Nostrum-Lookup und
    # Timer-Start — bleiben hier, damit `initial_state/3` pur (und ohne Nostrum
    # testbar) bleibt. Die Felder selbst sind dort bereits angelegt.
    participants = initial_participants(cfg)

    {:ok,
     %{
       state
       | participants: participants,
         presence_timer: Process.send_after(self(), :presence_tick, Presence.tick_ms()),
         # Issue #1013: wer beim Bot-Join schon im Kanal sitzt, gilt als begrüßt
         # — die #989-Erst-Ansage spricht bereits den ganzen Raum an. Begrüßt
         # werden nur echte SPÄTERE Beitritte.
         announce_queue: AnnounceQueue.seed_greeted(state.announce_queue, participants)
     }}
  end

  @doc false
  # Der komplette State-Aufbau als PURE Funktion — extrahiert nach einem echten
  # Prod-Crash-Loop (#1002-Hotfix): `consent_timer` fehlte hier, und
  # `%{state | consent_timer: ref}` in `begin_listening/1` wirft bei fehlendem
  # Key ein KeyError. Folge: Crash → `restart: :transient` → Neu-Join → Ansage →
  # Crash → die Ansage kam im Kanal endlos wiederholt.
  #
  # **Jedes Feld, das eine `handle_info`-Klausel per `%{state | …}` anfasst, MUSS
  # hier stehen.** Map-Update-Syntax ist bewusst beibehalten (sie ist der
  # Tippfehler-Schutz für bestehende Felder) — dafür ist dieser Aufbau jetzt
  # ohne Nostrum testbar, und ein Test hält die Feldliste gegen die tatsächlich
  # verwendeten Keys fest.
  @spec initial_state(cfg(), reference() | nil, integer(), integer()) :: map()
  def initial_state(cfg, start_listen_timer, session_start_ms, session_start_wall_ms) do
    cfg
    |> Map.put(:listening?, false)
    |> Map.put(:session_start_ms, session_start_ms)
    # Issue #1060: dieselbe Sekunde wie `session_start_ms`, nur auf der
    # Wall-Clock. Aus beidem zusammen wird jeder session-relative Offset in eine
    # echte Uhrzeit übersetzbar (`Worker.Discord.Flush.window_start_wall_ms/1`).
    |> Map.put(:session_start_wall_ms, session_start_wall_ms)
    |> Map.put(:start_listen_timer, start_listen_timer)
    # Issue #985 Slice 1 (Stage F): rohe Frames werden gesammelt (Reverse-
    # Prepend, günstigste Liste-Operation) und erst beim Terminieren (egal
    # ob geplanter Stop oder Crash — lieber Teil-Audio als gar keins)
    # gemeinsam durch AudioBridge geschickt. `arrival_ms` relativ zu
    # `session_start_ms` (nicht absolute Systemzeit) — das ist exakt die
    # gemeinsame Zeitreferenz, die FrameBuffer für die sprecherübergreifende
    # Ausrichtung braucht.
    |> Map.put(:frames, [])
    # Issue #1009: der Puffer wird nicht mehr nur am Sessionende geleert, sondern
    # periodisch (`:flush_tick`). `window_start_ms` ist die session-relative
    # Untergrenze des laufenden Fensters und damit die Zeitbasis, auf die
    # `FrameBuffer.rebase/2` den Clip verschiebt. Beginnt bei 0 = Session-Start.
    |> Map.put(:window_start_ms, 0)
    |> Map.put(:flush_timer, nil)
    # Issue #1008: Session-weite Zähler für die Abschluss-Diagnose. Sie müssen
    # session-weit sein, weil `frames` seit #1009 periodisch geleert wird — beim
    # Terminieren stünde dort fast immer eine kurze Restliste.
    |> Map.put(:frames_total, 0)
    |> Map.put(:frames_unresolved, 0)
    # Issue #989: Ansage-Kette (wav + Deadline + Poll-Timer).
    |> Map.put(:announce_wav, nil)
    |> Map.put(:announce_deadline, nil)
    |> Map.put(:announce_timer, nil)
    # Issue #1002: Consent-Phase. `:consent` = die Frames aus dem
    # Zustimmungs-Fenster (werden NIE persistiert, nur ausgewertet und
    # verworfen); `:recording` = die regulären Frames. `consents` sammelt
    # `discord_id => verdict` aus der Auswertung.
    |> Map.put(:consents, %{})
    # Issue #1005: Consent-HISTORIE pro Sprecher (%{did => ConsentState.history()}).
    # Nicht nur das letzte Verdikt: mit Widerruf ist die gedeckte Menge ein
    # Intervall, bei Grant→Revoke→Re-Grant eine Intervall-Menge.
    |> Map.put(:consent_history, %{})
    # Issue #988: Live-Präsenz. `participants` = wer laut Discord im Kanal sitzt,
    # `last_packet_at` = wann zuletzt ein Paket von wem kam (daraus leitet
    # `Presence` „spricht gerade" ab). Alle drei werden in handle_info/handle_cast
    # per `%{state | …}` angefasst — sie MÜSSEN deshalb hier stehen (die
    # Crash-Loop-Lektion des #1002-Hotfix). Die echten Werte setzt `init/1`.
    |> Map.put(:participants, [])
    |> Map.put(:last_packet_at, %{})
    |> Map.put(:presence_timer, nil)
    # Issue #1013: Beitritts-Ansagen. `announce_queue` = der pure
    # Entscheidungs-Zustand (AnnounceQueue: Warteschlange + Begrüßungs-Dedup +
    # Erinnerungs-Deckel + Namens-Cache); `pending_dids` = die im laufenden
    # Debounce-Fenster gesammelten Nicht-Zustimmer (Sammelform statt
    # Einzel-Unterbrechungen); `tts_busy?` verhindert parallele piper-Tasks.
    |> Map.put(:announce_queue, AnnounceQueue.new())
    |> Map.put(:pending_dids, MapSet.new())
    |> Map.put(:pending_timer, nil)
    |> Map.put(:queue_timer, nil)
    |> Map.put(:tts_busy?, false)
  end

  # Anfangsbestand: wer sitzt beim Bot-Join schon im Kanal? :VOICE_STATE_UPDATE
  # kommt nur für ÄNDERUNGEN — ohne diesen Schritt bliebe die Anzeige leer, bis
  # jemand den Kanal wechselt. Best-effort: der Guild-Cache kann beim Join noch
  # kalt sein (dann füllt sich die Liste über die Updates nach), und ein
  # fehlender Cache darf den Session-Start nie verhindern.
  defp initial_participants(cfg) do
    guild = Nostrum.Cache.GuildCache.get!(cfg.guild_id)
    bot_id = with %{id: id} <- Nostrum.Cache.Me.get(), do: id

    Presence.initial_participants(
      Map.get(guild, :voice_states) || [],
      cfg.voice_channel_id,
      bot_id
    )
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Issue #989: VOR dem Zuhören die Consent-Ansage sprechen — erst danach
  # `start_listen_async`. Zwei Gründe für diese Reihenfolge: (1) die Einwilligung
  # kommt vor der Aufzeichnung, nicht parallel dazu; (2) die eigene Ansage kann
  # so unmöglich im Mitschnitt landen. Die ~6 s Verzögerung sind gewollt.
  @impl true
  def handle_info(:start_listen, state) do
    case Worker.Discord.Announcement.wav_for_campaign(
           state.campaign_id,
           Worker.Discord.Announcer.missing_names(state)
         ) do
      {:ok, wav} ->
        # Poll-Kette statt blockierendem Warten: der Prozess bleibt
        # antwortfähig (Pakete kommen erst nach start_listen, aber ein
        # blockierter GenServer wäre trotzdem falsch).
        deadline = System.monotonic_time(:millisecond) + @announce_max_ms
        ref = Process.send_after(self(), :announce_try, 0)

        {:noreply,
         state
         |> Map.put(:announce_wav, wav)
         |> Map.put(:announce_deadline, deadline)
         |> Map.put(:announce_timer, ref)}

      {:error, reason} ->
        Worker.Discord.VoiceErrors.report_announce_failure(state, reason)
        {:noreply, begin_listening(state)}
    end
  end

  # Die Voice-Verbindung muss stehen, bevor `play` etwas ausliefern kann — sonst
  # ginge die Ansage lautlos ins Leere (die Silent-Failure-Variante dieses
  # Features). Poll bis `ready?`, gedeckelt durch @announce_max_ms.
  @impl true
  def handle_info(:announce_try, state) do
    cond do
      announce_expired?(state) ->
        Logger.warning(
          "Worker.Discord.VoiceSession: Voice-Verbindung wurde nicht rechtzeitig bereit — " <>
            "Ansage übersprungen, Aufnahme startet campaign=#{state.campaign_id}"
        )

        {:noreply, begin_listening(state)}

      Worker.Discord.NostrumSafe.ready?(state.guild_id) ->
        case Worker.Discord.NostrumSafe.play_url(
               state.guild_id,
               state.announce_wav,
               state.campaign_id
             ) do
          :ok ->
            ref = Process.send_after(self(), :announce_wait, @announce_poll_ms)
            {:noreply, Map.put(state, :announce_timer, ref)}

          {:error, reason} ->
            Worker.Discord.VoiceErrors.report_announce_failure(state, reason)
            {:noreply, begin_listening(state)}
        end

      true ->
        ref = Process.send_after(self(), :announce_try, @announce_poll_ms)
        {:noreply, Map.put(state, :announce_timer, ref)}
    end
  end

  # Warten bis die Ansage durchgelaufen ist (`playing?` false) — dann zuhören.
  @impl true
  def handle_info(:announce_wait, state) do
    if Worker.Discord.NostrumSafe.playing?(state.guild_id) and not announce_expired?(state) do
      ref = Process.send_after(self(), :announce_wait, @announce_poll_ms)
      {:noreply, Map.put(state, :announce_timer, ref)}
    else
      {:noreply, begin_listening(state)}
    end
  end

  # Issue #988: fester 5-Hz-Takt statt Broadcast pro Paket — Nostrum beziffert
  # den Strom auf „about 50 events per second per speaking user", ein Broadcast
  # je Paket würde die LiveViews fluten.
  @impl true
  def handle_info(:presence_tick, state) do
    ref = Process.send_after(self(), :presence_tick, Presence.tick_ms())
    broadcast_presence(state)
    {:noreply, %{state | presence_timer: ref}}
  end

  # Issue #1009: der periodische Teil-Flush. Vorher lag eine komplette Sitzung
  # ausschließlich in `state.frames` — RAM des GenServers — und wurde erst in
  # `terminate/2` geschrieben. Ein `kill -9`, ein OOM oder ein Stromausfall
  # kostete damit den ganzen Abend; ein 4-Stunden-Mitschnitt hielt zudem alle
  # Opus-Frames aller Sprecher gleichzeitig im Speicher.
  #
  # Jedes Fenster wird zu einer eigenen Datei: der Clip trägt einen frischen
  # EBML-Header, worauf `AudioBuffer.write_chunk/6` auf ein neues Segment
  # rotiert (#469) und `ChunkManifest` (#757) für jedes Segment einen eigenen
  # Zeitanker schreibt. Die Wiederherstellungs-Mechanik dafür existiert also
  # schon vollständig — das war der Grund, diesen Weg zu gehen und nicht einen
  # eigenen Zwischenspeicher zu erfinden.
  #
  # Diese Klausel MUSS vor dem Catch-all darunter stehen. Stünde sie dahinter,
  # würde der Tick als „unerwartete Nachricht" geloggt und der Flush fände nie
  # statt — ein stiller Totalausfall dieses Features.
  def handle_info(:flush_tick, state) do
    state = Worker.Discord.Flush.window(state)

    {:noreply,
     %{
       state
       | flush_timer: Process.send_after(self(), :flush_tick, Worker.Discord.Flush.interval_ms())
     }}
  end

  # ─── Issue #1013: Beitritts-Ansagen ────────────────────────────────
  #
  # Die Orchestrierung (Queue-Drain, TTS-Task, Pending-Debounce, Deckel) lebt
  # in `Worker.Discord.Announcer` — die drei Klauseln hier sind reine
  # Delegation und MÜSSEN vor dem Catch-all stehen (#1009-Lektion: eine
  # Klausel dahinter matcht nie, und das Feature ist still tot).
  def handle_info(:queue_next, state), do: {:noreply, Worker.Discord.Announcer.drain(state)}

  def handle_info({:announce_tts, item, result}, state),
    do: {:noreply, Worker.Discord.Announcer.tts_result(state, item, result)}

  def handle_info(:pending_fire, state),
    do: {:noreply, Worker.Discord.Announcer.pending_fire(state)}

  # Issue #1005: Catch-all — MUSS die letzte handle_info-Klausel bleiben.
  #
  # Ohne sie ist jede unerwartete Nachricht ein `FunctionClauseError`, und weil
  # dieser Prozess `restart: :transient` hat, bedeutet das: Crash → Neu-Join →
  # Ansage → Crash. Genau die Schleife, die #1002 live produziert hat (dort über
  # ein fehlendes State-Feld). Die Fläche wächst mit jedem neuen Mechanismus:
  # `Process.monitor` liefert `{:DOWN, …}`, `Task.async_nolink` liefert
  # `{ref, result}`, und `trap_exit` ist gesetzt — also kommen auch `{:EXIT, …}`
  # hier an. Alle sind harmlos, solange sie nicht crashen.
  #
  # Bewusst `Logger.warning` statt stillem `:ok`: eine unerwartete Nachricht ist
  # kein Normalfall, sondern ein Hinweis auf einen fehlenden Handler.
  def handle_info(msg, state) do
    Logger.warning(
      "Worker.Discord.VoiceSession: unerwartete Nachricht ignoriert " <>
        "campaign=#{state.campaign_id}: #{inspect(msg, limit: 5)}"
    )

    {:noreply, state}
  end

  # Issue #1005: das globale 45-Sekunden-Consent-Fenster ist WEG. Es hatte zwei
  # Fehler, die der erste Live-Lauf zeigte: (1) es galt für ALLE, also wurde in
  # den ersten 45 s nichts gespeichert — eine kurze Session endete mit 0
  # Utterances; (2) wer SPÄTER beitrat, konnte prinzipiell nie zustimmen, weil
  # das Fenster längst zu war.
  #
  # An seine Stelle tritt die Zeitachse pro Sprecher (`ConsentState`): die
  # Aufnahme läuft ab sofort, und beim Flush wird pro Sprecher gefiltert. Wer
  # dauerhaft zugestimmt hat, ist ab Sekunde 0 gedeckt; wer erst klickt, ab dem
  # Klick. Damit ist der Late-Joiner kein Sonderfall mehr.
  defp begin_listening(state) do
    Voice.start_listen_async(state.guild_id)
    post_consent_button(state)

    # Issue #1009: ab jetzt kommen Pakete → ab jetzt wird periodisch geflusht.
    # Das Fenster beginnt hier, nicht beim Session-Start: die Ansage-Phase davor
    # produziert keine Frames, und ein Fenster mit ~6 s Vorlauf-Stille hätte den
    # Zeitanker des ersten Clips verschoben.
    %{
      state
      | listening?: true,
        window_start_ms: elapsed_ms(state),
        flush_timer: Process.send_after(self(), :flush_tick, Worker.Discord.Flush.interval_ms())
    }
    # Issue #1013: die Ansage-Queue läuft erst AB HIER — die #989-Erst-Ansage
    # davor bleibt unangetastet (Einwilligung vor Aufzeichnung, eigene
    # Poll-Kette). Beitritte während der Erst-Ansage sind schon gereiht und
    # werden jetzt abgearbeitet.
    |> Worker.Discord.Announcer.kick()
  end

  @doc false
  # Public (@doc false) seit #1060: `Worker.Discord.Flush` braucht die
  # Session-Zeitachse, um die Fenstergrenze zu bestimmen.
  @spec elapsed_ms(map()) :: integer()
  def elapsed_ms(state), do: System.monotonic_time(:millisecond) - state.session_start_ms

  # Issue #1005: die Nachricht mit den beiden Buttons in den Voice-Kanal (Discord
  # erlaubt Text im Voice-Channel — deshalb braucht es kein zusätzliches
  # Config-Feld und keine Schema-Erweiterung).
  #
  # Best-effort mit LAUTEM Fehler: fehlt dem Bot das Schreibrecht oder gibt es
  # den Text-in-Voice-Chat nicht, läuft die Aufnahme weiter (die Zustimmungen
  # früherer Abende gelten ja), aber es steht in /admin/errors. Ohne diese
  # Sichtbarkeit wäre „niemand kann zustimmen" ein stiller Totalausfall.
  defp post_consent_button(state) do
    payload = Worker.Discord.ConsentButton.payload(state.session_id, campaign_name(state))

    case Nostrum.Api.Message.create(state.voice_channel_id, payload) do
      {:ok, _message} ->
        Logger.info(
          "Worker.Discord.VoiceSession: Consent-Button gepostet campaign=#{state.campaign_id} " <>
            "channel=#{state.voice_channel_id}"
        )

      {:error, reason} ->
        Worker.Discord.VoiceErrors.report_button_failure(state, reason)
    end
  rescue
    e -> Worker.Discord.VoiceErrors.report_button_failure(state, Exception.message(e))
  catch
    kind, reason ->
      Worker.Discord.VoiceErrors.report_button_failure(state, inspect({kind, reason}))
  end

  defp campaign_name(state) do
    case Worker.Repo.get_campaign(state.campaign_id) do
      %{name: name} -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp announce_expired?(%{announce_deadline: deadline}) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) > deadline

  defp announce_expired?(_state), do: false

  @impl true
  def handle_cast({:packet, ssrc, opus, arrival_ms, speaker_id}, state) do
    # Issue #1005: die aufgelöste Identität reist AM FRAME mit (#988 löst sie am
    # Paket auf). Sie ist der Schlüssel für die Consent-Zeitachse beim Flush —
    # eine spätere Auflösung über die `ssrc_map` wäre nach einem Voice-Reconnect
    # nicht bloß unvollständig, sondern falsch (neue SSRC-Vergabe ⇒ Audio unter
    # fremder Identität). `nil` bleibt zulässig: Discord schickt das
    # :speaking-Event, das die Map füllt, nicht zwingend vor dem ersten Paket.
    frame = %{
      ssrc: ssrc,
      opus: opus,
      arrival_ms: arrival_ms - state.session_start_ms,
      did: if(speaker_id, do: to_string(speaker_id))
    }

    # Issue #988: Sprech-Zeitstempel mitschreiben. Passiert VOR der Phasen-
    # Weiche und damit auch während des Consent-Fensters — dort sieht der GM
    # dann schon, wer gerade antwortet. Nur der Zeitstempel wird behalten, kein
    # Audio: die Consent-Frames selbst bleiben dem #1002-Pfad vorbehalten.
    state = note_speaking(state, speaker_id, arrival_ms)

    # Issue #1005: EIN Puffer, keine Weiche. Im Hot-Path (50 Casts/s/Sprecher)
    # darf keine Zustandsannahme sitzen — divergierte sie, landeten Frames eines
    # Zugestimmten im falschen Eimer und würden verworfen (stiller Audioverlust).
    # Was gespeichert werden darf, entscheidet der Flush anhand der Zeitachse.
    {:noreply,
     %{
       state
       | frames: [frame | state.frames],
         # Issue #1008: mitzählen, nicht später aus dem Puffer rekonstruieren.
         frames_total: state.frames_total + 1,
         frames_unresolved: state.frames_unresolved + if(frame.did, do: 0, else: 1)
     }}
  end

  # Issue #1005: ein Consent-Button-Klick. Die Gültigkeitsprüfung ist schon
  # passiert (`ConsentInteraction`, pure) — hier wird nur der Zustand fortge-
  # schrieben. Der Zeitstempel kommt von derselben monotonen Uhr wie
  # `arrival_ms` der Frames; er wird session-relativ gemacht, damit beide
  # vergleichbar sind (eine Uhr, nicht zwei).
  @impl true
  def handle_cast({:consent_click, action, discord_id, at_ms}, state) do
    verdict = if action == :grant, do: :granted, else: :revoked
    rel_ms = max(at_ms - state.session_start_ms, 0)

    history =
      state
      |> history_for(discord_id)
      |> Worker.Discord.ConsentState.put(verdict, rel_ms)

    Logger.info(
      "Worker.Discord.VoiceSession: Consent-Klick #{verdict} campaign=#{state.campaign_id} " <>
        "did=#{discord_id} bei #{rel_ms}ms"
    )

    state = %{
      state
      | consent_history: Map.put(state.consent_history, discord_id, history),
        consents: Map.put(state.consents, discord_id, verdict)
    }

    # Issue #988: wer einwilligt, wird Mitspieler der Kampagne.
    if verdict == :granted, do: Worker.Discord.AutoMember.ensure(state.campaign_id, discord_id)

    # Issue #1013: die hörbare Bestätigung, dass der Klick ankam — ohne sie weiß
    # niemand, ob es funktioniert hat, und wundert sich hinterher über eine
    # fehlende Spur. Wer zugestimmt hat, fällt zugleich aus dem laufenden
    # Pending-Fenster (keine Erinnerung mehr an Erledigte).
    state =
      if verdict == :granted,
        do: Worker.Discord.Announcer.on_granted(state, discord_id),
        else: state

    # Die Präsenz-Anzeige soll den neuen Zustand sofort zeigen, nicht erst beim
    # nächsten Tick.
    broadcast_presence(state)

    {:noreply, state}
  end

  # Issue #988: jemand hat einen Voice-Channel dieser Guild betreten/verlassen.
  # Nur UNSER Kanal zählt — ein Wechsel in einen anderen Kanal derselben Guild
  # ist für uns ein Verlassen. Wer geht, verliert auch seinen Sprech-Zeitstempel
  # (sonst wüchse die Map über eine lange Session monoton mit jedem Gast).
  @impl true
  def handle_cast({:voice_state, user_id, channel_id, display_name}, state) do
    did = to_string(user_id)

    # Issue #1013: der Bot selbst löst hier nichts aus — sein eigener Join käme
    # sonst als „Beitritt" an (Begrüßung des Bots durch den Bot). Konsistent zu
    # `initial_participants/1`, das ihn aus dem Anfangsbestand filtert.
    if did == Worker.Discord.NostrumSafe.me_did() do
      {:noreply, state}
    else
      joined? = channel_id == state.voice_channel_id and did not in state.participants

      participants =
        if channel_id == state.voice_channel_id do
          Enum.uniq([did | state.participants])
        else
          List.delete(state.participants, did)
        end

      state =
        %{
          state
          | participants: participants,
            last_packet_at: Presence.prune(state.last_packet_at, participants)
        }
        |> Worker.Discord.Announcer.on_voice_state(did, display_name, joined?, channel_id)

      {:noreply, state}
    end
  end

  # Timer-Cleanup (Credo TimerWithoutCleanup, #544 Cut 2).
  #
  # Issue #1005: vorher war das eine handgeschriebene KETTE
  # (`cancel_start_listen_timer` → `cancel_announce_timer` → `cancel_consent_timer`
  # → `cancel_presence_timer`), bei der `terminate/2` nur das erste Glied rief.
  # Wer ein Timer-Feld ergänzt und das Verketten vergisst, leakt still — und die
  # Kette war nach #989/#1002/#988 schon vier Glieder lang. Jetzt EINE Liste
  # (`@timer_keys`) und EIN `Enum.each`. Ein Quelltext-Wächter im Test hält die
  # Liste vollständig: jedes `Process.send_after(self(), :x, …)` braucht ein
  # `:x`-Feld in `@timer_keys` UND eine `handle_info(:x, …)`-Klausel.
  #
  # Der `:presence_tick` ist als einziger selbst-reschedulend (läuft die ganze
  # Session) — canceln ist dort nicht bloß Hygiene, sondern verhindert einen
  # Tick ins Leere nach dem Terminieren.
  # Issue #1009: `:flush_timer` ist wie `:presence_timer` selbst-reschedulend —
  # canceln ist hier also nicht bloß Hygiene.
  @timer_keys [
    :start_listen_timer,
    :announce_timer,
    :presence_timer,
    :flush_timer,
    :pending_timer,
    :queue_timer
  ]

  @doc false
  @spec timer_keys() :: [atom()]
  def timer_keys, do: @timer_keys

  defp cancel_timers(state) do
    Enum.each(@timer_keys, fn key ->
      case Map.get(state, key) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end
    end)
  end

  # Issue #1008/#1009: die Abräum-Sequenz stand vorher in JEDER der vier
  # terminate-Klauseln einzeln ausgeschrieben — dieselbe Bauform, an der die
  # Timer-Kette schon einmal ein Glied verloren hat (#1005). Jetzt EINE
  # Reihenfolge an einer Stelle; die Klauseln unterscheiden sich nur noch im Log.
  #
  # Die Reihenfolge ist load-bearing: Timer aus (kein Tick ins Leere), Kanal
  # verlassen, DANN das letzte Fenster schreiben, DANN den Ausgang bewerten. Der
  # Flush muss vor der Bewertung laufen, weil er das Restaudio noch abschickt.
  defp shutdown_sequence(state) do
    cancel_timers(state)
    leave_voice_channel(state)
    # Lieber Teil-Audio bis zum Crash-Zeitpunkt als gar keins.
    Worker.Discord.Flush.all(state)
    Worker.Discord.VoiceErrors.report_capture_outcome(state)
    :ok
  end

  @impl true
  def terminate(:normal, state) do
    Logger.info(
      "Worker.Discord.VoiceSession: terminate reason=:normal campaign=#{state.campaign_id}"
    )

    shutdown_sequence(state)
  end

  def terminate(:shutdown, state) do
    Logger.info(
      "Worker.Discord.VoiceSession: terminate reason=:shutdown campaign=#{state.campaign_id}"
    )

    shutdown_sequence(state)
  end

  def terminate({:shutdown, sub_reason}, state) do
    Logger.info(
      "Worker.Discord.VoiceSession: terminate reason={:shutdown, #{inspect(sub_reason)}} campaign=#{state.campaign_id}"
    )

    shutdown_sequence(state)
  end

  def terminate(reason, state) do
    shutdown_sequence(state)

    Logger.error(
      "Worker.Discord.VoiceSession: abnormaler Exit campaign=#{state.campaign_id} " <>
        "guild=#{state.guild_id}: #{inspect(reason)}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_voice",
      state.session_id,
      :discord_voice_session_crashed,
      "Discord-Voice-Session abgestürzt (guild=#{state.guild_id}): #{inspect(reason)}"
    )

    :ok
  end

  # Bug (echter Live-Test-Fund, #987-Nacharbeit): `init/1` joint per
  # `Voice.join_channel/4`, aber KEIN `terminate/2`-Zweig rief je
  # `Voice.leave_channel/1` — der Bot blieb nach jedem Stop (normal ODER
  # Crash) im Voice-Channel hängen, weil Nostrums Voice-State pro Guild
  # unabhängig vom Lebenszyklus DIESES GenServers ist. Best-effort wie
  # `safe_ssrc_map/1` — ein Fehler beim Verlassen (z.B. Gateway schon down)
  # darf terminate/2 nie crashen lassen. ABER: der Fehler muss SICHTBAR
  # sein (Logger.warning) — ein zweiter Live-Test-Fund war, dass ein
  # rescue/catch OHNE jedes Logging genau das Diagnostizieren unmöglich
  # machte, als der Bot trotz dieses Fixes weiter im Kanal hängen blieb.
  defp leave_voice_channel(state),
    do: Worker.Discord.NostrumSafe.leave_channel(state.guild_id, state.campaign_id)

  # Issue #1002: zwei Quellen, weil die eine allein nicht reicht:
  #   1. das Urteil aus DIESEM Consent-Fenster (`state.consents`) — es zählt
  #      sofort, obwohl das `AudioConsentRecorded`-Event den Umweg über den Hub
  #      noch nicht zurückgelegt hat (bei einer kurzen Session wäre die Row sonst
  #      noch nicht da und die Spur würde fälschlich verworfen);
  #   2. der persistierte Consent — deckt frühere Spielabende UND den
  #      Browser-Pfad ab (gleiche Tabelle, gekeyed auf discord_id).
  # Issue #988: Sprech-Zeitstempel pro Discord-User. `nil` = die SSRC ist noch
  # keinem User zugeordnet (Discords :speaking-Event, das die Map füllt, kommt
  # nicht garantiert vor dem ersten Paket) — dann gibt es nichts zu vermerken.
  # Wer spricht, ohne in `participants` zu stehen, wird mit aufgenommen: das
  # :VOICE_STATE_UPDATE kann fehlen (kalter Guild-Cache beim Join), aber ein
  # ankommendes Paket ist der härtere Beweis für Anwesenheit als jede Liste.
  defp note_speaking(state, nil, _arrival_ms), do: state

  defp note_speaking(state, speaker_id, arrival_ms) do
    did = to_string(speaker_id)

    %{
      state
      | last_packet_at: Map.put(state.last_packet_at, did, arrival_ms),
        participants: Enum.uniq([did | state.participants])
    }
  end

  # Issue #988: Snapshot an den Hub. Best-effort wie jeder Status-Broadcast —
  # ein Fehler hier darf die laufende Aufnahme nie stören.
  defp broadcast_presence(state) do
    now = System.monotonic_time(:millisecond)

    consent_by_id =
      Map.new(state.participants, fn did -> {did, consent_ok?(state, did)} end)

    Worker.HubClient.publish_status(%{
      "kind" => "discord_presence",
      "campaign_id" => state.campaign_id,
      "session_id" => state.session_id,
      "participants" =>
        Presence.snapshot(state.participants, state.last_packet_at, consent_by_id, now)
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Die Historie eines Sprechers; `pre_granted?` kommt aus dem PERSISTIERTEN
  # Status (früherer Spielabend oder Browser-Pfad) — dann ist die ganze Session
  # gedeckt und die Aufnahme läuft ab Sekunde 0.
  @doc false
  # Public (@doc false) seit #1013: auch `Worker.Discord.Announcer` braucht die
  # Consent-Sicht — die Logik wird geteilt statt dupliziert (ConsentGate-Regel:
  # eine Lesestelle). Seit #1060 liest `Worker.Discord.Flush` sie ebenso.
  def history_for(state, did) do
    case Map.get(state.consent_history || %{}, did) do
      nil -> Worker.Discord.ConsentState.new(persisted_allows?(did))
      history -> history
    end
  end

  defp persisted_allows?(did) do
    Worker.Discord.ConsentGate.allow?(nil, persisted_consent(did))
  end

  @doc false
  # Public (@doc false) seit #1060: `Worker.Discord.Flush` entscheidet damit pro
  # Clip. Weiterhin die EINE Lesestelle für „darf das gespeichert werden" —
  # die Präsenz-Anzeige (#988) fragt dieselbe Funktion (ConsentGate-Regel).
  @spec consent_ok?(map(), String.t()) :: boolean()
  def consent_ok?(state, discord_id) do
    Worker.Discord.ConsentGate.allow?(
      Map.get(state.consents || %{}, discord_id),
      persisted_consent(discord_id)
    )
  end

  # Issue #1005: der EFFEKTIVE Status (Zustimmung ODER Widerruf), Read-both/
  # Write-new — nicht mehr die reine Legacy-Zustimmungs-Tabelle. Ein Widerruf
  # gewinnt damit auch gegen eine Alt-Zustimmung ohne event_id.
  defp persisted_consent(discord_id) do
    Worker.Repo.audio_consent_status(discord_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Eine verworfene Spur ist für den GM eine wichtige Information (im Protokoll
  # fehlt ein Mitspieler) — deshalb sichtbar in /admin/errors, nicht nur im Log.
end
