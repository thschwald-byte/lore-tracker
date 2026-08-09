defmodule Worker.ApplicationDiscordBotChildTest do
  @moduledoc """
  Issue #985 Slice 1 (Stage C): `Worker.Application.discord_bot_child/0` —
  der Nostrum-Kindprozess wird NUR aufgenommen, wenn beim Boot ein Bot-Token
  konfiguriert ist. Pure Child-Spec-Konstruktion (kein `Supervisor.start_link/2`
  hier) — sicher ohne echte Discord-Gateway-Verbindung testbar.
  """

  use ExUnit.Case, async: false

  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    original_env = System.get_env("DISCORD_BOT_TOKEN")
    System.delete_env("DISCORD_BOT_TOKEN")

    on_exit(fn ->
      if original_env, do: System.put_env("DISCORD_BOT_TOKEN", original_env)
      if is_nil(original_env), do: System.delete_env("DISCORD_BOT_TOKEN")
    end)

    :ok
  end

  test "kein Token konfiguriert -> leere Liste (kein Crash-Loop-Log-Spam)" do
    assert Worker.Application.discord_bot_child() == []
  end

  test "Token via Settings konfiguriert -> genau ein {Nostrum.Bot, opts}-Child" do
    Settings.put(:discord_bot_token, "tok-123")

    assert [{Nostrum.Bot, opts}] = Worker.Application.discord_bot_child()
    assert opts.consumer == Worker.Discord.Consumer
    assert opts.intents == [:guilds, :guild_voice_states]
    assert is_function(opts.wrapped_token, 0)
    assert opts.wrapped_token.() == "tok-123"
  end

  test "Token nur via ENV konfiguriert -> Child wird trotzdem aufgenommen" do
    System.put_env("DISCORD_BOT_TOKEN", "tok-env")

    assert [{Nostrum.Bot, opts}] = Worker.Application.discord_bot_child()
    assert opts.wrapped_token.() == "tok-env"
  end
end
