defmodule Worker.Repo do
  @moduledoc """
  Read/write Mnesia wrappers for the worker's tables. Writes are owned by
  `Worker.Materializer` (event-driven); the snapshot/read helpers are used
  by `Worker.HubClient` to answer `snapshot_request` pushes from the Hub.

  All transactions raise on abort — Mnesia aborts here are programmer
  errors (schema mismatch, missing table), not expected runtime conditions.

  ## Issue #581: God-Module-Split

  Die `snapshot/1`-Familie liegt in `Worker.Repo.Snapshots`, die User-/Membership-
  Reads in `Worker.Repo.Users`. Beide werden hier per `defdelegate` re-exportiert
  (Call-Sites bleiben `Worker.Repo.x()`). `transaction/1` + `fetch_users/1` sind
  geteilt → `@doc false`-public, damit die Submodule sie via `import` erreichen.
  """

  alias Worker.Schema.Mnesia, as: S

  # ─── worker_state ────────────────────────────────────────────────

  @spec get_state(atom()) :: term() | nil
  def get_state(key) when is_atom(key) do
    transaction(fn -> :mnesia.read(S.worker_state(), key) end)
    |> case do
      [{_, ^key, value}] -> value
      [] -> nil
    end
  end

  @spec put_state(atom(), term()) :: :ok
  def put_state(key, value) when is_atom(key) do
    transaction(fn -> :mnesia.write({S.worker_state(), key, value}) end)
    :ok
  end

  @doc """
  Issue #475: monoton steigender Zähler der `{:ok, :pending}`-Publishes (Hub-Sync
  gescheitert, Event nur lokal). Macht den sonst unbeobachtbaren :pending-Zustand
  sichtbar — abfragbar via `get_state(:pending_publish_count)` + im Warning-Log
  als laufende Summe. Gibt den neuen Stand zurück.
  """
  @spec bump_pending_publish_count(pos_integer()) :: pos_integer()
  def bump_pending_publish_count(by \\ 1) do
    n = (get_state(:pending_publish_count) || 0) + by
    put_state(:pending_publish_count, n)
    n
  end

  @spec put_state_many(map() | keyword()) :: :ok
  def put_state_many(map) do
    table = S.worker_state()

    transaction(fn ->
      Enum.each(map, fn {key, value} ->
        :mnesia.write({table, key, value})
      end)
    end)

    :ok
  end

  # ─── users ──────────────────────────────────────────────────────

  # Returns %{discord_id => %{"display_name" => name, "avatar_url" => url | nil}}.
  # Fallback: if a user-record doesn't exist yet, display_name = discord_id,
  # avatar_url = nil. The UI's `avatar/1` helper computes a Discord-default
  # avatar from the discord_id in that case.
  # Issue #581: public (@doc false) — von Worker.Repo.{Users,Snapshots} via import genutzt.
  @doc false
  def fetch_users(discord_ids) do
    discord_ids
    |> Enum.uniq()
    |> Enum.into(%{}, fn did ->
      case transaction(fn -> :mnesia.read(S.users(), did) end) do
        [{_, _, name, _, avatar, _role, _cap}] ->
          {did, %{"display_name" => name, "avatar_url" => avatar, "deleted" => false}}

        [] ->
          # Issue #57: dangling discord_id (User wurde gelöscht, oder hat
          # sich noch nie eingeloggt). UI rendert das als `<.deleted_user_pill>`
          # via "deleted" == true. display_name bleibt = discord_id für Pfade
          # die das deleted-Flag (noch) nicht checken.
          {did, %{"display_name" => did, "avatar_url" => nil, "deleted" => true}}
      end
    end)
  end

  # ─── campaigns ──────────────────────────────────────────────────

  def get_campaign(id) do
    # Issue #475: die 3-Arity-Tupel-Dekodierung (8/9/10-Tupel) lebt an genau
    # EINER Stelle — campaign_row_to_map/1 (das auch all_campaigns nutzt). Vorher
    # reimplementierte get_campaign dieselbe Dekodierung dreifach; getrennte
    # Implementierungen droht zu driften (genau die Klasse, die mehrere #140-
    # Bugs auslöste). get_campaign ist jetzt campaign_row_to_map + die zusätzliche
    # :vorgaben-Auflösung (die der List-/Snapshot-Pfad nicht braucht).
    #
    # owner_discord_id (kein persistiertes Feld seit #140 → erster Spielleiter)
    # + transcript_source/flavors-Normalisierung erbt get_campaign damit aus
    # campaign_row_to_map; Permission-Gating läuft trotzdem über campaign_role/2.
    case transaction(fn -> :mnesia.read(S.campaigns(), id) end) do
      [row] -> campaign_row_to_map(row) |> Map.put(:vorgaben, vorgaben_for(id))
      [] -> nil
    end
  end

  # Issue #394: transcript_source defensiv normalisieren (nil/alt → :confirmed).
  defp normalize_transcript_source(:live), do: :live
  defp normalize_transcript_source(_), do: :confirmed

  # Issue #313: Ausgabe-Vorgaben der Campaign als `%{stage => %{name,
  # darstellungsform}}`. Fehlende Stages tauchen nicht auf — der Caller
  # fällt dann auf seine Default-Werte zurück.
  defp vorgaben_for(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_vorgaben(), campaign_id, :campaign_id)
    end)
    |> Enum.into(%{}, fn {_, _key, _cid, stage, name, form} ->
      {stage, %{name: name, darstellungsform: form}}
    end)
  end

  @spec recent_utterance_texts(String.t(), pos_integer()) :: [String.t()]
  def recent_utterance_texts(session_id, limit \\ 10) do
    list_utterances(session_id, limit: limit)
    |> Enum.map(& &1.text)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

  defp normalize_flavors(m) when is_map(m), do: m
  defp normalize_flavors(s) when is_binary(s) and s != "", do: %{"base" => s}
  defp normalize_flavors(_), do: %{}

  # Issue #140 post-A hotfix: Sort-Comparator-Safety. Wenn die Repair-
  # Migration auf einer noch-nicht-gebooteten Worker-Instanz nicht
  # gelaufen ist (Mehrnode-Setup) oder ein Edge-Case ein Nicht-DateTime
  # ins Feld setzt, soll der Sort nicht den ganzen Dashboard-Snapshot
  # killen. Fallback auf Epoch, damit kaputte Rows hinten landen.
  defp safe_created_at(%DateTime{} = dt), do: dt
  defp safe_created_at(_), do: ~U[1970-01-01 00:00:00.000000Z]

  def list_campaigns_for(discord_id) do
    discord_id
    |> list_campaign_ids_for()
    |> Enum.map(&get_campaign/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(&safe_created_at(&1.created_at), {:desc, DateTime})
  end

  @doc "Liste aller Kampagnen auf dieser Instance (für Admin-UI #35)."
  def all_campaigns do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.campaigns()) end)
    |> Enum.map(&campaign_row_to_map/1)
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(&safe_created_at(&1.created_at), {:desc, DateTime})
  end

  # Issue #215: Row-Schema hat zwei Varianten (8-Tupel pre-#214, 9-Tupel
  # mit vocab_hint ab #214). Wir akzeptieren beide damit Worker mit
  # noch-nicht-vollständig-migrierten Mnesia-Rows nicht crashen.
  # Issue #394: 10-Tupel mit transcript_source.
  defp campaign_row_to_map(
         {_, id, name, icon, theme, status, created_at, flavors, vocab_hint, transcript_source}
       ) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      owner_discord_id: first_spielleiter(id),
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: vocab_hint,
      transcript_source: normalize_transcript_source(transcript_source)
    }
  end

  defp campaign_row_to_map({_, id, name, icon, theme, status, created_at, flavors, vocab_hint}) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      owner_discord_id: first_spielleiter(id),
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: vocab_hint,
      transcript_source: :confirmed
    }
  end

  defp campaign_row_to_map({_, id, name, icon, theme, status, created_at, flavors}) do
    %{
      id: id,
      name: name,
      icon_url: icon,
      theme_blurb: theme,
      status: status,
      owner_discord_id: first_spielleiter(id),
      created_at: created_at,
      flavors: normalize_flavors(flavors),
      vocab_hint: nil,
      transcript_source: :confirmed
    }
  end

  # Probelauf-Campaigns (Issue #74) sollen NICHT in normalen Listen
  # auftauchen — sie sind ephemer und werden nach dem Lauf cascade-deleted.
  # ID-Prefix-Match reicht (Worker.Probelauf seedet mit "probelauf-" + uuid).
  defp probelauf_campaign?(%{id: id}) when is_binary(id),
    do: String.starts_with?(id, "probelauf-")

  defp probelauf_campaign?(_), do: false

  def list_campaign_ids_for(discord_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.map(fn row -> elem(row, 2) end)
    |> Enum.uniq()
  end

  # ─── sessions ───────────────────────────────────────────────────

  def list_sessions(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.sessions(), campaign_id, :campaign_id)
    end)
    |> Enum.map(&row_to_session/1)
    |> Enum.sort_by(& &1.number)
  end

  def get_session(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.sessions(), session_id) end) do
      [row] -> row_to_session(row)
      [] -> nil
    end
  end

  defp row_to_session({_, id, cid, num, name, status, sched, started, ended}) do
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

  # ─── members ────────────────────────────────────────────────────

  def list_members(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), campaign_id, :campaign_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.map(&member_row_to_map/1)
  end

  # Issue #133 (Etappe 3d): Tombstone-Filter. Pre-Migration-Rows haben arity
  # 7 ohne deleted_at → nicht tombstone'd.
  # Issue #581: public (@doc false) — von Worker.Repo.Users via import genutzt.
  @doc false
  def member_row_deleted?({_, _key, _cid, _did, _role, _at, _name, deleted_at}),
    do: deleted_at != nil

  def member_row_deleted?(_), do: false

  defp member_row_to_map({_, _key, cid, did, role, at, character_name, _deleted_at}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
  end

  defp member_row_to_map({_, _key, cid, did, role, at, character_name}) do
    %{
      campaign_id: cid,
      discord_id: did,
      role: role,
      joined_at: at,
      character_name: character_name
    }
  end

  @doc """
  Map of `discord_id → character_name` for the given campaign — only entries
  where an alias is actually set (nil entries excluded). Used by the Hub
  display layer to override the discord-display-name fallback chain.
  """
  def character_names_for(campaign_id) do
    list_members(campaign_id)
    |> Enum.flat_map(fn
      %{discord_id: did, character_name: name} when is_binary(name) and name != "" ->
        [{did, name}]

      _ ->
        []
    end)
    |> Map.new()
  end

  def member?(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [row] -> not member_row_deleted?(row)
      [] -> false
    end
  end

  @doc """
  Per-Campaign-Rolle eines Users in einer Kampagne (Issue #140):
  `:spielleiter | :spieler | nil`. `nil` wenn nicht Member (oder
  Tombstoned). Quelle der Wahrheit: `campaign_members.role`.
  """
  def campaign_role(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [row] ->
        if member_row_deleted?(row), do: nil, else: elem(row, 4)

      [] ->
        nil
    end
  end

  @doc """
  Erster Spielleiter einer Kampagne als discord_id (oder nil falls keiner
  gefunden — sollte nur passieren wenn die Auto-Member-Migration aus
  Issue #140 für historische Daten noch nicht gelaufen ist).
  """
  def first_spielleiter(campaign_id) do
    list_members(campaign_id)
    |> Enum.find(&(&1.role == :spielleiter))
    |> case do
      %{discord_id: did} -> did
      nil -> nil
    end
  end

  # ─── invites ────────────────────────────────────────────────────

  def get_invite(token) when is_binary(token) do
    case transaction(fn -> :mnesia.read(S.campaign_invites(), token) end) do
      [{_, ^token, cid, by, created, expires, status, redeemed_by}] ->
        %{
          token: token,
          campaign_id: cid,
          created_by_discord_id: by,
          created_at: created,
          expires_at: expires,
          status: status,
          redeemed_by_discord_id: redeemed_by
        }

      [] ->
        nil
    end
  end

  def list_invites(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_invites(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, token, cid, by, created, expires, status, redeemed_by} ->
      %{
        token: token,
        campaign_id: cid,
        created_by_discord_id: by,
        created_at: created,
        expires_at: expires,
        status: status,
        redeemed_by_discord_id: redeemed_by
      }
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # ─── utterances ─────────────────────────────────────────────────

  @doc """
  Utterances einer Session, chronologisch sortiert.

  Issue #418: `:live`-Rows aus Alt-Sessions (vor dem Live-Removal, als es noch
  Live-Transkription gab) werden defensiv rausgefiltert — die Batch-
  `confirmed`-Variante ist die kanonische. `mix lore.purge_live` löscht die
  Alt-Live-Rows endgültig.
  """
  def list_utterances(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    rows =
      transaction(fn ->
        :mnesia.index_read(S.utterances(), session_id, :session_id)
      end)
      |> Enum.reject(&utterance_row_deleted?/1)
      |> Enum.map(&utterance_row_to_map/1)
      |> Enum.reject(&(&1.status == :live))
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})

    # Issue #506: `limit: :all` lädt die GANZE Session — für den Stage-2-
    # Pipeline-Pfad, der sonst nur die letzten 200 Utts einer langen Session
    # summt (→ trunkiertes Resümee, vergiftet Epos + Chronik downstream).
    # UI-/Snapshot-Reader behalten das 200-Default-Cap (kein 3000-Utt-Load
    # in eine LiveView).
    case limit do
      :all -> rows
      n when is_integer(n) -> Enum.take(rows, -n)
    end
  end

  # Issue #133 (Etappe 3d): Tombstone-Filter für utterances. Pre-Migration-
  # Rows haben arity 8 ohne deleted_at → nicht tombstone'd.
  defp utterance_row_deleted?({_, _id, _sid, _did, _ts, _text, _conf, _status, deleted_at}),
    do: deleted_at != nil

  defp utterance_row_deleted?(_), do: false

  defp utterance_row_to_map({_, id, sid, did, ts, text, conf, status, _deleted_at}) do
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

  defp utterance_row_to_map({_, id, sid, did, ts, text, conf, status}) do
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

  @doc """
  Issue #418: Plan für `Worker.Maintenance.purge_live/0`. Klassifiziert alle
  Sessions mit `status: :live`-Rows danach, ob ein Batch-Pendant existiert:

      %{clearable: [{session_id, live_count}], orphan: [{session_id, live_count}]}

  `clearable` = Session hat live UND mindestens eine nicht-live Row → die live-
  Rows sind redundant und können via `LiveUtterancesCleared` getilgt werden.
  `orphan` = nur live, kein Batch → NICHT tilgen (Datenverlust). Tombstone'd
  Rows zählen nicht mit.
  """
  def live_purge_plan do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.utterances()) end)
    |> Enum.reject(&utterance_row_deleted?/1)
    |> Enum.map(&utterance_row_to_map/1)
    |> Enum.group_by(& &1.session_id)
    |> Enum.reduce(%{clearable: [], orphan: []}, fn {sid, rows}, acc ->
      live_count = Enum.count(rows, &(&1.status == :live))

      cond do
        live_count == 0 ->
          acc

        Enum.any?(rows, &(&1.status != :live)) ->
          %{acc | clearable: [{sid, live_count} | acc.clearable]}

        true ->
          %{acc | orphan: [{sid, live_count} | acc.orphan]}
      end
    end)
  end

  def list_markers(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.markers(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, id, sid, at, kind, label} ->
      %{id: id, session_id: sid, at_ts: at, kind: kind, label: label}
    end)
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end

  # ─── speaker assignments (Issue #19) ────────────────────────────

  @doc """
  Sprecher-Zuordnungen aller Sessions einer Kampagne. Liefert eine Liste
  von `%{session_id, speaker_label, discord_id}`. Pseudo-Labels ohne
  Zuordnung tauchen hier nicht auf — sie werden in der UI als „Sprecher N"
  gerendert.
  """
  def list_speaker_assignments_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(fn s -> list_speaker_assignments(s.id) end)
  end

  def list_speaker_assignments(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.speaker_assignments(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, _key, sid, label, did, _at} ->
      %{session_id: sid, speaker_label: label, discord_id: did}
    end)
  end

  @doc """
  All utterances across every session of `campaign_id`, oldest first.
  Used by Protokoll so prior sessions remain visible when a new recording
  starts.

  Issue #150: globales Limit auf 10_000 hochgesetzt (war 1000) — bei
  Bühnenstück-großen Kampagnen wie der Folger-R&J-Demo (1060 Utterances,
  27 Sessions) fielen sonst die ältesten Utterances raus und Session 1
  verschwand komplett aus der Protokoll-Spalte. Pro-Session-Limit bleibt
  bei 1000 (default in `list_utterances/2`). Wenn Render-Performance ein
  Thema wird, ist Pagination der saubere Weg — eigenes Issue.
  """
  def list_utterances_for_campaign(campaign_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)

    list_sessions(campaign_id)
    |> Enum.flat_map(&list_utterances(&1.id, limit: limit))
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.take(-limit)
  end

  @doc "All markers across every session of `campaign_id`, oldest first."
  def list_markers_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(&list_markers(&1.id))
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end

  @doc "First non-completed session for a campaign (or nil)."
  def active_session_for(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.find(fn s -> s.status in [:recording, :paused] end)
  end

  @doc "Next session number for a campaign (max+1, or 1 if none yet)."
  def next_session_number(campaign_id) do
    case list_sessions(campaign_id) do
      [] -> 1
      list -> Enum.max_by(list, & &1.number).number + 1
    end
  end

  # ─── epos ───────────────────────────────────────────────────────

  @doc "Current Epos entry for a campaign (or nil)."
  def get_epos_entry(entry_id) when is_binary(entry_id) do
    case transaction(fn -> :mnesia.read(S.epos_entries(), entry_id) end) do
      # Issue #114: 7-Tupel mit source_refs trailing.
      [{_, id, cid, parent, content, updated, refs}] ->
        %{
          id: id,
          campaign_id: cid,
          parent_id: parent,
          content_md: content,
          updated_at: updated,
          source_refs: refs || []
        }

      [] ->
        nil
    end
  end

  # ─── summaries / chronik ────────────────────────────────────────

  def get_session_summary(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_summaries(), session_id) end) do
      # Issue #114: source_refs trailing; Issue #715: flagged_claims trailing.
      [{_, sid, cid, content, generated_at, source, refs, flagged}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          content_md: content,
          generated_at: generated_at,
          source: source,
          source_refs: refs || [],
          flagged_claims: flagged || []
        }

      [] ->
        nil
    end
  end

  # Issue #651 (Wahrheitsbild, Phase A): die extrahierten Fakten EINER Session.
  # facts_json wird zur Read-Zeit dekodiert (Liste von Fakt-Maps, String-Keys
  # wie gespeichert). nil wenn (noch) keine Extraktion lief.
  def get_session_facts(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_facts(), session_id) end) do
      [{_, sid, cid, facts_json, extracted_at}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          facts: decode_facts(facts_json),
          extracted_at: extracted_at
        }

      [] ->
        nil
    end
  end

  # Issue #651: alle Fakten einer Campaign, flach + chronologisch nach
  # session.number (wie list_chronik_entries #650). Jeder Fakt bekommt sein
  # `"session_id"` zur Provenienz mit (für Campaign-Epos + Phase-B-Verify).
  def list_campaign_facts(campaign_id) when is_binary(campaign_id) do
    order =
      campaign_id |> list_sessions() |> Map.new(fn s -> {s.id, s.number} end)

    transaction(fn ->
      :mnesia.index_read(S.session_facts(), campaign_id, :campaign_id)
    end)
    |> Enum.sort_by(fn {_, sid, _cid, _json, _ts} -> Map.get(order, sid, 1_000_000) end)
    |> Enum.flat_map(fn {_, sid, _cid, facts_json, _ts} ->
      facts_json |> decode_facts() |> Enum.map(&Map.put(&1, "session_id", sid))
    end)
  end

  defp decode_facts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_facts(_), do: []

  def list_session_summaries(campaign_id) when is_binary(campaign_id) do
    # Sortierung nach Session-Nummer (Issue #24): die Spalte soll
    # chronologisch nach Session-Verlauf lesen — Session 1 oben, neueste
    # Session unten — NICHT nach generated_at (wann die LLM-Pipeline den
    # Resümee-Text erzeugt hat). Fallback auf große Zahl wenn die Session
    # selbst inzwischen gelöscht wurde, damit Orphan-Resümees ans Ende
    # sortieren statt zu crashen.
    sessions_by_id =
      campaign_id |> list_sessions() |> Enum.into(%{}, &{&1.id, &1})

    transaction(fn ->
      :mnesia.index_read(S.session_summaries(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, content, generated_at, source, refs, flagged} ->
      %{
        session_id: sid,
        campaign_id: cid,
        content_md: content,
        generated_at: generated_at,
        source: source,
        source_refs: refs || [],
        flagged_claims: flagged || []
      }
    end)
    |> Enum.sort_by(fn s ->
      case sessions_by_id[s.session_id] do
        %{number: n} -> n
        _ -> 999_999
      end
    end)
  end

  # Issue #11 Phase 2: Faithfulness-Score pro Session.
  # claims_json wird hier eager dekodiert — die UI braucht Claim-Texte für
  # das Click-to-Expand-Detail.
  def get_faithfulness_score(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_faithfulness_scores(), session_id) end) do
      [{_, sid, cid, score, claims_json, scored_at}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          score: score,
          claims: decode_claims(claims_json),
          scored_at: scored_at
        }

      [] ->
        nil
    end
  end

  def list_faithfulness_scores(campaign_id) when is_binary(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.session_faithfulness_scores(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, score, claims_json, scored_at} ->
      %{
        session_id: sid,
        campaign_id: cid,
        score: score,
        claims: decode_claims(claims_json),
        scored_at: scored_at
      }
    end)
  end

  defp decode_claims(nil), do: []
  defp decode_claims(""), do: []

  defp decode_claims(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_claims(_), do: []

  def list_chronik_entries(campaign_id) when is_binary(campaign_id) do
    # Issue #650: primär nach Session-Reihenfolge (session.number), erst sekundär
    # nach in_game_date. Vorher rein nach in_game_date → über Sessions hinweg
    # verdreht (LLM-Datumsformate sind nicht global vergleichbar; "Tag 1" aus S2
    # sortierte vor "Tag 3" aus S1). Einträge ohne bekannte Session (Orphans /
    # nil) wandern ans Ende.
    session_order = chronik_session_order(campaign_id)

    transaction(fn ->
      :mnesia.index_read(S.chronik_entries(), campaign_id, :campaign_id)
    end)
    # Issue #114: source_refs trailing.
    # Issue #385: markdown_body — verbatim User-Markdown fürs Hub-Display.
    # Issue #724: in_game_day (kanonischer Tageszähler) + precision trailing.
    # nil bei nicht-migrierten / :chain-Einträgen.
    |> Enum.map(fn {_, id, cid, in_game_date, label, summary, sid, refs, md_body, day, precision} ->
      %{
        id: id,
        campaign_id: cid,
        in_game_date: in_game_date,
        label: label,
        summary: summary,
        session_id: sid,
        source_refs: refs || [],
        markdown_body: md_body,
        in_game_day: day,
        precision: precision
      }
    end)
    # Issue #724: Sort-Cutover. Familie 0 (echter Tageszähler, global vergleichbar)
    # NUR bei integer in_game_day — der :wahrheitsbild-Zeitstrahl. Sonst Familie 1
    # = das bestehende #650-Verhalten (Session-Reihenfolge, dann Freitext-Datum).
    # Solange keine Row einen in_game_day hat (alle :chain), ist das exakt der
    # Status quo → null Regression.
    |> Enum.sort_by(fn e ->
      case e.in_game_day do
        d when is_integer(d) ->
          {0, d, ""}

        _ ->
          {1, Map.get(session_order, e.session_id, 1_000_000),
           derive_chronik_sort_tuple(e.in_game_date)}
      end
    end)
  end

  # Issue #650: session_id → session.number, für die primäre Chronik-Sortierung.
  defp chronik_session_order(campaign_id) do
    campaign_id
    |> list_sessions()
    |> Map.new(fn s -> {s.id, s.number} end)
  end

  # Issue #724: der per-Campaign-Kalender (eigene Tabelle @campaign_calendars).
  # Fehlende Row ODER kaputtes JSON → Calendar.default/0 (Boundary-Defense, nie
  # crashen). calendar_json wird als Jason-String gespeichert (Slice C schreibt).
  @doc "Kalender-Definition der Campaign; `Worker.Timeline.Calendar.default/0` bei Miss."
  @spec get_campaign_calendar(String.t()) :: Worker.Timeline.Calendar.t()
  def get_campaign_calendar(campaign_id) when is_binary(campaign_id) do
    row =
      transaction(fn -> :mnesia.read(S.campaign_calendars(), campaign_id) end)

    case row do
      [{_tbl, _cid, calendar_json, _updated_at}] when is_binary(calendar_json) ->
        case Jason.decode(calendar_json) do
          {:ok, map} -> Worker.Timeline.Calendar.from_json(map)
          _ -> Worker.Timeline.Calendar.default()
        end

      _ ->
        Worker.Timeline.Calendar.default()
    end
  end

  # Issue #724: kanonischer In-Game-Tageszähler der Session (eigene Tabelle
  # @session_anchors) — Anker für relative Fakt-Offsets im Resolver. nil, wenn
  # der GM (noch) kein Datum gesetzt hat.
  @doc "In-Game-Tageszähler der Session als Resolver-Anker; nil wenn nicht gesetzt."
  @spec get_session_anchor_day(String.t()) :: integer() | nil
  def get_session_anchor_day(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_anchors(), session_id) end) do
      [{_tbl, _sid, _cid, in_game_day, _raw}] -> in_game_day
      _ -> nil
    end
  end

  # Issue #135: Sort-Reihenfolge wird zur Lesezeit aus dem `in_game_date`-
  # String abgeleitet — kein persistiertes derived value mehr. Tuple-Layout:
  # `{family, primary, original}`. Familien-Priorität:
  #
  #   0 — Session/Tag/Day/Akt + Zahl (häufigste Form in der Praxis)
  #   1 — Jahres-Datum (z.B. "552 CY", "552 CY - Spring")
  #   2 — Narrativer Marker ("Aufbruch", "Erste Begegnung")
  #   9 — nil / leerer String (sortiert ans Ende)
  #
  # Innerhalb einer Familie sortiert die `primary`-Zahl numerisch; der
  # `original`-String bricht Ties stabil. Wenn neue LLM-Modelle weitere
  # Datumsformate emittieren, kommt eine zusätzliche Klausel dazu.
  @doc false
  def derive_chronik_sort_tuple(nil), do: {9, 0, ""}
  def derive_chronik_sort_tuple(""), do: {9, 0, ""}

  def derive_chronik_sort_tuple(date) when is_binary(date) do
    cond do
      n = leading_unit_number(date) ->
        {0, n, date}

      year_n = year_with_optional_season(date) ->
        {1, year_n, date}

      true ->
        {2, 0, date}
    end
  end

  # Matches "Session 13", "Tag 38", "Day 14", "Akt 2", "Scene 5" — case-
  # insensitive, optional whitespace, leading number captured.
  defp leading_unit_number(date) do
    case Regex.run(~r/^\s*(?:session|tag|day|akt|szene|scene)\s+(\d+)/i, date) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # Matches "552 CY", "552 CY - Spring", "550 CY (Winter)" etc. Returns
  # year * 10 + season_bump so two events in the same year sort by season.
  defp year_with_optional_season(date) do
    case Regex.run(~r/(\d+)\s*CY/, date) do
      [_, y] ->
        season =
          cond do
            date =~ ~r/Spring/i -> 1
            date =~ ~r/Summer/i -> 2
            date =~ ~r/Autumn|Fall/i -> 3
            date =~ ~r/Winter/i -> 4
            true -> 0
          end

        String.to_integer(y) * 10 + season

      _ ->
        nil
    end
  end

  @doc "History rows for an Epos entry, newest first."
  def list_epos_history(entry_id) when is_binary(entry_id) do
    transaction(fn ->
      :mnesia.index_read(S.epos_history(), entry_id, :entry_id)
    end)
    |> Enum.map(fn {_, id, eid, content, edited_at, edited_by, source, seq} ->
      %{
        id: id,
        entry_id: eid,
        content_md: content,
        edited_at: edited_at,
        edited_by: edited_by,
        source: source,
        seq: seq
      }
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  @doc """
  Letzter beendeter Single-Probelauf (Issue #74) — also ein Run der **nicht**
  Teil eines Sweeps war. Als Map oder nil. Sortiert nach finished_at
  (sekundärer Sort gegen run_id für Determinismus).
  """
  def last_probelauf_run do
    all_probelauf_runs()
    |> Enum.filter(fn r -> r.finished_at && is_nil(r.sweep_id) end)
    |> Enum.sort_by(fn r -> {DateTime.to_unix(r.finished_at, :microsecond), r.run_id} end, :desc)
    |> List.first()
  end

  @doc """
  Alle Probelauf-Runs (Phase 1 + Phase 2). Jede Row als Map mit nun
  optionalen `sweep_id` + `sweep_variant` Feldern (Issue #88).
  """
  def all_probelauf_runs do
    transaction(fn ->
      :mnesia.match_object({S.probelauf_runs(), :_, :_, :_, :_, :_, :_, :_, :_})
    end)
    |> Enum.map(fn {_, run_id, started_at, finished_at, started_by, sessions, settings, sweep_id,
                    sweep_variant} ->
      %{
        run_id: run_id,
        started_at: started_at,
        finished_at: finished_at,
        started_by: started_by,
        sessions: sessions,
        settings_snapshot: settings,
        sweep_id: sweep_id,
        sweep_variant: sweep_variant
      }
    end)
  end

  @doc """
  Letzter beendeter Sweep (Issue #88, Phase 2a) als Map mit aggregierter
  Variants-Liste, oder nil. Aggregation pro (stage, model): Median-Dauer
  über alle Sessions, Success-Rate über alle Stages aller Sessions.
  """
  def last_probelauf_sweep do
    case last_n_probelauf_sweeps(1) do
      [] -> nil
      [latest | _] -> latest
    end
  end

  @doc """
  Die letzten `n` beendeten Sweeps (default 3), sortiert nach
  finished_at desc (neuester zuerst). Issue #88 (Phase 2b): die LV
  zeigt mehrere Sweeps gleichzeitig nach einem Multi-Stage-Sweep, je
  ein Sweep pro durchgesweepte Stage. Jeder Eintrag enthält bereits
  die zugehörigen `:runs`.
  """
  @spec last_n_probelauf_sweeps(pos_integer()) :: [map()]
  def last_n_probelauf_sweeps(n \\ 3) when is_integer(n) and n > 0 do
    sweeps =
      transaction(fn ->
        :mnesia.match_object({S.probelauf_sweeps(), :_, :_, :_, :_, :_, :_, :_, :_})
      end)
      |> Enum.map(fn {_, sweep_id, started_at, finished_at, started_by, stage, models,
                      default_model, variants} ->
        %{
          sweep_id: sweep_id,
          started_at: started_at,
          finished_at: finished_at,
          started_by: started_by,
          stage: stage,
          models: models,
          default_model: default_model,
          variants: variants
        }
      end)
      |> Enum.filter(& &1.finished_at)
      |> Enum.sort_by(
        fn s -> {DateTime.to_unix(s.finished_at, :microsecond), s.sweep_id} end,
        :desc
      )
      |> Enum.take(n)

    case sweeps do
      [] ->
        []

      list ->
        all_runs = all_probelauf_runs()

        Enum.map(list, fn sweep ->
          runs_for_sweep =
            Enum.filter(all_runs, fn r -> r.sweep_id == sweep.sweep_id && r.finished_at end)

          Map.put(sweep, :runs, runs_for_sweep)
        end)
    end
  end

  # Issue #581: public (@doc false) — von Worker.Repo.{Users,Snapshots} via import genutzt.
  @doc false
  def transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end

  # ─── Issue #581: Façade-Delegation an die ausgelagerten Submodule ─────────
  # Call-Sites bleiben `Worker.Repo.x()`; die Implementierung lebt im Submodul.

  defdelegate upsert_user(discord_id, display_name), to: Worker.Repo.Users
  defdelegate get_user(discord_id), to: Worker.Repo.Users
  defdelegate audio_consent(discord_id), to: Worker.Repo.Users
  defdelegate list_all_users(), to: Worker.Repo.Users
  defdelegate admin_exists?(), to: Worker.Repo.Users
  defdelegate last_admin?(discord_id), to: Worker.Repo.Users
  defdelegate last_spielleiter_campaigns_for(discord_id), to: Worker.Repo.Users
  defdelegate users_for_campaign(campaign_id), to: Worker.Repo.Users
  defdelegate users_for_dashboard(viewer_discord_id), to: Worker.Repo.Users

  defdelegate snapshot(scope), to: Worker.Repo.Snapshots
  defdelegate monthly_spend_usd(discord_id), to: Worker.Repo.Snapshots
  defdelegate last_n_pipeline_errors(n \\ 50), to: Worker.Repo.Snapshots
  defdelegate any_active_recording?(), to: Worker.Repo.Snapshots
end
