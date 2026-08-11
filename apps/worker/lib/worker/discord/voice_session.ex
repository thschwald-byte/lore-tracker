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

  @join_settle_ms 3_000

  # Issue #989: Poll-Intervall der Ansage-Kette (ready? → play → playing?) und
  # der harte Deckel darüber. Ohne Deckel würde ein `playing?`, das nie false
  # wird (oder eine Voice-Verbindung, die nie bereit wird), die Aufnahme
  # dauerhaft blockieren — dann lieber ohne Ansage aufzeichnen als nicht.
  @announce_poll_ms 500
  @announce_max_ms 30_000

  # Issue #1002: die Version des Einwilligungs-Wortlauts lebt bei
  # `Worker.Recording.ConsentPhrase` (sie gehört zum TEXT) — hier NICHT
  # zweitschreiben, sonst driften Schreib- und Prüfseite auseinander. Sie ist
  # bewusst identisch zur Browser-Pfad-Version: dieselbe Einwilligung in
  # dieselbe Sache, nur anders erteilt.

  @type cfg :: %{
          campaign_id: String.t(),
          session_id: String.t(),
          guild_id: non_neg_integer(),
          voice_channel_id: non_neg_integer()
        }

  @typedoc "Registry-Wert: besitzende Kampagne + der tatsächlich belegte Voice-Channel."
  @type owner :: %{campaign_id: String.t(), voice_channel_id: non_neg_integer()}

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
    owner = %{campaign_id: cfg.campaign_id, voice_channel_id: cfg.voice_channel_id}
    GenServer.start_link(__MODULE__, cfg, name: via(cfg.guild_id, owner))
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
  @spec incoming_packet(non_neg_integer(), non_neg_integer(), binary()) :: :ok
  def incoming_packet(guild_id, ssrc, opus) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:packet, ssrc, opus, System.monotonic_time(:millisecond)})

      [] ->
        :ok
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

    state =
      cfg
      |> Map.put(:listening?, false)
      |> Map.put(:session_start_ms, System.monotonic_time(:millisecond))
      |> Map.put(:start_listen_timer, timer_ref)
      # Issue #985 Slice 1 (Stage F): rohe Frames werden gesammelt (Reverse-
      # Prepend, günstigste Liste-Operation) und erst beim Terminieren (egal
      # ob geplanter Stop oder Crash — lieber Teil-Audio als gar keins)
      # gemeinsam durch AudioBridge geschickt. `arrival_ms` relativ zu
      # `session_start_ms` (nicht absolute Systemzeit) — das ist exakt die
      # gemeinsame Zeitreferenz, die FrameBuffer für die sprecherübergreifende
      # Ausrichtung braucht.
      |> Map.put(:frames, [])
      # Issue #1002: Consent-Phase. `:consent` = die Frames aus dem
      # Zustimmungs-Fenster (werden NIE persistiert, nur ausgewertet und
      # verworfen); `:recording` = die regulären Frames. `consents` sammelt
      # `discord_id => verdict` aus der Auswertung.
      |> Map.put(:phase, :consent)
      |> Map.put(:consent_frames, [])
      |> Map.put(:consents, %{})

    {:ok, state}
  end

  # Issue #989: VOR dem Zuhören die Consent-Ansage sprechen — erst danach
  # `start_listen_async`. Zwei Gründe für diese Reihenfolge: (1) die Einwilligung
  # kommt vor der Aufzeichnung, nicht parallel dazu; (2) die eigene Ansage kann
  # so unmöglich im Mitschnitt landen. Die ~6 s Verzögerung sind gewollt.
  @impl true
  def handle_info(:start_listen, state) do
    case Worker.Discord.Announcement.wav_for_campaign(state.campaign_id) do
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
        report_announce_failure(state, reason)
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

      voice_ready?(state.guild_id) ->
        case play_announcement(state) do
          :ok ->
            ref = Process.send_after(self(), :announce_wait, @announce_poll_ms)
            {:noreply, Map.put(state, :announce_timer, ref)}

          {:error, reason} ->
            report_announce_failure(state, reason)
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
    if announce_playing?(state.guild_id) and not announce_expired?(state) do
      ref = Process.send_after(self(), :announce_wait, @announce_poll_ms)
      {:noreply, Map.put(state, :announce_timer, ref)}
    else
      {:noreply, begin_listening(state)}
    end
  end

  # Fenster vorbei → auswerten. Der Whisper-Lauf ist BLOCKIEREND (System.cmd auf
  # whisper-cli), darf also nicht im GenServer laufen: sonst stauen sich die
  # eingehenden Pakete für Sekunden. Deshalb ein unverlinkter Task, der sein
  # Ergebnis per Message zurückschickt. Stirbt der Task, kommt nie ein
  # `:consent_result` — dann bleibt es beim leeren Consent-Set, und das ist
  # fail-closed korrekt (keine Zustimmung ⇒ keine Aufzeichnung).
  @impl true
  def handle_info(:consent_window_done, state) do
    frames = Enum.reverse(state.consent_frames)
    ssrc_map = safe_ssrc_map(state.guild_id)
    parent = self()

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      send(parent, {:consent_result, Worker.Discord.ConsentCheck.evaluate_frames(frames, ssrc_map)})
    end)

    # Ab jetzt regulär aufnehmen. Die Consent-Frames sind aus dem State heraus
    # (der Task hält seine eigene Kopie) und werden nie gespeichert.
    {:noreply, %{state | phase: :recording, consent_frames: [], consent_timer: nil}}
  end

  # Ergebnis der Auswertung: `%{discord_id => verdict}`. Zustimmungen werden als
  # `AudioConsentRecorded` publisht (derselbe Speicher wie der Browser-Pfad,
  # gekeyed auf discord_id) → beim nächsten Spielabend wird nicht neu gefragt.
  @impl true
  def handle_info({:consent_result, verdicts}, state) when is_map(verdicts) do
    Enum.each(verdicts, fn {discord_id, verdict} ->
      Logger.info(
        "Worker.Discord.VoiceSession: Consent campaign=#{state.campaign_id} " <>
          "did=#{discord_id} verdict=#{verdict}"
      )

      if verdict == :granted, do: publish_consent(discord_id)
    end)

    {:noreply, %{state | consents: Map.merge(state.consents, verdicts)}}
  end

  defp publish_consent(discord_id) do
    Worker.Intents.publish(%{
      "kind" => Shared.Events.audio_consent_recorded(),
      "discord_id" => to_string(discord_id),
      "version" => Worker.Recording.ConsentPhrase.version(),
      "accepted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Issue #1002: das Zuhören beginnt im **Consent-Fenster**. Der Bot MUSS
  # zuhören, um die gesprochene Zustimmung überhaupt zu hören — die Frames
  # dieses Fensters landen aber im separaten `consent_frames`-Eimer und werden
  # nach der Auswertung verworfen (nie persistiert).
  defp begin_listening(state) do
    Voice.start_listen_async(state.guild_id)
    ref = Process.send_after(self(), :consent_window_done, consent_window_ms())

    %{state | listening?: true, phase: :consent, consent_timer: ref}
  end

  # Fenster-Länge pro Worker tunbar; Default 45 s (lang genug, dass jemand die
  # Ansage hört und nachspricht, kurz genug, dass es nicht als Hänger wirkt).
  defp consent_window_ms do
    Worker.Settings.get(:discord_consent_window_ms, 45_000)
  end

  defp announce_expired?(%{announce_deadline: deadline}) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) > deadline

  defp announce_expired?(_state), do: false

  # Nostrum-Aufrufe best-effort einkapseln (Muster `safe_ssrc_map/1`): ein
  # Fehler im Ansage-Pfad darf die Aufnahme nie mitreißen.
  defp voice_ready?(guild_id) do
    Voice.ready?(guild_id)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp announce_playing?(guild_id) do
    Voice.playing?(guild_id)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp play_announcement(state) do
    Logger.info(
      "Worker.Discord.VoiceSession: Consent-Ansage abspielen campaign=#{state.campaign_id} " <>
        "guild=#{state.guild_id} wav=#{state.announce_wav}"
    )

    Voice.play(state.guild_id, state.announce_wav, :url)
    :ok
  rescue
    e -> {:error, {:announce_play_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:announce_play_failed, inspect({kind, reason})}}
  end

  # Kein hörbares Signal, aber ein SICHTBARER Fehler: eigene
  # `/admin/errors`-Klasse (Stage `discord_ansage`). Die Aufnahme läuft weiter —
  # bewusste Abwägung, s. `Worker.Discord.Announcement`-Moduledoc.
  defp report_announce_failure(state, reason) do
    Logger.error(
      "Worker.Discord.VoiceSession: Consent-Ansage fehlgeschlagen campaign=#{state.campaign_id}: " <>
        "#{inspect(reason)} — Aufnahme läuft OHNE hörbare Ansage weiter"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_ansage",
      state.session_id,
      reason,
      "Consent-Ansage beim Discord-Join fehlgeschlagen: #{inspect(reason)}. " <>
        "Die Aufnahme läuft OHNE hörbares Signal für die Teilnehmer."
    )
  end

  @impl true
  def handle_cast({:packet, ssrc, opus, arrival_ms}, state) do
    frame = %{ssrc: ssrc, opus: opus, arrival_ms: arrival_ms - state.session_start_ms}

    # Issue #1002: während des Consent-Fensters landen die Frames in einem
    # SEPARATEN Eimer. Der wird nur zur Zustimmungs-Prüfung transkribiert und
    # danach verworfen — er erreicht `AudioBuffer.append/4` nie. Das grenzt das
    # Bootstrap-Problem ein („um die Zustimmung zu hören, muss man zuhören"):
    # verarbeitet ja, gespeichert nein.
    case state.phase do
      :consent -> {:noreply, %{state | consent_frames: [frame | state.consent_frames]}}
      _ -> {:noreply, %{state | frames: [frame | state.frames]}}
    end
  end

  # Timer-Cleanup (Credo TimerWithoutCleanup, #544 Cut 2): der :start_listen-
  # Timer aus init/1 ist ein Ein-Schuss-Timer, sein Ziel-Prozess stirbt mit
  # jedem Exit ohnehin mit — cancel_timer ist hier reine Hygiene (die Message
  # würde sonst ins Leere laufen, kein echter State-Leak), aber die
  # projektweite Faustregel gilt unabhängig von der konkreten Risikohöhe.
  defp cancel_start_listen_timer(%{start_listen_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    cancel_announce_timer(state)
  end

  defp cancel_start_listen_timer(state), do: cancel_announce_timer(state)

  # Issue #989: die Ansage-Poll-Kette (:announce_try/:announce_wait) hält
  # denselben Ein-Schuss-Timer-Vertrag wie :start_listen — beim Terminieren
  # canceln, damit keine Message ins Leere läuft.
  defp cancel_announce_timer(%{announce_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    cancel_consent_timer(state)
  end

  defp cancel_announce_timer(state), do: cancel_consent_timer(state)

  # Issue #1002: der Consent-Fenster-Timer, gleiche Hygiene.
  defp cancel_consent_timer(%{consent_timer: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_consent_timer(_state), do: :ok

  @impl true
  def terminate(:normal, state) do
    Logger.info("Worker.Discord.VoiceSession: terminate reason=:normal campaign=#{state.campaign_id}")
    cancel_start_listen_timer(state)
    leave_voice_channel(state)
    flush_frames(state)
    :ok
  end

  def terminate(:shutdown, state) do
    Logger.info("Worker.Discord.VoiceSession: terminate reason=:shutdown campaign=#{state.campaign_id}")
    cancel_start_listen_timer(state)
    leave_voice_channel(state)
    flush_frames(state)
    :ok
  end

  def terminate({:shutdown, sub_reason}, state) do
    Logger.info(
      "Worker.Discord.VoiceSession: terminate reason={:shutdown, #{inspect(sub_reason)}} campaign=#{state.campaign_id}"
    )

    cancel_start_listen_timer(state)
    leave_voice_channel(state)
    flush_frames(state)
    :ok
  end

  def terminate(reason, state) do
    cancel_start_listen_timer(state)
    leave_voice_channel(state)
    # Lieber Teil-Audio bis zum Crash-Zeitpunkt als gar keins.
    flush_frames(state)

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
  defp leave_voice_channel(state) do
    result = Voice.leave_channel(state.guild_id)

    Logger.info(
      "Worker.Discord.VoiceSession: leave_channel campaign=#{state.campaign_id} " <>
        "guild=#{state.guild_id} result=#{inspect(result)}"
    )
  rescue
    e ->
      Logger.warning(
        "Worker.Discord.VoiceSession: leave_channel fehlgeschlagen campaign=#{state.campaign_id} " <>
          "guild=#{state.guild_id}: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "Worker.Discord.VoiceSession: leave_channel fehlgeschlagen campaign=#{state.campaign_id} " <>
          "guild=#{state.guild_id}: #{inspect({kind, reason})}"
      )
  end

  # Issue #985 Slice 1 (Stage F): baut pro Sprecher den WebM-Clip
  # (FrameBuffer-Zeitkorrektur + Ogg-Opus-Mux + Decode/Splice/Re-Encode, s.
  # `Worker.Discord.AudioBridge`-Moduledoc) und speist ihn in denselben
  # `AudioBuffer.append/5`-Pfad ein, den der Browser-Mic nutzt (`:per_player`).
  # SSRC→Discord-User-ID-Mapping kommt aus `Voice.get_ssrc_map/1` — best-effort
  # (Spike-Vorbild `safe_ssrc_map/1`): ein nicht auflösbarer SSRC verwirft den
  # Clip (kein Audio unter falscher Identität), statt zu raten.
  defp flush_frames(%{frames: []}), do: :ok

  defp flush_frames(state) do
    ssrc_map = safe_ssrc_map(state.guild_id)
    clips = Worker.Discord.AudioBridge.build_speaker_clips(Enum.reverse(state.frames))

    Enum.each(clips, fn {ssrc, result} ->
      handle_clip(state, ssrc_map, ssrc, result)
    end)
  end

  defp handle_clip(state, ssrc_map, ssrc, {:ok, base64_webm}) do
    case Map.get(ssrc_map, ssrc) do
      discord_id when is_integer(discord_id) ->
        did = to_string(discord_id)

        # Issue #1002: DIE Durchsetzungs-Stelle. Ohne Einwilligung wird die Spur
        # verworfen statt gespeichert — dieselbe Regel wie beim fehlenden
        # SSRC-Mapping direkt darunter (kein Audio ohne geklärte Grundlage),
        # nur mit anderem Grund. Die Aufnahme der ANDEREN läuft weiter; niemand
        # blockiert damit den Spielabend.
        if consent_ok?(state, did) do
          Worker.Recording.AudioBuffer.append(state.session_id, did, :per_player, base64_webm)
        else
          report_missing_consent(state, did)
        end

      nil ->
        Logger.error(
          "Worker.Discord.VoiceSession: kein SSRC->User-Mapping für ssrc=#{ssrc} " <>
            "campaign=#{state.campaign_id} — Clip verworfen (keine Audio-Zuordnung ohne Identität)."
        )
    end
  end


  defp handle_clip(state, _ssrc_map, ssrc, {:error, reason}) do
    Logger.error(
      "Worker.Discord.VoiceSession: Clip-Bau fehlgeschlagen campaign=#{state.campaign_id} " <>
        "ssrc=#{ssrc}: #{inspect(reason)}"
    )
  end

  defp safe_ssrc_map(guild_id) do
    Voice.get_ssrc_map(guild_id)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # Issue #1002: zwei Quellen, weil die eine allein nicht reicht:
  #   1. das Urteil aus DIESEM Consent-Fenster (`state.consents`) — es zählt
  #      sofort, obwohl das `AudioConsentRecorded`-Event den Umweg über den Hub
  #      noch nicht zurückgelegt hat (bei einer kurzen Session wäre die Row sonst
  #      noch nicht da und die Spur würde fälschlich verworfen);
  #   2. der persistierte Consent — deckt frühere Spielabende UND den
  #      Browser-Pfad ab (gleiche Tabelle, gekeyed auf discord_id).
  defp consent_ok?(state, discord_id) do
    Worker.Discord.ConsentGate.allow?(
      Map.get(state.consents || %{}, discord_id),
      persisted_consent(discord_id)
    )
  end

  defp persisted_consent(discord_id) do
    Worker.Repo.audio_consent(discord_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Eine verworfene Spur ist für den GM eine wichtige Information (im Protokoll
  # fehlt ein Mitspieler) — deshalb sichtbar in /admin/errors, nicht nur im Log.
  defp report_missing_consent(state, discord_id) do
    Logger.warning(
      "Worker.Discord.VoiceSession: keine Einwilligung für did=#{discord_id} " <>
        "campaign=#{state.campaign_id} — Spur VERWORFEN (nicht gespeichert, nicht transkribiert)"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_consent",
      state.session_id,
      :consent_missing,
      "Für einen Sprecher lag keine Einwilligung vor — seine Tonspur wurde " <>
        "verworfen (nicht gespeichert, nicht transkribiert). Er kann beim nächsten " <>
        "Beitritt zustimmen, indem er den in der Ansage genannten Satz spricht."
    )
  end
end
