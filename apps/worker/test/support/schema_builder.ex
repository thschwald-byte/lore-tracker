defmodule Worker.Schema.Builder do
  @moduledoc """
  Test-Builder für Worker-Mnesia-Records (Issue #166 Stufe B).

  Hardcoded-Tuple-Literale (`{table, id, name, icon_url, theme_blurb,
  status, created_at, flavors}`) sind über 17 Test-Files verstreut. Jeder
  Schema-Refactor (neue Spalte, Slot-Verschiebung) bricht reihenweise
  Tests. Mit den Builder-Funktionen leben Tuple-Shapes an genau einer
  Stelle — ein Schema-Refactor erfordert genau einen Edit hier.

  ## Usage

      defmodule MyTest do
        use ExUnit.Case, async: false
        import Worker.TestHelper
        alias Worker.Schema.Builder

        setup do
          clear_all_tables!()
          Builder.write!(Builder.campaign("c-1", name: "Romeo"))
          Builder.write!(Builder.campaign_member("c-1", "did-1", role: :spielleiter))
          :ok
        end
      end

  Alle Builder-Funktionen nehmen Pflicht-Felder als Positional-Args und
  optionale Felder als `attrs`-Keyword-List. Defaults sind generische
  Test-Werte.
  """

  alias Worker.Schema.Mnesia, as: S

  ## ─── Domain-Builders ─────────────────────────────────────────────

  @doc "Campaign-Tuple (`{tbl, id, name, icon_url, theme_blurb, status, created_at, flavors, vocab_hint}`)."
  def campaign(id, attrs \\ []) when is_binary(id) do
    {
      S.campaigns(),
      id,
      Keyword.get(attrs, :name, "Test Campaign"),
      Keyword.get(attrs, :icon_url),
      Keyword.get(attrs, :theme_blurb),
      Keyword.get(attrs, :status, :active),
      Keyword.get(attrs, :created_at, DateTime.utc_now()),
      Keyword.get(attrs, :flavors, %{}),
      Keyword.get(attrs, :vocab_hint)
    }
  end

  @doc "Campaign-Member-Tuple (`{tbl, cm_key, campaign_id, discord_id, role, joined_at, character_name, deleted_at}`)."
  def campaign_member(campaign_id, discord_id, attrs \\ [])
      when is_binary(campaign_id) and is_binary(discord_id) do
    {
      S.campaign_members(),
      S.member_key(campaign_id, discord_id),
      campaign_id,
      discord_id,
      Keyword.get(attrs, :role, :spieler),
      Keyword.get(attrs, :joined_at, DateTime.utc_now()),
      Keyword.get(attrs, :character_name),
      Keyword.get(attrs, :deleted_at)
    }
  end

  @doc "User-Tuple (`{tbl, discord_id, display_name, joined_at, avatar_url, role}`)."
  def user(discord_id, attrs \\ []) when is_binary(discord_id) do
    {
      S.users(),
      discord_id,
      Keyword.get(attrs, :display_name, "Test User"),
      Keyword.get(attrs, :joined_at, DateTime.utc_now()),
      Keyword.get(attrs, :avatar_url),
      Keyword.get(attrs, :role, :spieler)
    }
  end

  @doc "Session-Tuple (`{tbl, id, campaign_id, number, name, status, scheduled_for, started_at, ended_at}`)."
  def session(id, campaign_id, attrs \\ [])
      when is_binary(id) and is_binary(campaign_id) do
    {
      S.sessions(),
      id,
      campaign_id,
      Keyword.get(attrs, :number, 1),
      Keyword.get(attrs, :name, "Session #{Keyword.get(attrs, :number, 1)}"),
      Keyword.get(attrs, :status, :ended),
      Keyword.get(attrs, :scheduled_for),
      Keyword.get(attrs, :started_at, DateTime.utc_now()),
      Keyword.get(attrs, :ended_at, DateTime.utc_now())
    }
  end

  @doc "Utterance-Tuple (`{tbl, id, session_id, discord_id, timestamp, text, confidence, status, deleted_at}`)."
  def utterance(id, session_id, attrs \\ [])
      when is_binary(id) and is_binary(session_id) do
    {
      S.utterances(),
      id,
      session_id,
      Keyword.get(attrs, :discord_id, "test-did"),
      Keyword.get(attrs, :timestamp, DateTime.utc_now()),
      Keyword.get(attrs, :text, "Hello"),
      Keyword.get(attrs, :confidence, 1.0),
      Keyword.get(attrs, :status, :active),
      Keyword.get(attrs, :deleted_at)
    }
  end

  @doc "Marker-Tuple (`{tbl, id, session_id, at_ts, kind, label}`)."
  def marker(id, session_id, attrs \\ [])
      when is_binary(id) and is_binary(session_id) do
    {
      S.markers(),
      id,
      session_id,
      Keyword.get(attrs, :at_ts, DateTime.utc_now()),
      Keyword.get(attrs, :kind, :note),
      Keyword.get(attrs, :label, "test marker")
    }
  end

  ## ─── Write-Helper ─────────────────────────────────────────────────

  @doc """
  Schreibt einen Builder-Record in Mnesia per Transaction.

  Returnt `{:atomic, :ok}` bei Erfolg oder einen `{:aborted, reason}`-Error.

      Builder.write!(Builder.campaign("c-1"))
  """
  def write!(record) when is_tuple(record) do
    :mnesia.transaction(fn -> :mnesia.write(record) end)
  end

  @doc """
  Schreibt mehrere Builder-Records in Mnesia in einer Transaction.

      Builder.write_many!([
        Builder.campaign("c-1"),
        Builder.campaign_member("c-1", "did-1", role: :spielleiter)
      ])
  """
  def write_many!(records) when is_list(records) do
    :mnesia.transaction(fn ->
      Enum.each(records, &:mnesia.write/1)
    end)
  end
end
