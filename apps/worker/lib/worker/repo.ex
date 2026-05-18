defmodule Worker.Repo do
  @moduledoc """
  Read/write Mnesia wrappers for the worker's tables. Writes are owned by
  `Worker.Materializer` (event-driven); the snapshot/read helpers are used
  by `Worker.HubClient` to answer `snapshot_request` pushes from the Hub.

  All transactions raise on abort — Mnesia aborts here are programmer
  errors (schema mismatch, missing table), not expected runtime conditions.
  """

  alias Worker.Schema.Mnesia, as: S

  # ─── worker_state ────────────────────────────────────────────────

  @spec get_state(atom()) :: term() | nil
  def get_state(key) when is_atom(key) do
    transaction(fn -> :mnesia.read(S.worker_state(), key) end)
    |> case do
      [{_, ^key, value}] -> value
      [] -> nil
    end
  end

  @spec put_state(atom(), term()) :: :ok
  def put_state(key, value) when is_atom(key) do
    transaction(fn -> :mnesia.write({S.worker_state(), key, value}) end)
    :ok
  end

  @spec put_state_many(map() | keyword()) :: :ok
  def put_state_many(map) do
    table = S.worker_state()

    transaction(fn ->
      Enum.each(map, fn {key, value} ->
        :mnesia.write({table, key, value})
      end)
    end)

    :ok
  end

  # ─── users ──────────────────────────────────────────────────────

  @spec upsert_user(String.t(), String.t()) :: :ok
  def upsert_user(discord_id, display_name)
      when is_binary(discord_id) and is_binary(display_name) do
    transaction(fn ->
      joined_at =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, _, ts}] -> ts
          [] -> DateTime.utc_now()
        end

      :mnesia.write({S.users(), discord_id, display_name, joined_at})
    end)

    :ok
  end

  def get_user(discord_id) do
    case transaction(fn -> :mnesia.read(S.users(), discord_id) end) do
      [{_, did, name, joined_at}] -> %{discord_id: did, display_name: name, joined_at: joined_at}
      [] -> nil
    end
  end

  # ─── campaigns ──────────────────────────────────────────────────

  def get_campaign(id) do
    case transaction(fn -> :mnesia.read(S.campaigns(), id) end) do
      [{_, id, name, icon, theme, status, owner, created_at}] ->
        %{
          id: id,
          name: name,
          icon_url: icon,
          theme_blurb: theme,
          status: status,
          owner_discord_id: owner,
          created_at: created_at
        }

      [] ->
        nil
    end
  end

  def list_campaigns_for(discord_id) do
    discord_id
    |> list_campaign_ids_for()
    |> Enum.map(&get_campaign/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  def list_campaign_ids_for(discord_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    end)
    |> Enum.map(fn {_, _key, campaign_id, _did, _role, _at} -> campaign_id end)
    |> Enum.uniq()
  end

  # ─── sessions ───────────────────────────────────────────────────

  def list_sessions(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.sessions(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, id, cid, num, name, status, sched, started, ended} ->
      %{
        id: id,
        campaign_id: cid,
        number: num,
        name: name,
        status: status,
        scheduled_for: sched,
        started_at: started,
        ended_at: ended
      }
    end)
    |> Enum.sort_by(& &1.number)
  end

  # ─── members ────────────────────────────────────────────────────

  def list_members(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, _key, cid, did, role, at} ->
      %{campaign_id: cid, discord_id: did, role: role, joined_at: at}
    end)
  end

  def member?(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [_] -> true
      [] -> false
    end
  end

  # ─── invites ────────────────────────────────────────────────────

  def get_invite(token) when is_binary(token) do
    case transaction(fn -> :mnesia.read(S.campaign_invites(), token) end) do
      [{_, ^token, cid, by, created, expires, status, redeemed_by}] ->
        %{
          token: token,
          campaign_id: cid,
          created_by_discord_id: by,
          created_at: created,
          expires_at: expires,
          status: status,
          redeemed_by_discord_id: redeemed_by
        }

      [] ->
        nil
    end
  end

  def list_invites(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_invites(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, token, cid, by, created, expires, status, redeemed_by} ->
      %{
        token: token,
        campaign_id: cid,
        created_by_discord_id: by,
        created_at: created,
        expires_at: expires,
        status: status,
        redeemed_by_discord_id: redeemed_by
      }
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # ─── utterances ─────────────────────────────────────────────────

  def list_utterances(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    transaction(fn ->
      :mnesia.index_read(S.utterances(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, id, sid, did, ts, text, conf, status} ->
      %{
        id: id,
        session_id: sid,
        discord_id: did,
        timestamp: ts,
        text: text,
        confidence: conf,
        status: status
      }
    end)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.take(-limit)
  end

  def list_markers(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.markers(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, id, sid, at, kind, label} ->
      %{id: id, session_id: sid, at_ts: at, kind: kind, label: label}
    end)
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end

  @doc "First non-completed session for a campaign (or nil)."
  def active_session_for(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.find(fn s -> s.status in [:recording, :paused] end)
  end

  @doc "Next session number for a campaign (max+1, or 1 if none yet)."
  def next_session_number(campaign_id) do
    case list_sessions(campaign_id) do
      [] -> 1
      list -> Enum.max_by(list, & &1.number).number + 1
    end
  end

  # ─── epos ───────────────────────────────────────────────────────

  @doc "Current Epos entry for a campaign (or nil)."
  def get_epos_entry(entry_id) when is_binary(entry_id) do
    case transaction(fn -> :mnesia.read(S.epos_entries(), entry_id) end) do
      [{_, id, cid, parent, content, updated}] ->
        %{
          id: id,
          campaign_id: cid,
          parent_id: parent,
          content_md: content,
          updated_at: updated
        }

      [] ->
        nil
    end
  end

  @doc "History rows for an Epos entry, newest first."
  def list_epos_history(entry_id) when is_binary(entry_id) do
    transaction(fn ->
      :mnesia.index_read(S.epos_history(), entry_id, :entry_id)
    end)
    |> Enum.map(fn {_, id, eid, content, edited_at, edited_by, source, seq} ->
      %{
        id: id,
        entry_id: eid,
        content_md: content,
        edited_at: edited_at,
        edited_by: edited_by,
        source: source,
        seq: seq
      }
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  # ─── snapshot dispatch ──────────────────────────────────────────

  @doc """
  Answer a `snapshot_request` from the Hub. `scope` is a JSON-shaped map
  with a `"kind"` field. Unknown kinds yield `%{"error" => ...}` so the
  caller can decide what to do.
  """
  def snapshot(%{"kind" => "campaigns_for", "discord_id" => did}) do
    %{"campaigns" => list_campaigns_for(did) |> Enum.map(&serialize/1)}
  end

  def snapshot(%{"kind" => "campaign", "id" => id, "viewer_discord_id" => viewer}) do
    cond do
      not member?(id, viewer) ->
        %{"forbidden" => true}

      true ->
        case get_campaign(id) do
          nil ->
            %{"not_found" => true}

          c ->
            active = active_session_for(id)

            utterances =
              case active do
                nil -> []
                s -> list_utterances(s.id)
              end

            markers =
              case active do
                nil -> []
                s -> list_markers(s.id)
              end

            epos =
              case get_epos_entry(id) do
                nil -> nil
                entry -> serialize(entry)
              end

            %{
              "campaign" => serialize(c),
              "sessions" => list_sessions(id) |> Enum.map(&serialize/1),
              "members" => list_members(id) |> Enum.map(&serialize/1),
              "invites" => list_invites(id) |> Enum.map(&serialize/1),
              "active_session" => active && serialize(active),
              "utterances" => Enum.map(utterances, &serialize/1),
              "markers" => Enum.map(markers, &serialize/1),
              "epos" => epos,
              "epos_history" => list_epos_history(id) |> Enum.map(&serialize/1)
            }
        end
    end
  end

  def snapshot(%{"kind" => "active_session", "campaign_id" => cid}) do
    case active_session_for(cid) do
      nil -> %{"session_id" => nil}
      s -> %{"session_id" => s.id}
    end
  end

  def snapshot(%{"kind" => "invite", "token" => token}) do
    case get_invite(token) do
      nil ->
        %{"not_found" => true}

      invite ->
        campaign =
          case get_campaign(invite.campaign_id) do
            nil -> nil
            c -> serialize(c)
          end

        %{"invite" => serialize(invite), "campaign" => campaign}
    end
  end

  def snapshot(scope), do: %{"error" => "unknown_scope", "scope" => inspect(scope)}

  # ─── helpers ────────────────────────────────────────────────────

  defp serialize(%{} = m) do
    # Convert DateTime / atoms / nested maps to JSON-friendly values.
    for {k, v} <- m, into: %{}, do: {to_string(k), wire(v)}
  end

  defp wire(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp wire(a) when is_atom(a) and not is_nil(a) and not is_boolean(a), do: Atom.to_string(a)
  defp wire(other), do: other

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end
end
