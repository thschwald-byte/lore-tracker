defmodule Worker.Recording.RecorderStopOrderTest do
  @moduledoc """
  Issue #1011: im Stop-Pfad muss der Discord-Bot VOR dem Finalize gestoppt
  werden.

  Vorher war es umgekehrt, und weil der einzige Schreibpfad des Bots
  `flush_frames/1` aus `VoiceSession.terminate/2` ist, kam jede Discord-Aufnahme
  garantiert NACH dem Finalize an. Sichtbar im Prod-Log (dreimal in Folge am
  2026-08-12):

      finalized session=… files=0 → handing off to Transcribe
      no audio files … kein Transcribe-Task, Pipeline wird nicht getriggert
      VoiceSession: terminate reason=:shutdown
      Late-Append re-opens ended session=… (Issue #949)
      late-append … files=1 → Nach-Transkription

  Es funktionierte also nur, weil #949 (Late-Append für verspätete
  Browser-Chunks) die beendete Session wieder aufmachte — ein Notfallnetz als
  Regelpfad.

  **Warum ein Quelltext-Wächter und kein Verhaltenstest:** die Invariante ist
  eine REIHENFOLGE zweier Seiteneffekte auf zwei verschiedene Prozesse, von denen
  einer (`Nostrum.Voice`) ohne echte Discord-Verbindung nicht startbar ist. Ein
  Verhaltenstest müsste beide durch Mocks ersetzen und würde dann die Mocks
  prüfen, nicht die Reihenfolge. Ein Vertauschen der beiden Zeilen ist genau der
  Rückfall, der hier auffallen soll — und er fällt hier auf.
  """

  use ExUnit.Case, async: true

  @source "lib/worker/recording/recorder.ex"

  defp stop_clause_body do
    src = File.read!(Path.join(__DIR__, "../../../#{@source}"))

    # Nur der `{:stop, campaign_id}`-Zweig, bis zur nächsten handle_call-Klausel.
    [_, rest] = String.split(src, "def handle_call({:stop, campaign_id}", parts: 2)

    rest
    |> String.split("\n  def handle_call", parts: 2)
    |> hd()
  end

  test "der Bot wird VOR dem Finalize gestoppt" do
    body = stop_clause_body()

    stop_at = index_of!(body, "maybe_stop_discord_bot", "Bot-Stop")
    finalize_at = index_of!(body, "AudioBuffer.finalize", "Finalize")

    assert stop_at < finalize_at, """
    Im Stop-Pfad steht `AudioBuffer.finalize` VOR `maybe_stop_discord_bot`.

    Damit landet das Discord-Audio wieder nach dem Finalize (files=0) und wird
    nur noch durch den Late-Append-Notpfad (#949) gerettet — genau der Zustand
    aus #1011.
    """
  end

  test "beide Aufrufe stehen überhaupt noch in diesem Zweig" do
    # Verhindert, dass der Wächter still wirkungslos wird, weil einer der beiden
    # Aufrufe umbenannt oder in eine Hilfsfunktion verschoben wurde.
    body = stop_clause_body()

    assert body =~ "maybe_stop_discord_bot"
    assert body =~ "AudioBuffer.finalize"
  end

  defp index_of!(body, needle, label) do
    case :binary.match(body, needle) do
      {pos, _} ->
        pos

      :nomatch ->
        flunk("#{label} (`#{needle}`) steht nicht mehr im {:stop, …}-Zweig von #{@source}")
    end
  end
end
