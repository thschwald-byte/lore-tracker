defmodule Worker.Discord.VoiceErrors do
  @moduledoc """
  Sichtbarkeit für Ausfälle im Discord-Voice-Pfad: jeder Weg, auf dem eine
  Aufnahme scheitert oder eine Tonspur verloren geht, wird hier zu einem
  `PipelineErrorLogged`-Event für `/admin/errors` (Issue #1008).

  Ausgelagert aus `Worker.Discord.VoiceSession`, das damit die 1000-Zeilen-Grenze
  des God-Module-Checks (#544) riss. Der Schnitt ist inhaltlich: das hier ist
  **eine** Verantwortlichkeit („wie wird ein Ausfall sichtbar"), sie enthält
  keinen GenServer-Zustand und keine Discord-API-Aufrufe, und sie ist der Teil,
  der mit jeder neuen Fehlerart wächst. Die `VoiceSession` behält die
  Prozess-Verantwortung.

  **Warum es diese Klassen überhaupt gibt:** Der Discord-Pfad hatte am
  2026-08-12 einen Spielabend lang nichts geliefert (#1008), ohne dass irgendwo
  etwas zu sehen war — die betroffenen Stellen schrieben nur `Logger`. Der GM sah
  während der Sitzung nichts Auffälliges und merkte erst hinterher, dass kein
  Transkript entstand. Jede Funktion hier ist eine dieser vormals stummen
  Stellen.

  Alle Meldungen nennen zusätzlich den Prüfschritt („darf der Bot im Voice-Kanal
  Nachrichten senden?"), weil ein Fehlercode ohne nächsten Schritt den GM allein
  lässt.
  """

  require Logger

  def report_button_failure(state, reason) do
    Logger.error(
      "Worker.Discord.VoiceSession: Consent-Button NICHT gepostet " <>
        "campaign=#{state.campaign_id} channel=#{state.voice_channel_id}: #{inspect(reason)}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_consent",
      state.session_id,
      :consent_button_unavailable,
      "Die Einwilligungs-Nachricht konnte nicht in den Voice-Kanal gepostet werden " <>
        "(#{inspect(reason)}). Wer noch nicht zugestimmt hat, kann es in dieser Sitzung " <>
        "nicht — seine Tonspur wird verworfen. Prüfen: darf der Bot im Voice-Kanal " <>
        "Nachrichten senden?"
    )
  end

  # Kein hörbares Signal, aber ein SICHTBARER Fehler: eigene
  # `/admin/errors`-Klasse (Stage `discord_ansage`). Die Aufnahme läuft weiter —
  # bewusste Abwägung, s. `Worker.Discord.Announcement`-Moduledoc.
  def report_announce_failure(state, reason) do
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

  # Issue #1008: „Aufnahme lief, aber es kam kein Transkript raus" war ein
  # STILLER Totalverlust — der GM sah während der Sitzung nichts Auffälliges
  # (Bot im Kanal, Leiste da, Uhr lief) und merkte erst hinterher, dass nichts
  # angekommen war. In /admin/errors stand nichts, weil die betroffenen Stellen
  # nur `Logger` schrieben.
  #
  # Die Ursache DIESES Vorfalls war die vertauschte Stop-Reihenfolge aus #1011
  # (Audio kam nach dem Finalize an). Das ist behoben — aber „behoben" ist keine
  # Zusicherung, dass der Pfad nie wieder auf andere Weise nichts liefert (der
  # Empfangsweg gilt seit dem #941-Spike als fragil). Deshalb wird hier der
  # Ausgang der Aufnahme aktiv bewertet statt auf den nächsten Zufallsfund zu
  # warten.
  #
  # Bewusst nur die EINDEUTIGEN Totalausfälle, ohne geratene Schwellen: gar kein
  # Paket, oder kein einziges zuordenbares Paket. Ein Teilausfall (einzelne
  # unauflösbare Frames — ~200 ms zu Sprechbeginn sind normal) bleibt eine
  # Log-Warnung; ihn zur Fehlerklasse zu machen hieße, eine Zahl zu erfinden.
  @doc """
  Issue #1008: das Urteil über den Ausgang einer Aufnahme, als PURE Funktion —
  damit die Klassifikation ohne laufenden Discord-Bot testbar ist (die
  `VoiceSession` selbst ist ohne Nostrum nicht startbar).

  `:no_frames` = gar kein Paket empfangen. `:unresolved` = Pakete kamen an, aber
  KEIN einziges war einem Nutzer zuordenbar. `:ok` = alles andere, inklusive des
  Teilausfalls (einzelne unauflösbare Frames sind normal, ~200 ms zu
  Sprechbeginn).
  """
  @spec capture_outcome(non_neg_integer(), non_neg_integer()) :: :ok | :no_frames | :unresolved
  def capture_outcome(0, _unresolved), do: :no_frames
  def capture_outcome(total, total) when total > 0, do: :unresolved
  def capture_outcome(_total, _unresolved), do: :ok

  def report_capture_outcome(state) do
    case capture_outcome(state.frames_total, state.frames_unresolved) do
      :no_frames -> report_no_frames(state)
      :unresolved -> report_unresolved(state)
      :ok -> log_capture_ok(state)
    end
  end

  def report_no_frames(state) do
    Logger.error(
      "Worker.Discord.VoiceSession: KEIN einziges Audio-Paket empfangen " <>
        "campaign=#{state.campaign_id} session=#{state.session_id}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_voice",
      state.session_id,
      :no_frames_captured,
      "Der Bot war im Voice-Kanal, hat aber während der ganzen Aufnahme kein " <>
        "einziges Audio-Paket empfangen — es gibt deshalb kein Transkript. " <>
        "Häufigste Ursachen: der Bot war serverseitig stummgeschaltet, oder die " <>
        "Voice-Verbindung stand nur scheinbar. Prüfen: sitzt der Bot im richtigen " <>
        "Kanal, und ist er dort nicht gemutet?"
    )
  end

  def report_unresolved(%{frames_total: total} = state) do
    Logger.error(
      "Worker.Discord.VoiceSession: alle #{total} empfangenen Frames ohne Identität " <>
        "campaign=#{state.campaign_id} session=#{state.session_id}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_voice",
      state.session_id,
      :unresolved_ssrc_frames,
      "Es kam Audio an, aber KEIN Paket ließ sich einem Discord-Nutzer zuordnen — " <>
        "ohne Identität wird nichts gespeichert (es gäbe keine Einwilligung, die es " <>
        "deckt). Typisch nach einem Voice-Reconnect, bei dem Discord die " <>
        "Sprecher-Zuordnung neu vergibt. Aufnahme neu starten."
    )
  end

  def log_capture_ok(state) do
    Logger.info(
      "Worker.Discord.VoiceSession: Aufnahme beendet campaign=#{state.campaign_id} " <>
        "frames=#{state.frames_total} ohne_identität=#{state.frames_unresolved}"
    )
  end

  def report_missing_consent(state, discord_id) do
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

  @doc """
  Ein Clip-Bau ist gescheitert (ffmpeg fehlt, Decode-Fehler, Platte voll) — die
  Tonspur dieses Sprechers ist damit weg.

  Vorher endete dieser Pfad im Log, und eine verlorene Spur war für den GM nicht
  von „hat keiner gesprochen" zu unterscheiden.
  """
  @spec report_clip_failed(map(), term(), term()) :: :ok
  def report_clip_failed(state, ssrc, reason) do
    Logger.error(
      "Worker.Discord.VoiceSession: Clip-Bau fehlgeschlagen campaign=#{state.campaign_id} " <>
        "ssrc=#{ssrc}: #{inspect(reason)}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_voice",
      state.session_id,
      {:clip_build_failed, reason},
      "Die Tonspur eines Sprechers konnte nicht in eine Audiodatei umgewandelt " <>
        "werden und ist verloren (#{inspect(reason)}). Die übrigen Sprecher sind " <>
        "davon nicht betroffen. Prüfen: ist `ffmpeg` installiert und erreichbar, " <>
        "und ist auf der Platte noch Platz?"
    )
  end
end
