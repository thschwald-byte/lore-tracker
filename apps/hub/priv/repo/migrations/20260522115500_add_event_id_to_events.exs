defmodule Hub.Repo.Migrations.AddEventIdToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :event_id, :string, null: true
    end

    create index(:events, [:event_id])
  end
end
