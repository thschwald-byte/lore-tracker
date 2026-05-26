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

  Nur Worker, deren `admin_discord_id` als Member der Kampagne registriert
  ist, fahren die Pipeline (Issue #236). Vorher war der Check auf
  `campaign.owner_discord_id` — seit Issue #140 ist `owner_discord_id`
  aber nur noch abgeleiteter Wert aus dem ersten `:spielleiter`-Member,
  also fragil bei Multi-GM-Setups. Member-Check ist die robuste Variante.

  Bei mehreren connected Member-Workern entscheidet die Leader-Election
  in `Hub.Commands.pick_leader/2` welcher Worker den Trigger bekommt —
  hier feuert die Pipeline einfach, wenn die `SessionEnded`-Event ankommt
  und der Worker Member ist.
  """

  use GenServer

  require Logger

  alias Worker.{Intents, LLM, Repo}

  # Issue #230: LLM-Sentinel-Strings die selbst-eingestandene Fabrication
  # markieren. Wenn einer davon in `in_game_date`, `label` oder `summary`
  # eines Chronik-Eintrags auftaucht, droppt `filter_fabricated_chronik/1`
  # den Eintrag mit Logger.warning. Konservativ gehalten — nur explizite
  # Placeholder, keine subjektiven Unsicherheits-Wörter (legitime Plot-
  # Texte dürfen "vermutet" oder "unklar" enthalten).
  @fabrication_sentinels [
    ~r/nicht im transkript/iu,
    ~r/nicht erwähnt/iu,
    ~r/keine angabe/iu,
    ~r/^unbekannt$/iu,
    ~r/^n\/a$/i,
    ~r/^---+$/
  ]

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
    run_for_session(session_id, [])
  end

  @doc """
  Issue #201: optionaler `only_stages: [2 | 3 | 4]`-Schlüssel führt nur die
  angegebenen Stages aus. Pre-Stage-Inputs werden aus dem Repo geladen
  (Stage 3 liest Goldstandard-Summary, Stage 4 liest Goldstandard-Epos).

  Wird vom Probelauf-Sweep genutzt um Modell-Vergleiche pro Stage fair
  zu messen — ohne Beifang-Stages und ohne Pre-Stage-Output-Drift.

  Ohne `only_stages`: alle Stages 2/3/4 wie gehabt.
  """
  @spec run_for_session(String.t(), keyword()) :: :ok
  def run_for_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    # Synchroner Call: returnt erst nachdem der `running`-Marker gesetzt ist,
    # damit CampaignReplay.wait_pipeline_idle/1 nicht race-conditional gegen
    # einen noch nicht verarbeiteten Cast pollt.
    GenServer.call(__MODULE__, {:run_for_session, session_id, opts}, :infinity)
  end

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Worker.PubSub, Worker.Materializer.topic())
    {:ok, %{running: MapSet.new()}}
  end

  @impl true
  def handle_call({:run_for_session, session_id, opts}, _from, state) do
    Logger.info(
      "Pipeline: manual re-run requested for session=#{session_id} opts=#{inspect(opts)}"
    )

    state = %{state | running: MapSet.delete(state.running, session_id)}

    # Issue #226: manueller Re-Run = explizite Variation gewünscht. Stage 3
    # bekommt einen Re-Run-Hint + temperature-Override, damit das LLM nicht
    # den bisherigen Epos-Text bit-identisch wiederholt.
    #
    # Issue #201: `only_stages` aus opts merged mit force? — Probelauf-Sweep
    # ruft mit `only_stages: [N]` an und braucht KEIN force-regen-Hint
    # (Goldstandard-Setup soll wiederholbar sein).
    merged_opts = Keyword.put_new(opts, :force?, not Keyword.has_key?(opts, :only_stages))

    case maybe_run(session_id, state, merged_opts) do
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

  defp maybe_run(session_id, state, opts \\ []) do
    case session_and_campaign(session_id) do
      {:ok, session, campaign} ->
        admin = Repo.get_state(:admin_discord_id)

        if Repo.member?(campaign.id, admin) do
          Logger.info(
            "Pipeline: starting stages for session=#{session_id} campaign=#{campaign.id}"
          )

          me = self()

          Task.start(fn ->
            run_stages(session, campaign, opts)
            send(me, {:stage_done, session_id})
          end)

          {:noreply, %{state | running: MapSet.put(state.running, session_id)}}
        else
          Logger.warning(
            "Pipeline: session=#{session_id} campaign=#{campaign.id} — " <>
              "admin=#{admin} is not a member; skipping. " <>
              "Add the admin as member to enable Stages 2-4."
          )

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

  defp run_stages(session, campaign, opts \\ []) do
    utterances = Repo.list_utterances(session.id)

    if utterances == [] do
      Logger.info("Pipeline: session=#{session.id} has no utterances; skipping LLM stages")
    else
      only_stages = Keyword.get(opts, :only_stages)

      result =
        with {:ok, summary_md} <- run_or_load_stage2(only_stages, utterances, session, campaign),
             :ok <- maybe_faithfulness(only_stages, summary_md, utterances, session, campaign),
             {:ok, epos_md} <- run_or_load_stage3(only_stages, summary_md, session, campaign, opts),
             :ok <- maybe_stage4(only_stages, epos_md, session, campaign) do
          :ok
        end

      case result do
        :ok ->
          Logger.info("Pipeline: completed for session=#{session.id} only_stages=#{inspect(only_stages)}")

        {:error, reason} ->
          Logger.error("Pipeline: failed for session=#{session.id}: #{inspect(reason)}")
      end
    end
  end

  # Issue #201: Stage-Skip-Helpers. Wenn `only_stages` gesetzt und die Stage
  # NICHT enthalten ist, wird das prior-Stage-Output aus dem Repo geladen
  # (Goldstandard-Pre-Seed im Probelauf-Sweep). Sonst läuft die Stage normal.

  defp run_or_load_stage2(nil, utterances, session, campaign) do
    with_status(campaign.id, "stage2", fn -> stage2(utterances, session.id, campaign) end)
  end

  defp run_or_load_stage2(only_stages, utterances, session, campaign) do
    if 2 in only_stages do
      with_status(campaign.id, "stage2", fn -> stage2(utterances, session.id, campaign) end)
    else
      load_summary_from_repo(session.id)
    end
  end

  defp run_or_load_stage3(nil, summary_md, _session, campaign, opts) do
    with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign, opts) end)
  end

  defp run_or_load_stage3(only_stages, summary_md, _session, campaign, opts) do
    if 3 in only_stages do
      with_status(campaign.id, "stage3", fn -> stage3(summary_md, campaign, opts) end)
    else
      load_epos_from_repo(campaign.id)
    end
  end

  defp maybe_stage4(nil, epos_md, session, campaign) do
    with_status(campaign.id, "stage4", fn -> stage4(epos_md, session.id, campaign) end)
  end

  defp maybe_stage4(only_stages, epos_md, session, campaign) do
    if 4 in only_stages do
      with_status(campaign.id, "stage4", fn -> stage4(epos_md, session.id, campaign) end)
    else
      :ok
    end
  end

  defp maybe_faithfulness(nil, summary_md, utterances, session, campaign) do
    stage_faithfulness(summary_md, utterances, session.id, campaign.id)
  end

  # Bei isoliertem Sweep läuft Faithfulness separat im Sweep-Code (gegen
  # Goldstandard), nicht hier in der Pipeline.
  defp maybe_faithfulness(_only_stages, _summary_md, _utterances, _session, _campaign), do: :ok

  defp load_summary_from_repo(session_id) do
    case Repo.get_session_summary(session_id) do
      %{content_md: md} when is_binary(md) and md != "" ->
        {:ok, md}

      _ ->
        {:error,
         {:stage2,
          {:no_goldstandard,
           "session=#{session_id} hat kein Stage-2-Output im Repo (Pre-Seed fehlt)"}}}
    end
  end

  defp load_epos_from_repo(campaign_id) do
    case Repo.get_epos_entry(campaign_id) do
      %{content_md: md} when is_binary(md) and md != "" ->
        {:ok, md}

      _ ->
        {:error,
         {:stage3,
          {:no_goldstandard,
           "campaign=#{campaign_id} hat kein Stage-3-Output im Repo (Pre-Seed fehlt)"}}}
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

  defp stage3(_summary_md, campaign, opts \\ []) do
    force? = Keyword.get(opts, :force?, false)
    existing = Repo.get_epos_entry(campaign.id)
    existing_md = (existing && existing.content_md) || ""

    # Use all summaries of the campaign, not just the just-generated one —
    # so the Epos has the full chronological context.
    all_summaries =
      Repo.list_session_summaries(campaign.id)
      |> Enum.sort_by(& &1.generated_at, {:asc, DateTime})

    prompt = build_epos_prompt(existing_md, all_summaries, campaign[:flavors] || %{}, force?)

    # Issue #226: Diagnostik IMMER aktiv (auch ohne force?). Macht künftig
    # diagnostizierbar ob "same prompt → same output" (LLM-Determinismus bei
    # niedrig-temp) oder "different prompt → same output" (echtes Caching
    # irgendwo, was wir heute nicht haben aber sicherheitshalber checken).
    Logger.info(
      "Pipeline: Stage 3 prompt sha=#{short_sha(prompt)} #{byte_size(prompt)} bytes #{length(all_summaries)} summaries force=#{force?}"
    )

    base_llm_opts = [num_ctx: Worker.Settings.get(:ctx_stage3, 16384)] ++ sampling_opts(3)

    # Issue #226: bei manuellem Re-Run temperature hochsetzen — sonst
    # bleibt das LLM bei temp=0.2 + nahezu identischem Prompt deterministisch
    # auf dem bisherigen Output kleben.
    llm_opts =
      if force?, do: Keyword.put(base_llm_opts, :temperature, 0.5), else: base_llm_opts

    case LLM.complete(:epos, prompt, llm_opts) do
      {:ok, new_md} ->
        Logger.info(
          "Pipeline: Stage 3 output sha=#{short_sha(new_md)} #{byte_size(new_md)} bytes"
        )

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

  defp short_sha(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp stage4(epos_md, session_id, campaign) do
    opts =
      [format: "json", num_ctx: Worker.Settings.get(:ctx_stage4, 8192)] ++ sampling_opts(4)

    flavors = campaign[:flavors] || %{}

    with {:ok, entries} <- stage4_extract(epos_md, opts, :first_try, flavors),
         {:ok, entries} <- maybe_retry_stage4(entries, epos_md, opts, flavors) do
      stage4_publish(entries, session_id, campaign)
    else
      {:error, reason} -> {:error, {:stage4, reason}}
    end
  end

  defp stage4_extract(epos_md, opts, attempt, flavors) do
    prompt = build_chronik_prompt(epos_md, attempt, flavors)

    case LLM.complete(:chronik, prompt, opts) do
      {:ok, json_str} ->
        entries =
          json_str
          |> parse_chronik_json()
          |> filter_fabricated_chronik()

        if entries == [] do
          Logger.warning(
            "Stage 4 (#{attempt}): LLM returned 0 entries (after fabrication-filter). " <>
              "Raw output (truncated): " <> String.slice(json_str || "", 0, 400)
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

  # Issue #230: drop Einträge die LLM-Sentinel-Strings enthalten (selbst-
  # eingestandene Fabrication wie `in_game_date == "Nicht im Transkript
  # erwähnt"`). Public via @doc false damit der Pipeline-Filter-Test ohne
  # GenServer-Setup direkt callen kann — analog zu `parse_chronik_json/1`.
  @doc false
  def filter_fabricated_chronik(entries) when is_list(entries) do
    {kept, dropped} = Enum.split_with(entries, &(not fabricated_entry?(&1)))

    if dropped != [] do
      sample =
        dropped
        |> List.first()
        |> case do
          %{} = e ->
            Map.get(e, "label") || Map.get(e, "title") || Map.get(e, "in_game_date") || ""

          _ ->
            ""
        end

      Logger.warning(
        "Stage 4: filtered #{length(dropped)} fabricated chronik entries " <>
          "(kept #{length(kept)}). Sample=#{inspect(sample)}"
      )
    end

    kept
  end

  def filter_fabricated_chronik(_), do: []

  defp fabricated_entry?(entry) when is_map(entry) do
    fields = [
      Map.get(entry, "in_game_date") || Map.get(entry, "date") || "",
      Map.get(entry, "label") || Map.get(entry, "title") || "",
      Map.get(entry, "summary") || Map.get(entry, "description") || ""
    ]

    Enum.any?(@fabrication_sentinels, fn pattern ->
      Enum.any?(fields, fn field ->
        is_binary(field) and Regex.match?(pattern, field)
      end)
    end)
  end

  defp fabricated_entry?(_), do: true

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
  defp stage4_publish([], _session_id, _campaign) do
    Logger.warning("Stage 4: LLM returned no usable chronik entries even after retry")
    {:error, :empty_chronik}
  end

  # Issue #227: Re-Run-Cleanup. Vor neuen ChronikEntryChanged-Events räumen
  # wir die bestehenden Chronik-Rows derselben session_id aus — sonst
  # akkumulieren Halluzinationen über jeden Re-Run hinweg, weil die
  # SHA-abgeleiteten IDs auf (date, label) sich ändern und alte Rows nie
  # überschrieben werden.
  defp stage4_publish(entries, session_id, campaign) do
    case Intents.publish(%{
           "kind" => Shared.Events.chronik_cleared_for_session(),
           "campaign_id" => campaign.id,
           "session_id" => session_id,
           "cleared_by" => "llm"
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Stage 4: chronik-clear publish failed (session=#{session_id}): #{inspect(reason)} — " <>
            "proceeding with entry-publish anyway"
        )
    end

    results =
      Enum.map(entries, fn entry ->
        Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_chronik_id(entry),
          "campaign_id" => campaign.id,
          "in_game_date" => Map.get(entry, "in_game_date") || Map.get(entry, "date"),
          "label" => Map.get(entry, "label") || Map.get(entry, "title") || "",
          "summary" => Map.get(entry, "summary") || Map.get(entry, "description"),
          "session_id" => session_id
        })
      end)

    failures = Enum.reject(results, &match?({:ok, _}, &1))

    if failures == [] do
      Logger.info("Stage 4: wrote #{length(entries)} chronik entries (session=#{session_id})")
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
        Logger.warning("Pipeline: publish failed (kind=#{payload["kind"]}): #{inspect(reason)}")

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

  # Public so tests können den Prompt-Build über `apply/3` verifizieren
  # (Issue #226). Marker `@doc false` weil interne API — nicht für externe
  # Aufrufer gedacht.
  @doc false
  def build_epos_prompt(existing_md, summaries, flavors, force? \\ false)
      when is_list(summaries) do
    summaries_block =
      summaries
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> "### Session #{i}\n#{s.content_md}" end)
      |> Enum.join("\n\n")

    # Issue #226: bei manuellem Re-Run (force=true) einen expliziten Hinweis
    # in den Prompt einbauen — sonst produziert das LLM bei nahezu-identischem
    # Input einen bit-identischen Output (temp=0.2 + nur subtil geänderte
    # Summaries → deterministisches Verhalten).
    force_hint =
      if force? do
        """

        HINWEIS: Dies ist ein expliziter Re-Run. Integriere insbesondere die
        jüngsten Session-Inhalte sichtbar in den fortlaufenden Epos. Wiederhole
        NICHT den bisherigen Text wortgleich, sondern erweitere ihn um die
        neuen Plot-Punkte aus den zuletzt hinzugekommenen Resümees.
        """
      else
        ""
      end

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
    #{force_hint}
    """
  end

  defp build_chronik_prompt(epos_md, attempt, flavors) do
    nudge =
      case attempt do
        :retry ->
          """

          HINWEIS: Im ersten Versuch hast du eine leere Liste geliefert.
          Schaue noch einmal nach klaren Plot-Beats (Ankunft, Begegnung,
          Kampf, Entdeckung). Wenn das Material in einem Kapitel keinen
          klaren Plot-Beat hergibt, lass es weg — eine leere Liste ist
          besser als erfundene Einträge.
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
    - Antworte NUR mit dem JSON, keine Vorrede.

    ANTI-FABRICATION (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Wenn der Text kein konkretes Datum oder keinen klaren Plot-Beat
      hergibt, lass den Eintrag weg. Eine leere Liste ist eine gültige
      Antwort.
    - Schreibe NIEMALS in `in_game_date` Strings wie "Nicht im Transkript
      erwähnt", "Unbekannt", "Keine Angabe", "N/A" — das sind keine
      gültigen Daten, der Eintrag gehört dann gar nicht in die Liste.
    - Erfinde keine Cliffhanger, keine Atmospheric Filler, keine
      Übergangs-Sätze "Die Gruppe macht sich auf …" wenn dazu nichts
      Konkretes im Transkript steht.#{nudge}

    Text:
    #{epos_md}

    #{fact_fidelity_block("Text")}
    """
  end
end
