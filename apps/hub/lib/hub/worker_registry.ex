defmodule Hub.WorkerRegistry do
  @moduledoc """
  Phoenix.Tracker view of currently-connected workers.

  Each entry: `worker_id => %{admin_discord_id, applied_seq, channel_pid,
  subscribed_campaigns}`. `applied_seq` is updated whenever the worker acks
  an event apply; the Hub picks the worker with the highest `applied_seq`
  for snapshot reads.

  Issue #129 (Etappe 3b): `subscribed_campaigns` ist eine MapSet von
  campaign_ids für die der Worker Member ist (Owner oder Spieler).
  `Hub.WorkerChannel` filtert event_appended-Broadcasts darauf — nur Worker
  mit Subscription auf die jeweilige Campaign bekommen den Event-Push.

  Membership changes broadcast `{:workers_changed, joins, leaves}` on
  Hub.PubSub topic `"workers"` so LiveViews can re-fetch their snapshots
  the moment a worker comes online (instead of waiting for an event).
  """

  use Phoenix.Tracker

  @topic "workers"

  def topic, do: @topic

  # ─── Tracker plumbing ─────────────────────────────────────────────

  def start_link(opts) do
    opts =
      Keyword.merge(
        [name: __MODULE__, pubsub_server: Hub.PubSub],
        opts
      )

    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @impl true
  def init(opts) do
    {:ok, %{pubsub_server: Keyword.fetch!(opts, :pubsub_server)}}
  end

  @impl true
  def handle_diff(diff, state) do
    case Map.get(diff, @topic) do
      nil ->
        :ok

      {joins, leaves} ->
        if joins != [] or leaves != [] do
          # Issue #238: Telemetry für Worker-Joins/Leaves. Hub.Telemetry
          # logged hub.worker_registry.changed joins=[id,...] leaves=[id,...].
          # Phoenix.Tracker liefert `joins` und `leaves` als Tupel-Listen
          # `[{worker_id, meta_map}, ...]` — wir extrahieren nur die IDs.
          join_ids = Enum.map(joins, fn {id, _meta} -> id end)
          leave_ids = Enum.map(leaves, fn {id, _meta} -> id end)

          :telemetry.execute(
            [:hub, :worker_registry, :changed],
            %{joins_count: length(join_ids), leaves_count: length(leave_ids)},
            %{joins: join_ids, leaves: leave_ids}
          )

          Phoenix.PubSub.broadcast(
            state.pubsub_server,
            @topic,
            {:workers_changed, joins, leaves}
          )
        end
    end

    {:ok, state}
  end

  # ─── API used from WorkerChannel ──────────────────────────────────

  @doc "Register the calling channel pid as the worker with the given id."
  def track(worker_id, admin_discord_id) when is_binary(worker_id) do
    Phoenix.Tracker.track(__MODULE__, self(), @topic, worker_id, %{
      admin_discord_id: admin_discord_id,
      applied_seq: 0,
      channel_pid: self(),
      subscribed_campaigns: MapSet.new()
    })
  end

  @doc "Bump the applied_seq metadata for the calling channel pid."
  def update_applied_seq(worker_id, seq) when is_binary(worker_id) and is_integer(seq) do
    Phoenix.Tracker.update(__MODULE__, self(), @topic, worker_id, fn meta ->
      Map.put(meta, :applied_seq, max(seq, meta.applied_seq))
    end)
  end

  @doc """
  Issue #129: füge campaign_ids zur Subscription-Liste des Workers hinzu.
  Idempotent (MapSet). Aufrufer ist der WorkerChannel beim Join + bei späteren
  subscribe_campaign-Messages.
  """
  @spec subscribe(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def subscribe(worker_id, campaign_ids)
      when is_binary(worker_id) and is_list(campaign_ids) do
    Phoenix.Tracker.update(__MODULE__, self(), @topic, worker_id, fn meta ->
      current = Map.get(meta, :subscribed_campaigns, MapSet.new())
      Map.put(meta, :subscribed_campaigns, MapSet.union(current, MapSet.new(campaign_ids)))
    end)
  end

  @doc "Entferne campaign_ids aus der Subscription-Liste."
  @spec unsubscribe(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def unsubscribe(worker_id, campaign_ids)
      when is_binary(worker_id) and is_list(campaign_ids) do
    Phoenix.Tracker.update(__MODULE__, self(), @topic, worker_id, fn meta ->
      current = Map.get(meta, :subscribed_campaigns, MapSet.new())
      Map.put(meta, :subscribed_campaigns, MapSet.difference(current, MapSet.new(campaign_ids)))
    end)
  end

  @doc """
  Issue #50: Worker pusht seine Liste der lokal installierten LLM-Modelle
  (Ollama `/api/tags`) als MapSet ins Meta. Settings-LV aggregiert das
  über alle Worker eines Users für den Multi-Worker-Union-Badge in der
  Modell-Combobox.

  Idempotent — `report_models([])` (Ollama offline / fresh start) wird
  als leerer MapSet geschrieben statt zu crashen.
  """
  @spec report_models(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def report_models(worker_id, model_names)
      when is_binary(worker_id) and is_list(model_names) do
    Phoenix.Tracker.update(__MODULE__, self(), @topic, worker_id, fn meta ->
      Map.put(meta, :models_available, MapSet.new(model_names))
    end)
  end

  @doc "List `{worker_id, metadata}` for everyone currently connected."
  def list, do: Phoenix.Tracker.list(__MODULE__, @topic)

  @doc """
  Issue #451 (Track B): liefert die Worker dieses Admins als Liste von
  `%{id, applied_seq, models_count}`-Maps, sortiert nach `applied_seq` desc
  (frischester Worker zuerst). Genutzt vom Worker-Selector in `/settings`.
  """
  @spec list_for_admin(String.t()) :: [%{id: String.t(), applied_seq: integer(), models_count: non_neg_integer()}]
  def list_for_admin(discord_id) when is_binary(discord_id) do
    list()
    |> Enum.filter(fn {_id, meta} -> meta.admin_discord_id == discord_id end)
    |> Enum.map(fn {id, meta} ->
      %{
        id: id,
        applied_seq: Map.get(meta, :applied_seq, 0),
        models_count: meta |> Map.get(:models_available, MapSet.new()) |> MapSet.size()
      }
    end)
    |> Enum.sort_by(& &1.applied_seq, :desc)
  end
end
