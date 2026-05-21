defmodule Hub.Repo.Migrations.AddVersionFieldsToWorkerTokens do
  use Ecto.Migration

  def change do
    alter table(:worker_tokens) do
      add :last_seen_version, :text
      add :last_seen_sha, :text
      add :last_seen_protocol_version, :integer
    end
  end
end
