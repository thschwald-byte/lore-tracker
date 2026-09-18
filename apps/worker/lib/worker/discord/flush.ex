defmodule Worker.Discord.Flush do
  @moduledoc """
  Der Schreibpfad einer Discord-Voice-Session: Fenster schneiden, Frames gegen
  die Einwilligung filtern, Clips bauen, in den `AudioBuffer` geben.

  Herausgelöst aus `Worker.Discord.VoiceSession` (Issue #1060), weil die dort
  gewachsene Datei die God-Module-Grenze riss. Der Schnitt ist nicht bloß
  Zeilenverteilung: dieser Pfad hat eine eigene, geschlossene Verantwortung —
  aus einer Frame-Zeitachse werden Audio-Dateien mit Zeitankern. Der Rest der
  `VoiceSession` ist Lebenszyklus (Join, Consent-Interaktion, Ansagen,
  Präsenz).

  Die Aufteilung der Zeitachsen ist die Kernentscheidung des Moduls:

    * **monoton** (`arrival_ms`, session-relativ) — alles, was Reihenfolge und
      Abstände betrifft: Fenstergrenze, Consent-Intervalle, Stille zwischen
      Frames. Sie springt bei NTP-Korrekturen nicht.
    * **Wall-Clock** — ausschließlich der Anker, unter dem ein Clip abgelegt
      wird (`window_start_wall_ms/1`), weil daraus am Ende ein UTC-Zeitstempel
      an der Utterance wird.

  Der Zustand bleibt der State der `VoiceSession` — dieses Modul nimmt ihn
  entgegen und gibt ihn zurück (Muster `Worker.Discord.Announcer`), statt einen
  eigenen Prozess aufzumachen.
  """

  require Logger

  alias Worker.Discord.{AudioBridge, FrameBuffer, VoiceErrors, VoiceSession}

  @doc """
  Schreibt das laufende Fenster weg und öffnet das nächste.

  Die Fenstergrenze ist EIN Zeitpunkt für beide Seiten (`now` wird sowohl als
  Rebase-Basis des nächsten Fensters gesetzt als auch als Schnittkante benutzt)
  — sonst entstünde je nach Rundung ein Frame-Loch oder eine Dopplung an der
  Naht.

  Frames, die während des Flushes eintreffen, landen wegen der GenServer-
  Serialisierung erst danach in `state.frames` und tragen ein `arrival_ms`
  jenseits von `now` — sie gehören ins nächste Fenster und werden dort mit der
  neuen Basis verrechnet. Deshalb wird hier nach `arrival_ms` geschnitten und
  nicht einfach die ganze Liste geleert.
  """
  @spec window(map()) :: map()
  def window(state) do
    now = VoiceSession.elapsed_ms(state)
    {due, pending} = FrameBuffer.split_window(state.frames, now)

    all(%{state | frames: due})

    %{state | frames: pending, window_start_ms: now}
  end

  @doc """
  Issue #1009: Fensterlänge. Sie ist ein Kompromiss in zwei Richtungen, deshalb
  einstellbar statt hart verdrahtet:

    * **Verlust bei Absturz** ist auf ein Fenster begrenzt (vorher: die ganze
      Sitzung) — kleiner ist besser.
    * **Dateizahl/Overhead**: pro Fenster und Sprecher ein
      ffmpeg-Decode/Splice/Re-Encode plus ein Whisper-Lauf. Größer ist besser.

  60 s ist der gewählte Punkt: Whispers eigenes Analysefenster sind 30 s, ein
  Schnitt bei 60 s kostet also keine Transkriptionsqualität, und ein
  Vier-Stunden-Abend bleibt bei ~240 Segmenten pro Sprecher.

  Issue #1060: die Fensterlänge war bis dahin eine DRITTE Achse — der Anker war
  das Fensterende, also verschob ein längeres Fenster die Zeitstempel weiter.
  Seit die Clips am Fensterbeginn verankert werden (`window_start_wall_ms/1`),
  ist die Genauigkeit von dieser Zahl unabhängig.
  """
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Worker.Settings.get(:discord_flush_interval_ms, 60_000)
  end

  @doc """
  Issue #1060: der Beginn des gerade geflushten Fensters als Wall-Clock in
  Millisekunden — der Zeitanker, unter dem die Clips dieses Fensters abgelegt
  werden. PURE (rechnet nur auf dem State, fragt keine Uhr).

  `window_start_ms` ist session-relativ auf der monotonen Achse; addiert auf die
  Wall-Clock des Sessionbeginns ergibt das den echten Zeitpunkt. Bewusst NICHT
  „jetzt minus Fensterlänge": der Flush läuft nach dem Fenster und dauert selbst
  (Mux + ffmpeg je Sprecher), und der Schluss-Flush kommt zu einem beliebigen
  Zeitpunkt im Fenster.
  """
  @spec window_start_wall_ms(map()) :: integer()
  def window_start_wall_ms(%{session_start_wall_ms: wall, window_start_ms: offset}),
    do: wall + offset

  @doc """
  Issue #985 Slice 1 (Stage F): baut pro Sprecher den WebM-Clip
  (FrameBuffer-Zeitkorrektur + Ogg-Opus-Mux + Decode/Splice/Re-Encode, s.
  `Worker.Discord.AudioBridge`-Moduledoc) und speist ihn in denselben
  `AudioBuffer.append/6`-Pfad ein, den der Browser-Mic nutzt (`:per_player`).

  **Die Identität kommt aus den Frames, nicht aus einer Tabelle** (#1052). Jeder
  Frame trägt sie seit #988 mit sich, aufgelöst im Moment des Empfangs. Bis
  #1052 holte dieser Pfad stattdessen `Voice.get_ssrc_map/1` **beim Speichern**
  erneut — also nach dem Fenster, das er gerade schreibt. War die
  Voice-Verbindung in diesem Moment tot, war die Tabelle leer und das ganze
  Fenster verloren (bis zu eine Minute, alle Sprecher); war sie erneuert,
  konnte eine neu vergebene Kennung Audio unter fremder Identität speichern.
  Die Warnung davor stand wörtlich an der Paket-Stelle — der Speicherpfad tat
  es trotzdem. Seitdem fragt dieses Modul Nostrum gar nicht mehr.
  """
  @spec all(map()) :: :ok
  def all(%{frames: []}), do: :ok

  def all(state) do
    # Issue #1005: DIE Durchsetzung der Invariante — „kein Frame außerhalb eines
    # Grant-Intervalls wird gespeichert". Der Filter läuft VOR dem Clip-Bau, weil
    # nur hier die Frame-Zeitachse noch vorliegt; ein Clip ist danach ein
    # undurchsichtiger Audio-Blob.
    #
    # Die Einwilligung wirkt damit **nur nach vorn**: wer in Minute 12 zustimmt,
    # dessen Audio aus Minute 0–12 wird verworfen, nicht nachträglich freigegeben.
    # Ein Widerruf schneidet ab seinem Zeitpunkt ab, lässt den bereits gedeckten
    # Teil aber stehen (Intervall-Semantik, s. `ConsentState`).
    kept = state.frames |> Enum.reverse() |> keepable(state)

    if kept == [] do
      Logger.warning(
        "Worker.Discord.Flush: keine einwilligungsgedeckten Frames " <>
          "campaign=#{state.campaign_id} — nichts gespeichert"
      )
    end

    # Issue #1009: erst NACH dem Consent-Filter rebasen. Der Filter vergleicht
    # `arrival_ms` gegen die Grant-Intervalle, und die sind session-relativ —
    # auf einer fenster-relativen Achse würde er das falsche Intervall treffen.
    # Der Rebase ist reine Clip-Geometrie und gehört deshalb unmittelbar vor den
    # Clip-Bau.
    # Issue #1011: die Dauer wird GEMESSEN, nicht geschätzt. Der Schluss-Flush
    # läuft synchron im `handle_call({:stop, …})` des Recorders und damit im
    # Timeout-Budget von `stop_for_campaign/1` (s. dortiger Kommentar). Wie lange
    # er wirklich braucht, weiß bisher niemand — ohne Zahl bliebe die Frage „ist
    # das Budget groß genug" für immer eine Vermutung. Pro Sprecher sind es zwei
    # ffmpeg-Aufrufe (Decode + Re-Encode), sequenziell.
    # Issue #1052: die Identität kommt aus den Frames (s. Moduledoc).
    # `keepable/2` oben hat jeden Frame ohne Identität bereits entfernt.
    identitaeten = identitaeten_aus_frames(kept, state)

    {us, _} =
      :timer.tc(fn ->
        kept
        |> FrameBuffer.rebase(state.window_start_ms)
        |> AudioBridge.build_speaker_clips()
        |> Enum.each(fn {ssrc, result} ->
          handle_clip(state, Map.get(identitaeten, ssrc), ssrc, result)
        end)
      end)

    VoiceErrors.log_flush_duration(state, kept, div(us, 1000))
  end

  # Pro Sprecher gegen seine Consent-Historie filtern. Frames ohne aufgelöste
  # Identität fallen raus — ohne Identität gibt es keine Einwilligung, die sie
  # decken könnte (dieselbe Regel wie beim fehlenden SSRC-Mapping unten, nur
  # früher angewandt).
  defp keepable(frames, state) do
    frames
    |> Enum.group_by(& &1.did)
    |> Enum.flat_map(fn
      {nil, dropped} ->
        Logger.warning(
          "Worker.Discord.Flush: #{length(dropped)} Frame(s) ohne aufgelöste " <>
            "Identität verworfen campaign=#{state.campaign_id}"
        )

        []

      {did, speaker_frames} ->
        Worker.Discord.ConsentState.keepable_frames(
          speaker_frames,
          VoiceSession.history_for(state, did)
        )
    end)
    |> Enum.sort_by(& &1.arrival_ms)
  end

  # Issue #1052: die Zuordnung SSRC → Identität, abgeleitet aus den Frames
  # dieses Fensters. Jeder trägt beides; welche Kennung Discord dem Sprecher
  # INZWISCHEN zugeteilt hat, ist für bereits empfangenes Audio bedeutungslos.
  #
  # Trägt ein SSRC im selben Fenster MEHRERE Identitäten, wird nicht geraten:
  # Discord vergibt Kennungen nach einem Reconnect neu, und eine kollidierende
  # würde Audio unter fremder Identität speichern — also unter fremder
  # Einwilligung. Das ist der schwerste denkbare Fehler an dieser Stelle, und
  # er ist strukturell möglich, auch wenn er noch nicht beobachtet wurde.
  defp identitaeten_aus_frames(frames, state) do
    frames
    |> Enum.group_by(& &1.ssrc, & &1.did)
    |> Map.new(fn {ssrc, dids} ->
      case Enum.uniq(dids) do
        [did] ->
          {ssrc, did}

        mehrere ->
          VoiceErrors.report_ambiguous_ssrc(state, ssrc, mehrere)
          {ssrc, nil}
      end
    end)
  end

  defp handle_clip(state, did, ssrc, {:ok, base64_webm}) do
    case did do
      did when is_binary(did) ->
        # Issue #1002: DIE Durchsetzungs-Stelle. Ohne Einwilligung wird die Spur
        # verworfen statt gespeichert — dieselbe Regel wie beim fehlenden
        # SSRC-Mapping direkt darunter (kein Audio ohne geklärte Grundlage),
        # nur mit anderem Grund. Die Aufnahme der ANDEREN läuft weiter; niemand
        # blockiert damit den Spielabend.
        if VoiceSession.consent_ok?(state, did) do
          # Issue #1060: den Zeitanker mitgeben. Ohne ihn nähme der Writer seine
          # eigene Ankunftszeit und läse sie als ENDE des Clips — beides falsch:
          # der Clip endet beim letzten Wort dieses Sprechers (wer früh verstummt,
          # rutschte um den Rest des Fensters nach hinten), und der Schreibzeitpunkt
          # liegt hinter Mux + zwei ffmpeg-Läufen JE Sprecher, nacheinander.
          # Bekannt ist stattdessen der Fensterbeginn — und der ist per Konstruktion
          # der Anfang jedes Clips dieses Fensters (`FrameBuffer.rebase/2` füllt
          # führende Stille bis dorthin auf). Damit tragen alle Sprecher eines
          # Fensters denselben Anker und bleiben zueinander ausgerichtet.
          Worker.Recording.AudioBuffer.append(
            state.session_id,
            did,
            :per_player,
            base64_webm,
            nil,
            wall_clock_ms: window_start_wall_ms(state),
            anchor: :start
          )
        else
          VoiceErrors.report_missing_consent(state, did)
        end

      nil ->
        # Issue #1052: hier landet nur noch die Mehrdeutigkeit — Frames ohne
        # Identität hat `keepable/2` längst entfernt, und der Vorfall ist in
        # `identitaeten_aus_frames/2` bereits nach `/admin/errors` gemeldet.
        # Vorher stand an dieser Stelle „kein SSRC->User-Mapping", und zwar
        # als EINZIGER Fehlerpfad im Flush ohne Eintrag dort: ein verworfener
        # Clip war nur im Log zu finden.
        Logger.error(
          "Worker.Discord.Flush: keine eindeutige Identität für ssrc=#{ssrc} " <>
            "campaign=#{state.campaign_id} — Clip verworfen (kein Audio unter ungeklärter Identität)."
        )
    end
  end

  defp handle_clip(state, _did, ssrc, {:error, reason}) do
    VoiceErrors.report_clip_failed(state, ssrc, reason)
  end
end
