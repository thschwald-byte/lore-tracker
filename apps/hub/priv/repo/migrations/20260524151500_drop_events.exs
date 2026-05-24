defmodule Hub.Repo.Migrations.DropEvents do
  @moduledoc """
  Etappe 4c.4 (Issue #154): Hub-side events-Tabelle entfällt komplett.

  Nach 4b schreibt der Worker-Sync-Pfad (`publish_intent`) nicht mehr in
  die Tabelle; nach 4c.2/4c.3 schreiben auch keine Hub-Side-Producer
  (CampaignLive, AdminUsersLive, AuthController, InviteController,
  DevIntentController, Mix-Tasks) mehr rein. Inhalte werden seit 3a/3c
  kanonisch in den Worker-Per-Campaign-Stores + worker_events_global
  gehalten + via pull-Mechanik synchronisiert.

  Rollback: würde die Tabelle wieder anlegen, wäre aber leer (alle
  Hub-Producer schreiben nicht mehr). Reverten erfordert auch die
  Code-Revert (vorhergehende PRs zurück).
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:events)
  end

  def down do
    create table(:events, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :payload, :map, null: false
      add :author_worker_id, :text
      add :ts, :utc_datetime_usec, null: false
      add :event_id, :string
    end

    create index(:events, [:event_id])
  end
end
