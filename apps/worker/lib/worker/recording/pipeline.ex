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
    opts = [num_ctx: Worker.Settings.get(:ctx_stage2, 8192), temperature: 0.4]

    case LLM.complete(:summary, prompt, opts) do
      {:ok, summary_md} ->
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.session_summary_generated(),
            "session_id" => session_id,
            "campaign_id" => campaign_id,
            "content_md" => String.trim(summary_md),
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
    opts = [num_ctx: Worker.Settings.get(:ctx_stage3, 16384), temperature: 0.5]

    case LLM.complete(:epos, prompt, opts) do
      {:ok, new_md} ->
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => campaign.id,
            "campaign_id" => campaign.id,
            "new_md" => String.trim(new_md),
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
    opts = [format: "json", num_ctx: Worker.Settings.get(:ctx_stage4, 8192), temperature: 0.2]

    case LLM.complete(:chronik, prompt, opts) do
      {:ok, json_str} ->
        entries =
          case Jason.decode(json_str) do
            {:ok, %{"entries" => list}} when is_list(list) -> list
            {:ok, list} when is_list(list) -> list
            # Empty object / missing entries → LLM said "nothing to extract" (legit).
            {:ok, %{}} -> []
            other ->
              Logger.warning("Stage 4: unexpected JSON shape #{inspect(other)}")
              []
          end

        Enum.each(entries, fn entry ->
          {:ok, _seq} =
            Intents.publish(%{
              "kind" => Shared.Events.chronik_entry_changed(),
              "id" => derive_chronik_id(entry),
              "campaign_id" => campaign.id,
              "in_game_date" => Map.get(entry, "in_game_date") || Map.get(entry, "date"),
              "in_game_sort_key" => Map.get(entry, "sort_key") ||
                sort_key_for(Map.get(entry, "in_game_date") || Map.get(entry, "date") || ""),
              "label" => Map.get(entry, "label") || Map.get(entry, "title") || "",
              "summary" => Map.get(entry, "summary") || Map.get(entry, "description"),
              "session_id" => nil
            })
        end)

        Logger.info("Stage 4: wrote #{length(entries)} chronik entries")
        :ok

      {:error, reason} ->
        {:error, {:stage4, reason}}
    end
  end

  defp derive_chronik_id(entry) do
    seed =
      [
        Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
        Map.get(entry, "label") || Map.get(entry, "title") || ""
      ]
      |> Enum.join("|")

    "chronik-" <>
      (:crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  # ─── Prompt builders ─────────────────────────────────────────────

  defp build_summary_prompt(utterances) do
    transcript =
      utterances
      |> Enum.map(fn u -> "#{u.discord_id}: #{u.text}" end)
      |> Enum.join("\n")

    """
    Du bist Chronist einer Pen&Paper-Rollenspielrunde. Verdichte das
    folgende Transkript zu einem narrativen Resümee auf Deutsch
    (3-6 Sätze, „Was letztes Mal geschah"-Stil, im Präteritum).
    Konzentriere dich auf plot-relevante Handlungen und Charaktere;
    überspringe Out-of-Game-Smalltalk (Pizza, Pausen, Regelfragen).
    Antworte NUR mit dem Resümee, keine Vorrede.

    Transkript:
    #{transcript}
    """
  end

  defp build_epos_prompt(existing_md, summary_md) do
    """
    Du bist der Chronist einer Pen&Paper-Rollenspielrunde und pflegst das
    laufende "Epos" — ein Buch in Markdown, das die Kampagnen-Geschichte
    erzählt. Erweitere oder bearbeite das Buch um den Inhalt des neuen
    Session-Resümees. Schreibe im Stil von epischer Fantasy-Prosa
    (Präteritum, Deutsch). Behalte vorhandene Kapitel-Überschriften
    und Struktur bei; ergänze ein neues Kapitel oder einen neuen
    Abschnitt für die neue Session, statt alles zu überschreiben.
    Antworte NUR mit dem vollständigen neuen Buch-Markdown — keine
    Vorrede, keine Meta-Kommentare.

    Bisheriges Epos:
    #{existing_md}

    Neues Resümee:
    #{summary_md}
    """
  end

  defp build_chronik_prompt(epos_md) do
    """
    Du extrahierst aus dem folgenden RPG-Kampagnen-Epos eine
    In-Game-Zeitstrahl-Liste. Liefere JSON in genau diesem Format:

    {
      "entries": [
        {
          "in_game_date": "550 CY",
          "label": "Departure from Oakhaven",
          "summary": "Die Helden brechen auf zum Sunken Crypt."
        }
      ]
    }

    Regeln:
    - `in_game_date` ist die In-Game-Zeitangabe wie sie im Epos steht
      (z.B. "550 CY", "552 CY - Spring", "Tag 14 nach der Schlacht").
    - `label` ist eine kurze Überschrift (max 50 Zeichen).
    - `summary` ist ein Satz auf Deutsch.
    - Wenn im Text keine In-Game-Zeit erkennbar ist, gib eine leere
      `entries`-Liste zurück.
    - Antworte NUR mit dem JSON, keine Vorrede.

    Epos:
    #{epos_md}
    """
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
