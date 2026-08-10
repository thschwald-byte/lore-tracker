defmodule Worker.Recording.RecorderDiscordBotTest do
  @moduledoc """
  Issue #985 Slice 1 (Stage E): `Recorder.maybe_start_discord_bot/2` — der
  best-effort Hook-Punkt, der den Kern-Recording-Start nie blockieren darf.
  Getestet wird die Gate-/Parse-Logik (kein Bot-Token, keine Config, kaputte
  Werte) OHNE einen echten `Nostrum.Bot` — genau die Fälle, die synchron vor
  jedem Discord-Verbindungsversuch entscheiden.

  Issue #987 (Registry-Ownership-Fix): `maybe_start_discord_bot/2` liefert die
  Guild-ID NUR zurück, wenn `BotSupervisor.maybe_start_voice_session/1`
  tatsächlich `{:ok, _}` meldet — ohne echten `Nostrum.Bot` scheitert der
  reale Verbindungsversuch immer (`:error`), auch bei sonst gültiger Config.
  Das ist die korrekte neue Verhaltensweise: die alte Fassung gab die
  Guild-ID unbedingt zurück, wodurch ein späterer Stop eine fremde
  Kampagnen-Session hätte killen können (der eigentliche #987-Bug).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Recording.Recorder
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Settings

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    {:ok, _} = start_supervised({Registry, keys: :unique, name: Worker.Discord.Registry})

    {:ok, _} =
      start_supervised(
        {DynamicSupervisor, name: Worker.Discord.BotSupervisor, strategy: :one_for_one}
      )

    :ok
  end

  defp write_discord_config!(cid, guild_id, voice_channel_id) do
    Builder.write!(
      {S.campaign_discord_configs(), cid, guild_id, voice_channel_id, DateTime.utc_now()}
    )
  end

  test "kein Bot-Token konfiguriert -> nil, kein Versuch (auch mit gültiger Config)" do
    write_discord_config!("camp-e-1", "111", "222")
    assert Recorder.maybe_start_discord_bot("camp-e-1", "sess-1") == nil
  end

  test "Bot-Token gesetzt, aber keine Discord-Config -> nil" do
    Settings.put(:discord_bot_token, "tok")
    assert Recorder.maybe_start_discord_bot("camp-e-2", "sess-2") == nil
  end

  test "Bot-Token + gültige Config, aber kein echter Nostrum.Bot -> nil (kein Fake-Erfolg)" do
    Settings.put(:discord_bot_token, "tok")
    write_discord_config!("camp-e-3", "111222333", "444555666")

    assert Recorder.maybe_start_discord_bot("camp-e-3", "sess-3") == nil
  end

  test "bereits laufende eigene Session -> Guild-ID (Issue #987 idempotent-Pfad)" do
    Settings.put(:discord_bot_token, "tok")
    write_discord_config!("camp-e-6", "111222333", "444555666")

    owner = %{campaign_id: "camp-e-6", voice_channel_id: 444_555_666}

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Worker.Discord.BotSupervisor,
        %{
          id: :fake_voice_session,
          start:
            {Agent, :start_link,
             [fn -> :ok end, [name: Worker.Discord.VoiceSession.via(111_222_333, owner)]]}
        }
      )

    assert Recorder.maybe_start_discord_bot("camp-e-6", "sess-6") == 111_222_333
  end

  test "Bot-Token + Config mit nicht-numerischen Werten -> nil (kein Crash)" do
    Settings.put(:discord_bot_token, "tok")
    write_discord_config!("camp-e-4", "keine-zahl", "222")

    assert Recorder.maybe_start_discord_bot("camp-e-4", "sess-4") == nil
  end

  test "Bot-Token + Config mit leeren Feldern (Reset-Zustand) -> nil" do
    Settings.put(:discord_bot_token, "tok")
    write_discord_config!("camp-e-5", "", "")

    assert Recorder.maybe_start_discord_bot("camp-e-5", "sess-5") == nil
  end
end
