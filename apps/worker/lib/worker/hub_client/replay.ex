defmodule Worker.HubClient.Replay do
  @moduledoc """
  Issue #585: Pipeline-Replay-Topic-Bündel aus `Worker.HubClient`.

  - `start_session_regenerate` — eine Session erneut durch die LLM-Pipeline jagen
    (Stage 2/3/4); Owner-Check macht die Pipeline selbst (Issue #121).
  - `start_campaign_replay` — sequenzieller Replay aller Sessions einer Campaign
    (Worker.Recording.CampaignReplay).
  - `start_thread_recluster` — Voll-Re-Cluster der Handlungsstrang-Registry
    (Issue #842, seltener/expliziter Gegenpart zum automatischen
    inkrementellen Pfad, der bei jeder Session mitläuft).
  """

  require Logger

  def on_session_regenerate(
        %{"discord_id" => did, "campaign_id" => cid, "session_id" => sid},
        socket
      ) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      # Owner-Check macht die Pipeline selbst (maybe_run filtert nach
      # campaign.owner_discord_id == admin_discord_id). Wir leiten den Trigger
      # einfach weiter — der Hub hat schon den Owner-Worker gepickt.
      Logger.info(
        "HubClient: UI-triggered session-regenerate by=#{did} campaign=#{cid} session=#{sid}"
      )

      :ok = Worker.Recording.Pipeline.run_for_session(sid)
    end)

    {:ok, socket}
  end

  def on_campaign_replay(%{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Recording.CampaignReplay.start(cid, did) do
        {:ok, run_id} ->
          Logger.info(
            "HubClient: UI-triggered campaign_replay started campaign=#{cid} run_id=#{run_id}"
          )

        {:error, {:already_running, existing}} ->
          Logger.warning(
            "HubClient: UI start_campaign_replay rejected — already running #{existing}"
          )

        {:error, :no_sessions_with_utterances} ->
          Logger.warning("HubClient: UI start_campaign_replay for empty campaign=#{cid}")

        {:error, reason} ->
          Logger.warning("HubClient: UI start_campaign_replay failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def on_thread_recluster(%{"discord_id" => did, "campaign_id" => cid}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      Logger.info("HubClient: UI-triggered thread-recluster by=#{did} campaign=#{cid}")

      case Worker.Recording.Pipeline.ThreadRegistry.full_recluster_campaign_threads(cid) do
        {:ok, _registry} ->
          Logger.info("HubClient: UI thread-recluster done campaign=#{cid}")

        {:error, reason} ->
          Logger.warning("HubClient: UI thread-recluster failed campaign=#{cid}: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end
end
