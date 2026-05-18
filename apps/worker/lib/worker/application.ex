defmodule Worker.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    bootstrap_storage!()

    children =
      if paired?() do
        Logger.info("Worker: pairing vorhanden. Starte PubSub + Materializer + HubClient + Pipeline.")

        base = [
          {Phoenix.PubSub, name: Worker.PubSub},
          Worker.Materializer,
          Worker.HubClient,
          Worker.Recording.Pipeline
        ]

        base ++ discord_children()
      else
        Logger.info(
          "Worker: kein Pairing vorhanden. Starte Setup-Endpoint auf localhost:#{setup_port()} und öffne Browser."
        )

        open_browser_async("http://127.0.0.1:#{setup_port()}/setup")
        [{Worker.Setup.Endpoint, port: setup_port()}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Worker.Supervisor)
  end

  defp bootstrap_storage! do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()
  end

  defp paired? do
    case Worker.Repo.get_state(:hub_token) do
      nil -> false
      _ -> true
    end
  end

  defp setup_port, do: Application.fetch_env!(:worker, :setup_port)

  defp discord_children do
    if Application.get_env(:worker, :discord_bot_enabled?, false) do
      case Application.ensure_all_started(:nostrum) do
        {:ok, _} ->
          Logger.info("Worker: Discord-Bot aktiv (DISCORD_BOT_TOKEN gesetzt).")
          [Worker.Discord]

        {:error, reason} ->
          Logger.error("Worker: Nostrum start failed: #{inspect(reason)} — bot disabled")
          []
      end
    else
      Logger.info(
        "Worker: kein DISCORD_BOT_TOKEN — lore-spy bleibt aus. Setze die Env-Var und restart."
      )

      []
    end
  end

  defp open_browser_async(url) do
    Task.start(fn ->
      # Give Cowboy a moment to bind the port before we open the browser.
      Process.sleep(500)

      opener =
        cond do
          System.find_executable("xdg-open") -> "xdg-open"
          System.find_executable("open") -> "open"
          true -> nil
        end

      case opener do
        nil ->
          Logger.warning(
            "Konnte keinen Browser-Opener finden (xdg-open/open). Bitte manuell öffnen: #{url}"
          )

        cmd ->
          System.cmd(cmd, [url], stderr_to_stdout: true)
      end
    end)
  end
end
