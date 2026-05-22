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

  @doc """
  Manueller Pipeline-Trigger für eine Session — direkt aufgerufen aus
  `CampaignReplay`, `Probelauf` und dem UI-Pfad (`Worker.HubClient`
  beim `start_session_regenerate`-Push). Kein Event-Roundtrip durch
  den Hub.

  Räumt eine etwaige stuck/finished prior-run Markierung aus dem
  `running`-Set, damit ein hängengebliebener Vorlauf den Retry nicht
  blockiert.
  """
  @spec run_for_session(String.t()) :: :ok
  def run_for_session(session_id) when is_binary(session_id) do
    # Synchroner Call: returnt erst nachdem der `running`-Marker gesetzt ist,
    # damit CampaignReplay.wait_pipeline_idle/1 nicht race-conditional gegen
    # einen noch nicht verarbeiteten Cast pollt.
    GenServer.call(__MODULE__, {:run_for_session, session_id}, :infinity)
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_call({:run_for_session, session_id}, _from, state) do
    Logger.info("Pipeline: manual re-run requested for session=#{session_id}")
    state = %{state | running: MapSet.delete(state.running, session_id)}

    case maybe_run(session_id, state) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
    end
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
      with {:ok, summary_md} <-
             with_status(campaign.id, "stage2", fn -> stage2(utterances, session.id, campaign) end),
           :ok <- stage_faithfulness(summary_md, utterances, session.id, campaign.id),
           {:ok, epos_md} <-
             with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign) end),
           :ok <- with_status(campaign.id, "stage4", fn -> stage4(epos_md, campaign) end) do
        Logger.info("Pipeline: completed for session=#{session.id}")
      else
        {:error, reason} ->
          Logger.error("Pipeline: failed for session=#{session.id}: #{inspect(reason)}")
      end
    end
  end

  defp with_status(campaign_id, stage, fun) do
    notify_status(campaign_id, stage, "started", nil)
    result = fun.()

    {status, error_msg} =
      case result do
        {:ok, _} -> {"ended", nil}
        :ok -> {"ended", nil}
        {:error, reason} -> {"failed", format_error(reason)}
        _ -> {"failed", nil}
      end

    notify_status(campaign_id, stage, status, error_msg)
    result
  end

  defp notify_status(campaign_id, stage, status, error_msg) do
    payload =
      %{
        "kind" => "pipeline_stage",
        "campaign_id" => campaign_id,
        "stage" => stage,
        "status" => status,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> then(fn p -> if error_msg, do: Map.put(p, "error", error_msg), else: p end)

    Worker.HubClient.publish_status(payload)

    # Worker-lokaler Mit-Listener (Issue #74): Probelauf-Engine läuft im
    # selben BEAM und braucht Per-Stage-Timings ohne den Umweg über Hub.
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
  end

  # Issue #27: aus dem internen Pipeline-Reason eine UI-lesbare Message machen.
  # Reasons kommen in mehreren Formen rein:
  #   {:stage2, {:upstream, code, status, msg}}  ← Anthropic-Backend
  #   {:stage4, :empty_chronik}                  ← Stage-4-empty-Output
  #   {:stage3, :timeout}                        ← HTTP-Timeout
  #   {:stage_n, atom_or_term}                   ← sonstiges
  defp format_error({_stage, {:upstream, code, status, msg}}) when is_binary(msg),
    do: "Cloud-Backend (#{code} #{status}): #{msg}"

  defp format_error({_stage, {:upstream, code, status, _}}),
    do: "Cloud-Backend (#{code} #{status})"

  defp format_error({_stage, :empty_chronik}), do: "LLM lieferte keine Chronik-Einträge"
  defp format_error({_stage, :timeout}), do: "Timeout — LLM antwortet nicht"
  defp format_error({_stage, :no_key_configured}), do: "Kein Cloud-API-Key konfiguriert"
  defp format_error({_stage, :no_worker_token}), do: "Worker nicht gepairt"
  defp format_error({_stage, reason}), do: "Fehler: #{inspect(reason)}"
  defp format_error(reason), do: inspect(reason)

  # ─── Stages ─────────────────────────────────────────────────────

  defp stage2(utterances, session_id, campaign) do
    speaker_names = resolve_speaker_names(campaign.id)
    prompt = build_summary_prompt(utterances, speaker_names, campaign[:flavors] || %{})
    opts = [num_ctx: Worker.Settings.get(:ctx_stage2, 8192)] ++ sampling_opts(2)

    case LLM.complete(:summary, prompt, opts) do
      {:ok, summary_md} ->
        publish_event(%{
          "kind" => Shared.Events.session_summary_generated(),
          "session_id" => session_id,
          "campaign_id" => campaign.id,
          "content_md" => String.trim(summary_md),
          "source" => "llm"
        })
        |> case do
          :ok -> {:ok, summary_md}
          {:error, reason} -> {:error, {:stage2, {:publish_failed, reason}}}
        end

      {:error, reason} ->
        {:error, {:stage2, reason}}
    end
  end

  # Issue #11 Phase 2: Faithfulness-Score gegen Quell-Transkript.
  # Sidecar-Aufruf ist optional — bei Fehler/Offline läuft die Pipeline
  # ohne Score weiter (Status-Notifikation als "ended" mit warning).
  defp stage_faithfulness(summary_md, utterances, session_id, campaign_id) do
    notify_status(campaign_id, "faithfulness", "started", nil)

    case Worker.LLM.Faithfulness.score(summary_md, utterances) do
      {:ok, %{score: score, claims: claims}} ->
        # Faithfulness ist optional — Publish-Failure soll die Pipeline nicht
        # blocken, nur als warning loggen.
        _ =
          publish_event(%{
            "kind" => Shared.Events.session_faithfulness_scored(),
            "session_id" => session_id,
            "campaign_id" => campaign_id,
            "score" => score,
            "claims" => Enum.map(claims, &Map.new(&1, fn {k, v} -> {to_string(k), v} end)),
            "scored_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        notify_status(campaign_id, "faithfulness", "ended", nil)
        :ok

      {:error, :sidecar_offline} ->
        Logger.info("Pipeline: faithfulness sidecar offline — skipping for session=#{session_id}")
        notify_status(campaign_id, "faithfulness", "ended", "sidecar offline")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline: faithfulness scoring failed for session=#{session_id}: #{inspect(reason)}"
        )

        notify_status(campaign_id, "faithfulness", "ended", "scoring failed")
        :ok
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

    prompt = build_epos_prompt(existing_md, all_summaries, campaign[:flavors] || %{})
    opts = [num_ctx: Worker.Settings.get(:ctx_stage3, 16384)] ++ sampling_opts(3)

    case LLM.complete(:epos, prompt, opts) do
      {:ok, new_md} ->
        publish_event(%{
          "kind" => Shared.Events.epos_entry_edited(),
          "entry_id" => campaign.id,
          "campaign_id" => campaign.id,
          "new_md" => String.trim(new_md),
          "edited_by" => "llm",
          "source" => "llm"
        })
        |> case do
          :ok -> {:ok, new_md}
          {:error, reason} -> {:error, {:stage3, {:publish_failed, reason}}}
        end

      {:error, reason} ->
        {:error, {:stage3, reason}}
    end
  end

  defp stage4(epos_md, campaign) do
    opts =
      [format: "json", num_ctx: Worker.Settings.get(:ctx_stage4, 8192)] ++ sampling_opts(4)

    flavors = campaign[:flavors] || %{}

    with {:ok, entries} <- stage4_extract(epos_md, opts, :first_try, flavors),
         {:ok, entries} <- maybe_retry_stage4(entries, epos_md, opts, flavors) do
      stage4_publish(entries, campaign)
    else
      {:error, reason} -> {:error, {:stage4, reason}}
    end
  end

  defp stage4_extract(epos_md, opts, attempt, flavors) do
    prompt = build_chronik_prompt(epos_md, attempt, flavors)

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
  defp maybe_retry_stage4([] = _empty, epos_md, opts, flavors) do
    case stage4_extract(epos_md, opts, :retry, flavors) do
      {:ok, entries} -> {:ok, entries}
      err -> err
    end
  end

  defp maybe_retry_stage4(entries, _epos_md, _opts, _flavors), do: {:ok, entries}

  # Tries hard to extract a JSON array of chronik entries from arbitrary LLM
  # output. Issue #75: qwen3 (Thinking-Mode) prefixes every answer with a
  # `<think>...</think>` block, which busts Ollama's strict `format: "json"`
  # mode AND defeats `Jason.decode/1` if the model falls back to free-form
  # text. We strip the thinking-block, peel off Markdown code-fences, and
  # finally regex out the first JSON object/array if it's still embedded in
  # prose. Empty input or undecodable output return [], which the caller
  # treats as a stage failure (`stage4_publish/2`).
  @doc false
  def parse_chronik_json(raw) when is_binary(raw) do
    raw
    |> strip_think_blocks()
    |> strip_code_fence()
    |> extract_json_blob()
    |> Jason.decode()
    |> case do
      {:ok, %{"entries" => list}} when is_list(list) -> list
      {:ok, %{"chronik" => list}} when is_list(list) -> list
      {:ok, %{"timeline" => list}} when is_list(list) -> list
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def parse_chronik_json(_), do: []

  defp strip_think_blocks(s) do
    Regex.replace(~r/<think>.*?<\/think>/s, s, "")
  end

  defp strip_code_fence(s) do
    case Regex.run(~r/```(?:json)?\s*\n?(.+?)\n?```/s, s) do
      [_, inner] -> inner
      _ -> s
    end
  end

  defp extract_json_blob(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        trimmed

      true ->
        case Regex.run(~r/(\{.*\}|\[.*\])/s, trimmed) do
          [_, json] -> json
          _ -> trimmed
        end
    end
  end

  # Issue #75: an empty entries list after retry is a stage failure, not a
  # silent OK. Without this branch the LLM can return "" forever and the
  # pipeline still reports `ended` — masking real model-incompatibility.
  defp stage4_publish([], _campaign) do
    Logger.warning("Stage 4: LLM returned no usable chronik entries even after retry")
    {:error, :empty_chronik}
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

  # Hard-Match auf `{:ok, _seq}` wird vermieden: bei Hub-Outage liefert
  # `Intents.publish` `{:error, :not_connected}` (oder Timeout), was ohne diesen
  # Wrapper einen MatchError in der Stage werfen würde. Stattdessen wird der
  # Fehler geloggt und an den Caller propagiert, der entscheidet ob die Stage
  # damit als fehlgeschlagen gilt (z.B. Stage 2/3) oder ob die Pipeline trotzdem
  # weiterläuft (z.B. Faithfulness, weil optional).
  defp publish_event(payload) do
    case Intents.publish(payload) do
      {:ok, _seq} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pipeline: publish failed (kind=#{payload["kind"]}): #{inspect(reason)}"
        )

        {:error, reason}
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

  defp build_summary_prompt(utterances, speaker_names, flavors) do
    transcript =
      utterances
      |> Enum.map(fn u -> "#{Map.get(speaker_names, u.discord_id, u.discord_id)}: #{u.text}" end)
      |> Enum.join("\n")

    """
    #{flavor_preamble(flavors, "summary")}Verdichte das folgende Transkript zu einem Resümee auf Deutsch
    (3-6 Sätze). Überspringe Out-of-Game-Smalltalk (Pizza, Pausen,
    Regelfragen). Antworte NUR mit dem Resümee, keine Vorrede.

    Transkript:
    #{transcript}

    #{fact_fidelity_block("Transkript")}
    """
  end

  defp fact_fidelity_block(source_label) do
    """
    FAKTENTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Verwende NUR Namen, Orte und Ereignisse die explizit im #{source_label} oben stehen.
    - Wenn ein Detail nicht im #{source_label} steht, lass es weg — fülle keine Lücken aus.
    - Wenn das Material nicht für die angefragte Länge reicht, schreibe weniger.
    - Keine inneren Monologe, keine erfundenen Nebenfiguren, keine ausgeschmückten Szenen.
    """
  end

  # Stellt den Stil/Voice der LLM-Antworten als Preamble vorne an. Base
  # (Welt/Setting) und slot-spezifische Voice werden kombiniert. Wenn die
  # Campaign weder Base noch Slot gesetzt hat, kommt nichts — der Prompt
  # bleibt setting-neutral und sachlich.
  defp flavor_preamble(flavors, slot) when is_map(flavors) do
    parts =
      ["base", slot]
      |> Enum.uniq()
      |> Enum.map(&Map.get(flavors, &1))
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.trim/1)

    case parts do
      [] ->
        ""

      list ->
        "Stil-Vorgabe für diese Kampagne (oberste Priorität — Wortwahl, Ton, Atmosphäre, NICHT Inhalt oder Format):\n\n" <>
          Enum.join(list, "\n\n") <> "\n\n"
    end
  end

  defp flavor_preamble(_flavors, _slot), do: ""

  # Sampling-Knöpfe pro Stage (Issue #11). Liefert eine Keyword-Liste mit
  # temperature/top_p/num_predict/repeat_penalty; nil-Werte werden vom
  # Backend ignoriert (Worker.LLM.Local.build_options/1).
  defp sampling_opts(stage) when stage in [2, 3, 4] do
    [
      temperature: Worker.Settings.get(:"temperature_stage#{stage}"),
      top_p: Worker.Settings.get(:"top_p_stage#{stage}"),
      num_predict: Worker.Settings.get(:"num_predict_stage#{stage}"),
      repeat_penalty: Worker.Settings.get(:"repeat_penalty_stage#{stage}")
    ]
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

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

  defp build_epos_prompt(existing_md, summaries, flavors) when is_list(summaries) do
    summaries_block =
      summaries
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> "### Session #{i}\n#{s.content_md}" end)
      |> Enum.join("\n\n")

    """
    #{flavor_preamble(flavors, "epos")}Schreibe ein zusammenhängendes Markdown-Dokument auf Deutsch basierend
    auf den chronologisch aufgelisteten Session-Resümees unten. Verwende
    Kapitel-Überschriften (Markdown `#`/`##`). Antworte NUR mit dem
    vollständigen Markdown — keine Vorrede, keine Meta-Kommentare.

    Bisheriger Text (als Referenz für vorhandene Namen und Kontinuität):
    #{existing_md}

    Session-Resümees (chronologisch):
    #{summaries_block}

    #{fact_fidelity_block("Session-Resümees")}
    """
  end

  defp build_chronik_prompt(epos_md, attempt, flavors) do
    nudge =
      case attempt do
        :retry ->
          """

          WICHTIG: Im ersten Versuch hast du eine leere Liste geliefert. Der
          Text unten enthält fast immer mindestens ein Kapitel mit einem
          Ereignis — wenn keine explizite In-Game-Datumsangabe existiert,
          verwende beschreibende Marker (z.B. "Aufbruch", "Erste Begegnung")
          als `in_game_date`. Liefere mindestens einen Eintrag pro Kapitel.
          """

        _ ->
          ""
      end

    """
    #{flavor_preamble(flavors, "chronik")}Du extrahierst aus dem folgenden Text eine In-Game-Zeitstrahl-Liste.
    Liefere JSON in genau diesem Format:

    {
      "entries": [
        {
          "in_game_date": "Tag 14",
          "label": "Ereignis A",
          "summary": "Die Gruppe ereignete X."
        }
      ]
    }

    Regeln:
    - `in_game_date` ist die In-Game-Zeitangabe wie sie im Text steht.
      Wenn der Text nur narrative Marker hat, verwende diese als Datum.
    - `label` ist eine kurze Überschrift (max 50 Zeichen).
    - `summary` ist ein Satz auf Deutsch.
    - Liefere möglichst einen Eintrag pro Kapitel oder Szene.
    - Antworte NUR mit dem JSON, keine Vorrede.#{nudge}

    Text:
    #{epos_md}

    #{fact_fidelity_block("Text")}
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
