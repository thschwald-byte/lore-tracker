defmodule Hub.Schema.CloudKey do
  @moduledoc """
  Ecto schema for cloud LLM provider keys (Postgres adapter, Issue #27).

  `encrypted_key` is AES-GCM ciphertext from `Hub.Vault`. Never readable
  without the master key in `LORE_CLOAK_KEY`.
  """

  use Ecto.Schema

  @primary_key {:provider, :string, autogenerate: false}
  schema "cloud_keys" do
    field :encrypted_key, :binary
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :created_by_discord_id, :string
  end
end
