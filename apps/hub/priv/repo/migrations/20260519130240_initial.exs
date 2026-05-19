defmodule Hub.Repo.Migrations.Initial do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :payload, :map, null: false
      add :author_worker_id, :text
      add :ts, :utc_datetime_usec, null: false
    end

    create table(:worker_tokens, primary_key: false) do
      add :token, :text, primary_key: true
      add :worker_id, :text, null: false
      add :admin_discord_id, :text, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create index(:worker_tokens, [:worker_id])
  end
end
