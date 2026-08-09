defmodule Worker.Discord.BotTokenTest do
  @moduledoc """
  Issue #985 Slice 1: Settings-first / ENV-Fallback-Lookup, Muster
  Worker.LLM.ApiKey. Not async — mutiert das Singleton worker_state + eine
  Prozess-globale Env-Var.
  """

  use ExUnit.Case, async: false

  alias Worker.Discord.BotToken
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    original_env = System.get_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      if original_env, do: System.put_env("DISCORD_BOT_TOKEN", original_env)
      if is_nil(original_env), do: System.delete_env("DISCORD_BOT_TOKEN")
    end)

    System.delete_env("DISCORD_BOT_TOKEN")
    :ok
  end

  test "weder Settings noch Env gesetzt -> nil / :unset" do
    assert BotToken.get() == nil
    assert BotToken.status() == :unset
  end

  test "über Settings gesetzt -> get liefert Wert, status :set_via_settings" do
    Settings.put(:discord_bot_token, "tok-from-settings")
    assert BotToken.get() == "tok-from-settings"
    assert BotToken.status() == :set_via_settings
  end

  test "nur über ENV gesetzt -> get liefert Wert, status :set_via_env" do
    System.put_env("DISCORD_BOT_TOKEN", "tok-from-env")
    assert BotToken.get() == "tok-from-env"
    assert BotToken.status() == :set_via_env
  end

  test "Settings gewinnt vor ENV" do
    System.put_env("DISCORD_BOT_TOKEN", "tok-from-env")
    Settings.put(:discord_bot_token, "tok-from-settings")
    assert BotToken.get() == "tok-from-settings"
    assert BotToken.status() == :set_via_settings
  end

  test "Leerstring in Settings zählt als nicht-gesetzt -> fällt auf ENV zurück" do
    Settings.put(:discord_bot_token, "")
    System.put_env("DISCORD_BOT_TOKEN", "tok-from-env")
    assert BotToken.get() == "tok-from-env"
    assert BotToken.status() == :set_via_env
  end
end
