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

  @topic "applied_events"
  def topic, do: @topic

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

    case result do
      {:applied, _} -> Phoenix.PubSub.broadcast(Worker.PubSub, @topic, {:applied, event})
      _ -> :ok
    end

    result
  end

  defp current_cursor_in_tx do
    case :mnesia.read(S.worker_state(), :last_applied_seq) do
      [{_, _, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp apply_payload(
         %{"payload" => %{"kind" => kind} = payload, "ts" => ts, "seq" => seq} = event
       ) do
    meta = %{seq: seq, author_worker_id: event["author_worker_id"]}
    apply_kind(kind, payload, parse_ts(ts), meta)
  end

  defp apply_payload(other) do
    Logger.warning("Materializer: unrecognized event shape #{inspect(other)}")
    :ok
  end

  # ─── Per-kind handlers ───────────────────────────────────────────

  defp apply_kind("CampaignCreated", payload, ts, _meta) do
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
        ts,
        %{}
      })

    # Auto-membership: the owner is the first member with role :owner.
    # 7th field is :character_name (Issue #2) — nil at creation, set later
    # via CampaignAliasSet.
    :ok =
      :mnesia.write({
        S.campaign_members(),
        S.member_key(id, owner),
        id,
        owner,
        :owner,
        ts,
        nil
      })

    # Owner often has no users-table entry yet (they didn't redeem an
    # invite — they created the campaign directly). Upsert here so the UI
    # can resolve their discord_id → display_name. Preserve any existing
    # joined_at so InviteRedeemed → CampaignCreated order doesn't matter.
    display_name = payload["owner_display_name"] || owner

    {existing_joined_at, existing_avatar_url, existing_role} =
      case :mnesia.read(S.users(), owner) do
        [{_, _, _, j, a, r}] -> {j, a, r}
        [] -> {ts, nil, :spieler}
      end

    :ok =
      :mnesia.write(
        {S.users(), owner, display_name, existing_joined_at, existing_avatar_url, existing_role}
      )
  end

  defp apply_kind("CampaignUpdated", payload, _ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.campaigns(), id) do
      [{_, ^id, name, icon, theme, status, owner, created_at, flavors}] ->
        :ok =
          :mnesia.write({
            S.campaigns(),
            id,
            payload["name"] || name,
            payload["icon_url"] || icon,
            payload["theme_blurb"] || theme,
            payload["status"] || status,
            owner,
            created_at,
            flavors
          })

      [] ->
        Logger.warning("CampaignUpdated for unknown id=#{id} — ignoring")
    end
  end

  defp apply_kind("CampaignDeleted", payload, _ts, _meta) do
    id = payload["campaign_id"]

    case :mnesia.read(S.campaigns(), id) do
      [] ->
        Logger.warning("CampaignDeleted for unknown id=#{id} — ignoring")

      [_] ->
        # Sessions zuerst — wir brauchen ihre IDs für utterances + markers.
        session_ids =
          S.sessions()
          |> :mnesia.index_read(id, :campaign_id)
          |> Enum.map(&elem(&1, 1))

        Enum.each(session_ids, fn sid ->
          :mnesia.index_read(S.utterances(), sid, :session_id)
          |> Enum.each(fn row -> :mnesia.delete({S.utterances(), elem(row, 1)}) end)

          :mnesia.index_read(S.markers(), sid, :session_id)
          |> Enum.each(fn row -> :mnesia.delete({S.markers(), elem(row, 1)}) end)

          :mnesia.delete({S.sessions(), sid})
        end)

        # Campaign-scoped tables.
        delete_by_campaign(S.campaign_members(), id)
        delete_by_campaign(S.campaign_invites(), id)
        delete_by_campaign(S.session_summaries(), id)
        delete_by_campaign(S.chronik_entries(), id)
        delete_by_campaign(S.epos_entries(), id)

        # Epos-Historie ist nach entry_id indiziert (entry_id == campaign_id
        # für die single-entry-pro-campaign-Welt).
        :mnesia.index_read(S.epos_history(), id, :entry_id)
        |> Enum.each(fn row -> :mnesia.delete({S.epos_history(), elem(row, 1)}) end)

        :mnesia.delete({S.campaigns(), id})

        Logger.info("CampaignDeleted id=#{id} — cascade dropped #{length(session_ids)} session(s)")
    end
  end

  defp delete_by_campaign(table, campaign_id) do
    :mnesia.index_read(table, campaign_id, :campaign_id)
    |> Enum.each(fn row ->
      # PK ist immer im 2. Tupel-Slot (Mnesia-Konvention für unsere Tabellen);
      # für campaign_members ist es der composite key cm_key.
      :mnesia.delete({table, elem(row, 1)})
    end)
  end

  @flavor_slots ~w(base summary epos chronik)

  defp apply_kind("CampaignFlavorSet", payload, _ts, _meta) do
    id = payload["campaign_id"]
    slot = payload["slot"] || "base"
    raw = payload["flavor"]

    cond do
      slot not in @flavor_slots ->
        Logger.warning("CampaignFlavorSet: unknown slot=#{inspect(slot)} for id=#{id} — dropping")

      true ->
        case :mnesia.read(S.campaigns(), id) do
          [{_, ^id, name, icon, theme, status, owner, created_at, old_flavors}] ->
            existing =
              case old_flavors do
                m when is_map(m) -> m
                s when is_binary(s) and s != "" -> %{"base" => s}
                _ -> %{}
              end

            cleaned =
              case raw do
                nil -> nil
                s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
                _ -> nil
              end

            new_flavors =
              if is_nil(cleaned), do: Map.delete(existing, slot), else: Map.put(existing, slot, cleaned)

            :ok =
              :mnesia.write({
                S.campaigns(),
                id,
                name,
                icon,
                theme,
                status,
                owner,
                created_at,
                new_flavors
              })

          [] ->
            Logger.warning("CampaignFlavorSet for unknown id=#{id} — ignoring")
        end
    end
  end

  defp apply_kind("SessionScheduled", payload, _ts, _meta) do
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

  defp apply_kind("SessionStarted", payload, ts, _meta) do
    update_session(payload["id"], fn {_, id, cid, num, name, _status, sched, _started, ended} ->
      {S.sessions(), id, cid, num, name, :recording, sched, ts, ended}
    end)
  end

  defp apply_kind("SessionEnded", payload, ts, _meta) do
    update_session(payload["id"], fn {_, id, cid, num, name, _status, sched, started, _ended} ->
      {S.sessions(), id, cid, num, name, :completed, sched, started, ts}
    end)
  end

  defp apply_kind("RecordingStateChanged", payload, _ts, _meta) do
    new_status = String.to_atom(payload["state"])

    update_session(payload["session_id"], fn {_, id, cid, num, name, _status, sched, started,
                                              ended} ->
      {S.sessions(), id, cid, num, name, new_status, sched, started, ended}
    end)
  end

  defp apply_kind("UtteranceAppended", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.utterances(),
        payload["id"],
        payload["session_id"],
        payload["discord_id"],
        parse_ts(payload["timestamp"]),
        payload["text"],
        payload["confidence"],
        String.to_atom(payload["status"] || "confirmed")
      })
  end

  defp apply_kind("UtteranceEdited", payload, _ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.utterances(), id) do
      [{tbl, ^id, sid, did, ts, _old_text, conf, _old_status}] ->
        new_text = payload["new_text"] || ""
        :ok = :mnesia.write({tbl, id, sid, did, ts, new_text, conf, :edited})

      [] ->
        Logger.warning("UtteranceEdited for unknown id=#{id} — dropping")
        :ok
    end
  end

  defp apply_kind("UtteranceDeleted", payload, _ts, _meta) do
    id = payload["id"]
    :ok = :mnesia.delete({S.utterances(), id})
  end

  defp apply_kind("LiveUtterancesCleared", payload, _ts, _meta) do
    session_id = payload["session_id"]

    rows = :mnesia.index_read(S.utterances(), session_id, :session_id)

    Enum.each(rows, fn {_, id, _sid, _did, _ts, _text, _conf, status} ->
      if status == :live, do: :mnesia.delete({S.utterances(), id})
    end)

    :ok
  end

  defp apply_kind("UserUpserted", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || discord_id

    {existing_joined_at, existing_avatar_url, existing_role} =
      case :mnesia.read(S.users(), discord_id) do
        [{_, _, _, j, a, r}] -> {j, a, r}
        [] -> {ts, nil, :spieler}
      end

    # avatar_url in the payload wins (allows refresh); fall back to existing
    # so an older event without the field doesn't blank the avatar.
    avatar_url =
      case Map.fetch(payload, "avatar_url") do
        {:ok, url} -> url
        :error -> existing_avatar_url
      end

    :ok =
      :mnesia.write({
        S.users(),
        discord_id,
        display_name,
        existing_joined_at,
        avatar_url,
        existing_role
      })
  end

  @valid_roles ~w(admin spielleiter spieler)

  defp apply_kind("UserRoleSet", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    role_str = payload["role"]

    cond do
      role_str not in @valid_roles ->
        Logger.warning(
          "UserRoleSet: unknown role=#{inspect(role_str)} for discord_id=#{discord_id} — dropping"
        )

      true ->
        role = String.to_atom(role_str)

        {display_name, joined_at, avatar_url} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, name, j, a, _}] -> {name, j, a}
            [] -> {discord_id, ts, nil}
          end

        :ok =
          :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role})
    end
  end

  defp apply_kind("MarkerAdded", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.markers(),
        payload["id"],
        payload["session_id"],
        parse_ts(payload["at_ts"]),
        String.to_atom(payload["marker_kind"] || "plot"),
        payload["label"]
      })
  end

  defp apply_kind("InviteCreated", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.campaign_invites(),
        payload["token"],
        payload["campaign_id"],
        payload["created_by_discord_id"],
        ts,
        parse_ts(payload["expires_at"]),
        :active,
        nil
      })
  end

  defp apply_kind("InviteRevoked", payload, _ts, _meta) do
    token = payload["token"]

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, cid, by, created, expires, _status, redeemed_by}] ->
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            cid,
            by,
            created,
            expires,
            :revoked,
            redeemed_by
          })

      [] ->
        Logger.warning("InviteRevoked for unknown token=#{token}")
    end
  end

  defp apply_kind("InviteRedeemed", payload, ts, _meta) do
    token = payload["token"]
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || "User #{discord_id}"

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, campaign_id, created_by, created_at, expires_at, _status, _redeemed_by}] ->
        # Mark invite redeemed.
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            campaign_id,
            created_by,
            created_at,
            expires_at,
            :redeemed,
            discord_id
          })

        # Upsert user (preserve joined_at + avatar_url if already known).
        {existing_joined_at, existing_avatar_url, existing_role} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, _, j, a, r}] -> {j, a, r}
            [] -> {ts, nil, :spieler}
          end

        :ok =
          :mnesia.write({
            S.users(),
            discord_id,
            display_name,
            existing_joined_at,
            existing_avatar_url,
            existing_role
          })

        # Add membership (idempotent — same key overwrites).
        # Preserve any existing character_name if the user is being
        # re-added (e.g. invite re-redeemed); default nil for first-time.
        existing_character_name =
          case :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id)) do
            [{_, _, _, _, _, _, name}] -> name
            _ -> nil
          end

        :ok =
          :mnesia.write({
            S.campaign_members(),
            S.member_key(campaign_id, discord_id),
            campaign_id,
            discord_id,
            :player,
            ts,
            existing_character_name
          })

      [] ->
        Logger.warning("InviteRedeemed for unknown token=#{token}")
    end
  end

  defp apply_kind("MemberRemoved", payload, _ts, _meta) do
    :ok =
      :mnesia.delete({
        S.campaign_members(),
        S.member_key(payload["campaign_id"], payload["discord_id"])
      })
  end

  defp apply_kind("CampaignAliasSet", payload, _ts, _meta) do
    campaign_id = payload["campaign_id"]
    discord_id = payload["discord_id"]
    name = normalize_alias(payload["character_name"])
    key = S.member_key(campaign_id, discord_id)

    case :mnesia.read(S.campaign_members(), key) do
      [{tbl, ^key, ^campaign_id, ^discord_id, role, joined_at, _old_name}] ->
        :ok = :mnesia.write({tbl, key, campaign_id, discord_id, role, joined_at, name})

      [] ->
        Logger.warning(
          "CampaignAliasSet for unknown member campaign=#{campaign_id} did=#{discord_id} — dropping"
        )

        :ok
    end
  end

  defp apply_kind("SessionSummaryGenerated", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.session_summaries(),
        payload["session_id"],
        payload["campaign_id"],
        payload["content_md"] || "",
        ts,
        String.to_atom(payload["source"] || "llm")
      })
  end

  defp apply_kind("SessionSummaryEdited", payload, ts, _meta) do
    case :mnesia.read(S.session_summaries(), payload["session_id"]) do
      [{_, sid, cid, _content, _generated_at, _source}] ->
        :ok =
          :mnesia.write({
            S.session_summaries(),
            sid,
            cid,
            payload["new_md"] || "",
            ts,
            :manual
          })

      [] ->
        Logger.warning("SessionSummaryEdited for unknown session=#{payload["session_id"]}")
    end
  end

  defp apply_kind("ChronikEntryChanged", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.chronik_entries(),
        payload["id"],
        payload["campaign_id"],
        payload["in_game_date"],
        payload["in_game_sort_key"] || 0,
        payload["label"],
        payload["summary"],
        payload["session_id"]
      })
  end

  defp apply_kind("EposEntryEdited", payload, ts, meta) do
    entry_id = payload["entry_id"]
    campaign_id = payload["campaign_id"] || entry_id
    new_md = payload["new_md"] || ""

    # Upsert the current snapshot of the entry.
    :ok =
      :mnesia.write({
        S.epos_entries(),
        entry_id,
        campaign_id,
        payload["parent_id"],
        new_md,
        ts
      })

    # Append a history row. History id is derived from seq so re-applying
    # the same event is idempotent (overwrites the same row).
    history_id = "ehist-#{meta.seq}"

    :ok =
      :mnesia.write({
        S.epos_history(),
        history_id,
        entry_id,
        new_md,
        ts,
        meta.author_worker_id,
        String.to_atom(payload["source"] || "manual"),
        meta.seq
      })
  end

  defp apply_kind(kind, _payload, _ts, _meta) do
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

  defp update_session(id, fun) do
    case :mnesia.read(S.sessions(), id) do
      [row] -> :ok = :mnesia.write(fun.(row))
      [] -> Logger.warning("Session update for unknown id=#{id}")
    end
  end

  defp normalize_alias(nil), do: nil

  defp normalize_alias(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: nil, else: trimmed
  end
end
