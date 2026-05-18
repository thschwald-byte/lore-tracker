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
  @sessions :worker_sessions

  def worker_state, do: @worker_state
  def users, do: @users
  def campaigns, do: @campaigns
  def campaign_members, do: @campaign_members
  def sessions, do: @sessions

  def all_tables,
    do: [@worker_state, @users, @campaigns, @campaign_members, @sessions]

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
  end

  @doc "Composite PK helper for campaign_members."
  def member_key(campaign_id, discord_id), do: {campaign_id, discord_id}
end
