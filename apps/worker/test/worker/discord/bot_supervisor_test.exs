defmodule Worker.Discord.BotSupervisorTest do
  @moduledoc """
  Issue #985 Slice 1 (Stage D): `Worker.Discord.BotSupervisor` — best-effort
  Start/Stop, darf den Caller nie crashen. Ohne laufenden `Nostrum.Bot`
  (kein Token im Test-Env konfiguriert) scheitert `Voice.join_channel/4`
  synchron im `VoiceSession.init/1` mit einem `RuntimeError` — verifiziert
  am tatsächlichen Verhalten (nicht angenommen): `DynamicSupervisor.start_child/2`
  liefert dafür sauber `{:error, {exception, stacktrace}}`, crasht NICHT den
  Supervisor selbst und hinterlässt keinen Zombie-Prozess. Das ist exakt der
  Pfad, den `maybe_start_voice_session/1` abfangen muss — dieser Test
  exerziert ihn real, nicht simuliert.
  """

  use ExUnit.Case, async: false

  alias Worker.Discord.BotSupervisor

  setup do
    {:ok, _} = start_supervised({Registry, keys: :unique, name: Worker.Discord.Registry})

    {:ok, _} =
      start_supervised(
        {DynamicSupervisor, name: Worker.Discord.BotSupervisor, strategy: :one_for_one}
      )

    :ok
  end

  defp cfg(guild_id),
    do: %{
      campaign_id: "camp-985",
      session_id: "sess-985",
      guild_id: guild_id,
      voice_channel_id: 999
    }

  test "kein Nostrum.Bot verbunden -> Start scheitert graceful, kein Crash, keine Zombie-Row" do
    assert :ok = BotSupervisor.maybe_start_voice_session(cfg(111))
    assert DynamicSupervisor.which_children(Worker.Discord.BotSupervisor) == []
    assert Registry.lookup(Worker.Discord.Registry, 111) == []
  end

  test "doppelter Start-Aufruf für dieselbe Guild bleibt idempotent-sicher" do
    assert :ok = BotSupervisor.maybe_start_voice_session(cfg(222))
    assert :ok = BotSupervisor.maybe_start_voice_session(cfg(222))
    assert DynamicSupervisor.which_children(Worker.Discord.BotSupervisor) == []
  end

  test "Stop ohne laufende Session ist ein sicherer No-op" do
    assert :ok = BotSupervisor.stop_voice_session(333)
  end
end
