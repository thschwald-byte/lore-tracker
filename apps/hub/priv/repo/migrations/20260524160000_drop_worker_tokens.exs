defmodule Hub.Repo.Migrations.DropWorkerTokens do
  @moduledoc """
  Etappe 5a (Issue #160): Hub-side worker_tokens-Tabelle entfällt.

  Pairing + Channel-Auth laufen ab dieser Migration über JWT (RFC 7519,
  HS256 gegen LORE_JWT_SECRET) — siehe `Hub.WorkerJWT`. Token-Lookup ist
  jetzt eine reine Signatur-Verifikation, kein DB-Zugriff.

  Migrations-Strategie: hart. Beim Deploy bekommen alle bestehenden Worker
  401 (Token-Format ändert sich, alte JWT-fremde Tokens sind ungültig).
  Self-Hoster pairt alle Worker einmalig neu via Discord-OAuth.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:worker_tokens)
  end

  def down do
    create table(:worker_tokens, primary_key: false) do
      add :token, :text, primary_key: true
      add :worker_id, :text, null: false
      add :admin_discord_id, :text, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :worker_version, :text
      add :worker_sha, :text
      add :protocol_version, :text
    end

    create index(:worker_tokens, [:worker_id])
  end
end
