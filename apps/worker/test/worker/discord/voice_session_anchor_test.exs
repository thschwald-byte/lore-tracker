defmodule Worker.Discord.VoiceSessionAnchorTest do
  @moduledoc """
  Issue #1060: der Discord-Clip muss mit dem FENSTERBEGINN als Start-Anker in
  den AudioBuffer gehen.

  Ohne die beiden Optionen nimmt der Writer seine eigene Ankunftszeit und liest
  sie als ENDE des Stücks (`ChunkManifest`-Default). Für den Browser ist das
  richtig, hier ist es doppelt falsch: der Clip endet beim letzten Wort DIESES
  Sprechers (wer früh im Fenster verstummt, rutscht um den Rest des Fensters
  nach hinten — bei 60-s-Fenstern bis zu einer Minute), und der Schreibzeitpunkt
  liegt hinter Mux + zwei ffmpeg-Läufen je Sprecher.

  **Warum ein Quelltext-Wächter:** `handle_clip/4` ist privat, braucht eine
  aufgelöste SSRC-Map aus `Nostrum.Voice` und schreibt in einen benannten
  GenServer. Ein Verhaltenstest müsste Nostrum mocken und prüfte dann den Mock.
  Das Entfernen der Optionen ist genau der stille Rückfall, der hier auffallen
  soll — die Zeitstempel wären danach wieder falsch, ohne dass irgendein Test
  rot wird. Die Rechnung selbst (`window_start_wall_ms/1`) und ihre Wirkung
  (`ChunkManifest.resolve/4` mit `:start`) sind separat verhaltensgetestet.
  """

  use ExUnit.Case, async: true

  @source "lib/worker/discord/voice_session.ex"

  defp append_call do
    src = File.read!(Path.join(__DIR__, "../../../#{@source}"))

    case String.split(src, "Worker.Recording.AudioBuffer.append(", parts: 2) do
      [_, rest] -> rest |> String.split("\n        else", parts: 2) |> hd()
      _ -> flunk("#{@source} ruft `Worker.Recording.AudioBuffer.append(` gar nicht mehr auf")
    end
  end

  test "der Clip geht mit dem Fensterbeginn als Start-Anker raus" do
    call = append_call()

    assert call =~ "wall_clock_ms: window_start_wall_ms(state)", """
    Der `AudioBuffer.append`-Aufruf gibt den Fensterbeginn nicht mehr mit.

    Damit verankert der Writer den Clip wieder an seiner eigenen Schreibzeit —
    also hinter Mux + ffmpeg, und pro Sprecher unterschiedlich weit hinter dem
    Fenster. Genau der Zustand aus #1060.
    """

    assert call =~ "anchor: :start", """
    Der `AudioBuffer.append`-Aufruf setzt `anchor: :start` nicht mehr.

    Ohne den Anker liest `ChunkManifest.resolve/4` den mitgegebenen Zeitpunkt
    als ENDE des Clips und rechnet rückwärts — der Clip endet aber beim letzten
    Wort des Sprechers, nicht am Fensterende.
    """
  end

  test "der Anker wird aus dem State gerechnet, nicht aus einer Uhr" do
    # `window_start_wall_ms/1` ist pure; stünde hier stattdessen ein
    # `System.system_time`-Aufruf, wäre die Verarbeitungsdauer des Flushes
    # wieder im Zeitstempel.
    refute append_call() =~ "System.system_time"
  end
end
