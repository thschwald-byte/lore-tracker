defmodule Hub.Schema.WorkerToken do
  @moduledoc """
  Ecto schema for issued worker-pairing tokens (Postgres adapter).
  """

  use Ecto.Schema

  @primary_key {:token, :string, autogenerate: false}
  schema "worker_tokens" do
    field :worker_id, :string
    field :admin_discord_id, :string
    field :issued_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
  end
end
