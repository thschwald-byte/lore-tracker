defmodule Worker.Discord.VoiceSessionTest do
  @moduledoc """
  Echter Live-Test-Fund (#987-Nacharbeit): `init/1` joint per
  `Nostrum.Voice.join_channel/4`, aber KEIN `terminate/2`-Zweig rief je
  `Nostrum.Voice.leave_channel/1` — der Bot blieb nach jedem Stop im
  Voice-Channel hängen (Nostrums Voice-State pro Guild lebt unabhängig vom
  Lebenszyklus dieses GenServers). Diese Tests rufen `terminate/2` DIREKT
  (kein laufender Prozess nötig, GenServer-Callback ist eine reine Funktion)
  und verifizieren nur die Crash-Sicherheit ohne echten `Nostrum.Bot` — den
  tatsächlichen `leave_channel`-Aufruf ohne Mocking-Lib zu verifizieren ist
  hier nicht möglich (Muster `BotSupervisorTest`: reale Ausführung gegen
  einen fehlenden Bot, kein Mock).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Discord.VoiceSession

  setup do
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        campaign_id: "camp-vs-987",
        session_id: "sess-vs-987",
        guild_id: 999_888_777,
        voice_channel_id: 111,
        listening?: true,
        session_start_ms: 0,
        start_listen_timer: nil,
        frames: []
      },
      overrides
    )
  end

  test "terminate(:normal, ...) versucht Voice.leave_channel, crasht nicht ohne echten Nostrum.Bot" do
    assert :ok = VoiceSession.terminate(:normal, state())
  end

  test "terminate(:shutdown, ...) crasht nicht ohne echten Nostrum.Bot" do
    assert :ok = VoiceSession.terminate(:shutdown, state())
  end

  test "terminate({:shutdown, reason}, ...) crasht nicht ohne echten Nostrum.Bot" do
    assert :ok = VoiceSession.terminate({:shutdown, :some_reason}, state())
  end

  test "abnormaler Exit: crasht nicht, publisht trotzdem den PipelineErrorLogged" do
    assert :ok = VoiceSession.terminate(:some_crash_reason, state())
  end
end
