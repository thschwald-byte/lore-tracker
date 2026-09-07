defmodule Mix.Tasks.Lore.PrTest.StageOhneBotTokenTest do
  @moduledoc """
  Issue #1156: eine Teststage darf das Prod-Discord-Gateway nie versehentlich
  halten. Zwei Mechanismen, beide pur und hier gepinnt:

  - `Runner.worker_env/5` gibt dem Stage-Worker ohne `--discord` ein ungültiges
    Bot-Token fest mit (Sentinel), mit `--discord` nicht.
  - `Mix.Tasks.Lore.PrTest.dotenv_neu/2` lässt `.env` nur Variablen setzen, die
    im OS-Env noch fehlen — die Shell gewinnt, wie in `config/runtime.exs`.

  Beides erzeugt keinen Fehler, wenn es zurückfällt: der Worker verbindet sich
  einfach — und beantwortet fremde `/lore`-Befehle falsch (07.09.2026, zweimal).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Lore.PrTest
  alias Mix.Tasks.Lore.PrTest.Runner

  describe "Runner.worker_env/5 — der Sentinel" do
    test "ohne --discord traegt der Stage-Worker das ungueltige Token" do
      env = Runner.worker_env("/tmp/m", 4003, "lore-issue-1156", 0, false)
      assert {"DISCORD_BOT_TOKEN", Runner.sentinel_token()} in env

      refute Runner.sentinel_token() =~ ~r/^[A-Za-z0-9_-]{24}\./,
             "der Sentinel darf nicht wie ein echtes Token aussehen"
    end

    test "mit --discord bleibt die Variable unangetastet (Worker nimmt das OS-Env)" do
      env = Runner.worker_env("/tmp/m", 4003, "lore-issue-1156", 0, true)
      refute List.keymember?(env, "DISCORD_BOT_TOKEN", 0)
    end

    test "die uebrigen Variablen bleiben, wie sie waren" do
      env = Runner.worker_env("/tmp/m", 4003, "tag", 2, false)
      assert {"LORE_MNESIA_DIR", "/tmp/m"} in env
      assert {"HUB_BASE_URL", "http://localhost:4003"} in env
      assert {"LORE_WORKER_SETUP_PORT", "4092"} in env
      assert {"LORE_PRTEST_TAG", "tag"} in env
    end
  end

  describe "PrTest.dotenv_neu/2 — die Shell gewinnt" do
    @env """
    # Kommentar
    DISCORD_BOT_TOKEN="echt.aus.der.env"
    LORE_LOCAL_ADMIN_DISCORD_ID=123

    ANDERE=x
    """

    test "eine bereits gesetzte Variable wird NICHT ueberschrieben" do
      gesetzt = fn
        "DISCORD_BOT_TOKEN" -> "invalid-prtest-token"
        _ -> nil
      end

      neu = PrTest.dotenv_neu(@env, gesetzt)
      refute List.keymember?(neu, "DISCORD_BOT_TOKEN", 0)
      assert {"LORE_LOCAL_ADMIN_DISCORD_ID", "123"} in neu
      assert {"ANDERE", "x"} in neu
    end

    test "ohne Vorbelegung kommt alles (Anfuehrungszeichen gestrippt, Kommentare weg)" do
      assert PrTest.dotenv_neu(@env, fn _ -> nil end) == [
               {"DISCORD_BOT_TOKEN", "echt.aus.der.env"},
               {"LORE_LOCAL_ADMIN_DISCORD_ID", "123"},
               {"ANDERE", "x"}
             ]
    end
  end

  describe "Quelltext-Waechter" do
    defp quelle(rel), do: File.read!(Path.join([__DIR__, "../../../../..", rel]))

    test "load_dotenv geht ueber dotenv_neu, nicht direkt ueber put_env" do
      [rumpf] =
        Regex.run(
          ~r/defp load_dotenv do\n(.*?)\n  end\n/s,
          quelle("lib/mix/tasks/lore.pr_test.ex"), capture: :all_but_first)

      assert rumpf =~ "dotenv_neu(content, &System.get_env/1)"
    end

    test "start_worker! baut die Umgebung ueber worker_env/5" do
      assert quelle("lib/mix/tasks/lore.pr_test/runner.ex") =~
               ~r/env = worker_env\(worker_mnesia, port, tag, descriptor\.idx, discord\?\)/
    end
  end
end
