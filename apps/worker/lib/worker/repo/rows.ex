defmodule Worker.Repo.Rows do
  @moduledoc """
  Issue #719 (Fortsetzung des #581-Splits): die PUREN Mnesia-Row-Mapper +
  Tombstone-Filter — eine Quelle pro Tabellen-Shape, die Migrations-Arities
  einer Tabelle stehen co-lokiert nebeneinander (statt über `Worker.Repo`
  verstreut). Keine Mnesia-Zugriffe, keine Anreicherung — Tupel rein, Map raus.

  Anreicherungen, die selbst lesen müssen (z.B. `owner_discord_id` einer
  Campaign via `first_spielleiter/1`, #140), passieren beim Aufrufer
  (`Worker.Repo.campaign_row_to_map/1`).
  """

  # ─── campaigns ──────────────────────────────────────────────────

  @doc """
  Campaign-Row → Map (OHNE `owner_discord_id`-Anreicherung — die braucht einen
  Member-Read und lebt in `Worker.Repo`). Issue #215: 8-Tupel pre-#214,
  9-Tupel mit vocab_hint ab #214; Issue #394: 10-Tupel mit transcript_source.
  Alle Arities akzeptiert, damit Worker mit noch-nicht-migrierten Rows nicht
  crashen.
  """
  def campaign(
        {_, id, name, icon, theme, status, created_at, flavors, vocab_hint, transcript_source}
      ) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: vocab_hint,
      transcript_source: normalize_transcript_source(transcript_source)
    }
  end

  def campaign({_, id, name, icon, theme, status, created_at, flavors, vocab_hint}) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: vocab_hint,
      transcript_source: :confirmed
    }
  end

  def campaign({_, id, name, icon, theme, status, created_at, flavors}) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: nil,
      transcript_source: :confirmed
    }
  end

  defp normalize_flavors(m) when is_map(m), do: m
  defp normalize_flavors(s) when is_binary(s) and s != "", do: %{"base" => s}
  defp normalize_flavors(_), do: %{}

  # Issue #394: transcript_source defensiv normalisieren (nil/alt → :confirmed).
  defp normalize_transcript_source(:live), do: :live
  defp normalize_transcript_source(_), do: :confirmed

  # ─── campaign_members ───────────────────────────────────────────

  @doc """
  Issue #133 (Etappe 3d): Tombstone-Filter. Pre-Migration-Rows haben arity 7
  ohne deleted_at → nicht tombstone'd.
  """
  def member_deleted?({_, _key, _cid, _did, _role, _at, _name, deleted_at}),
    do: deleted_at != nil

  def member_deleted?(_), do: false

  def member({_, _key, cid, did, role, at, character_name, _deleted_at}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
  end

  def member({_, _key, cid, did, role, at, character_name}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
  end

  # ─── sessions ───────────────────────────────────────────────────

  def session({_, id, cid, num, name, status, sched, started, ended}) do
    %{
      id: id,
      campaign_id: cid,
      number: num,
      name: name,
      status: status,
      scheduled_for: sched,
      started_at: started,
      ended_at: ended
    }
  end

  # ─── utterances ─────────────────────────────────────────────────

  @doc """
  Issue #133 (Etappe 3d): Tombstone-Filter für utterances. Pre-Migration-Rows
  haben arity 8 ohne deleted_at → nicht tombstone'd.
  """
  def utterance_deleted?({_, _id, _sid, _did, _ts, _text, _conf, _status, deleted_at}),
    do: deleted_at != nil

  def utterance_deleted?(_), do: false

  def utterance({_, id, sid, did, ts, text, conf, status, _deleted_at}) do
    %{
      id: id,
      session_id: sid,
      discord_id: did,
      timestamp: ts,
      text: text,
      confidence: conf,
      status: status
    }
  end

  def utterance({_, id, sid, did, ts, text, conf, status}) do
    %{
      id: id,
      session_id: sid,
      discord_id: did,
      timestamp: ts,
      text: text,
      confidence: conf,
      status: status
    }
  end
end
