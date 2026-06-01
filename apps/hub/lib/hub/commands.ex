defmodule Hub.Commands do
  @moduledoc """
  Hub-side helpers for non-event commands (channel pushes that don't change
  domain state and aren't replicated to other workers).

  Currently only `:shutdown_worker`. Lease/regenerate commands for the LLM
  pipeline (M8) land here too.
  """

  alias Hub.WorkerRegistry

  require Logger

  @spec shutdown_worker(String.t()) :: :ok | {:error, :worker_offline}
  def shutdown_worker(worker_id) when is_binary(worker_id) do
    case Enum.find(WorkerRegistry.list(), fn {id, _} -> id == worker_id end) do
      nil ->
        {:error, :worker_offline}

      {_id, %{channel_pid: pid}} ->
        send(pid, :shutdown_worker)
        :ok
    end
  end

  @doc """
  Shut down every connected worker whose admin Discord-ID matches `discord_id`.
  Returns the number of workers signalled.
  """
  @spec shutdown_my_workers(String.t()) :: non_neg_integer()
  def shutdown_my_workers(discord_id) when is_binary(discord_id) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, :shutdown_worker) end)
    |> length()
  end

  @doc """
  Push a settings update to every connected worker whose admin Discord-ID
  matches `discord_id`. `kv` is a map of `Worker.Settings`-key → value.
  Returns the number of workers signalled.
  """
  @spec update_my_worker_settings(String.t(), map()) :: non_neg_integer()
  def update_my_worker_settings(discord_id, kv) when is_binary(discord_id) and is_map(kv) do
    WorkerRegistry.list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, {:update_settings, kv}) end)
    |> length()
  end

  @doc """
  Same as `update_my_worker_settings/2` but to every connected worker
  regardless of admin. Used by the dev `/dev/settings` endpoint.
  """
  @spec update_all_worker_settings(map()) :: non_neg_integer()
  def update_all_worker_settings(kv) when is_map(kv) do
    WorkerRegistry.list()
    |> Enum.map(fn {_id, %{channel_pid: pid}} -> send(pid, {:update_settings, kv}) end)
    |> length()
  end

  @doc """
  Ask the campaign's recording-leader-worker (deterministic pick under
  Member-Workers, Issue #237) to start recording. Was previously a
  fan-out to every admin-worker — that created duplicate sessions.

  Returns 1 wenn signalisiert, 0 wenn kein Member-Worker connected
  (UI mapped auf Flash-Error).
  """
  @spec request_recording_start(String.t(), String.t(), atom()) :: non_neg_integer()
  def request_recording_start(discord_id, campaign_id, mode \\ :default) do
    case pick_leader(discord_id, campaign_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_recording, discord_id, campaign_id, mode})
        1
    end
  end

  @spec request_recording_stop(String.t(), String.t()) :: non_neg_integer()
  def request_recording_stop(discord_id, campaign_id) do
    case pick_leader(discord_id, campaign_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:stop_recording, campaign_id})
        1
    end
  end

  @doc """
  Ask the own-worker of `discord_id` to start an LLM-Probelauf (Issue #74).
  Probelauf ist nicht campaign-bound — `pick_leader/2` mit `nil`-cid
  liefert den own-worker (kein Member-Filter). Returns 1 wenn ein Worker
  das Signal bekommen hat, 0 wenn keiner verbunden ist.
  """
  @spec request_probelauf_start(String.t()) :: non_neg_integer()
  def request_probelauf_start(discord_id) when is_binary(discord_id) do
    case pick_leader(discord_id, nil) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_probelauf, discord_id})
        1
    end
  end

  @doc """
  Issue #292: GpuQueue-Job-Verwaltung vom Admin-LV. `action ∈
  "move_up" | "move_down" | "cancel"`. Returns 1 wenn ein Worker das
  Signal bekommen hat, 0 sonst.
  """
  @spec request_gpu_job_action(String.t(), String.t(), String.t()) :: non_neg_integer()
  def request_gpu_job_action(discord_id, action, job_id)
      when is_binary(discord_id) and is_binary(action) and is_binary(job_id) and
             action in ["move_up", "move_down", "cancel"] do
    case pick_leader(discord_id, nil) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:gpu_job_action, action, job_id})
        1
    end
  end

  def request_gpu_job_action(_, _, _), do: 0

  @doc """
  Ask the own-worker of `discord_id` to start an LLM-Probelauf-Sweep
  (Issue #88, Phase 2a). Variiert genau eine Stage durch eine Liste von
  Modellen — pro Modell ein voller Probelauf. Nicht campaign-bound
  (`pick_leader(_, nil)`). Returns 1 wenn ein Worker das Signal bekommen
  hat, 0 sonst.
  """
  @spec request_probelauf_sweep(String.t(), integer(), [String.t()]) :: non_neg_integer()
  def request_probelauf_sweep(discord_id, stage, models),
    do: request_probelauf_sweep(discord_id, stage, models, nil)

  @doc """
  Issue #284: erweitertes Sweep-Request mit `session_set` (Liste aus
  \"short\"/\"medium\"/\"long\"). `nil` oder `[]` = alle.
  """
  @spec request_probelauf_sweep(String.t(), integer(), [String.t()], [String.t()] | nil) ::
          non_neg_integer()
  def request_probelauf_sweep(discord_id, stage, models, session_set)
      when is_binary(discord_id) and stage in [2, 3, 4] and is_list(models) do
    case pick_leader(discord_id, nil) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_probelauf_sweep, discord_id, stage, models, session_set})
        1
    end
  end

  @doc """
  Issue #262: Stage-isolierter Probelauf-Sweep. Pro Modell läuft nur die
  Ziel-Stage gegen den Goldstandard-Pre-Seed (Issue #201) statt voller
  Pipeline. Schneller + fair vergleichbar für Stage 3+4 (kein Drift durch
  davor laufende Default-Stage).

  Returns 1 wenn signalisiert, 0 wenn kein Own-Worker verbunden.
  """
  @spec request_probelauf_sweep_isolated(String.t(), integer(), [String.t()]) ::
          non_neg_integer()
  def request_probelauf_sweep_isolated(discord_id, stage, models),
    do: request_probelauf_sweep_isolated(discord_id, stage, models, nil)

  @doc """
  Issue #284: erweitertes Isolated-Sweep-Request mit `session_set`.
  """
  @spec request_probelauf_sweep_isolated(
          String.t(),
          integer(),
          [String.t()],
          [String.t()] | nil
        ) ::
          non_neg_integer()
  def request_probelauf_sweep_isolated(discord_id, stage, models, session_set)
      when is_binary(discord_id) and stage in [2, 3, 4] and is_list(models) do
    case pick_leader(discord_id, nil) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_probelauf_sweep_isolated, discord_id, stage, models, session_set})
        1
    end
  end

  @doc """
  Issue #289 Phase 4: Param-Sweep (Temperature-Varianten). Variiert
  `temperature_stageN` über eine Werte-Liste bei fixem (current default)
  Modell. Returns 1 wenn signalisiert, 0 wenn kein Own-Worker verbunden.
  """
  @spec request_probelauf_sweep_isolated_param(
          String.t(),
          integer(),
          [float()],
          [String.t()] | nil
        ) :: non_neg_integer()
  def request_probelauf_sweep_isolated_param(discord_id, stage, temperatures, session_set \\ nil)

  def request_probelauf_sweep_isolated_param(discord_id, stage, temperatures, session_set)
      when is_binary(discord_id) and stage in [2, 3, 4] and is_list(temperatures) do
    case pick_leader(discord_id, nil) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(
          pid,
          {:start_probelauf_sweep_isolated_param, discord_id, stage, temperatures, session_set}
        )

        1
    end
  end

  @doc """
  Issue #104: campaign-weiten Pipeline-Re-Run anstoßen. Member-Worker
  (Issue #237) bekommt einen `start_campaign_replay`-Push, der intern
  `Worker.Recording.CampaignReplay.start/2` ruft. Returns 1 wenn signalisiert,
  0 wenn kein Member-Worker verbunden ist.
  """
  @spec request_campaign_replay(String.t(), String.t()) :: non_neg_integer()
  def request_campaign_replay(discord_id, campaign_id)
      when is_binary(discord_id) and is_binary(campaign_id) do
    case pick_leader(discord_id, campaign_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_campaign_replay, discord_id, campaign_id})
        1
    end
  end

  @doc """
  Issue #121: einzelne Session-Pipeline neu starten. Member-Worker (Issue
  #237) bekommt einen `start_session_regenerate`-Push, der intern
  `Worker.Recording.Pipeline.run_for_session/1` ruft. Returns 1 wenn
  signalisiert, 0 wenn kein Member-Worker verbunden ist.
  """
  @spec request_session_regenerate(String.t(), String.t(), String.t()) :: non_neg_integer()
  def request_session_regenerate(discord_id, campaign_id, session_id)
      when is_binary(discord_id) and is_binary(campaign_id) and is_binary(session_id) do
    case pick_leader(discord_id, campaign_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:start_session_regenerate, discord_id, campaign_id, session_id})
        1
    end
  end

  @doc """
  Issue #392: graceful Mic-Stop. Signalisiert dem Recording-Leader-Worker, den
  Streamer sofort aus der Presence zu nehmen — statt auf den Chunk-Recency-
  Sweep (~4s) zu warten. Best-effort: kein Member-Worker connected → no-op.
  """
  @spec mic_leave(String.t(), String.t(), String.t()) :: :ok
  def mic_leave(discord_id, campaign_id, session_id)
      when is_binary(discord_id) and is_binary(campaign_id) and is_binary(session_id) do
    case pick_leader(discord_id, campaign_id) do
      nil -> :ok
      {_id, %{channel_pid: pid}} -> send(pid, {:mic_leave, session_id, discord_id})
    end

    :ok
  end

  @doc """
  Issue #400: einen Mic-Setup-Phrase-Clip an einen für die Kampagne
  zuständigen Worker zum Transkribieren schicken. Async — die Antwort kommt
  via `transcribe_clip_response` (WorkerChannel) und wird per PubSub auf
  `"mic_clip:<discord_id>"` an die wartende CampaignLive gebroadcastet.

  Kein Member-Worker connected → `{:error, :no_worker}`; das Setup blockiert
  dann hart (kein Rückfall auf den alten Pegel-Check), siehe CampaignLive.
  """
  @spec request_clip_transcribe(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :no_worker}
  def request_clip_transcribe(discord_id, campaign_id, request_id, chunk_b64)
      when is_binary(discord_id) and is_binary(campaign_id) and
             is_binary(request_id) and is_binary(chunk_b64) do
    case pick_leader(discord_id, campaign_id) do
      nil ->
        {:error, :no_worker}

      {_id, %{channel_pid: pid}} ->
        send(pid, {:transcribe_clip, request_id, discord_id, chunk_b64})
        :ok
    end
  end

  @doc """
  Forward a single MediaRecorder audio chunk from a player's browser to
  a recording-leader worker for `campaign_id`. One target, no fan-out —
  the browser is streaming chunks tagged with one session_id, and only
  the worker that holds that session in its AudioBuffer can use the data
  anyway.

  Issue #237: Routing geht über Member-Check der Kampagne, nicht mehr
  über Owner-Discord-ID. Wenn kein Member-Worker connected ist, returnt
  `0` — der Frontend-Hook bekommt damit das Signal, dass das Recording
  nicht erfolgreich gestartet wurde.
  """
  @spec forward_audio_chunk(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  def forward_audio_chunk(campaign_id, session_id, sender_discord_id, chunk_b64)
      when is_binary(campaign_id) and is_binary(session_id) and
             is_binary(sender_discord_id) and is_binary(chunk_b64) do
    case pick_leader(sender_discord_id, campaign_id) do
      nil ->
        0

      {_id, %{channel_pid: pid}} ->
        send(pid, {:audio_chunk, session_id, sender_discord_id, chunk_b64})
        1
    end
  end

  # Defensive fallback — drop the chunk + log enough to debug. Most common
  # cause: the JS hook fires once with nil/non-binary args (e.g. session_id
  # not yet set, or blobToBase64 returned undefined).
  def forward_audio_chunk(campaign_id, session_id, sender_discord_id, chunk_b64) do
    require Logger

    Logger.warning(
      "Hub.Commands.forward_audio_chunk: ignoring chunk with bad args " <>
        inspect(%{
          campaign: type_of(campaign_id),
          session: type_of(session_id),
          sender: type_of(sender_discord_id),
          chunk: type_of(chunk_b64)
        })
    )

    0
  end

  # Wählt einen connected Worker für eine Operation aus.
  #
  # Bei `campaign_id == nil` (z.B. Probelauf — admin-globaler Test, nicht
  # campaign-bound): nur der own-worker des Discord-Users, höchste
  # applied_seq, deterministisch.
  #
  # Bei `campaign_id` gesetzt (Recording, Pipeline-Rerun, Audio-Forward —
  # Issues #236 + #237): strikter Member-Filter. Nur Worker, deren
  # admin_discord_id als Member der Kampagne registriert ist (= das
  # `subscribed_campaigns`-MapSet im Tracker-Meta enthält die cid). Das
  # MapSet wird vom Worker.Materializer bei MemberAdded/InviteRedeemed
  # automatisch synchronisiert.
  #
  # Member-Leader-Election: lexikografisch kleinste worker_id — stateless,
  # race-frei, deterministisch (gleiches Worker-Set → gleicher Leader).
  # Verhindert Parallel-Pipelining wenn mehrere Member-Worker connected
  # sind.
  #
  # Kein Fallback auf beliebigen Worker mehr. Wenn kein Member-Worker
  # connected ist, returnt `nil` — Caller mappen auf `0` = UI-Flash-Error.
  # Auch global :admin bekommt KEINEN Bypass (User-Decision 2026-05-26).
  defp pick_leader(discord_id, campaign_id \\ nil) do
    all = WorkerRegistry.list()

    case campaign_id do
      nil ->
        # Probelauf-Pfad: own-worker only.
        all
        |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
        |> Enum.sort_by(fn {id, meta} -> {-Map.get(meta, :applied_seq, 0), id} end)
        |> List.first()

      cid when is_binary(cid) ->
        # Recording/Pipeline-Pfad: Member-Filter, deterministischer Leader.
        member_workers =
          all
          |> Enum.filter(fn {_id, meta} ->
            MapSet.member?(Map.get(meta, :subscribed_campaigns, MapSet.new()), cid)
          end)

        case Enum.sort_by(member_workers, fn {id, _meta} -> id end) do
          [] ->
            Logger.warning(
              "Hub.Commands.pick_leader: no member-worker connected for campaign=#{cid} " <>
                "(caller=#{discord_id}); operation will fail."
            )

            nil

          [leader | _rest] ->
            leader
        end
    end
  end

  defp type_of(nil), do: nil
  defp type_of(v) when is_binary(v), do: {:binary, byte_size(v)}
  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_atom(v), do: {:atom, v}
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_list(v), do: :list
  defp type_of(_), do: :other

  @doc """
  Issue #57: Triggert das finale UserDeleted-Event. Pre-Checks:
    - Caller != Target (kein Self-Delete)
    - Target ist nicht der einzige :admin (Last-Admin-Lockout)
    - Target ist in keiner Kampagne der letzte Spielleiter (Last-SL-Check;
      die UI muss vorher MemberRolePromoted oder CampaignArchived ausführen).
  Bei :ok wird `UserDeleted` via `Hub.EventBridge.publish/1` an einen
  online-Worker geroutet (Cascade läuft im Materializer).
  """
  @spec request_user_delete(String.t(), String.t()) ::
          :ok
          | {:error, :cannot_delete_self}
          | {:error, :last_admin}
          | {:error, {:unresolved_last_sl, [String.t()]}}
          | {:error, :no_worker_online}
          | {:error, term()}
  def request_user_delete(caller_discord_id, target_discord_id)
      when is_binary(caller_discord_id) and is_binary(target_discord_id) do
    cond do
      caller_discord_id == target_discord_id ->
        {:error, :cannot_delete_self}

      true ->
        case Hub.Reader.read(%{
               "kind" => "user_delete_preview",
               "discord_id" => target_discord_id
             }) do
          {:ok, %{"last_admin" => true}} ->
            {:error, :last_admin}

          {:ok, %{"last_sl_campaigns" => sl_campaigns}}
          when is_list(sl_campaigns) and sl_campaigns != [] ->
            ids = Enum.map(sl_campaigns, & &1["id"])
            {:error, {:unresolved_last_sl, ids}}

          {:ok, _} ->
            payload = %{
              "kind" => Shared.Events.user_deleted(),
              "discord_id" => target_discord_id,
              "deleted_by" => caller_discord_id
            }

            Hub.EventBridge.publish(payload)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
