defmodule Worker.Materializer do
  @moduledoc """
  Applies events from the Hub to the local Mnesia view.

  Idempotent: events with `seq <= last_applied_seq` are dropped (echo
  protection on reconnect / repeated catch-ups). Each apply happens in a
  single Mnesia transaction that also bumps `last_applied_seq`, so the
  cursor never drifts from the materialized state.

  Per-kind handlers (`apply_kind/3`) are added as new event types land.
  Unknown kinds are logged + ignored — forward-compatible: a fresh
  worker can replay an event log produced by a newer hub without dying.
  """

  use GenServer

  require Logger

  alias Worker.Schema.Mnesia, as: S

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec apply_event(map()) :: {:applied, pos_integer()} | :skipped
  def apply_event(event), do: GenServer.call(__MODULE__, {:apply, event})

  @spec apply_batch([map()]) :: non_neg_integer()
  def apply_batch(events) when is_list(events) do
    Enum.reduce(events, last_applied_seq(), fn ev, acc ->
      case apply_event(ev) do
        {:applied, seq} -> max(seq, acc)
        :skipped -> acc
      end
    end)
  end

  @spec last_applied_seq() :: non_neg_integer()
  def last_applied_seq, do: Worker.Repo.get_state(:last_applied_seq) || 0

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:apply, event}, _from, state) do
    {:reply, do_apply(event), state}
  end

  # ─── Apply ───────────────────────────────────────────────────────

  defp do_apply(%{"seq" => seq} = event) when is_integer(seq) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        cursor = current_cursor_in_tx()

        cond do
          seq <= cursor ->
            :skipped

          true ->
            if seq > cursor + 1 do
              Logger.warning(
                "Materializer: gap detected (cursor=#{cursor}, incoming=#{seq}). Applying anyway."
              )
            end

            apply_payload(event)
            :mnesia.write({S.worker_state(), :last_applied_seq, seq})
            {:applied, seq}
        end
      end)

    result
  end

  defp current_cursor_in_tx do
    case :mnesia.read(S.worker_state(), :last_applied_seq) do
      [{_, _, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp apply_payload(%{"payload" => %{"kind" => kind} = payload, "ts" => ts}) do
    apply_kind(kind, payload, parse_ts(ts))
  end

  defp apply_payload(other) do
    Logger.warning("Materializer: unrecognized event shape #{inspect(other)}")
    :ok
  end

  # ─── Per-kind handlers ───────────────────────────────────────────

  defp apply_kind("CampaignCreated", payload, ts) do
    id = payload["id"]
    owner = payload["owner_discord_id"]

    :ok =
      :mnesia.write({
        S.campaigns(),
        id,
        payload["name"],
        payload["icon_url"],
        payload["theme_blurb"],
        :active,
        owner,
        ts
      })

    # Auto-membership: the owner is the first member with role :owner.
    :ok =
      :mnesia.write({
        S.campaign_members(),
        S.member_key(id, owner),
        id,
        owner,
        :owner,
        ts
      })
  end

  defp apply_kind("CampaignUpdated", payload, _ts) do
    id = payload["id"]

    case :mnesia.read(S.campaigns(), id) do
      [{_, ^id, name, icon, theme, status, owner, created_at}] ->
        :ok =
          :mnesia.write({
            S.campaigns(),
            id,
            payload["name"] || name,
            payload["icon_url"] || icon,
            payload["theme_blurb"] || theme,
            payload["status"] || status,
            owner,
            created_at
          })

      [] ->
        Logger.warning("CampaignUpdated for unknown id=#{id} — ignoring")
    end
  end

  defp apply_kind("SessionScheduled", payload, _ts) do
    :ok =
      :mnesia.write({
        S.sessions(),
        payload["id"],
        payload["campaign_id"],
        payload["number"],
        payload["name"],
        :scheduled,
        parse_ts(payload["scheduled_for"]),
        nil,
        nil
      })
  end

  defp apply_kind(kind, _payload, _ts) do
    Logger.debug(fn -> "Materializer: ignoring unknown kind=#{kind} (handler not implemented yet)" end)
    :ok
  end

  defp parse_ts(nil), do: nil
  defp parse_ts(%DateTime{} = dt), do: dt

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
