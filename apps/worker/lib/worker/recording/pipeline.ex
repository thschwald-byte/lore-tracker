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

  # Manual re-run trigger from the UI. We clear any existing entry from
  # `running` first, so a stuck/finished prior run doesn't block the retry.
  def handle_info(
        {:applied,
         %{
           "payload" => %{
             "kind" => "RegenerateRequested",
             "scope" => "session_pipeline",
             "session_id" => session_id
           }
         }},
        state
      ) do
    Logger.info("Pipeline: manual re-run requested for session=#{session_id}")
    state = %{state | running: MapSet.delete(state.running, session_id)}
    maybe_run(session_id, state)
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
      with {:ok, summary_md} <- with_status(campaign.id, "stage2", fn -> stage2(utterances, session.id, campaign) end),
           {:ok, epos_md} <- with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign) end),
           :ok <- with_status(campaign.id, "stage4", fn -> stage4(epos_md, campaign) end) do
        Logger.info("Pipeline: completed for session=#{session.id}")
      else
        {:error, reason} ->
          Logger.error("Pipeline: failed for session=#{session.id}: #{inspect(reason)}")
      end
    end
  end

  defp with_status(campaign_id, stage, fun) do
    notify_status(campaign_id, stage, "started")
    result = fun.()

    status =
      case result do
        {:ok, _} -> "ended"
        :ok -> "ended"
        _ -> "failed"
      end

    notify_status(campaign_id, stage, status)
    result
  end

  defp notify_status(campaign_id, stage, status) do
    Worker.HubClient.publish_status(%{
      "kind" => "pipeline_stage",
      "campaign_id" => campaign_id,
      "stage" => stage,
      "status" => status,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ─── Stages ─────────────────────────────────────────────────────

  defp stage2(utterances, session_id, campaign) do
    speaker_names = resolve_speaker_names(campaign.id)
    prompt = build_summary_prompt(utterances, speaker_names, campaign[:flavor])
    opts = [num_ctx: Worker.Settings.get(:ctx_stage2, 8192), temperature: 0.4]

    case LLM.complete(:summary, prompt, opts) do
      {:ok, summary_md} ->
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.session_summary_generated(),
            "session_id" => session_id,
            "campaign_id" => campaign.id,
            "content_md" => String.trim(summary_md),
            "source" => "llm"
          })

        {:ok, summary_md}

      {:error, reason} ->
        {:error, {:stage2, reason}}
    end
  end

  defp stage3(_summary_md, campaign) do
    existing = Repo.get_epos_entry(campaign.id)
    existing_md = (existing && existing.content_md) || ""

    # Use all summaries of the campaign, not just the just-generated one —
    # so the Epos has the full chronological context.
    all_summaries =
      Repo.list_session_summaries(campaign.id)
      |> Enum.sort_by(& &1.generated_at, {:asc, DateTime})

    prompt = build_epos_prompt(existing_md, all_summaries, campaign[:flavor])
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
    opts = [format: "json", num_ctx: Worker.Settings.get(:ctx_stage4, 8192), temperature: 0.2]
    flavor = campaign[:flavor]

    with {:ok, entries} <- stage4_extract(epos_md, opts, :first_try, flavor),
         {:ok, entries} <- maybe_retry_stage4(entries, epos_md, opts, flavor) do
      stage4_publish(entries, campaign)
    else
      {:error, reason} -> {:error, {:stage4, reason}}
    end
  end

  defp stage4_extract(epos_md, opts, attempt, flavor) do
    prompt = build_chronik_prompt(epos_md, attempt, flavor)

    case LLM.complete(:chronik, prompt, opts) do
      {:ok, json_str} ->
        entries = parse_chronik_json(json_str)

        if entries == [] do
          Logger.warning(
            "Stage 4 (#{attempt}): LLM returned 0 entries. Raw output (truncated): " <>
              String.slice(json_str || "", 0, 400)
          )
        end

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry once with a sharper prompt if the first pass yielded no entries —
  # qwen2.5 sometimes returns {} on its first JSON-mode answer and resolves
  # with one nudge.
  defp maybe_retry_stage4([] = _empty, epos_md, opts, flavor) do
    case stage4_extract(epos_md, opts, :retry, flavor) do
      {:ok, entries} -> {:ok, entries}
      err -> err
    end
  end

  defp maybe_retry_stage4(entries, _epos_md, _opts, _flavor), do: {:ok, entries}

  defp parse_chronik_json(json_str) do
    case Jason.decode(json_str || "") do
      {:ok, %{"entries" => list}} when is_list(list) -> list
      {:ok, %{"chronik" => list}} when is_list(list) -> list
      {:ok, %{"timeline" => list}} when is_list(list) -> list
      {:ok, list} when is_list(list) -> list
      {:ok, %{}} -> []
      _ -> []
    end
  end

  defp stage4_publish(entries, campaign) do
    results =
      Enum.map(entries, fn entry ->
        Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_chronik_id(entry),
          "campaign_id" => campaign.id,
          "in_game_date" => Map.get(entry, "in_game_date") || Map.get(entry, "date"),
          "in_game_sort_key" =>
            Map.get(entry, "sort_key") ||
              sort_key_for(Map.get(entry, "in_game_date") || Map.get(entry, "date") || ""),
          "label" => Map.get(entry, "label") || Map.get(entry, "title") || "",
          "summary" => Map.get(entry, "summary") || Map.get(entry, "description"),
          "session_id" => nil
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _}, &1))

    if failures == [] do
      Logger.info("Stage 4: wrote #{length(entries)} chronik entries")
      :ok
    else
      Logger.warning(
        "Stage 4: #{length(failures)} of #{length(entries)} chronik publishes failed: " <>
          inspect(List.first(failures))
      )

      {:error, {:stage4_publish, List.first(failures)}}
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

  defp build_summary_prompt(utterances, speaker_names, flavor) do
    transcript =
      utterances
      |> Enum.map(fn u -> "#{Map.get(speaker_names, u.discord_id, u.discord_id)}: #{u.text}" end)
      |> Enum.join("\n")

    """
    #{flavor_preamble(flavor)}Du bist Chronist einer Pen&Paper-Rollenspielrunde. Verdichte das
    folgende Transkript zu einem narrativen Resümee auf Deutsch
    (3-6 Sätze, „Was letztes Mal geschah"-Stil, im Präteritum).
    Konzentriere dich auf plot-relevante Handlungen und Charaktere;
    überspringe Out-of-Game-Smalltalk (Pizza, Pausen, Regelfragen).
    Antworte NUR mit dem Resümee, keine Vorrede.

    Transkript:
    #{transcript}
    """
  end

  # Stellt den Stil/Voice der LLM-Antworten als Preamble vorne an. Wenn
  # die Campaign keinen Stil hat, kommt nichts — Default-Prompt steht
  # für sich allein.
  defp flavor_preamble(nil), do: ""
  defp flavor_preamble(""), do: ""

  defp flavor_preamble(flavor) when is_binary(flavor) do
    """
    Stil-Vorgabe für diese Kampagne (oberste Priorität — gilt für Wortwahl,
    Ton und Atmosphäre, NICHT für Inhalt oder Format):
    #{String.trim(flavor)}

    """
  end

  # Build discord_id → preferred-display-name STRING map for the campaign:
  # character_name (Issue #2) wins; else users.display_name; else raw id.
  defp resolve_speaker_names(campaign_id) do
    char_names = Repo.character_names_for(campaign_id)

    # users_for_campaign returns %{did => %{display_name, avatar_url}} after #6;
    # flatten to a string-map before merging with char_names (also strings).
    user_names =
      Repo.users_for_campaign(campaign_id)
      |> Enum.into(%{}, fn
        {did, %{"display_name" => name}} -> {did, name}
        {did, name} when is_binary(name) -> {did, name}
        {did, _} -> {did, did}
      end)

    Map.merge(user_names, char_names)
  end

  defp build_epos_prompt(existing_md, summaries, flavor) when is_list(summaries) do
    summaries_block =
      summaries
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> "### Session #{i}\n#{s.content_md}" end)
      |> Enum.join("\n\n")

    """
    #{flavor_preamble(flavor)}Du bist der Chronist einer Pen&Paper-Rollenspielrunde und pflegst das
    laufende "Epos" — ein Buch in Markdown, das die Kampagnen-Geschichte
    erzählt. Schreibe das Buch komplett neu, basierend auf den
    chronologisch aufgelisteten Session-Resümees unten. Stil: epische
    Fantasy-Prosa, Präteritum, Deutsch. Mit Kapitel-Überschriften
    (Markdown `#`/`##`). Antworte NUR mit dem vollständigen Buch-Markdown
    — keine Vorrede, keine Meta-Kommentare.

    Bisheriges Epos (als Referenz für Stil und vorhandene Namen):
    #{existing_md}

    Session-Resümees (chronologisch):
    #{summaries_block}
    """
  end

  defp build_chronik_prompt(epos_md, attempt, flavor) do
    nudge =
      case attempt do
        :retry ->
          """

          WICHTIG: Im ersten Versuch hast du eine leere Liste geliefert. Das
          Epos unten enthält fast immer mindestens ein Kapitel mit einem
          Ereignis — wenn keine explizite In-Game-Datumsangabe existiert,
          verwende beschreibende Marker wie "Aufbruch der Helden",
          "Erste Begegnung mit dem Drachen", etc. als `in_game_date`.
          Liefere mindestens einen Eintrag pro Kapitel des Epos.
          """

        _ ->
          ""
      end

    """
    #{flavor_preamble(flavor)}Du extrahierst aus dem folgenden RPG-Kampagnen-Epos eine
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
      Wenn das Epos nur narrative Marker hat, verwende diese als Datum
      (z.B. "Aufbruch ins Tal", "Vor der Drachenschlacht").
    - `label` ist eine kurze Überschrift (max 50 Zeichen).
    - `summary` ist ein Satz auf Deutsch.
    - Liefere möglichst einen Eintrag pro Kapitel oder Szene des Epos.
    - Antworte NUR mit dem JSON, keine Vorrede.#{nudge}

    Epos:
    #{epos_md}
    """
  end

  # "550 CY" → 5500, "552 CY - Spring" → 5521, "552 CY - Summer" → 5522, etc.
  # Heuristic fallback when the LLM doesn't emit a sort_key itself.
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
