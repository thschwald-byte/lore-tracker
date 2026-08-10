defmodule Worker.Discord.BotSupervisorTest do
  @moduledoc """
  Issue #985 Slice 1 (Stage D) + Issue #987 (Registry-Ownership-Fix):
  `Worker.Discord.BotSupervisor` — best-effort Start/Stop, darf den Caller nie
  crashen. Ohne laufenden `Nostrum.Bot` (kein Token im Test-Env konfiguriert)
  scheitert `Voice.join_channel/4` synchron im `VoiceSession.init/1` mit einem
  `RuntimeError` — verifiziert am tatsächlichen Verhalten (nicht angenommen):
  `DynamicSupervisor.start_child/2` liefert dafür sauber `{:error, {exception,
  stacktrace}}`, crasht NICHT den Supervisor selbst und hinterlässt keinen
  Zombie-Prozess. Das ist exakt der Pfad, den `maybe_start_voice_session/1`
  abfangen muss — dieser Test exerziert ihn real, nicht simuliert.

  Die Ownership-Tests (#987: zwei Kampagnen auf derselben Guild dürfen sich
  nie gegenseitig die Session stehlen/killen) simulieren eine "bereits
  laufende Session" über einen echten, im `Worker.Discord.Registry` unter dem
  `VoiceSession.via/2`-Namen registrierten Fake-Prozess (ein `Agent`, als
  Kind des `Worker.Discord.BotSupervisor` gestartet) — ohne einen echten
  Nostrum-Bot zu brauchen.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Discord.BotSupervisor
  alias Worker.Discord.VoiceSession

  setup do
    # Der :conflict-Pfad publisht ein `PipelineErrorLogged` — braucht den
    # echten Materializer-GenServer (sonst `GenServer.call` gegen einen toten
    # Namen).
    ensure_materializer!()
    {:ok, _} = start_supervised({Registry, keys: :unique, name: Worker.Discord.Registry})

    {:ok, _} =
      start_supervised(
        {DynamicSupervisor, name: Worker.Discord.BotSupervisor, strategy: :one_for_one}
      )

    :ok
  end

  defp cfg(guild_id, campaign_id \\ "camp-985"),
    do: %{
      campaign_id: campaign_id,
      session_id: "sess-985",
      guild_id: guild_id,
      voice_channel_id: 999
    }

  defp start_fake_session!(guild_id, owner) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Worker.Discord.BotSupervisor,
        %{
          id: {:fake_voice_session, guild_id},
          start: {Agent, :start_link, [fn -> :ok end, [name: VoiceSession.via(guild_id, owner)]]}
        }
      )

    pid
  end

  test "kein Nostrum.Bot verbunden -> Start scheitert graceful (:error), kein Crash, keine Zombie-Row" do
    assert :error = BotSupervisor.maybe_start_voice_session(cfg(111))
    assert DynamicSupervisor.which_children(Worker.Discord.BotSupervisor) == []
    assert Registry.lookup(Worker.Discord.Registry, 111) == []
  end

  test "bereits laufende Session derselben Kampagne -> {:ok, guild_id} idempotent, kein Doppel-Start" do
    owner = %{campaign_id: "camp-985", voice_channel_id: 999}
    start_fake_session!(222, owner)

    assert {:ok, 222} = BotSupervisor.maybe_start_voice_session(cfg(222))
    assert length(DynamicSupervisor.which_children(Worker.Discord.BotSupervisor)) == 1
  end

  test "andere Kampagne belegt dieselbe Guild -> :conflict, fremde Session bleibt unangetastet" do
    owner = %{campaign_id: "camp-other", voice_channel_id: 777}
    start_fake_session!(333, owner)

    assert :conflict = BotSupervisor.maybe_start_voice_session(cfg(333, "camp-985"))
    assert [{_pid, ^owner}] = Registry.lookup(Worker.Discord.Registry, 333)
    assert length(DynamicSupervisor.which_children(Worker.Discord.BotSupervisor)) == 1
  end

  test "Stop ohne laufende Session ist ein sicherer No-op" do
    assert :ok = BotSupervisor.stop_voice_session(444, "camp-985")
  end

  test "Stop terminiert nur die eigene Kampagne, fremde Session bleibt am Leben" do
    owner = %{campaign_id: "camp-owner", voice_channel_id: 888}
    pid = start_fake_session!(555, owner)

    assert :ok = BotSupervisor.stop_voice_session(555, "camp-not-owner")
    assert Process.alive?(pid)

    assert :ok = BotSupervisor.stop_voice_session(555, "camp-owner")
    refute Process.alive?(pid)
  end
end
