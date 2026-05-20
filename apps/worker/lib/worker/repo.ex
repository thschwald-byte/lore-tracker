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
      {joined_at, avatar_url} =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, _, ts, avatar}] -> {ts, avatar}
          [] -> {DateTime.utc_now(), nil}
        end

      :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url})
    end)

    :ok
  end

  def get_user(discord_id) do
    case transaction(fn -> :mnesia.read(S.users(), discord_id) end) do
      [{_, did, name, joined_at, avatar_url}] ->
        %{discord_id: did, display_name: name, joined_at: joined_at, avatar_url: avatar_url}

      [] ->
        nil
    end
  end

  @doc """
  Map of discord_id → display_name for every user the campaign's members
  set covers. Used to resolve raw discord_ids in the UI to friendly names.
  Owner and member-discord-ids that don't yet have a user record fall back
  to the raw id at the call site.
  """
  def users_for_campaign(campaign_id) do
    discord_ids =
      list_members(campaign_id)
      |> Enum.map(& &1.discord_id)

    fetch_users(discord_ids)
  end

  @doc """
  Map of discord_id → display_name for every owner of the campaigns the
  given viewer has access to (i.e. all campaigns where they're a member).
  Used by the Dashboard owner-pill.
  """
  def users_for_dashboard(viewer_discord_id) do
    owner_ids =
      list_campaigns_for(viewer_discord_id)
      |> Enum.map(& &1.owner_discord_id)
      |> Enum.uniq()

    fetch_users(owner_ids)
  end

  # Returns %{discord_id => %{"display_name" => name, "avatar_url" => url | nil}}.
  # Fallback: if a user-record doesn't exist yet, display_name = discord_id,
  # avatar_url = nil. The UI's `avatar/1` helper computes a Discord-default
  # avatar from the discord_id in that case.
  defp fetch_users(discord_ids) do
    discord_ids
    |> Enum.uniq()
    |> Enum.into(%{}, fn did ->
      case transaction(fn -> :mnesia.read(S.users(), did) end) do
        [{_, _, name, _, avatar}] ->
          {did, %{"display_name" => name, "avatar_url" => avatar}}

        [] ->
          {did, %{"display_name" => did, "avatar_url" => nil}}
      end
    end)
  end

  # ─── campaigns ──────────────────────────────────────────────────

  def get_campaign(id) do
    case transaction(fn -> :mnesia.read(S.campaigns(), id) end) do
      [{_, id, name, icon, theme, status, owner, created_at, flavors}] ->
        %{
          id: id,
          name: name,
          icon_url: icon,
          theme_blurb: theme,
          status: status,
          owner_discord_id: owner,
          created_at: created_at,
          flavors: normalize_flavors(flavors)
        }

      [] ->
        nil
    end
  end

  defp normalize_flavors(m) when is_map(m), do: m
  defp normalize_flavors(s) when is_binary(s) and s != "", do: %{"base" => s}
  defp normalize_flavors(_), do: %{}

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
    |> Enum.map(fn row -> elem(row, 2) end)
    |> Enum.uniq()
  end

  # ─── sessions ───────────────────────────────────────────────────

  def list_sessions(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.sessions(), campaign_id, :campaign_id)
    end)
    |> Enum.map(&row_to_session/1)
    |> Enum.sort_by(& &1.number)
  end

  def get_session(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.sessions(), session_id) end) do
      [row] -> row_to_session(row)
      [] -> nil
    end
  end

  defp row_to_session({_, id, cid, num, name, status, sched, started, ended}) do
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
  end

  # ─── members ────────────────────────────────────────────────────

  def list_members(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), campaign_id, :campaign_id)
    end)
    |> Enum.map(&member_row_to_map/1)
  end

  defp member_row_to_map({_, _key, cid, did, role, at, character_name}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
  end

  @doc """
  Map of `discord_id → character_name` for the given campaign — only entries
  where an alias is actually set (nil entries excluded). Used by the Hub
  display layer to override the discord-display-name fallback chain.
  """
  def character_names_for(campaign_id) do
    list_members(campaign_id)
    |> Enum.flat_map(fn
      %{discord_id: did, character_name: name} when is_binary(name) and name != "" ->
        [{did, name}]

      _ ->
        []
    end)
    |> Map.new()
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

  @doc """
  All utterances across every session of `campaign_id`, oldest first.
  Used by Protokoll so prior sessions remain visible when a new recording
  starts.
  """
  def list_utterances_for_campaign(campaign_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)

    list_sessions(campaign_id)
    |> Enum.flat_map(&list_utterances(&1.id, limit: limit))
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.take(-limit)
  end

  @doc "All markers across every session of `campaign_id`, oldest first."
  def list_markers_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(&list_markers(&1.id))
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end

  @doc "First non-completed session for a campaign (or nil)."
  def active_session_for(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.find(fn s -> s.status in [:recording, :paused] end)
  end

  @doc "Most-recently-ended session for a campaign (or nil)."
  def last_completed_session_for(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.filter(fn s -> s.status == :completed and s.ended_at end)
    |> Enum.sort_by(& &1.ended_at, {:desc, DateTime})
    |> List.first()
  end

  @doc """
  Most recently completed session for a campaign that actually has
  utterances. Used by the Protokoll display so a stop with no audio
  doesn't blank out the column.
  """
  def last_session_with_utterances(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.filter(fn s -> s.status == :completed and s.ended_at end)
    |> Enum.sort_by(& &1.ended_at, {:desc, DateTime})
    |> Enum.find(fn s -> list_utterances(s.id, limit: 1) != [] end)
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

  # ─── summaries / chronik ────────────────────────────────────────

  def get_session_summary(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_summaries(), session_id) end) do
      [{_, sid, cid, content, generated_at, source}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          content_md: content,
          generated_at: generated_at,
          source: source
        }

      [] ->
        nil
    end
  end

  def list_session_summaries(campaign_id) when is_binary(campaign_id) do
    # Sortierung nach Session-Nummer (Issue #24): die Spalte soll
    # chronologisch nach Session-Verlauf lesen — Session 1 oben, neueste
    # Session unten — NICHT nach generated_at (wann die LLM-Pipeline den
    # Resümee-Text erzeugt hat). Fallback auf große Zahl wenn die Session
    # selbst inzwischen gelöscht wurde, damit Orphan-Resümees ans Ende
    # sortieren statt zu crashen.
    sessions_by_id =
      campaign_id |> list_sessions() |> Enum.into(%{}, &{&1.id, &1})

    transaction(fn ->
      :mnesia.index_read(S.session_summaries(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, content, generated_at, source} ->
      %{
        session_id: sid,
        campaign_id: cid,
        content_md: content,
        generated_at: generated_at,
        source: source
      }
    end)
    |> Enum.sort_by(fn s ->
      case sessions_by_id[s.session_id] do
        %{number: n} -> n
        _ -> 999_999
      end
    end)
  end

  def list_chronik_entries(campaign_id) when is_binary(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.chronik_entries(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, id, cid, in_game_date, sort_key, label, summary, sid} ->
      %{
        id: id,
        campaign_id: cid,
        in_game_date: in_game_date,
        in_game_sort_key: sort_key,
        label: label,
        summary: summary,
        session_id: sid
      }
    end)
    |> Enum.sort_by(& &1.in_game_sort_key)
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
    campaigns = list_campaigns_for(did)

    %{
      "campaigns" =>
        Enum.map(campaigns, fn c ->
          c
          |> Map.put(:active_recording, active_recording_state(c.id))
          |> Map.put(:members, dashboard_members(c.id))
          |> serialize()
        end),
      "users" => users_for_dashboard_all_members(campaigns, did)
    }
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

            # Protokoll shows the full transcript history across all sessions
            # (chronological). Starting a fresh recording must not blank out
            # prior sessions.
            utterances = list_utterances_for_campaign(id)
            markers = list_markers_for_campaign(id)

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
              "epos_history" => list_epos_history(id) |> Enum.map(&serialize/1),
              "summaries" => list_session_summaries(id) |> Enum.map(&serialize/1),
              "chronik" => list_chronik_entries(id) |> Enum.map(&serialize/1),
              "users" => users_for_campaign(id),
              "character_names" => character_names_for(id),
              "transcribe_mode" => Atom.to_string(Worker.Settings.get(:transcribe_mode, :batch))
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

  def snapshot(%{"kind" => "settings"}) do
    %{
      "settings" => Worker.Settings.snapshot() |> serialize(),
      "any_active_recording" => any_active_recording?()
    }
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

  defp active_recording_state(campaign_id) do
    case active_session_for(campaign_id) do
      nil -> nil
      %{status: status} -> Atom.to_string(status)
    end
  end

  defp dashboard_members(campaign_id) do
    Enum.map(list_members(campaign_id), fn m ->
      %{"discord_id" => m.discord_id, "role" => Atom.to_string(m.role)}
    end)
  end

  # Dashboard now needs display_names for every member of every campaign
  # the viewer has access to (not just the owners). Reuse fetch_users/1
  # with the union of all member-discord-ids + the viewer themselves.
  defp users_for_dashboard_all_members(campaigns, viewer_did) do
    ids =
      campaigns
      |> Enum.flat_map(fn c -> list_members(c.id) end)
      |> Enum.map(& &1.discord_id)
      |> Enum.concat([viewer_did])

    fetch_users(ids)
  end

  # True if any campaign on this worker has a session currently in
  # :recording or :paused — used by the EinstellungenLive toggle to
  # disable mid-session mode switches.
  defp any_active_recording? do
    transaction(fn ->
      :mnesia.foldl(
        fn {_, _, _, _, _, status, _, _, _}, acc -> acc or status in [:recording, :paused] end,
        false,
        S.sessions()
      )
    end)
  end

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
