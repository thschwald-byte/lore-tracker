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

  ## Issue #1005: warum eine Lücken-SCHWELLE nötig ist

  Der ursprüngliche Ansatz klemmte nur die **negative** Jitter-Richtung („nie
  negative Stille") und übernahm die **positive** ungeprüft als echte Pause:

      silence_before_ms = max(frame.arrival_ms - prev_end_ms, 0)

  Bei nominal 20 ms Frame-Abstand ist der gemessene Abstand aber `20 ± Jitter`.
  Damit wurde **jeder positive Jitter zu eingefügter Stille**, während jeder
  negative auf 0 fiel — ein systematischer Bias in eine Richtung, der
  zusammenhängende Rede **alle 20 ms** mit Mikro-Pausen durchsetzt und die Spur
  dehnt. Real gemessene Folge (#1005): Whisper machte aus einem klaren Satz
  Bruchstücke („Das wäre jetzt. auch mit zu. Aufnahme."), `mean_volume` fiel auf
  −40 dB, und die VAD fand gar keine Sprachsegmente. Verschärfend: `arrival_ms`
  wird in einem pro Gateway-Event frisch gespawnten Task gemessen, ist also
  scheduler-abhängig — unter Whisper-Last ist der Jitter kein ±5 ms mehr.

  **Herleitung der Schwelle (`@min_gap_ms`), statt einer geratenen Zahl:** die
  Abstandsverteilung ist **bimodal**, weil Discord in Pausen *gar keine* Pakete
  sendet. Es gibt also nur zwei Sorten Abstände:

    * **innerhalb einer Sprech-Passage:** ≈ 20 ms plus Jitter (Netz + Scheduler),
    * **echte Pause:** die Pausenlänge selbst — Wortgrenzen ab ~150 ms,
      Satzpausen ab ~300 ms, Sprecherwechsel deutlich mehr.

  Die Schwelle muss **über** dem Jitter und **unter** der kürzesten Pause liegen,
  die für die Whisper-Segmentierung zählt. 100 ms liegt in dieser Lücke: klar
  über dem Jitter (auch unter Last), klar unter Wortgrenzen-Pausen. Ein Abstand
  unter 100 ms ist damit als Jitter interpretiert und erzeugt **keine** Stille;
  alles darüber ist eine echte Pause und wird eingefügt.

  Das driftet nicht: jede Lücke wird lokal aus zwei Ankunftszeiten berechnet
  (`prev_end` leitet sich aus dem *vorherigen* Frame ab, es akkumuliert nichts).
  Unterdrückter Jitter innerhalb einer Passage verkürzt diese Passage minimal,
  statt sie zu zerhacken.

  Eingefügte Stille wird zusätzlich auf **20-ms-Vielfache** quantisiert (die
  Frame-Dauer), damit die Sample-Ausrichtung der Spur erhalten bleibt.

  **Der Session-Start-Offset des ERSTEN Frames bleibt ungeschwellt und
  unquantisiert** — er ist die sprecherübergreifende Ausrichtung (B beginnt 5 s
  nach A) und keine Jitter-Frage.

  **Bekannte Grenzen (bewusst nicht gelöst):**
  - Keine RTP-Sequenznummer-basierte Reordering — Frames müssen bereits in
    Ankunftsreihenfolge hereinkommen. Der RTP-Timestamp wäre die robustere Uhr,
    braucht aber Unwrapping (16-bit-`seq` läuft nach ~21,8 min Dauerrede über,
    manche Clients setzen den 32-bit-`ts` beim Sprech-Neustart neu) — eigener
    Schnitt, nicht nebenbei.
  - Echte Pausen **unter** `@min_gap_ms` werden geschlossen. Das ist die gewollte
    Richtung: eine geschluckte 80-ms-Pause kostet nichts, eine erfundene kostet
    die Verständlichkeit.
  - Kein Jitter-Buffer, keine Verlust-Kompensation.
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

  # Issue #1005: Lücken unter dieser Schwelle sind Jitter, nicht Pause — s.
  # Moduledoc-Herleitung (bimodale Verteilung: ~20 ms innerhalb einer Passage,
  # ≥150 ms bei echten Pausen; 100 ms liegt in der Lücke dazwischen).
  @min_gap_ms 100

  defp segment_ssrc(frames) do
    frames
    |> Enum.sort_by(& &1.arrival_ms)
    |> Enum.map_reduce(nil, fn frame, prev_end_ms ->
      silence_before_ms =
        case prev_end_ms do
          # Erster Frame dieses Sprechers: Stille vom Session-Start (t=0) bis
          # zum ersten Wort — das ist die sprecherübergreifende Ausrichtung und
          # bewusst NICHT geschwellt/quantisiert (keine Jitter-Frage).
          nil -> frame.arrival_ms
          prev -> gap_silence(frame.arrival_ms - prev)
        end

      out = %{opus: frame.opus, silence_before_ms: silence_before_ms}
      {out, frame.arrival_ms + @frame_duration_ms}
    end)
    |> elem(0)
  end

  @doc """
  Issue #1005: gemessene Lücke → einzufügende Stille. PURE, damit die
  Schwellen-Entscheidung ohne Discord-Session testbar ist.

  Unter `@min_gap_ms` (inkl. negativer Werte aus Out-of-Order-Ankunft) → `0`:
  das ist Jitter, keine Pause. Darüber → auf `@frame_duration_ms` abgerundet,
  damit die Sample-Ausrichtung der Spur erhalten bleibt.
  """
  @spec gap_silence(integer()) :: non_neg_integer()
  def gap_silence(gap_ms) when is_integer(gap_ms) do
    if gap_ms < @min_gap_ms do
      0
    else
      div(gap_ms, @frame_duration_ms) * @frame_duration_ms
    end
  end

  @doc false
  @spec min_gap_ms() :: pos_integer()
  def min_gap_ms, do: @min_gap_ms
end
