defmodule Worker.Discord.FrameBufferTest do
  @moduledoc """
  Issue #985 Slice 1: `Worker.Discord.FrameBuffer.segment/1` — das im Plan-
  Review geforderte Zwei-Sprecher-Pause-Szenario, das der #941-Spike
  nachweislich nicht gelöst hat (RTP-Timestamp gebunden, nie benutzt,
  lückenloses Aneinanderhängen). Pure Funktion, keine Discord-Verbindung
  nötig.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.FrameBuffer

  defp frame(ssrc, opus, arrival_ms), do: %{ssrc: ssrc, opus: opus, arrival_ms: arrival_ms}

  test "ein Sprecher, lückenlose Frames -> silence_before_ms jeweils 0 (außer dem ersten)" do
    frames = [
      frame(:a, "f0", 0),
      frame(:a, "f1", 20),
      frame(:a, "f2", 40)
    ]

    assert %{a: [s0, s1, s2]} = FrameBuffer.segment(frames)
    # Erster Frame ab arrival_ms=0 -> keine Session-Start-Stille.
    assert s0 == %{opus: "f0", silence_before_ms: 0}
    assert s1 == %{opus: "f1", silence_before_ms: 0}
    assert s2 == %{opus: "f2", silence_before_ms: 0}
  end

  test "ein Sprecher mit echter Sprechpause -> Lücke wird als silence_before_ms auf dem Folge-Frame sichtbar" do
    frames = [
      frame(:a, "f0", 0),
      frame(:a, "f1", 20),
      # Pause: nächstes Paket erst nach 2000ms statt nach 20ms.
      frame(:a, "f2", 2020)
    ]

    assert %{a: [_, s1, s2]} = FrameBuffer.segment(frames)
    assert s1.silence_before_ms == 0
    # f1 endet bei 20+20=40ms, f2 kommt bei 2020ms -> 1980ms Lücke.
    assert s2 == %{opus: "f2", silence_before_ms: 1980}
  end

  test "Zwei-Sprecher-Pause-Szenario: B beginnt später, A pausiert während B spricht, A setzt fort" do
    # A spricht 0-40ms, pausiert, B spricht 500-540ms (während A schweigt),
    # A setzt bei 1000ms fort. Die Pro-Sprecher-Spuren müssen relativ zu
    # einem gemeinsamen t=0 korrekt ausgerichtet bleiben — B's erster Frame
    # braucht 500ms Stille davor, A's Fortsetzungs-Frame braucht die Lücke
    # seit seinem letzten eigenen Frame (nicht seit B's Frames).
    frames = [
      frame(:a, "a0", 0),
      frame(:a, "a1", 20),
      frame(:b, "b0", 500),
      frame(:b, "b1", 520),
      frame(:a, "a2", 1000)
    ]

    result = FrameBuffer.segment(frames)

    assert result[:a] == [
             %{opus: "a0", silence_before_ms: 0},
             %{opus: "a1", silence_before_ms: 0},
             # a1 endet bei 20+20=40ms, a2 kommt bei 1000ms -> 960ms Lücke.
             %{opus: "a2", silence_before_ms: 960}
           ]

    assert result[:b] == [
             # B's erster Frame: Stille vom Session-Start (t=0) bis 500ms.
             %{opus: "b0", silence_before_ms: 500},
             %{opus: "b1", silence_before_ms: 0}
           ]
  end

  test "Frames kommen unsortiert an -> pro SSRC intern nach arrival_ms sortiert" do
    frames = [
      frame(:a, "a1", 20),
      frame(:a, "a0", 0)
    ]

    assert %{a: [%{opus: "a0"}, %{opus: "a1"}]} = FrameBuffer.segment(frames)
  end

  test "leichte Out-of-Order-Ankunft (negative Lücke) wird auf 0 geklemmt, nie negativ" do
    frames = [
      frame(:a, "a0", 100),
      # a0 endet bei 120ms, a1 kommt "früher" an als rechnerisch erwartet
      # (Jitter) -> negative Lücke, muss auf 0 geklemmt werden.
      frame(:a, "a1", 110)
    ]

    assert %{a: [_, %{silence_before_ms: 0}]} = FrameBuffer.segment(frames)
  end

  # ─── Issue #1005: Jitter darf keine Stille erzeugen ────────────────

  describe "Jitter-Schwelle (#1005)" do
    test "REGRESSION: Ankunfts-Jitter innerhalb einer Sprech-Passage erzeugt KEINE Stille" do
      # Der Bug: `max(arrival - prev_end, 0)` machte aus jedem positiven Jitter
      # eingefügte Stille — bei nominal 20 ms Abstand also eine Mikro-Pause in
      # praktisch JEDEM Frame. Folge war zerhacktes Audio (Whisper lieferte
      # Bruchstücke, mean_volume −40 dB). Hier mit realistischem ±5 ms Jitter:
      frames = [
        frame(:a, "f0", 0),
        frame(:a, "f1", 25),
        frame(:a, "f2", 43),
        frame(:a, "f3", 68),
        frame(:a, "f4", 85)
      ]

      assert %{a: segs} = FrameBuffer.segment(frames)

      for s <- tl(segs) do
        assert s.silence_before_ms == 0,
               "Jitter wurde als Stille eingefügt (der #1005-Bug): #{inspect(s)}"
      end
    end

    test "auch starker Jitter unter der Schwelle bleibt stille-frei (Scheduler-Last)" do
      # arrival_ms wird in einem pro Event gespawnten Task gemessen; unter
      # Whisper-Last ist der Jitter deutlich größer als ±5 ms.
      frames = [frame(:a, "f0", 0), frame(:a, "f1", 100), frame(:a, "f2", 190)]

      assert %{a: [_, s1, s2]} = FrameBuffer.segment(frames)
      # 100 - 20 = 80 ms Lücke → unter 100 ms → Jitter, keine Stille.
      assert s1.silence_before_ms == 0
      # 190 - 120 = 70 ms → ebenfalls Jitter.
      assert s2.silence_before_ms == 0
    end

    test "Grenzwerte: knapp unter der Schwelle = 0, knapp darüber = quantisierte Stille" do
      min_gap = FrameBuffer.min_gap_ms()

      # gap_silence/1 ist die pure Entscheidung — direkt geprüft, damit der
      # Grenzfall nicht von der Frame-Arithmetik verdeckt wird.
      assert FrameBuffer.gap_silence(min_gap - 1) == 0
      assert FrameBuffer.gap_silence(min_gap) == min_gap
      assert FrameBuffer.gap_silence(0) == 0
      # Negative Lücke (Out-of-Order) bleibt 0 — nie negative Stille.
      assert FrameBuffer.gap_silence(-30) == 0
    end

    test "eingefügte Stille ist immer ein 20-ms-Vielfaches (Sample-Ausrichtung)" do
      for gap <- [100, 137, 199, 250, 1993] do
        silence = FrameBuffer.gap_silence(gap)
        assert rem(silence, 20) == 0, "#{gap} ms → #{silence} ms ist kein 20-ms-Vielfaches"
        assert silence <= gap, "Stille darf die gemessene Lücke nie überschreiten"
      end
    end

    test "echte Pause (Discord sendet in Stille NICHTS) wird eingefügt" do
      # Der Fall, für den die Stille gedacht ist: eine echte Sprechpause.
      frames = [frame(:a, "f0", 0), frame(:a, "f1", 520)]

      assert %{a: [_, s1]} = FrameBuffer.segment(frames)
      # 520 - 20 = 500 ms → echte Pause, bleibt erhalten.
      assert s1.silence_before_ms == 500
    end

    test "Session-Start-Offset bleibt exakt (nicht geschwellt, nicht quantisiert)" do
      # Die sprecherübergreifende Ausrichtung ist keine Jitter-Frage: ein
      # Sprecher, der bei 37 ms einsetzt, muss genau dort einsetzen.
      assert %{a: [s0]} = FrameBuffer.segment([frame(:a, "f0", 37)])
      assert s0.silence_before_ms == 37
    end
  end

  test "leere Frame-Liste -> leere Map" do
    assert FrameBuffer.segment([]) == %{}
  end
end
