defmodule Worker.Materializer.Apply2 do
  @moduledoc """
  Issue #582 (God-Module-Split aus `Worker.Materializer`): zweite Hälfte der
  `apply_kind/4`-Event-Handler (Marker/Invite/Member/Chronik/Epos/Summary/
  Probelauf) + der finale Catch-all (unbekannter Kind → Log). Pendant zu
  `Worker.Materializer.Apply1`; selbe Prozess-/Transaktions-Semantik, geteilte
  Helfer via `import Worker.Materializer`.
  """
  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  def apply_kind("MarkerAdded", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.markers(),
        payload["id"],
        payload["session_id"],
        parse_ts(payload["at_ts"]),
        parse_marker_kind(payload["marker_kind"]),
        payload["label"]
      })
  end

  def apply_kind("InviteCreated", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.campaign_invites(),
        payload["token"],
        payload["campaign_id"],
        payload["created_by_discord_id"],
        ts,
        parse_ts(payload["expires_at"]),
        :active,
        nil
      })
  end

  def apply_kind("InviteRevoked", payload, _ts, _meta) do
    token = payload["token"]

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, cid, by, created, expires, _status, redeemed_by}] ->
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            cid,
            by,
            created,
            expires,
            :revoked,
            redeemed_by
          })

      [] ->
        Logger.warning("InviteRevoked for unknown token=#{token}")
    end
  end

  def apply_kind("InviteRedeemed", payload, ts, _meta) do
    token = payload["token"]
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || "User #{discord_id}"

    case :mnesia.read(S.campaign_invites(), token) do
      [{_, ^token, campaign_id, created_by, created_at, expires_at, _status, _redeemed_by}] ->
        # Mark invite redeemed.
        :ok =
          :mnesia.write({
            S.campaign_invites(),
            token,
            campaign_id,
            created_by,
            created_at,
            expires_at,
            :redeemed,
            discord_id
          })

        # Upsert user (preserve joined_at + avatar_url + cap if already known).
        {existing_joined_at, existing_avatar_url, existing_role, existing_cap} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, _, j, a, r, c}] -> {j, a, r, c}
            [] -> {ts, nil, :spieler, nil}
          end

        :ok =
          :mnesia.write({
            S.users(),
            discord_id,
            display_name,
            existing_joined_at,
            existing_avatar_url,
            existing_role,
            existing_cap
          })

        # Add membership (idempotent — same key overwrites).
        # Preserve any existing character_name if the user is being
        # re-added (e.g. invite re-redeemed); default nil for first-time.
        # Re-Join nach Tombstone: deleted_at wird auf nil zurückgesetzt.
        existing_character_name =
          case :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id)) do
            [{_, _, _, _, _, _, name, _deleted_at}] -> name
            [{_, _, _, _, _, _, name}] -> name
            _ -> nil
          end

        :ok =
          :mnesia.write({
            S.campaign_members(),
            S.member_key(campaign_id, discord_id),
            campaign_id,
            discord_id,
            :spieler,
            ts,
            existing_character_name,
            nil
          })

      [] ->
        Logger.warning("InviteRedeemed for unknown token=#{token}")
    end
  end

  # Issue #133 (Etappe 3d): Tombstone statt :mnesia.delete. Bei Re-Sync von
  # alten Edit-Events respektiert apply_kind den Tombstone (LWW). Repo-Reads
  # filtern Rows mit deleted_at != nil aus.
  def apply_kind("MemberRemoved", payload, ts, _meta) do
    key = S.member_key(payload["campaign_id"], payload["discord_id"])

    case :mnesia.read(S.campaign_members(), key) do
      [{tbl, ^key, cid, did, role, joined_at, character_name, _old_deleted_at}] ->
        :ok = :mnesia.write({tbl, key, cid, did, role, joined_at, character_name, ts})

      [] ->
        # Tombstone für Member den wir nicht kannten — Sync-Korrektheit:
        # neuer Worker holt sich beide Events (MemberAdded + MemberRemoved),
        # apply-Reihenfolge: Tombstone wird über schwebenden InviteRedeemed
        # gewinnen. Wir markieren nicht-existierende Row hier nicht — beim
        # Re-Sync wäre MemberRemoved nach InviteRedeemed angekommen.
        :ok
    end
  end

  # Issue #57: User komplett löschen. Cascade:
  #   1. Alle campaign_members-Rows des Users via index_read(:discord_id)
  #      → :deleted_at-Tombstone setzen (Soft-Delete, analog MemberRemoved).
  #   2. worker_users-Row hart löschen.
  # Utterances/Sessions/Markers bleiben unverändert — Audit-Trail. UI rendert
  # dangling-discord_ids als `<.deleted_user_pill>`-Placeholder.
  def apply_kind("UserDeleted", payload, ts, _meta) do
    discord_id = payload["discord_id"]

    :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    |> Enum.each(fn
      {tbl, key, cid, did, role, joined_at, character_name, nil} ->
        :ok = :mnesia.write({tbl, key, cid, did, role, joined_at, character_name, ts})

      _already_tombstoned ->
        :ok
    end)

    :ok = :mnesia.delete({S.users(), discord_id})
  end

  # Issue #57: Kampagne archivieren. Status -> :archived. Dashboard filtert
  # archivierte Kampagnen standardmäßig raus (Toggle "Archivierte zeigen").
  def apply_kind("CampaignArchived", payload, _ts, _meta) do
    campaign_id = payload["campaign_id"]

    case :mnesia.read(S.campaigns(), campaign_id) do
      [] ->
        Logger.warning("CampaignArchived for unknown campaign=#{campaign_id} — ignoring")

      [
        {tbl, ^campaign_id, name, icon, theme, _old_status, created_at, flavors, vocab_hint,
         transcript_source}
      ] ->
        :ok =
          :mnesia.write(
            {tbl, campaign_id, name, icon, theme, :archived, created_at, flavors, vocab_hint,
             transcript_source}
          )
    end
  end

  def apply_kind("CampaignAliasSet", payload, _ts, _meta) do
    campaign_id = payload["campaign_id"]
    discord_id = payload["discord_id"]
    name = normalize_alias(payload["character_name"])
    key = S.member_key(campaign_id, discord_id)

    case :mnesia.read(S.campaign_members(), key) do
      [{tbl, ^key, ^campaign_id, ^discord_id, role, joined_at, _old_name, deleted_at}] ->
        :ok =
          :mnesia.write({tbl, key, campaign_id, discord_id, role, joined_at, name, deleted_at})

      [] ->
        Logger.warning(
          "CampaignAliasSet for unknown member campaign=#{campaign_id} did=#{discord_id} — dropping"
        )

        :ok
    end
  end

  def apply_kind("SessionSummaryGenerated", payload, ts, _meta) do
    # Issue #133 (Etappe 3d): LWW pro session_id. Bei Sync mit älteren Events
    # nach lokalem Apply von einer neueren Edition wird der ältere skipped.
    # Issue #114: source_refs trailing — Liste der utterance_ids die in das
    # Resümee eingeflossen sind (Stage-2-LLM-Output im JSON-Mode).
    # Issue #715: flagged_claims trailing — Render-Gate-Flags aus dem
    # Wahrheitsbild-Pfad (nil auf Chain-Events → []).
    if lww_accept_summary?(payload["session_id"], ts) do
      :ok =
        :mnesia.write({
          S.session_summaries(),
          payload["session_id"],
          payload["campaign_id"],
          payload["content_md"] || "",
          ts,
          parse_summary_source(payload["source"]),
          payload["source_refs"] || [],
          payload["flagged_claims"] || []
        })
    end

    :ok
  end

  def apply_kind("SessionSummaryEdited", payload, ts, _meta) do
    case :mnesia.read(S.session_summaries(), payload["session_id"]) do
      # Issue #114: 8-Tupel (source_refs + flagged_claims trailing) — bei
      # manuellem Edit bleiben die alten source_refs erhalten (kein LLM-Output).
      # Issue #715: flagged_claims werden gelöscht, weil die Prosa nach dem
      # Edit nicht mehr die vom Gate geprüfte ist — alte Flags würden ins
      # Leere zeigen bzw. den falschen Text markieren.
      [{_, sid, cid, _content, existing_ts, _source, refs, _flagged}] ->
        if datetime_lt?(existing_ts, ts) do
          :ok =
            :mnesia.write({
              S.session_summaries(),
              sid,
              cid,
              payload["new_md"] || "",
              ts,
              :manual,
              refs,
              []
            })
        end

        :ok

      [] ->
        Logger.warning("SessionSummaryEdited for unknown session=#{payload["session_id"]}")
    end
  end

  # Issue #781 (I7-Bucket-C): LWW-by-event_id statt bedingungslosem Overwrite.
  # Ein zweiter Scoring-Lauf (oder ein zweiter Worker) gewinnt nur mit höherem
  # event_id → order-insensitiv, keine Snapshot-Divergenz mehr bei Umordnung.
  # event_id (UUIDv7) trailing in der Row (Schema #781).
  def apply_kind("SessionFaithfulnessScored", payload, ts, meta) do
    sid = payload["session_id"]
    event_id = Map.get(meta, :event_id)

    if event_id_supersedes?(event_id, existing_faithfulness_event_id(sid)) do
      :ok =
        :mnesia.write({
          S.session_faithfulness_scores(),
          sid,
          payload["campaign_id"],
          payload["score"],
          Jason.encode!(payload["claims"] || []),
          ts,
          event_id
        })
    end

    :ok
  end

  # Issue #651 (Wahrheitsbild, Phase A): per-Session extrahierte Fakten.
  # facts_json = Jason-encoded Liste von Fakt-Maps (wie claims oben).
  # Issue #781 (I7-Bucket-C): LWW-by-event_id — eine Re-Extraktion gewinnt nur
  # mit höherem event_id (order-insensitiv). event_id (UUIDv7) trailing.
  def apply_kind("SessionFactsExtracted", payload, ts, meta) do
    sid = payload["session_id"]
    event_id = Map.get(meta, :event_id)

    if event_id_supersedes?(event_id, existing_session_facts_event_id(sid)) do
      :ok =
        :mnesia.write({
          S.session_facts(),
          sid,
          payload["campaign_id"],
          Jason.encode!(payload["facts"] || []),
          ts,
          event_id
        })
    end

    :ok
  end

  # Issue #724 Slice F: GM-Korrektur eines Review-Queue-Fakts. Reiner LWW-Upsert
  # in der Overlay-Tabelle (session_facts bleibt unangetastet — s. Schema-
  # Kommentar). NIEMALS `:mnesia.delete` — auch `in_game_date_raw == ""` (Undo)
  # ist eine ganz normale Row, sonst wäre ein vertauschtes Set→Undo-Paar
  # order-sensitiv divergent (#698-Klasse: Undo käme zuerst an, fände nichts
  # zu löschen bzw. löschte die event_id-Referenz, das ältere Datum käme
  # danach an, fände keine Row zum LWW-Vergleich und insertete — zwei Worker
  # zeigen dann Unterschiedliches). `dismissed: true` schließt den Fakt sowohl
  # aus der Review-Queue (artifacts.ex) als auch aus jedem künftigen Zeitstrahl-
  # Republish aus (pipeline.ex) — nicht nur aus der Anzeige.
  def apply_kind("SessionFactDateSet", payload, _ts, meta) do
    sid = payload["session_id"]
    fid = payload["fact_id"]
    event_id = Map.get(meta, :event_id)

    if is_binary(sid) and is_binary(fid) do
      key = "#{sid}:#{fid}"

      if event_id_supersedes?(event_id, existing_fact_override_event_id(key)) do
        raw = String.slice(to_string(payload["in_game_date_raw"] || ""), 0, 200)
        dismissed = payload["dismissed"] == true

        :ok =
          :mnesia.write({
            S.session_fact_overrides(),
            key,
            sid,
            payload["campaign_id"],
            fid,
            raw,
            dismissed,
            event_id
          })
      end
    else
      Logger.warning(
        "SessionFactDateSet: fehlende session_id/fact_id (sid=#{inspect(sid)} fid=#{inspect(fid)}) — dropping"
      )
    end

    :ok
  end

  def apply_kind("ChronikEntryChanged", payload, _ts, meta) do
    # Issue #135: in_game_sort_key wird nicht mehr persistiert — Sort am
    # Read-Path. Payload-Feld bleibt akzeptiert (BC für ältere Events) und
    # wird ignoriert.
    # Issue #114: source_refs trailing — Stage 4 emittiert die utterance_ids
    # pro Eintrag aus dem Epos-Kontext + Session-Utterance-Liste.
    # Issue #385: markdown_body am Ende — verbatim User-Markdown für die
    # Chronik-Anzeige. nil bei alten Events (BC), wird beim ersten Edit
    # via Hub-Form gefüllt.
    # Issue #724: in_game_day (kanonischer Tageszähler, Sort-Schlüssel) +
    # precision (Rendering) trailing. nil bei :chain-Events + alten Events (BC).
    # Issue #698 (I7): generation (UUIDv7) trailing — Ordnungsschlüssel für den
    # Clear-Watermark-Vergleich am Read + LWW-by-generation bei gleicher id.
    # Pipeline-Runs setzen `payload["generation"]` (eine pro Run, Clear + alle
    # Entries teilen sie → within-run zuverlässig). Solitäre Events (Hub-Manual-
    # Edit, Seeds) haben keine → Fallback auf die Envelope-event_id (frisch/
    # später → live + gewinnt LWW). Ein schlüsselloses Alt-Event überschreibt
    # eine reguläre Row NICHT (chronik_entry_supersedes?/2).
    id = payload["id"]
    generation = payload["generation"] || Map.get(meta, :event_id)

    if event_id_supersedes?(generation, existing_chronik_generation(id)) do
      :ok =
        :mnesia.write({
          S.chronik_entries(),
          id,
          payload["campaign_id"],
          payload["in_game_date"],
          payload["label"],
          payload["summary"],
          payload["session_id"],
          payload["source_refs"] || [],
          payload["markdown_body"],
          payload["in_game_day"],
          payload["precision"],
          generation
        })
    end

    :ok
  end

  # Issue #227: Re-Run-Cleanup einer (campaign, session)-Chronik. Die Pipeline
  # emittiert das vor jedem Stage-4-Publish, damit Re-Runs keine Halluzinationen
  # früherer Läufe akkumulieren.
  #
  # Issue #698 (I7-Bucket-D): KEIN physisches Delete mehr — das war die
  # Resurrection-Quelle. Bei umgeordnetem Cold-Start-Replay konnte ein Clear VOR
  # den ChronikEntryChanged-Events eines früheren Runs greifen (löschte ins
  # Leere), dann lebten die Entries beim späteren Apply wieder auf (#698-Zombies,
  # #696-Klasse). Stattdessen: den Clear-Watermark der Session auf max(existing,
  # event_id) heben. `list_chronik_entries` filtert Rows mit event_id <= clear_key
  # raus. Der Producer emittiert den Clear VOR den Run-Entries → deren event_id
  # ist größer → live; Entries eines früheren Runs sind kleiner → unterdrückt.
  # Konvergent: egal in welcher Reihenfolge Clear/Entries applied werden, das
  # Endergebnis (Rows + Mark) und damit der gefilterte Read ist identisch.
  def apply_kind("ChronikClearedForSession", payload, _ts, meta) do
    campaign_id = payload["campaign_id"]
    session_id = payload["session_id"]
    generation = payload["generation"] || Map.get(meta, :event_id)

    if is_binary(session_id) and is_binary(generation) do
      new_key = max_clear_key(existing_clear_key(session_id), generation)
      :ok = :mnesia.write({S.chronik_clear_marks(), session_id, campaign_id, new_key})
    else
      Logger.warning(
        "ChronikClearedForSession: fehlende session_id/generation " <>
          "(sid=#{inspect(session_id)} gen=#{inspect(generation)}) — kein Clear-Mark gesetzt"
      )

      :ok
    end
  end

  def apply_kind("EposEntryEdited", payload, ts, meta) do
    entry_id = payload["entry_id"]
    campaign_id = payload["campaign_id"] || entry_id
    new_md = payload["new_md"] || ""
    # Issue #114: source_refs trailing — Stage 3 verkettet die source_refs
    # aller einfließenden Resümees, deduped. Bei manuellem Edit (source ==
    # "manual") behalten wir die vorherigen refs (kein neuer LLM-Output, kein
    # Drift). Bei LLM-Edit: das Payload bringt die neuen refs.
    source_refs =
      case payload["source_refs"] do
        list when is_list(list) -> list
        _ -> existing_epos_source_refs(entry_id)
      end

    # Issue #133 (Etappe 3d): LWW auf updated_at. Bei Sync mit älteren Events
    # nach lokalem Apply einer neueren Edition wird der ältere skipped — die
    # History-Row wird aber weiterhin geschrieben (Audit-Spur bleibt vollständig).
    upsert_current? =
      case :mnesia.read(S.epos_entries(), entry_id) do
        [{_, _, _, _, _, existing_updated_at, _refs}] -> datetime_lt?(existing_updated_at, ts)
        [] -> true
      end

    if upsert_current? do
      :ok =
        :mnesia.write({
          S.epos_entries(),
          entry_id,
          campaign_id,
          payload["parent_id"],
          new_md,
          ts,
          source_refs
        })
    end

    # Append a history row. History id is derived from event_id (Issue #123)
    # so re-applying the same event is idempotent (overwrites the same row).
    # Worker-First-Apply (seq=nil) und Hub-Broadcast-Reapply matchen über die
    # event_id auf denselben history_id. Pre-Migration-Events ohne event_id
    # fallen auf seq als Fallback zurück.
    history_id =
      case meta do
        %{event_id: id} when is_binary(id) -> "ehist-#{id}"
        %{seq: seq} when is_integer(seq) -> "ehist-#{seq}"
      end

    :ok =
      :mnesia.write({
        S.epos_history(),
        history_id,
        entry_id,
        new_md,
        ts,
        meta.author_worker_id,
        parse_epos_source(payload["source"]),
        meta.seq
      })
  end

  def apply_kind("ProbelaufStarted", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.probelauf_runs(),
        payload["run_id"],
        ts,
        nil,
        payload["started_by"],
        [],
        payload["settings_snapshot"] || %{},
        payload["sweep_id"],
        payload["sweep_variant"]
      })
  end

  def apply_kind("ProbelaufFinished", payload, ts, _meta) do
    run_id = payload["run_id"]

    {started_at, sweep_id_existing, sweep_variant_existing} =
      case :mnesia.read(S.probelauf_runs(), run_id) do
        # Post-migration shape (8 attrs + table tag = arity 9)
        [{_, _, started_at, _, _, _, _, sid, svar}] -> {started_at, sid, svar}
        # Pre-migration shape (6 attrs + table tag = arity 7) — defensive fallback
        [{_, _, started_at, _, _, _, _}] -> {started_at, nil, nil}
        _ -> {ts, nil, nil}
      end

    :ok =
      :mnesia.write({
        S.probelauf_runs(),
        run_id,
        started_at,
        ts,
        payload["started_by"],
        payload["sessions"] || [],
        payload["settings_snapshot"] || %{},
        payload["sweep_id"] || sweep_id_existing,
        payload["sweep_variant"] || sweep_variant_existing
      })
  end

  def apply_kind("ProbelaufSweepStarted", payload, ts, _meta) do
    :ok =
      :mnesia.write({
        S.probelauf_sweeps(),
        payload["sweep_id"],
        ts,
        nil,
        payload["started_by"],
        payload["stage"],
        payload["models"] || [],
        payload["default_model"],
        nil
      })
  end

  def apply_kind("ProbelaufSweepFinished", payload, ts, _meta) do
    sweep_id = payload["sweep_id"]
    variants = payload["variants"]

    case :mnesia.read(S.probelauf_sweeps(), sweep_id) do
      [{_, _, started_at, _, started_by, stage, models, default_model, _}] ->
        :ok =
          :mnesia.write({
            S.probelauf_sweeps(),
            sweep_id,
            started_at,
            ts,
            started_by,
            stage,
            models,
            default_model,
            variants
          })

      _ ->
        # SweepFinished without prior SweepStarted — shouldn't happen, but
        # don't crash. Materializer would be stuck on a corrupt eventlog.
        Logger.warning("Materializer: ProbelaufSweepFinished for unknown sweep_id=#{sweep_id}")
        :ok
    end
  end

  # Issue #140 Phase B: Spielleiter befördert / demotet einen Member.
  # `new_role ∈ "spielleiter" | "spieler"`. Idempotent — Re-Apply mit
  # gleichem Wert ist no-op. Tombstone-Schutz: ein per `MemberRemoved`
  # gelöschter Member wird NICHT durch ein nachgelagertes
  # `MemberRolePromoted` „wiederbelebt"; deleted_at bleibt erhalten und
  # die Repo-Reads filtern weiterhin raus.
  def apply_kind("MemberRolePromoted", payload, _ts, _meta) do
    key = S.member_key(payload["campaign_id"], payload["discord_id"])

    new_role =
      case payload["new_role"] do
        "spielleiter" -> :spielleiter
        "spieler" -> :spieler
        _ -> nil
      end

    cond do
      is_nil(new_role) ->
        Logger.warning(
          "MemberRolePromoted: invalid new_role=#{inspect(payload["new_role"])} for campaign=#{payload["campaign_id"]} did=#{payload["discord_id"]}"
        )

        :ok

      true ->
        case :mnesia.read(S.campaign_members(), key) do
          [{tbl, ^key, cid, did, _role, joined_at, character_name, deleted_at}] ->
            :mnesia.write({tbl, key, cid, did, new_role, joined_at, character_name, deleted_at})

          [] ->
            Logger.warning(
              "MemberRolePromoted for unknown member campaign=#{payload["campaign_id"]} did=#{payload["discord_id"]}"
            )

            :ok
        end
    end
  end

  def apply_kind(kind, _payload, _ts, _meta) do
    # Issue #471: einen Kind, der in Shared.Events existiert aber (noch) keinen
    # Materializer-Handler hat, bewusst leise ignorieren (debug). Ein Kind, der
    # GAR NICHT in Shared.Events steht, ist dagegen ein Tippfehler/Wire-Drift —
    # laut warnen statt still schlucken (Silent-Failure-Klasse).
    if kind in Shared.Events.all() do
      Logger.debug(fn ->
        "Materializer: kind=#{kind} hat (noch) keinen Handler — ignoriert"
      end)
    else
      Logger.warning(
        "Materializer: UNBEKANNTER kind=#{inspect(kind)} (nicht in Shared.Events) — " <>
          "Tippfehler oder Wire-Drift zwischen Producer und Worker?"
      )
    end

    :ok
  end

  # ─── Issue #698 (I7) Chronik-Konvergenz-Helfer ───────────────────

  # generation (12. Attribut → elem 11) der bestehenden Row, oder nil.
  defp existing_chronik_generation(id) do
    case :mnesia.read(S.chronik_entries(), id) do
      [row] when tuple_size(row) >= 12 -> elem(row, 11)
      _ -> nil
    end
  end

  # Issue #781: event_id der bestehenden session_facts-Row (6-Tupel → elem 5).
  defp existing_session_facts_event_id(sid) do
    case :mnesia.read(S.session_facts(), sid) do
      [row] when tuple_size(row) >= 6 -> elem(row, 5)
      _ -> nil
    end
  end

  # Issue #781: event_id der bestehenden faithfulness-Row (7-Tupel → elem 6).
  defp existing_faithfulness_event_id(sid) do
    case :mnesia.read(S.session_faithfulness_scores(), sid) do
      [row] when tuple_size(row) >= 7 -> elem(row, 6)
      _ -> nil
    end
  end

  # Issue #724: event_id der bestehenden Fact-Override-Row (8-Tupel → elem 7).
  defp existing_fact_override_event_id(key) do
    case :mnesia.read(S.session_fact_overrides(), key) do
      [row] when tuple_size(row) >= 8 -> elem(row, 7)
      _ -> nil
    end
  end

  # Issue #698/#781 (I7): generischer LWW-Guard über einen UUIDv7-Ordnungs-
  # schlüssel (event_id bzw. Chronik-generation). Höherer Schlüssel gewinnt
  # (UUIDv7 ist lexikografisch = chronologisch sortierbar). existing nil → immer
  # schreiben (neue Row / Pre-Migration). incoming nil bei vorhandenem existing →
  # NICHT clobbern (schlüsselloses Alt-Event darf eine reguläre Row nicht
  # überschreiben). beide nil → schreiben.
  defp event_id_supersedes?(_new, nil), do: true
  defp event_id_supersedes?(nil, _existing), do: false
  defp event_id_supersedes?(new, existing), do: new > existing

  # Clear-Watermark (elem 3) der Session, oder nil.
  defp existing_clear_key(session_id) do
    case :mnesia.read(S.chronik_clear_marks(), session_id) do
      [{_, _, _, key}] -> key
      [] -> nil
    end
  end

  defp max_clear_key(nil, new), do: new
  defp max_clear_key(existing, new), do: max(existing, new)
end
