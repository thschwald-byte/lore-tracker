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
      @epos_history
    ]

  def bootstrap! do
    :ok =
      Shared.Mnesia.ensure_table!(@worker_state,
        attributes: [:key, :value],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@users,
        attributes: [:discord_id, :display_name, :joined_at],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@campaigns,
        attributes: [:id, :name, :icon_url, :theme_blurb, :status, :owner_discord_id, :created_at],
        type: :set
      )

    :ok =
      Shared.Mnesia.ensure_table!(@campaign_members,
        attributes: [:cm_key, :campaign_id, :discord_id, :role, :joined_at],
        type: :set,
        index: [:campaign_id, :discord_id]
      )

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
  end

  @doc "Composite PK helper for campaign_members."
  def member_key(campaign_id, discord_id), do: {campaign_id, discord_id}
end
