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

  describe "classify/1 — Issue #1076: dauerhaft vs. vorübergehend" do
    test "200 -> :ok" do
      assert BotToken.classify({:ok, %{status: 200}}) == :ok
    end

    test "401/403 -> :rejected (derselbe Token wird nie gültig)" do
      assert BotToken.classify({:ok, %{status: 401}}) == :rejected
      assert BotToken.classify({:ok, %{status: 403}}) == :rejected
    end

    test "429 und 5xx sind KEINE Ablehnung — sonst gibt der Worker wegen einer Discord-Störung dauerhaft auf" do
      assert {:network_error, {:http_status, 429}} = BotToken.classify({:ok, %{status: 429}})
      assert {:network_error, {:http_status, 500}} = BotToken.classify({:ok, %{status: 500}})
      assert {:network_error, {:http_status, 503}} = BotToken.classify({:ok, %{status: 503}})
    end

    test "Transport-Fehler -> Netzfehler; das ist der reale Vorfall (DNS beim Boot noch nicht da)" do
      assert BotToken.classify({:error, %{reason: :nxdomain}}) ==
               {:network_error, %{reason: :nxdomain}}
    end

    test "unerwartete Form fällt sichtbar durch, statt still als gültig zu gelten" do
      assert {:network_error, {:unexpected, :garbage}} = BotToken.classify(:garbage)
    end
  end

  describe "check/0 ohne Token" do
    test "kein Token -> :no_token, ohne Netzwerk-Call" do
      assert BotToken.check() == :no_token
      refute BotToken.usable?()
    end
  end
end
