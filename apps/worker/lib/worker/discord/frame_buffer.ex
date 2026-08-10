defmodule Worker.Discord.FrameBuffer do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage D/F: reine
  Datenverarbeitung, von der Gateway-Verbindung entkoppelt — fixture-testbar
  ohne echte Discord-Session (der fehleranfälligste Teil der Bot-Integration,
  s. Plan-Review zu #985).

  **Das eigentliche Problem, das dieses Modul löst:** Discord sendet RTP-
  Pakete pro Sprecher NUR während gesprochen wird — kein Paket in Pausen.
  Ein naives Aneinanderhängen der ankommenden Opus-Frames pro Sprecher
  erzeugt lückenloses Audio, dessen Zeitachse gegen die Wanduhr und gegen
  die Spuren anderer Sprecher driftet. Verifiziert am tatsächlichen #941-
  Spike-Code: der hat genau das getan (RTP-Timestamp gebunden, nie benutzt)
  und war deshalb im Mehr-Sprecher-Pausen-Fall nachweislich falsch.

  **Ansatz — Ankunftszeit statt RTP-Timestamp als Referenz:** RTP-Timestamps
  starten pro SSRC bei einem zufälligen 32-Bit-Offset (RFC 3550) und sind
  daher NICHT sprecherübergreifend vergleichbar — für die sprecherübergreifende
  Ausrichtung taugen sie nicht. Stattdessen wird die Ankunftszeit
  (`arrival_ms`, eine gemeinsame monotone Uhr relativ zum Session-Start, t=0)
  als einzige Zeitreferenz genutzt — sowohl für Lücken INNERHALB eines
  Sprechers als auch für die Startversetzung ZWISCHEN Sprechern (Sprecher B
  beginnt 5s nach Sprecher A → B's erster Frame trägt 5000ms Stille davor).

  **Bekannte Grenzen (v1, bewusst nicht gelöst):**
  - Keine RTP-Sequenznummer-basierte Reordering — Frames müssen bereits in
    Ankunftsreihenfolge hereinkommen (bei UDP-Jitter innerhalb eines kurzen
    Fensters eine vertretbare Vereinfachung, aber keine Garantie).
  - Negative Lücken (Jitter/leichte Out-of-Order-Ankunft) werden auf 0
    geklemmt statt eine Korrektur zu versuchen — nie negative Stille.
  - Kein Jitter-Buffer, keine Verlust-Kompensation über den reinen
    Zeitstempel-Vergleich hinaus.
  """

  @doc """
  `frames`: Liste von `%{ssrc:, opus:, arrival_ms:}` in Ankunftsreihenfolge
  (über alle Sprecher gemischt; wird intern pro SSRC nochmal nach
  `arrival_ms` sortiert). Liefert `%{ssrc => [%{opus:, silence_before_ms:}]}`
  — pro Sprecher eine chronologische Liste, jeder Frame mit der Stille-Dauer
  (ms), die DAVOR eingefügt werden muss, damit die Pro-Sprecher-Spuren
  relativ zu einem gemeinsamen Session-Start (t=0) korrekt ausgerichtet
  bleiben.
  """
  @spec segment([%{ssrc: term(), opus: binary(), arrival_ms: non_neg_integer()}]) ::
          %{term() => [%{opus: binary(), silence_before_ms: non_neg_integer()}]}
  def segment(frames) when is_list(frames) do
    frames
    |> Enum.group_by(& &1.ssrc)
    |> Map.new(fn {ssrc, ssrc_frames} -> {ssrc, segment_ssrc(ssrc_frames)} end)
  end

  # Frame-Dauer bei Discord-Voice: 20ms (960 Samples @ 48kHz) — der de-facto
  # Standardwert für Opus-über-RTP in diesem Protokoll, nicht aus den Paketen
  # selbst ableitbar (Opus-Frames tragen ihre Dauer nicht im Klartext-Header).
  @frame_duration_ms 20

  defp segment_ssrc(frames) do
    frames
    |> Enum.sort_by(& &1.arrival_ms)
    |> Enum.map_reduce(nil, fn frame, prev_end_ms ->
      silence_before_ms =
        case prev_end_ms do
          # Erster Frame dieses Sprechers: Stille vom Session-Start (t=0) bis
          # zum ersten Wort — das ist die sprecherübergreifende Ausrichtung.
          nil -> frame.arrival_ms
          prev -> max(frame.arrival_ms - prev, 0)
        end

      out = %{opus: frame.opus, silence_before_ms: silence_before_ms}
      {out, frame.arrival_ms + @frame_duration_ms}
    end)
    |> elem(0)
  end
end
