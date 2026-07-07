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
      Keyword.get(attrs, :vocab_hint),
      # Issue #394: transcript_source (:confirmed | :live), Default :confirmed.
      Keyword.get(attrs, :transcript_source, :confirmed)
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

  @doc "User-Tuple (`{tbl, discord_id, display_name, joined_at, avatar_url, role, monthly_spend_cap_usd}`)."
  def user(discord_id, attrs \\ []) when is_binary(discord_id) do
    {
      S.users(),
      discord_id,
      Keyword.get(attrs, :display_name, "Test User"),
      Keyword.get(attrs, :joined_at, DateTime.utc_now()),
      Keyword.get(attrs, :avatar_url),
      Keyword.get(attrs, :role, :spieler),
      Keyword.get(attrs, :monthly_spend_cap_usd)
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

  @doc """
  Session-Summary-Tuple
  (`{tbl, session_id, campaign_id, content_md, generated_at, source, source_refs}`).

  Issue #114 ergänzte `source_refs` (7. Feld) — der Builder hält die Arity
  zentral, damit Tests nicht wieder das Pre-#114-6-Tupel hartkodieren (#459/#462).
  """
  def session_summary(session_id, campaign_id, attrs \\ [])
      when is_binary(session_id) and is_binary(campaign_id) do
    {
      S.session_summaries(),
      session_id,
      campaign_id,
      Keyword.get(attrs, :content_md, "Resümee"),
      Keyword.get(attrs, :generated_at, DateTime.utc_now()),
      Keyword.get(attrs, :source, :llm),
      Keyword.get(attrs, :source_refs, [])
    }
  end

  @doc """
  Epos-Entry-Tuple
  (`{tbl, id, campaign_id, parent_id, content_md, updated_at, source_refs}`).
  Single-Entry-pro-Campaign: `id == campaign_id`. `source_refs` seit #114.
  """
  def epos_entry(id, campaign_id, attrs \\ [])
      when is_binary(id) and is_binary(campaign_id) do
    {
      S.epos_entries(),
      id,
      campaign_id,
      Keyword.get(attrs, :parent_id),
      Keyword.get(attrs, :content_md, "Epos-Inhalt"),
      Keyword.get(attrs, :updated_at, DateTime.utc_now()),
      Keyword.get(attrs, :source_refs, [])
    }
  end

  @doc """
  Epos-History-Tuple
  (`{tbl, id, entry_id, content_md, edited_at, edited_by, source, seq}`).
  """
  def epos_history(id, entry_id, attrs \\ [])
      when is_binary(id) and is_binary(entry_id) do
    {
      S.epos_history(),
      id,
      entry_id,
      Keyword.get(attrs, :content_md, "alter Epos"),
      Keyword.get(attrs, :edited_at, DateTime.utc_now()),
      Keyword.get(attrs, :edited_by, "test-did"),
      Keyword.get(attrs, :source, :manual),
      Keyword.get(attrs, :seq, 1)
    }
  end

  @doc """
  Chronik-Entry-Tuple
  (`{tbl, id, campaign_id, in_game_date, label, summary, session_id,
  source_refs, markdown_body}`). `source_refs` seit #114, `markdown_body` seit #385.
  """
  def chronik_entry(id, campaign_id, attrs \\ [])
      when is_binary(id) and is_binary(campaign_id) do
    {
      S.chronik_entries(),
      id,
      campaign_id,
      Keyword.get(attrs, :in_game_date, "Tag 1"),
      Keyword.get(attrs, :label, "Event"),
      Keyword.get(attrs, :summary, "Zusammenfassung"),
      Keyword.get(attrs, :session_id),
      Keyword.get(attrs, :source_refs, []),
      Keyword.get(attrs, :markdown_body),
      # Issue #724: in_game_day (kanonischer Tageszähler) + precision, trailing.
      Keyword.get(attrs, :in_game_day),
      Keyword.get(attrs, :precision)
    }
  end

  @doc """
  Campaign-Invite-Tuple
  (`{tbl, token, campaign_id, created_by_discord_id, created_at, expires_at,
  status, redeemed_by_discord_id}`).
  """
  def campaign_invite(token, campaign_id, attrs \\ [])
      when is_binary(token) and is_binary(campaign_id) do
    {
      S.campaign_invites(),
      token,
      campaign_id,
      Keyword.get(attrs, :created_by_discord_id, "test-did"),
      Keyword.get(attrs, :created_at, DateTime.utc_now()),
      Keyword.get(attrs, :expires_at),
      Keyword.get(attrs, :status, :active),
      Keyword.get(attrs, :redeemed_by_discord_id)
    }
  end

  ## ─── Write-Helper ─────────────────────────────────────────────────

  @doc """
  Schreibt einen Builder-Record in Mnesia per Transaction.

  **Raised** bei Tx-Abort (z.B. Arity-Mismatch durch Schema-Drift) statt den
  Fehler still zurückzugeben — die `!`-Konvention. Vor #462 gab die Funktion
  `{:aborted, reason}` nur zurück, sodass Aufrufer den Abort schluckten und der
  Test mit einer leeren Tabelle weiterlief (false-negative, vgl. #459).

      Builder.write!(Builder.campaign("c-1"))
  """
  def write!(record) when is_tuple(record) do
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write(record) end)
    :ok
  end

  @doc """
  Schreibt mehrere Builder-Records in Mnesia in einer Transaction.
  Raised bei Tx-Abort (siehe `write!/1`).

      Builder.write_many!([
        Builder.campaign("c-1"),
        Builder.campaign_member("c-1", "did-1", role: :spielleiter)
      ])
  """
  def write_many!(records) when is_list(records) do
    {:atomic, :ok} = :mnesia.transaction(fn -> Enum.each(records, &:mnesia.write/1) end)
    :ok
  end
end
