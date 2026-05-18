defmodule Worker.Schema.Mnesia do
  @moduledoc """
  Table definitions for the worker's locally-replicated state.

  M2 only needs `worker_state` (singleton key/value) and `worker_users`.
  More tables (campaigns, sessions, utterances, ...) are added by the
  materializer in M4+.
  """

  # Tables ─────────────────────────────────────────────────────────
  @worker_state :worker_state
  @users :worker_users

  def worker_state, do: @worker_state
  def users, do: @users

  def all_tables, do: [@worker_state, @users]

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
  end
end
