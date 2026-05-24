defmodule Hub.Repo.Migrations.DropCloudKeys do
  @moduledoc """
  Etappe 5b (Issue #162): Hub-side cloud_keys-Tabelle entfällt.

  Worker calls Cloud-LLM-APIs (Anthropic) ab dieser PR direkt mit
  pro-Worker `ANTHROPIC_API_KEY`-Env-Var. Hub-LLM-Proxy + Hub.Vault
  entfallen.

  Self-Hoster muss pro Worker-Maschine `ANTHROPIC_API_KEY=sk-ant-...`
  in der Worker-Start-Umgebung setzen (siehe `docs/Worker-Setup.md`).
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:cloud_keys)
  end

  def down do
    create table(:cloud_keys, primary_key: false) do
      add :provider, :text, primary_key: true
      add :encrypted_key, :binary, null: false
      add :updated_by, :text
      add :updated_at_ts, :utc_datetime_usec, null: false
    end
  end
end
