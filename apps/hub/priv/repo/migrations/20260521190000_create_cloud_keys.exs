defmodule Hub.Repo.Migrations.CreateCloudKeys do
  use Ecto.Migration

  def change do
    create table(:cloud_keys, primary_key: false) do
      add :provider, :text, primary_key: true
      add :encrypted_key, :binary, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :created_by_discord_id, :text
    end
  end
end
