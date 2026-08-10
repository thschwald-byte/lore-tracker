defmodule Worker.ApplicationDiscordBotChildTest do
  @moduledoc """
  Issue #985 Slice 1 (Stage C, gehärtet nach echtem PR-Test-Fund):
  `Worker.Application.discord_bot_child/0` — der Nostrum-Kindprozess wird
  NUR aufgenommen, wenn `BotToken.usable?/0` den Token per echtem Discord-
  API-Call bestätigt.

  **Der echte Bug, den dieser Test-Umbau dokumentiert:** die ursprüngliche
  Fassung dieses Tests prüfte nur „irgendein String gesetzt → Child dabei" —
  genau die Lücke, die im echten PR-Test (`mix lore.pr_test.spawn`, ein
  bereits im `.env` hinterlegter, ungültiger `DISCORD_BOT_TOKEN`) den
  GESAMTEN Worker-Boot crashen ließ (`Nostrum.Shard.Supervisor` validiert den
  Token synchron gegen die echte Gateway-URL und wirft bei Ablehnung —
  `Nostrum.Bot` ist ein statischer Top-Level-Child, kein
  `DynamicSupervisor`-Kind, also propagiert der Crash nach oben). Ein reiner
  String-Check hätte diesen Bug nie gefangen; nur eine echte API-Validierung
  kann es.
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

  test "kein Token konfiguriert -> leere Liste, kein Netzwerk-Call (kein Crash-Loop-Log-Spam)" do
    assert Worker.Application.discord_bot_child() == []
  end

  test "Token konfiguriert aber ungültig -> [] statt Crash (der reale PR-Test-Fund)" do
    if not discord_api_reachable?() do
      IO.puts(
        :stderr,
        "application_discord_bot_child_test: skipping — discord.com/api nicht erreichbar"
      )
    else
      Settings.put(:discord_bot_token, "definitely-not-a-real-discord-bot-token")
      assert Worker.Application.discord_bot_child() == []
    end
  end

  defp discord_api_reachable? do
    case Req.get("https://discord.com/api/v10/gateway", receive_timeout: 3_000, retry: false) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
