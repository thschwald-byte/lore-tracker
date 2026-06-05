defmodule Worker.Repo.Users do
  @moduledoc """
  Issue #581 (God-Module-Split aus `Worker.Repo`): User-/Membership-zentrierte
  Mnesia-Reads. `Worker.Repo` delegiert die öffentliche API hierher (Call-Sites
  unverändert). Geteilte Helfer (`transaction/1`, `fetch_users/1`,
  `member_row_deleted?/1`, readers) bleiben in `Worker.Repo` und werden via
  `import` erreichbar gemacht — `except:` die hier selbst definierten Funktionen
  (sonst Klausel-Kollision mit den Façade-Delegates).
  """
  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo,
    except: [
      upsert_user: 2,
      get_user: 1,
      audio_consent: 1,
      list_all_users: 0,
      admin_exists?: 0,
      last_admin?: 1,
      last_spielleiter_campaigns_for: 1,
      users_for_campaign: 1,
      users_for_dashboard: 1
    ]

  @spec upsert_user(String.t(), String.t()) :: :ok
  def upsert_user(discord_id, display_name)
      when is_binary(discord_id) and is_binary(display_name) do
    transaction(fn ->
      {joined_at, avatar_url, role, cap} =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, _, ts, avatar, r, c}] -> {ts, avatar, r, c}
          [] -> {DateTime.utc_now(), nil, :spieler, nil}
        end

      :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role, cap})
    end)

    :ok
  end

  def get_user(discord_id) do
    case transaction(fn -> :mnesia.read(S.users(), discord_id) end) do
      [{_, did, name, joined_at, avatar_url, role, cap}] ->
        %{
          discord_id: did,
          display_name: name,
          joined_at: joined_at,
          avatar_url: avatar_url,
          role: role,
          monthly_spend_cap_usd: cap
        }

      [] ->
        nil
    end
  end

  @doc """
  Liefert den Audio-Consent-Stand für einen User (Issue #64). Returns
  `%{version, accepted_at}` falls der User akzeptiert hat, sonst `nil`.
  """
  def audio_consent(discord_id) do
    case transaction(fn -> :mnesia.read(S.audio_consents(), discord_id) end) do
      [{_, _did, version, accepted_at}] -> %{version: version, accepted_at: accepted_at}
      [] -> nil
    end
  end

  @doc "Liste aller User auf dieser Instance (für Admin-UI #35)."
  def list_all_users do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.users()) end)
    |> Enum.map(fn {_, did, name, joined_at, avatar_url, role, cap} ->
      %{
        discord_id: did,
        display_name: name,
        joined_at: joined_at,
        avatar_url: avatar_url,
        role: role,
        monthly_spend_cap_usd: cap
      }
    end)
    |> Enum.sort_by(& &1.display_name)
  end

  @doc "True wenn auf der Instance mindestens ein User mit role=:admin existiert."
  def admin_exists? do
    transaction(fn ->
      :mnesia.match_object({S.users(), :_, :_, :_, :_, :admin, :_}) != []
    end)
  end

  @doc """
  Issue #57: True wenn `discord_id` der einzige :admin auf der Instance ist.
  Vom Hub-Pre-Delete-Check verwendet (Last-Admin-Lockout-Schutz).
  """
  @spec last_admin?(String.t()) :: boolean()
  def last_admin?(discord_id) when is_binary(discord_id) do
    admins =
      transaction(fn ->
        :mnesia.match_object({S.users(), :_, :_, :_, :_, :admin, :_})
      end)
      |> Enum.map(fn {_, did, _, _, _, _, _} -> did end)

    admins == [discord_id]
  end

  @doc """
  Issue #57: Liste der Kampagnen in denen `discord_id` der **letzte**
  Spielleiter ist. Diese brauchen vor User-Delete eine Resolution (neuer
  SL per MemberRolePromoted oder CampaignArchived).

  Returnt `[%{id, name, members: [spieler_map_list]}]` — `members` sind die
  promotebaren Spieler dieser Kampagne (Spielleiter ohne Self).
  """
  @spec last_spielleiter_campaigns_for(String.t()) :: [
          %{id: String.t(), name: String.t(), members: [map()]}
        ]
  def last_spielleiter_campaigns_for(discord_id) when is_binary(discord_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.filter(fn {_, _key, _cid, _did, role, _, _, _} -> role == :spielleiter end)
    |> Enum.flat_map(fn {_, _key, cid, _did, _, _, _, _} ->
      other_sls =
        list_members(cid)
        |> Enum.filter(&(&1.role == :spielleiter and &1.discord_id != discord_id))

      if other_sls == [] do
        name =
          case transaction(fn -> :mnesia.read(S.campaigns(), cid) end) do
            [{_, ^cid, n, _, _, _, _, _, _, _}] -> n
            _ -> cid
          end

        spieler =
          list_members(cid)
          |> Enum.filter(&(&1.role == :spieler and &1.discord_id != discord_id))

        [%{id: cid, name: name, members: spieler}]
      else
        []
      end
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
end
