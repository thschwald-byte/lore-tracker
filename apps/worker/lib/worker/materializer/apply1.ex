defmodule Worker.Materializer.Apply1 do
  @moduledoc """
  Issue #582 (God-Module-Split aus `Worker.Materializer`): erste Hälfte der
  `apply_kind/4`-Event-Handler (Campaign/Session/Utterance/User/Billing/
  AdminMember). Läuft im selben Prozess + derselben Mnesia-Transaktion wie der
  Materializer-GenServer (vom Dispatch-Router aufgerufen). Geteilte Decode-/
  Write-Helfer (`parse_*`, `delete_by_campaign`, `update_session_status`, …) bleiben in
  `Worker.Materializer` (`@doc false`-public) und kommen via `import` rein.

  Die finale Klausel liefert das Sentinel `:__unhandled__` → der Router probiert
  dann `Worker.Materializer.Apply2`.
  """
  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  # Single-Source in Worker.Materializer (#865 Cascade-Split): dieselben Listen
  # validieren hier die Writes und räumen in Cascade die fold_meta-Keys auf.
  @flavor_slots Worker.Materializer.flavor_slots()
  @vorgabe_stages Worker.Materializer.vorgabe_stages()

  def apply_kind("CampaignCreated", payload, ts, _meta) do
    id = payload["id"]
    # Issue #140: owner_discord_id bleibt im Wire-Event (Hub kennt den
    # Ersteller), wird aber nicht mehr ins campaigns-Schema geschrieben.
    # Stattdessen legen wir den Ersteller als Auto-Member mit role
    # :spielleiter an — die per-Campaign-Membership ist die einzige
    # Quelle der Wahrheit für „wer ist SL dieser Kampagne".
    creator = payload["owner_discord_id"]

    :ok =
      :mnesia.write({
        S.campaigns(),
        id,
        payload["name"],
        payload["icon_url"],
        payload["theme_blurb"],
        :active,
        ts,
        %{},
        nil,
        # Issue #394: transcript_source default :confirmed (batch).
        :confirmed
      })

    :ok =
      :mnesia.write({
        S.campaign_members(),
        S.member_key(id, creator),
        id,
        creator,
        :spielleiter,
        ts,
        nil,
        nil
      })

    display_name = payload["owner_display_name"] || creator

    {existing_joined_at, existing_avatar_url, existing_role, existing_cap} =
      case :mnesia.read(S.users(), creator) do
        [{_, _, _, j, a, r, c}] -> {j, a, r, c}
        [] -> {ts, nil, :spieler, nil}
      end

    :ok =
      :mnesia.write(
        {S.users(), creator, display_name, existing_joined_at, existing_avatar_url, existing_role,
         existing_cap}
      )
  end

  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Voll-Snapshot-
  # Invariante verifiziert gegen den einzigen Producer (dashboard_live.ex) —
  # schickt immer alle 3 Felder zusammen. `status` NICHT mehr aus dem Payload
  # übernommen (war `payload["status"] || status`, toter Branch — kein
  # Producer schickt je ein status-Feld hier; CampaignArchived ist der
  # exklusive Owner von status. Der tote Branch war eine latente
  # Feld-Kollision zwischen zwei Event-Kinds, siehe #816).
  def apply_kind("CampaignUpdated", payload, _ts, meta) do
    id = payload["id"]
    event_id = Map.get(meta, :event_id)

    unless Map.has_key?(payload, "name") and Map.has_key?(payload, "icon_url") and
             Map.has_key?(payload, "theme_blurb") do
      Logger.warning(
        "CampaignUpdated: Partial-Payload id=#{id} keys=#{inspect(Map.keys(payload))} — " <>
          "Voll-Snapshot-Invariante gebrochen, Fold-Guard konvergiert dann nicht mehr!"
      )
    end

    if fold_supersedes?(S.campaigns(), id, :campaign_updated, event_id) do
      case :mnesia.read(S.campaigns(), id) do
        [{_, ^id, name, icon, theme, status, created_at, flavors, vocab_hint, transcript_source}] ->
          :ok =
            :mnesia.write({
              S.campaigns(),
              id,
              payload["name"] || name,
              payload["icon_url"] || icon,
              payload["theme_blurb"] || theme,
              status,
              created_at,
              flavors,
              vocab_hint,
              transcript_source
            })

          record_fold_winner!(S.campaigns(), id, :campaign_updated, event_id)

        [] ->
          Logger.warning("CampaignUpdated for unknown id=#{id} — ignoring")
      end
    end
  end

  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Payload hat nur
  # 1 Feld (vocab_hint) — Voll-Snapshot-Invariante trivial erfüllt.
  def apply_kind("CampaignVocabUpdated", payload, _ts, meta) do
    id = payload["campaign_id"]
    vocab = payload["vocab_hint"]
    event_id = Map.get(meta, :event_id)

    if fold_supersedes?(S.campaigns(), id, :campaign_vocab_updated, event_id) do
      case :mnesia.read(S.campaigns(), id) do
        [{_, ^id, name, icon, theme, status, created_at, flavors, _old_hint, transcript_source}] ->
          :ok =
            :mnesia.write(
              {S.campaigns(), id, name, icon, theme, status, created_at, flavors, vocab,
               transcript_source}
            )

          record_fold_winner!(S.campaigns(), id, :campaign_vocab_updated, event_id)

        [] ->
          Logger.warning("CampaignVocabUpdated for unknown id=#{id} — ignoring")
      end
    end
  end

  # Issue #394: per-Kampagne Pipeline-Quelle (live | confirmed) setzen.
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Payload hat nur
  # 1 Feld (transcript_source) — Voll-Snapshot-Invariante trivial erfüllt.
  def apply_kind("CampaignTranscriptSourceUpdated", payload, _ts, meta) do
    id = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    source =
      case payload["transcript_source"] do
        "live" -> :live
        :live -> :live
        _ -> :confirmed
      end

    if fold_supersedes?(S.campaigns(), id, :campaign_transcript_source_updated, event_id) do
      case :mnesia.read(S.campaigns(), id) do
        [{_, ^id, name, icon, theme, status, created_at, flavors, vocab_hint, _old_source}] ->
          :ok =
            :mnesia.write(
              {S.campaigns(), id, name, icon, theme, status, created_at, flavors, vocab_hint,
               source}
            )

          record_fold_winner!(S.campaigns(), id, :campaign_transcript_source_updated, event_id)

        [] ->
          Logger.warning("CampaignTranscriptSourceUpdated for unknown id=#{id} — ignoring")
      end
    end
  end

  def apply_kind("CampaignDeleted", payload, ts, meta),
    do: Worker.Materializer.Cascade.campaign_deleted(payload, meta, ts)

  def apply_kind("SessionDeleted", payload, _ts, meta),
    do: Worker.Materializer.Cascade.session_deleted(payload, meta)

  def apply_kind("CampaignFlavorSet", payload, _ts, meta) do
    id = payload["campaign_id"]
    slot = payload["slot"] || "base"
    raw = payload["flavor"]
    event_id = Map.get(meta, :event_id)

    cond do
      slot not in @flavor_slots ->
        Logger.warning("CampaignFlavorSet: unknown slot=#{inspect(slot)} for id=#{id} — dropping")

      not fold_supersedes?(S.campaigns(), {id, slot}, :campaign_flavor_set, event_id) ->
        :ok

      true ->
        case :mnesia.read(S.campaigns(), id) do
          [
            {_, ^id, name, icon, theme, status, created_at, old_flavors, vocab_hint,
             transcript_source}
          ] ->
            existing =
              case old_flavors do
                m when is_map(m) -> m
                s when is_binary(s) and s != "" -> %{"base" => s}
                _ -> %{}
              end

            cleaned =
              case raw do
                nil -> nil
                s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
                _ -> nil
              end

            new_flavors =
              if is_nil(cleaned),
                do: Map.delete(existing, slot),
                else: Map.put(existing, slot, cleaned)

            :ok =
              :mnesia.write({
                S.campaigns(),
                id,
                name,
                icon,
                theme,
                status,
                created_at,
                new_flavors,
                vocab_hint,
                transcript_source
              })

            record_fold_winner!(S.campaigns(), {id, slot}, :campaign_flavor_set, event_id)

          [] ->
            Logger.warning("CampaignFlavorSet for unknown id=#{id} — ignoring")
        end
    end
  end

  # Issue #313: Ausgabe-Vorgabe pro Campaign × Stage in eigener Tabelle.
  # name+darstellungsform kommen als Bündel aus dem LV; beide leer ⇒ Row
  # löschen (Default greift wieder).
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Guard umschließt
  # BEIDE Zweige (Write UND Delete) — sonst könnte ein alter "lösch"-Event
  # einen neueren "setze"-Event resettieren oder umgekehrt. Voll-Snapshot-
  # Invariante erfüllt: der Producer (stil.ex) schickt name+darstellungsform
  # immer als Bündel, kein `\|\|`-Preserve gegen die bestehende Row nötig.
  def apply_kind("CampaignVorgabeSet", payload, _ts, meta) do
    id = payload["campaign_id"]
    stage = payload["stage"]
    event_id = Map.get(meta, :event_id)

    cond do
      stage not in @vorgabe_stages or not is_binary(id) ->
        Logger.warning(
          "CampaignVorgabeSet: bad stage/id (stage=#{inspect(stage)} id=#{inspect(id)}) — dropping"
        )

      true ->
        key = "#{id}:#{stage}"

        if fold_supersedes?(S.campaign_vorgaben(), key, :campaign_vorgabe_set, event_id) do
          name = vorgabe_clean(payload["name"])
          form = vorgabe_clean(payload["darstellungsform"])

          if is_nil(name) and is_nil(form) do
            :mnesia.delete({S.campaign_vorgaben(), key})
          else
            :ok = :mnesia.write({S.campaign_vorgaben(), key, id, stage, name, form})
          end

          record_fold_winner!(S.campaign_vorgaben(), key, :campaign_vorgabe_set, event_id)
        end
    end
  end

  # Issue #724: per-Campaign-Kalender. Über Worker.Timeline.Calendar
  # validiert/normalisiert (kaputte Struktur → Default) und als kanonisches JSON
  # gespeichert (Repo.get_campaign_calendar/1 erwartet einen JSON-String).
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Payload trägt
  # immer das gesamte Kalender-Objekt (kein Partial-Update) — Voll-Snapshot-
  # Invariante trivial erfüllt.
  def apply_kind("CampaignCalendarSet", payload, ts, meta) do
    id = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not is_binary(id) ->
        Logger.warning("CampaignCalendarSet: bad campaign_id (#{inspect(id)}) — dropping")

      not fold_supersedes?(S.campaign_calendars(), id, :campaign_calendar_set, event_id) ->
        :ok

      true ->
        json =
          payload["calendar"]
          |> Worker.Timeline.Calendar.from_json()
          |> Worker.Timeline.Calendar.to_json()
          |> Jason.encode!()

        :ok = :mnesia.write({S.campaign_calendars(), id, json, ts})
        record_fold_winner!(S.campaign_calendars(), id, :campaign_calendar_set, event_id)
    end
  end

  # Issue #724: In-Game-Datum-Anker der Session. Der Roh-String wird DETERMINI-
  # STISCH gegen den Campaign-Kalender aufgelöst (parse → to_day); parst er nicht,
  # bleibt day=nil (der Roh-String wird trotzdem bewahrt → im UI sichtbar, Fakten
  # fallen auf unknown statt falsch datiert). Leerer Roh-String ⇒ Anker löschen.
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Guard umschließt
  # BEIDE Zweige (Write UND Delete). Payload trägt immer den vollen
  # Roh-String (oder leer für "löschen") — Voll-Snapshot-Invariante erfüllt.
  def apply_kind("SessionInGameAnchorSet", payload, _ts, meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]
    raw = payload["in_game_date_raw"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(sid) and is_binary(cid)) ->
        Logger.warning(
          "SessionInGameAnchorSet: bad session/campaign id (sid=#{inspect(sid)} cid=#{inspect(cid)}) — dropping"
        )

      not fold_supersedes?(S.session_anchors(), sid, :session_in_game_anchor_set, event_id) ->
        :ok

      is_nil(raw) or (is_binary(raw) and String.trim(raw) == "") ->
        :mnesia.delete({S.session_anchors(), sid})
        record_fold_winner!(S.session_anchors(), sid, :session_in_game_anchor_set, event_id)

      true ->
        cal = read_campaign_calendar(cid)

        day =
          case Worker.Timeline.Calendar.parse(cal, raw) do
            {:ok, ymd} -> Worker.Timeline.Calendar.to_day(cal, ymd)
            :error -> nil
          end

        :ok = :mnesia.write({S.session_anchors(), sid, cid, day, raw})
        record_fold_winner!(S.session_anchors(), sid, :session_in_game_anchor_set, event_id)
    end
  end

  def apply_kind("SessionScheduled", payload, _ts, _meta) do
    :ok =
      :mnesia.write({
        S.sessions(),
        payload["id"],
        payload["campaign_id"],
        payload["number"],
        payload["name"],
        :scheduled,
        parse_ts(payload["scheduled_for"]),
        nil,
        nil
      })
  end

  def apply_kind("SessionStarted", payload, ts, _meta) do
    update_session_status(payload["id"], :recording, fn {_, id, cid, num, name, _status, sched,
                                                         _started, ended} ->
      {S.sessions(), id, cid, num, name, :recording, sched, ts, ended}
    end)
  end

  def apply_kind("SessionEnded", payload, ts, _meta) do
    update_session_status(payload["id"], :completed, fn {_, id, cid, num, name, _status, sched,
                                                         started, _ended} ->
      {S.sessions(), id, cid, num, name, :completed, sched, started, ts}
    end)
  end

  def apply_kind("RecordingStateChanged", payload, _ts, _meta) do
    new_status = parse_recording_state(payload["state"])

    update_session_status(payload["session_id"], new_status, fn {_, id, cid, num, name, _status,
                                                                 sched, started, ended} ->
      {S.sessions(), id, cid, num, name, new_status, sched, started, ended}
    end)
  end

  def apply_kind("UtteranceAppended", payload, event_ts, _meta) do
    # Issue #95: utterance-ts darf nie nil sein, sonst crasht `Worker.Repo.list_utterances`
    # in Enum.sort_by mit DateTime.compare(nil, nil). Seed-Events (Schlegel-JSONL)
    # tragen nur das Envelope-`ts`, kein payload `timestamp` — Fallback nötig.
    utt_ts = parse_ts(payload["timestamp"]) || event_ts || DateTime.utc_now()

    :ok =
      :mnesia.write({
        S.utterances(),
        payload["id"],
        payload["session_id"],
        payload["discord_id"],
        utt_ts,
        payload["text"],
        payload["confidence"],
        parse_utterance_status(payload["status"]),
        nil
      })
  end

  # Issue #759: `new_timestamp` optional. Wenn gesetzt, wird der Utterance-ts
  # aktualisiert; sonst bleibt der bestehende ts erhalten. Ermöglicht one-off-
  # Korrektur der durch #757/#758 verursachten Cross-Speaker-Drifts in bereits
  # aufgezeichneten Sessions ohne Delete+Re-Append (das würde `source_refs` in
  # Chronik/Epos brechen). Backwards-kompatibel: alle bestehenden Publishes
  # (Hub-UI-Edit-Modal) senden nur `new_text` → Verhalten unverändert.
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar, in ZWEI Folds
  # gesplittet — `new_text`+`new_status` sind ein Feld-Paar (immer zusammen
  # gesetzt), `new_timestamp` ist ein komplett unabhängiges zweites Feld
  # (Issue #759, Ad-hoc-Korrektur ohne committeten Producer). Ein
  # gemeinsamer Fold-Key wäre Partial-Payload und würde zwei unabhängige
  # Feld-Updates gegeneinander guarden (#816-Design-Fund 2). Jede Feld-Gruppe
  # wird nur geguarded/vermerkt, wenn das jeweilige Feld im Payload wirklich
  # gesetzt ist (fehlt es, bleibt der alte Wert unangetastet wie bisher).
  def apply_kind("UtteranceEdited", payload, _ts, meta) do
    id = payload["id"]
    event_id = Map.get(meta, :event_id)

    case :mnesia.read(S.utterances(), id) do
      [{tbl, ^id, sid, did, old_ts, old_text, conf, old_status, deleted_at}] ->
        new_ts =
          case payload["new_timestamp"] do
            nil ->
              old_ts

            raw ->
              if fold_supersedes?(S.utterances(), id, :utterance_edited_ts, event_id) do
                record_fold_winner!(S.utterances(), id, :utterance_edited_ts, event_id)
                parse_ts(raw) || old_ts
              else
                old_ts
              end
          end

        {new_text, new_status} =
          case payload["new_text"] do
            nil ->
              {old_text, old_status}

            text ->
              if fold_supersedes?(S.utterances(), id, :utterance_edited_text, event_id) do
                record_fold_winner!(S.utterances(), id, :utterance_edited_text, event_id)
                {text, :edited}
              else
                {old_text, old_status}
              end
          end

        :ok =
          :mnesia.write({tbl, id, sid, did, new_ts, new_text, conf, new_status, deleted_at})

      [] ->
        Logger.warning("UtteranceEdited for unknown id=#{id} — dropping")
        :ok
    end
  end

  # Issue #133 (Etappe 3d): Tombstone statt :mnesia.delete.
  def apply_kind("UtteranceDeleted", payload, ts, _meta) do
    id = payload["id"]

    case :mnesia.read(S.utterances(), id) do
      [{tbl, ^id, sid, did, ts_ut, text, conf, status, _old_del}] ->
        :ok = :mnesia.write({tbl, id, sid, did, ts_ut, text, conf, status, ts})

      [] ->
        :ok
    end
  end

  # Issue #19: Sprecher-Zuordnung. Utterances behalten ihr Pseudo-Label —
  # diese Tabelle mappt Label → echte discord_id (aufgelöst beim Lesen).
  # discord_id leer/nil → Zuordnung aufheben (Row löschen). Idempotent:
  # Re-Assignment überschreibt einfach.
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Guard umschließt
  # BEIDE Zweige (Write UND Delete) — sonst könnte ein alter "lösch"-Event
  # eine neuere Zuordnung resettieren oder umgekehrt.
  def apply_kind("SpeakerAssigned", payload, ts, meta) do
    session_id = payload["session_id"]
    label = payload["speaker_label"]
    did = payload["discord_id"]
    key = S.speaker_assignment_key(session_id, label)
    event_id = Map.get(meta, :event_id)

    if fold_supersedes?(S.speaker_assignments(), key, :speaker_assigned, event_id) do
      if is_binary(did) and did != "" do
        :ok =
          :mnesia.write({
            S.speaker_assignments(),
            key,
            session_id,
            label,
            did,
            ts || DateTime.utc_now()
          })
      else
        :ok = :mnesia.delete({S.speaker_assignments(), key})
      end

      record_fold_winner!(S.speaker_assignments(), key, :speaker_assigned, event_id)
    else
      :ok
    end
  end

  def apply_kind("LiveUtterancesCleared", payload, _ts, _meta) do
    session_id = payload["session_id"]

    rows = :mnesia.index_read(S.utterances(), session_id, :session_id)

    Enum.each(rows, fn row ->
      {id, status} =
        case row do
          {_, id, _sid, _did, _ts, _text, _conf, status, _del} -> {id, status}
          {_, id, _sid, _did, _ts, _text, _conf, status} -> {id, status}
        end

      if status == :live, do: :mnesia.delete({S.utterances(), id})
    end)

    :ok
  end

  def apply_kind("UserUpserted", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || discord_id

    {existing_joined_at, existing_avatar_url, existing_role, existing_cap} =
      case :mnesia.read(S.users(), discord_id) do
        [{_, _, _, j, a, r, c}] -> {j, a, r, c}
        [] -> {ts, nil, :spieler, nil}
      end

    # avatar_url in the payload wins (allows refresh); fall back to existing
    # so an older event without the field doesn't blank the avatar.
    avatar_url =
      case Map.fetch(payload, "avatar_url") do
        {:ok, url} -> url
        :error -> existing_avatar_url
      end

    :ok =
      :mnesia.write({
        S.users(),
        discord_id,
        display_name,
        existing_joined_at,
        avatar_url,
        existing_role,
        existing_cap
      })
  end

  # Issue #64: pro Discord-User wird vermerkt dass das Audio-Consent-Modal
  # akzeptiert wurde. version ("v1") taggt den Wording-Stand — wenn der
  # Inhalt später ändert (v2), kann eine neue Akzeptanz erzwungen werden,
  # indem die LV nur v_current als "consented" durchgehen lässt.
  # Issue #177: Spend-Tracking — pro Cloud-LLM-Call ein Row in `worker_llm_spend`.
  # event_id ist der UUIDv7 aus dem Envelope (Materializer-Outer-Wrap), nicht
  # vom payload — wir greifen via meta.event_id zu, oder generieren einen
  # synthetischen Key wenn das je passieren sollte (sicherheitsnetz).
  def apply_kind("LLMCallBilled", payload, ts, meta) do
    event_id = Map.get(meta, :event_id) || "synth-#{:erlang.unique_integer([:positive])}"

    :ok =
      :mnesia.write({
        S.llm_spend(),
        event_id,
        ts,
        payload["provider"],
        payload["model"],
        payload["input_tokens"] || 0,
        payload["output_tokens"] || 0,
        payload["cost_usd"] || 0.0,
        payload["requested_by_discord_id"],
        payload["session_id"],
        payload["stage"],
        payload["duration_ms"]
      })
  end

  # Issue #68 (Phase 1): strukturiertes Pipeline-Fehler-Log. Pipeline.run_stages
  # publisht den Event auf jedem `{:error, reason}`-Pfad, /admin/errors liest
  # via Worker.Repo.last_n_pipeline_errors/1.
  def apply_kind("PipelineErrorLogged", payload, ts, meta) do
    error_id =
      payload["error_id"] || Map.get(meta, :event_id) ||
        "synth-#{:erlang.unique_integer([:positive])}"

    :ok =
      :mnesia.write({
        S.pipeline_errors(),
        error_id,
        ts,
        payload["session_id"],
        payload["campaign_id"],
        payload["stage"],
        payload["error_type"],
        payload["message"],
        payload["context"] || %{}
      })
  end

  def apply_kind("AudioConsentRecorded", payload, ts, _meta) do
    discord_id = payload["discord_id"]
    version = payload["version"] || "v1"

    accepted_at =
      case payload["accepted_at"] do
        nil ->
          ts

        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> ts
          end

        %DateTime{} = dt ->
          dt
      end

    # Issue #824 (Bucket C2): Max-Version-Lattice statt reinem Overwrite —
    # ein nachgezogenes altes Consent-Event darf eine bereits erteilte
    # neuere Zustimmungsversion nie zurückdrehen.
    if consent_version_supersedes?(discord_id, version, accepted_at) do
      :ok =
        :mnesia.write({
          S.audio_consents(),
          discord_id,
          version,
          accepted_at
        })
    end
  end

  def apply_kind("AdminMemberAdded", payload, ts, _meta) do
    campaign_id = payload["campaign_id"]
    discord_id = payload["discord_id"]
    display_name = payload["display_name"] || discord_id

    case :mnesia.read(S.campaigns(), campaign_id) do
      [] ->
        Logger.warning("AdminMemberAdded for unknown campaign=#{campaign_id} — ignoring")

      [_] ->
        # User-Row anlegen wenn nicht vorhanden (preserves existing role + cap).
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

        # Member-Row anlegen (idempotent — gleicher composite key überschreibt).
        # character_name bleibt erhalten falls schon Mitglied. deleted_at wird
        # explizit auf nil gesetzt (Re-Join nach Remove ist möglich).
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
    end
  end

  @valid_roles ~w(admin spielleiter spieler)

  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Payload hat nur
  # 1 Feld (role) — Voll-Snapshot-Invariante trivial erfüllt.
  def apply_kind("UserRoleSet", payload, ts, meta) do
    discord_id = payload["discord_id"]
    role_str = payload["role"]
    event_id = Map.get(meta, :event_id)

    cond do
      role_str not in @valid_roles ->
        Logger.warning(
          "UserRoleSet: unknown role=#{inspect(role_str)} for discord_id=#{discord_id} — dropping"
        )

      not fold_supersedes?(S.users(), discord_id, :user_role_set, event_id) ->
        :ok

      true ->
        # Issue #646: explizites String→Atom-Mapping statt String.to_existing_atom.
        # Der frühere Kommentar verließ sich darauf, dass :admin/:spielleiter/:spieler
        # via HubWeb.Permissions compile-zeit-interniert seien — das ist aber die
        # HUB-App. Im reinen Worker-BEAM (worker_prod, Eval-Bootstrap) ist :admin
        # beim ersten UserRoleSet u.U. noch nicht geladen → binary_to_existing_atom
        # wirft :badarg → Mnesia-Abort → Materializer-Crash. Das Mapping erzwingt
        # die Atom-Existenz im Worker selbst und ist unabhängig von Lade-Reihenfolge.
        role = role_str_to_atom(role_str)

        {display_name, joined_at, avatar_url, cap} =
          case :mnesia.read(S.users(), discord_id) do
            [{_, _, name, j, a, _, c}] -> {name, j, a, c}
            [] -> {discord_id, ts, nil, nil}
          end

        :ok =
          :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role, cap})

        record_fold_winner!(S.users(), discord_id, :user_role_set, event_id)
    end
  end

  # Issue #178: Admin setzt einen Per-User-Spend-Cap (USD/Monat). Nil = kein
  # Cap. Cap-Check passiert in `Worker.LLM.complete/3` vor jedem Cloud-Call.
  # Wenn der User-Row noch nicht existiert (z.B. der User war nie online),
  # legen wir einen Stub mit minimalen Defaults an — der nächste UserUpserted
  # füllt display_name + avatar_url nach.
  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar. Payload hat nur
  # 1 Feld (cap_usd) — Voll-Snapshot-Invariante trivial erfüllt.
  def apply_kind("UserSpendCapChanged", payload, ts, meta) do
    discord_id = payload["discord_id"]
    cap_usd = parse_cap(payload["cap_usd"])
    event_id = Map.get(meta, :event_id)

    if fold_supersedes?(S.users(), discord_id, :user_spend_cap_changed, event_id) do
      {display_name, joined_at, avatar_url, role} =
        case :mnesia.read(S.users(), discord_id) do
          [{_, _, name, j, a, r, _}] -> {name, j, a, r}
          [] -> {discord_id, ts, nil, :spieler}
        end

      :ok =
        :mnesia.write({S.users(), discord_id, display_name, joined_at, avatar_url, role, cap_usd})

      record_fold_winner!(S.users(), discord_id, :user_spend_cap_changed, event_id)
    end
  end

  def apply_kind(_kind, _payload, _ts, _meta), do: :__unhandled__

  # Issue #646: String→Atom ohne to_existing_atom. Exhaustiv über @valid_roles
  # (`~w(admin spielleiter spieler)`) — der Aufrufer (UserRoleSet) gated role_str
  # dagegen, ein nicht-gematchter Wert kann hier strukturell nicht ankommen.
  defp role_str_to_atom("admin"), do: :admin
  defp role_str_to_atom("spielleiter"), do: :spielleiter
  defp role_str_to_atom("spieler"), do: :spieler

  # Issue #724: Kalender einer Campaign INNERHALB der laufenden Materializer-
  # Transaktion lesen (kein Repo-Nested-Tx). Fehlende Row / kaputtes JSON →
  # Default.
  defp read_campaign_calendar(cid) do
    case :mnesia.read(S.campaign_calendars(), cid) do
      [{_, _, json, _}] when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} -> Worker.Timeline.Calendar.from_json(map)
          _ -> Worker.Timeline.Calendar.default()
        end

      _ ->
        Worker.Timeline.Calendar.default()
    end
  end
end
