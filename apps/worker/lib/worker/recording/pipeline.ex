defmodule Worker.Recording.Pipeline do
  @moduledoc """
  Listens for `SessionEnded` events on the worker-local PubSub and runs
  the per-session post-recording pipeline sequentially:

      Stage 2: snippets → Resümee   (Worker.LLM.complete(:summary, ...))
      Stage 3: snippets + Resümee → Epos  (Worker.LLM.complete(:epos, ...))
      Stage 4: Epos → Chronik bullets (Worker.LLM.complete(:chronik, ...))

  Each stage emits the corresponding event via `Worker.Intents.publish/1`,
  so other workers and the LiveView see the new content via the regular
  event-sourcing flow.

  Stage 1 (audio → text) is owned by `Worker.Recording.AudioCapture` once
  the Discord bot lands (M10); for now utterances arrive via the
  fake-session task and Pipeline starts at Stage 2.

  Only the **owner-worker** for the campaign runs the pipeline (the worker
  whose `admin_discord_id` matches `campaign.owner_discord_id`). This
  prevents N workers all firing duplicate LLM calls when many are online.
  """

  use GenServer

  require Logger

  alias Worker.{Intents, LLM, Repo}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_info({:applied, %{"payload" => %{"kind" => "SessionEnded"} = payload}}, state) do
    session_id = payload["id"]

    if not MapSet.member?(state.running, session_id) do
      maybe_run(session_id, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:applied, _}, state), do: {:noreply, state}

  def handle_info({:stage_done, session_id}, state) do
    {:noreply, %{state | running: MapSet.delete(state.running, session_id)}}
  end

  # ─── Internal ─────────────────────────────────────────────────────

  defp maybe_run(session_id, state) do
    case session_and_campaign(session_id) do
      {:ok, session, campaign} ->
        admin = Repo.get_state(:admin_discord_id)

        if campaign.owner_discord_id == admin do
          Logger.info(
            "Pipeline: starting stages for session=#{session_id} campaign=#{campaign.id}"
          )

          me = self()

          Task.start(fn ->
            run_stages(session, campaign)
            send(me, {:stage_done, session_id})
          end)

          {:noreply, %{state | running: MapSet.put(state.running, session_id)}}
        else
          Logger.debug(fn ->
            "Pipeline: session=#{session_id} belongs to owner=#{campaign.owner_discord_id}, " <>
              "we're admin=#{admin}; skipping."
          end)

          {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("Pipeline: cannot resolve session=#{session_id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp session_and_campaign(session_id) do
    sessions =
      :worker_sessions
      |> :mnesia.dirty_read(session_id)

    case sessions do
      [{_, _, campaign_id, _num, _name, _status, _sched, _start, _end}] ->
        case Repo.get_campaign(campaign_id) do
          nil -> {:error, :no_campaign}
          campaign -> {:ok, %{id: session_id, campaign_id: campaign_id}, campaign}
        end

      [] ->
        {:error, :no_session}
    end
  end

  defp run_stages(session, campaign) do
    utterances = Repo.list_utterances(session.id)

    if utterances == [] do
      Logger.info("Pipeline: session=#{session.id} has no utterances; skipping LLM stages")
    else
      with {:ok, summary_md} <- stage2(utterances, session.id, campaign.id),
           {:ok, epos_md} <- stage3(summary_md, campaign),
           :ok <- stage4(epos_md, campaign) do
        Logger.info("Pipeline: completed for session=#{session.id}")
      else
        {:error, reason} ->
          Logger.error("Pipeline: failed for session=#{session.id}: #{inspect(reason)}")
      end
    end
  end

  # ─── Stages ─────────────────────────────────────────────────────

  defp stage2(utterances, session_id, campaign_id) do
    prompt = build_summary_prompt(utterances)

    case LLM.complete(:summary, prompt) do
      {:ok, summary_md} ->
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.session_summary_generated(),
            "session_id" => session_id,
            "campaign_id" => campaign_id,
            "content_md" => summary_md,
            "source" => "llm"
          })

        {:ok, summary_md}

      {:error, reason} ->
        {:error, {:stage2, reason}}
    end
  end

  defp stage3(summary_md, campaign) do
    existing = Repo.get_epos_entry(campaign.id)
    existing_md = (existing && existing.content_md) || ""

    prompt = build_epos_prompt(existing_md, summary_md)

    case LLM.complete(:epos, prompt) do
      {:ok, new_md} ->
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => campaign.id,
            "campaign_id" => campaign.id,
            "new_md" => new_md,
            "edited_by" => "llm",
            "source" => "llm"
          })

        {:ok, new_md}

      {:error, reason} ->
        {:error, {:stage3, reason}}
    end
  end

  defp stage4(epos_md, campaign) do
    prompt = build_chronik_prompt(epos_md)

    case LLM.complete(:chronik, prompt) do
      {:ok, bullets} ->
        bullets
        |> parse_chronik_bullets()
        |> Enum.each(fn entry ->
          {:ok, _seq} =
            Intents.publish(%{
              "kind" => Shared.Events.chronik_entry_changed(),
              "id" => entry.id,
              "campaign_id" => campaign.id,
              "in_game_date" => entry.in_game_date,
              "in_game_sort_key" => entry.sort_key,
              "label" => entry.label,
              "summary" => entry.summary,
              "session_id" => nil
            })
        end)

        :ok

      {:error, reason} ->
        {:error, {:stage4, reason}}
    end
  end

  # ─── Prompt builders ─────────────────────────────────────────────

  defp build_summary_prompt(utterances) do
    utterances
    |> Enum.map(fn u -> "#{u.discord_id}: #{u.text}" end)
    |> Enum.join("\n")
  end

  defp build_epos_prompt(existing_md, summary_md) do
    """
    Vorheriger Epos-Stand:
    #{existing_md}

    Neues Resümee dieser Session:
    #{summary_md}
    """
  end

  defp build_chronik_prompt(epos_md), do: epos_md

  # Bullet-format from Mock backend:
  #   - <date> · <label> · <summary>
  defp parse_chronik_bullets(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^[-*]\s*(.+?)\s*·\s*(.+?)\s*·\s*(.+)$/u, String.trim(line)) do
        [_, date, label, summary] ->
          [
            %{
              id: hash_id([date, label]),
              in_game_date: date,
              sort_key: sort_key_for(date),
              label: label,
              summary: summary
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp hash_id(parts) do
    "chronik-" <>
      (:crypto.hash(:sha, Enum.join(parts, "|")) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  # "550 CY" → 5500, "552 CY - Spring" → 5521, "552 CY - Summer" → 5522, etc.
  # Crude but deterministic for the mock data. Real Chronik LLM should emit a sort_key directly.
  defp sort_key_for(date) do
    season_bump =
      cond do
        date =~ ~r/Spring/i -> 1
        date =~ ~r/Summer/i -> 2
        date =~ ~r/Autumn|Fall/i -> 3
        date =~ ~r/Winter/i -> 4
        true -> 0
      end

    year =
      case Regex.run(~r/(\d+)\s*CY/, date) do
        [_, y] -> String.to_integer(y)
        _ -> 0
      end

    year * 10 + season_bump
  end
end
