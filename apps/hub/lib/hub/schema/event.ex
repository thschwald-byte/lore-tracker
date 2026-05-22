defmodule Hub.Schema.Event do
  @moduledoc """
  Ecto schema for the append-only event log (Postgres adapter).

  `seq` is the primary key, populated by Postgres `BIGSERIAL` on insert.
  `payload` is JSONB; the Hub stores the JSON-decoded map it received from
  workers (via Slipstream) directly, so encoding is identity.
  """

  use Ecto.Schema

  @primary_key {:seq, :id, autogenerate: true}
  schema "events" do
    field :event_id, :string
    field :payload, :map
    field :author_worker_id, :string
    field :ts, :utc_datetime_usec
  end
end
