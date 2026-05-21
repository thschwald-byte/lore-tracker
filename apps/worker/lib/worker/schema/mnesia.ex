defmodule Worker.Schema.Mnesia do
  @moduledoc """
  Table definitions for the worker's locally-replicated state.

  Each table is created idempotently from `bootstrap!/0`. Materializer
  writes; LiveView reads via `Worker.Repo`.
  """

  # Singletons / known entities ─────────────────────────────────────
  @worker_state :worker_state
  @users :worker_users

  # Domain ──────────────────────────────────────────────────────────
  @campaigns :worker_campaigns
  @campaign_members :worker_campaign_members
  @campaign_invites :worker_campaign_invites
  @sessions :worker_sessions
  @utterances :worker_utterances
  @markers :worker_markers
  @epos_entries :worker_epos_entries
  @epos_history :worker_epos_history
  @session_summaries :worker_session_summaries
  @session_faithfulness_scores :worker_session_faithfulness_scores
  @chronik_entries :worker_chronik_entries
  @probelauf_runs :worker_probelauf_runs
  @probelauf_sweeps :worker_probelauf_sweeps

  def worker_state, do: @worker_state
  def users, do: @users
  def campaigns, do: @campaigns
  def campaign_members, do: @campaign_members
  def campaign_invites, do: @campaign_invites
  def sessions, do: @sessions
  def utterances, do: @utterances
  def markers, do: @markers
  def epos_entries, do: @epos_entries
  def epos_history, do: @epos_history
  def session_summaries, do: @session_summaries
  def session_faithfulness_scores, do: @session_faithfulness_scores
  def chronik_entries, do: @chronik_entries
  def probelauf_runs, do: @probelauf_runs
  def probelauf_sweeps, do: @probelauf_sweeps

  def all_tables,
    do: [
      @worker_state,
      @users,
      @campaigns,
      @campaign_members,
      @campaign_invites,
      @sessions,
      @utterances,
      @markers,
      @epos_entries,
      @epos_history,
      @session_summaries,
      @session_faithfulness_scores,
      @chronik_entries,
      @probelauf_runs,
      @probelauf_sweeps
    ]

  def bootstrap! do
    :ok =
      Shared.Mnesia.ensure_table!(@worker_state,
        attributes: [:key, :value],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@users,
        attributes: [:discord_id, :display_name, :joined_at, :avatar_url, :role],
        type: :set
      )

    :ok = migrate_users_avatar_url!()
    :ok = migrate_users_role!()

    :ok =
      Shared.Mnesia.ensure_table!(@campaigns,
        attributes: [
          :id,
          :name,
          :icon_url,
          :theme_blurb,
          :status,
          :owner_discord_id,
          :created_at,
          :flavors
        ],
        type: :set
      )

    :ok = migrate_campaigns_flavor!()
    :ok = migrate_campaigns_flavors!()

    :ok =
      Shared.Mnesia.ensure_table!(@campaign_members,
        attributes: [
          :cm_key,
          :campaign_id,
          :discord_id,
          :role,
          :joined_at,
          :character_name
        ],
        type: :set,
        index: [:campaign_id, :discord_id]
      )

    :ok = migrate_campaign_members_character_name!()

    :ok =
      Shared.Mnesia.ensure_table!(@sessions,
        attributes: [
          :id,
          :campaign_id,
          :number,
          :name,
          :status,
          :scheduled_for,
          :started_at,
          :ended_at
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@campaign_invites,
        attributes: [
          :token,
          :campaign_id,
          :created_by_discord_id,
          :created_at,
          :expires_at,
          :status,
          :redeemed_by_discord_id
        ],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@utterances,
        attributes: [
          :id,
          :session_id,
          :discord_id,
          :timestamp,
          :text,
          :confidence,
          :status
        ],
        type: :set,
        index: [:session_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@markers,
        attributes: [:id, :session_id, :at_ts, :kind, :label],
        type: :set,
        index: [:session_id]
      )

    # One Epos entry per campaign for M7 (entry_id == campaign_id). The schema
    # has a parent_id slot so M7+ can add a chapter tree without a migration.
    :ok =
      Shared.Mnesia.ensure_table!(@epos_entries,
        attributes: [:id, :campaign_id, :parent_id, :content_md, :updated_at],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@epos_history,
        attributes: [
          :id,
          :entry_id,
          :content_md,
          :edited_at,
          :edited_by,
          :source,
          :seq
        ],
        type: :set,
        index: [:entry_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@session_summaries,
        attributes: [:session_id, :campaign_id, :content_md, :generated_at, :source],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #11 Phase 2: Faithfulness-Score pro Session-Resümee.
    # claims_json = Jason-encoded List of %{text, span, label} — bleibt JSON
    # weil Mnesia-Records keine verschachtelten Listen gut handhaben.
    :ok =
      Shared.Mnesia.ensure_table!(@session_faithfulness_scores,
        attributes: [:session_id, :campaign_id, :score, :claims_json, :scored_at],
        type: :set,
        index: [:campaign_id]
      )

    :ok =
      Shared.Mnesia.ensure_table!(@chronik_entries,
        attributes: [
          :id,
          :campaign_id,
          :in_game_date,
          :in_game_sort_key,
          :label,
          :summary,
          :session_id
        ],
        type: :set,
        index: [:campaign_id]
      )

    # Issue #74: LLM-Probelauf. Pro Probelauf eine Row mit gemessenen
    # Per-Stage-Metriken und Settings-Snapshot. UI zeigt aktuell nur den
    # letzten, aber spätere Phasen können hier historisch vergleichen.
    # Issue #88 (Phase 2a): `sweep_id` + `sweep_variant` (Map oder nil)
    # taggen Runs, die Teil eines Sweep-Laufs sind.
    :ok =
      Shared.Mnesia.ensure_table!(@probelauf_runs,
        attributes: [
          :run_id,
          :started_at,
          :finished_at,
          :started_by,
          :sessions,
          :settings_snapshot,
          :sweep_id,
          :sweep_variant
        ],
        type: :set,
        index: [:sweep_id]
      )

    :ok = migrate_probelauf_runs_sweep_tags!()

    # Issue #88 (Phase 2a): Sweep-Header. Verlinkt N probelauf_runs via
    # gemeinsamem sweep_id.
    :ok =
      Shared.Mnesia.ensure_table!(@probelauf_sweeps,
        attributes: [
          :sweep_id,
          :started_at,
          :finished_at,
          :started_by,
          :stage,
          :models,
          :default_model
        ],
        type: :set
      )
  end

  @doc "Composite PK helper for campaign_members."
  def member_key(campaign_id, discord_id), do: {campaign_id, discord_id}

  # Idempotent in-place upgrade for the users table to add an :avatar_url
  # column (Issue #6). Old rows have arity 4:
  #   {table, discord_id, display_name, joined_at}
  # New rows have arity 5:
  #   {table, discord_id, display_name, joined_at, avatar_url}
  #
  # Skip-Check ist „avatar_url ist schon in den Spalten" — robust gegen
  # weitere Migrations (z.B. migrate_users_role!), die zusätzliche Spalten
  # *hinter* :avatar_url anhängen. Vergleich gegen die exakte 4-Feld-Zielform
  # würde sonst auf einer schon weiter-migrierten Tabelle erneut feuern und
  # an einem 6-Tuple-Row mit function_clause crashen (Issue #42).
  defp migrate_users_avatar_url! do
    current_attrs = :mnesia.table_info(@users, :attributes)

    if :avatar_url in current_attrs do
      :ok
    else
      target_attrs = [:discord_id, :display_name, :joined_at, :avatar_url]
      transform = fn {tbl, did, name, joined_at} -> {tbl, did, name, joined_at, nil} end
      {:atomic, :ok} = :mnesia.transform_table(@users, transform, target_attrs)
      :ok
    end
  end

  # Idempotent in-place upgrade for users to add a :role field (Issue #34).
  # arity 5 → 6. Default für bestehende User: :spieler. Erst-gepairter
  # User pro Instance bekommt :admin per UserRoleSet-Event aus dem
  # Pairing-Flow.
  defp migrate_users_role! do
    current_attrs = :mnesia.table_info(@users, :attributes)

    if :role in current_attrs do
      :ok
    else
      target_attrs = [:discord_id, :display_name, :joined_at, :avatar_url, :role]

      transform = fn {tbl, did, name, joined_at, avatar} ->
        {tbl, did, name, joined_at, avatar, :spieler}
      end

      {:atomic, :ok} = :mnesia.transform_table(@users, transform, target_attrs)
      :ok
    end
  end

  # Idempotent in-place upgrade for the campaign_members table to add a
  # :character_name column (Issue #2). Old rows have arity 6:
  #   {table, cm_key, campaign_id, discord_id, role, joined_at}
  # New rows have arity 7 (one extra trailing field):
  #   {table, cm_key, campaign_id, discord_id, role, joined_at, character_name}
  # If the table is already at the new shape, transform_table is a no-op.
  defp migrate_campaign_members_character_name! do
    current_attrs = :mnesia.table_info(@campaign_members, :attributes)
    target_attrs = [:cm_key, :campaign_id, :discord_id, :role, :joined_at, :character_name]

    if current_attrs == target_attrs do
      :ok
    else
      transform = fn
        {tbl, key, cid, did, role, joined_at} ->
          {tbl, key, cid, did, role, joined_at, nil}

        already_upgraded when tuple_size(already_upgraded) == 7 ->
          already_upgraded
      end

      {:atomic, :ok} =
        :mnesia.transform_table(@campaign_members, transform, target_attrs)

      :ok
    end
  end

  # Idempotent in-place upgrade für campaigns: trailende :flavor-Spalte
  # (LLM-Stilanweisung). arity 7→8. Default nil. Wird durch
  # migrate_campaigns_flavors! nochmal von :flavor → :flavors aufgewertet;
  # bleibt hier als Zwischenschritt für DBs, die noch auf arity 7 sind.
  defp migrate_campaigns_flavor! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    target_attrs_old = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavor
    ]

    target_attrs_new = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavors
    ]

    cond do
      current_attrs == target_attrs_old or current_attrs == target_attrs_new ->
        :ok

      true ->
        transform = fn
          {tbl, id, name, icon, blurb, status, owner, created_at} ->
            {tbl, id, name, icon, blurb, status, owner, created_at, nil}

          already_upgraded when tuple_size(already_upgraded) == 9 ->
            already_upgraded
        end

        {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs_old)
        :ok
    end
  end

  # Idempotent in-place upgrade: einzelnes :flavor (string|nil) → :flavors
  # (map). arity bleibt 8, nur das letzte Element wechselt den Shape.
  # Altdaten: string → %{"base" => string}; nil → %{}; map → identity.
  defp migrate_campaigns_flavors! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    target_attrs = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavors
    ]

    if current_attrs == target_attrs do
      :ok
    else
      transform = fn
        {tbl, id, name, icon, blurb, status, owner, created_at, flavor} ->
          new_flavors =
            case flavor do
              nil -> %{}
              "" -> %{}
              s when is_binary(s) -> %{"base" => s}
              m when is_map(m) -> m
              _ -> %{}
            end

          {tbl, id, name, icon, blurb, status, owner, created_at, new_flavors}
      end

      {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs)
      :ok
    end
  end

  # Issue #88 (Phase 2a): probelauf_runs bekommt sweep_id + sweep_variant
  # als optionale Felder. arity 6 → 8. Default für bestehende Runs:
  # beide nil (= waren kein Teil eines Sweeps).
  defp migrate_probelauf_runs_sweep_tags! do
    current_attrs = :mnesia.table_info(@probelauf_runs, :attributes)

    if :sweep_id in current_attrs do
      :ok
    else
      target_attrs = [
        :run_id,
        :started_at,
        :finished_at,
        :started_by,
        :sessions,
        :settings_snapshot,
        :sweep_id,
        :sweep_variant
      ]

      transform = fn {tbl, run_id, started_at, finished_at, started_by, sessions, snap} ->
        {tbl, run_id, started_at, finished_at, started_by, sessions, snap, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@probelauf_runs, transform, target_attrs)
      {:atomic, :ok} = :mnesia.add_table_index(@probelauf_runs, :sweep_id)
      :ok
    end
  end
end
