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

  test "leere Frame-Liste -> leere Map" do
    assert FrameBuffer.segment([]) == %{}
  end
end
