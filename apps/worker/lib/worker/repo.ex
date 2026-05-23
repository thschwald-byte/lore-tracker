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
      {joined_at, avatar_url, role} =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, _, ts, avatar, r}] -> {ts, avatar, r}
          [] -> {DateTime.utc_now(), nil, :spieler}
        end

      :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role})
    end)

    :ok
  end

  def get_user(discord_id) do
    case transaction(fn -> :mnesia.read(S.users(), discord_id) end) do
      [{_, did, name, joined_at, avatar_url, role}] ->
        %{
          discord_id: did,
          display_name: name,
          joined_at: joined_at,
          avatar_url: avatar_url,
          role: role
        }

      [] ->
        nil
    end
  end

  @doc "Liste aller User auf dieser Instance (für Admin-UI #35)."
  def list_all_users do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.users()) end)
    |> Enum.map(fn {_, did, name, joined_at, avatar_url, role} ->
      %{
        discord_id: did,
        display_name: name,
        joined_at: joined_at,
        avatar_url: avatar_url,
        role: role
      }
    end)
    |> Enum.sort_by(& &1.display_name)
  end

  @doc "True wenn auf der Instance mindestens ein User mit role=:admin existiert."
  def admin_exists? do
    transaction(fn ->
      :mnesia.match_object({S.users(), :_, :_, :_, :_, :admin}) != []
    end)
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
  Map of discord_id → display_name for every Spielleiter der Kampagnen,
  in denen `viewer_discord_id` Member ist. Issue #140: Owner-Pill ist
  jetzt SL-Pill — zeigt den ersten Spielleiter aus der Membership-Liste.
  """
  def users_for_dashboard(viewer_discord_id) do
    sl_ids =
      list_campaigns_for(viewer_discord_id)
      |> Enum.flat_map(fn c ->
        list_members(c.id)
        |> Enum.filter(&(&1.role == :spielleiter))
        |> Enum.map(& &1.discord_id)
      end)
      |> Enum.uniq()

    fetch_users(sl_ids)
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
        [{_, _, name, _, avatar, _role}] ->
          {did, %{"display_name" => name, "avatar_url" => avatar}}

        [] ->
          {did, %{"display_name" => did, "avatar_url" => nil}}
      end
    end)
  end

  # ─── campaigns ──────────────────────────────────────────────────

  def get_campaign(id) do
    case transaction(fn -> :mnesia.read(S.campaigns(), id) end) do
      [{_, id, name, icon, theme, status, created_at, flavors}] ->
        # Issue #140: Das Schema speichert kein owner_discord_id mehr. Der
        # erste Spielleiter aus der Members-Liste wird hier als
        # `:owner_discord_id` exponiert, damit bestehende Konsumenten
        # (Hub-Permissions-Fallback, Recording-Leader-Routing,
        # Dashboard-Pille) nicht aufgerissen werden müssen. Echtes
        # Permission-Gating soll trotzdem über `campaign_role/2` laufen.
        %{
          id: id,
          name: name,
          icon_url: icon,
          theme_blurb: theme,
          status: status,
          owner_discord_id: first_spielleiter(id),
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
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc "Liste aller Kampagnen auf dieser Instance (für Admin-UI #35)."
  def all_campaigns do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.campaigns()) end)
    |> Enum.map(fn {_, id, name, icon, theme, status, created_at, flavors} ->
      %{
        id: id,
        name: name,
        icon_url: icon,
        theme_blurb: theme,
        status: status,
        owner_discord_id: first_spielleiter(id),
        created_at: created_at,
        flavors: normalize_flavors(flavors)
      }
    end)
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # Probelauf-Campaigns (Issue #74) sollen NICHT in normalen Listen
  # auftauchen — sie sind ephemer und werden nach dem Lauf cascade-deleted.
  # ID-Prefix-Match reicht (Worker.Probelauf seedet mit "probelauf-" + uuid).
  defp probelauf_campaign?(%{id: id}) when is_binary(id),
    do: String.starts_with?(id, "probelauf-")

  defp probelauf_campaign?(_), do: false

  def list_campaign_ids_for(discord_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
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
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.map(&member_row_to_map/1)
  end

  # Issue #133 (Etappe 3d): Tombstone-Filter. Pre-Migration-Rows haben arity
  # 7 ohne deleted_at → nicht tombstone'd.
  defp member_row_deleted?({_, _key, _cid, _did, _role, _at, _name, deleted_at}),
    do: deleted_at != nil

  defp member_row_deleted?(_), do: false

  defp member_row_to_map({_, _key, cid, did, role, at, character_name, _deleted_at}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
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
      [row] -> not member_row_deleted?(row)
      [] -> false
    end
  end

  @doc """
  Per-Campaign-Rolle eines Users in einer Kampagne (Issue #140):
  `:spielleiter | :spieler | nil`. `nil` wenn nicht Member (oder
  Tombstoned). Quelle der Wahrheit: `campaign_members.role`.
  """
  def campaign_role(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [row] ->
        if member_row_deleted?(row), do: nil, else: elem(row, 4)

      [] ->
        nil
    end
  end

  @doc """
  Erster Spielleiter einer Kampagne als discord_id (oder nil falls keiner
  gefunden — sollte nur passieren wenn die Auto-Member-Migration aus
  Issue #140 für historische Daten noch nicht gelaufen ist).
  """
  def first_spielleiter(campaign_id) do
    list_members(campaign_id)
    |> Enum.find(&(&1.role == :spielleiter))
    |> case do
      %{discord_id: did} -> did
      nil -> nil
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
    |> Enum.reject(&utterance_row_deleted?/1)
    |> Enum.map(&utterance_row_to_map/1)
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.take(-limit)
  end

  # Issue #133 (Etappe 3d): Tombstone-Filter für utterances. Pre-Migration-
  # Rows haben arity 8 ohne deleted_at → nicht tombstone'd.
  defp utterance_row_deleted?({_, _id, _sid, _did, _ts, _text, _conf, _status, deleted_at}),
    do: deleted_at != nil

  defp utterance_row_deleted?(_), do: false

  defp utterance_row_to_map({_, id, sid, did, ts, text, conf, status, _deleted_at}) do
    %{
      id: id,
      session_id: sid,
      discord_id: did,
      timestamp: ts,
      text: text,
      confidence: conf,
      status: status
    }
  end

  defp utterance_row_to_map({_, id, sid, did, ts, text, conf, status}) do
    %{
      id: id,
      session_id: sid,
      discord_id: did,
      timestamp: ts,
      text: text,
      confidence: conf,
      status: status
    }
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

  # Issue #11 Phase 2: Faithfulness-Score pro Session.
  # claims_json wird hier eager dekodiert — die UI braucht Claim-Texte für
  # das Click-to-Expand-Detail.
  def get_faithfulness_score(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_faithfulness_scores(), session_id) end) do
      [{_, sid, cid, score, claims_json, scored_at}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          score: score,
          claims: decode_claims(claims_json),
          scored_at: scored_at
        }

      [] ->
        nil
    end
  end

  def list_faithfulness_scores(campaign_id) when is_binary(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.session_faithfulness_scores(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, score, claims_json, scored_at} ->
      %{
        session_id: sid,
        campaign_id: cid,
        score: score,
        claims: decode_claims(claims_json),
        scored_at: scored_at
      }
    end)
  end

  defp decode_claims(nil), do: []
  defp decode_claims(""), do: []

  defp decode_claims(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_claims(_), do: []

  def list_chronik_entries(campaign_id) when is_binary(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.chronik_entries(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, id, cid, in_game_date, label, summary, sid} ->
      %{
        id: id,
        campaign_id: cid,
        in_game_date: in_game_date,
        label: label,
        summary: summary,
        session_id: sid
      }
    end)
    |> Enum.sort_by(&derive_chronik_sort_tuple(&1.in_game_date))
  end

  # Issue #135: Sort-Reihenfolge wird zur Lesezeit aus dem `in_game_date`-
  # String abgeleitet — kein persistiertes derived value mehr. Tuple-Layout:
  # `{family, primary, original}`. Familien-Priorität:
  #
  #   0 — Session/Tag/Day/Akt + Zahl (häufigste Form in der Praxis)
  #   1 — Jahres-Datum (z.B. "552 CY", "552 CY - Spring")
  #   2 — Narrativer Marker ("Aufbruch", "Erste Begegnung")
  #   9 — nil / leerer String (sortiert ans Ende)
  #
  # Innerhalb einer Familie sortiert die `primary`-Zahl numerisch; der
  # `original`-String bricht Ties stabil. Wenn neue LLM-Modelle weitere
  # Datumsformate emittieren, kommt eine zusätzliche Klausel dazu.
  @doc false
  def derive_chronik_sort_tuple(nil), do: {9, 0, ""}
  def derive_chronik_sort_tuple(""), do: {9, 0, ""}

  def derive_chronik_sort_tuple(date) when is_binary(date) do
    cond do
      n = leading_unit_number(date) ->
        {0, n, date}

      year_n = year_with_optional_season(date) ->
        {1, year_n, date}

      true ->
        {2, 0, date}
    end
  end

  # Matches "Session 13", "Tag 38", "Day 14", "Akt 2", "Scene 5" — case-
  # insensitive, optional whitespace, leading number captured.
  defp leading_unit_number(date) do
    case Regex.run(~r/^\s*(?:session|tag|day|akt|szene|scene)\s+(\d+)/i, date) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # Matches "552 CY", "552 CY - Spring", "550 CY (Winter)" etc. Returns
  # year * 10 + season_bump so two events in the same year sort by season.
  defp year_with_optional_season(date) do
    case Regex.run(~r/(\d+)\s*CY/, date) do
      [_, y] ->
        season =
          cond do
            date =~ ~r/Spring/i -> 1
            date =~ ~r/Summer/i -> 2
            date =~ ~r/Autumn|Fall/i -> 3
            date =~ ~r/Winter/i -> 4
            true -> 0
          end

        String.to_integer(y) * 10 + season

      _ ->
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

  @doc """
  Letzter beendeter Single-Probelauf (Issue #74) — also ein Run der **nicht**
  Teil eines Sweeps war. Als Map oder nil. Sortiert nach finished_at
  (sekundärer Sort gegen run_id für Determinismus).
  """
  def last_probelauf_run do
    all_probelauf_runs()
    |> Enum.filter(fn r -> r.finished_at && is_nil(r.sweep_id) end)
    |> Enum.sort_by(fn r -> {DateTime.to_unix(r.finished_at, :microsecond), r.run_id} end, :desc)
    |> List.first()
  end

  @doc """
  Alle Probelauf-Runs (Phase 1 + Phase 2). Jede Row als Map mit nun
  optionalen `sweep_id` + `sweep_variant` Feldern (Issue #88).
  """
  def all_probelauf_runs do
    transaction(fn ->
      :mnesia.match_object({S.probelauf_runs(), :_, :_, :_, :_, :_, :_, :_, :_})
    end)
    |> Enum.map(fn {_, run_id, started_at, finished_at, started_by, sessions, settings, sweep_id,
                    sweep_variant} ->
      %{
        run_id: run_id,
        started_at: started_at,
        finished_at: finished_at,
        started_by: started_by,
        sessions: sessions,
        settings_snapshot: settings,
        sweep_id: sweep_id,
        sweep_variant: sweep_variant
      }
    end)
  end

  @doc """
  Letzter beendeter Sweep (Issue #88, Phase 2a) als Map mit aggregierter
  Variants-Liste, oder nil. Aggregation pro (stage, model): Median-Dauer
  über alle Sessions, Success-Rate über alle Stages aller Sessions.
  """
  def last_probelauf_sweep do
    sweeps =
      transaction(fn ->
        :mnesia.match_object({S.probelauf_sweeps(), :_, :_, :_, :_, :_, :_, :_})
      end)
      |> Enum.map(fn {_, sweep_id, started_at, finished_at, started_by, stage, models,
                      default_model} ->
        %{
          sweep_id: sweep_id,
          started_at: started_at,
          finished_at: finished_at,
          started_by: started_by,
          stage: stage,
          models: models,
          default_model: default_model
        }
      end)
      |> Enum.filter(& &1.finished_at)
      |> Enum.sort_by(
        fn s -> {DateTime.to_unix(s.finished_at, :microsecond), s.sweep_id} end,
        :desc
      )

    case sweeps do
      [] ->
        nil

      [latest | _] ->
        runs_for_sweep =
          all_probelauf_runs()
          |> Enum.filter(fn r -> r.sweep_id == latest.sweep_id && r.finished_at end)

        Map.put(latest, :runs, runs_for_sweep)
    end
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
          active_invites = list_invites(c.id) |> Enum.filter(&(&1.status == :active))

          c
          |> Map.put(:active_recording, active_recording_state(c.id))
          |> Map.put(:members, dashboard_members(c.id))
          |> Map.put(:active_invites, active_invites)
          |> serialize()
        end),
      "users" => users_for_dashboard_all_members(campaigns, did),
      "viewer_role" => viewer_role(did)
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
              "faithfulness" => list_faithfulness_scores(id) |> Enum.map(&serialize/1),
              "chronik" => list_chronik_entries(id) |> Enum.map(&serialize/1),
              "users" => users_for_campaign(id),
              "character_names" => character_names_for(id),
              "transcribe_mode" => Atom.to_string(Worker.Settings.get(:transcribe_mode, :batch)),
              "viewer_role" => viewer_role(viewer)
            }
        end
    end
  end

  # Globale Rolle des Viewers (Issue #36). Wird im snapshot mitgegeben
  # damit die LV ohne extra round-trip die richtigen Permissions-Checks
  # machen kann.
  defp viewer_role(discord_id) do
    case get_user(discord_id) do
      %{role: role} -> Atom.to_string(role)
      _ -> "spieler"
    end
  end

  def snapshot(%{"kind" => "active_session", "campaign_id" => cid}) do
    case active_session_for(cid) do
      nil -> %{"session_id" => nil}
      s -> %{"session_id" => s.id}
    end
  end

  # Admin-UI (Issue #35): Liste aller User der Instance + Liste aller
  # Kampagnen für "Zu Kampagne hinzufügen"-Dropdown. Permission-Gate
  # liegt am LV — der ruft das nur wenn Permissions.can?(user, :view_admin).
  def snapshot(%{"kind" => "all_users"}) do
    %{
      "users" => list_all_users() |> Enum.map(&serialize/1),
      "campaigns" =>
        all_campaigns()
        |> Enum.map(fn c ->
          %{id: c.id, name: c.name, owner_discord_id: c.owner_discord_id}
          |> serialize()
        end)
    }
  end

  def snapshot(%{"kind" => "settings"}) do
    {available_models, ollama_error} =
      case Worker.LLM.Local.list_models() do
        {:ok, names} -> {names, nil}
        {:error, reason} -> {[], inspect(reason)}
      end

    %{
      "settings" => Worker.Settings.snapshot() |> serialize(),
      "any_active_recording" => any_active_recording?(),
      "available_models" => available_models,
      "ollama_error" => ollama_error
    }
  end

  def snapshot(%{"kind" => "probelauf"}) do
    %{
      "running" => Worker.Probelauf.running() |> serialize(),
      "last_run" => last_probelauf_run() |> serialize(),
      "last_sweep" => last_probelauf_sweep() |> serialize(),
      "available_models" =>
        case Worker.LLM.Local.list_models() do
          {:ok, names} -> names
          {:error, _} -> []
        end
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

  defp serialize(nil), do: nil

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
