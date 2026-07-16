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

  # Nach oben gezogen (waren weiter unten bei ihren jeweiligen apply_kind-
  # Klauseln definiert) — CampaignDeleted braucht beide schon für seinen
  # fold_meta-Cascade-Cleanup, Modul-Attribute müssen vor Erstnutzung stehen.
  @flavor_slots ~w(base summary epos chronik)
  @vorgabe_stages ~w(summary epos chronik)

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

  def apply_kind("CampaignDeleted", payload, _ts, _meta) do
    id = payload["campaign_id"]

    case :mnesia.read(S.campaigns(), id) do
      [] ->
        Logger.warning("CampaignDeleted for unknown id=#{id} — ignoring")

      [_] ->
        # Sessions zuerst — wir brauchen ihre IDs für utterances + markers.
        session_ids =
          S.sessions()
          |> :mnesia.index_read(id, :campaign_id)
          |> Enum.map(&elem(&1, 1))

        Enum.each(session_ids, fn sid ->
          :mnesia.index_read(S.utterances(), sid, :session_id)
          |> Enum.each(fn row ->
            utt_id = elem(row, 1)
            :mnesia.delete({S.utterances(), utt_id})
            # Issue #766: fold_meta-Cleanup — diese Iteration läuft komplett
            # unabhängig von SessionDeleted's eigener (CampaignDeleted dupliziert
            # die Cascade-Logik inline statt SessionDeleted aufzurufen), beide
            # Löschpfade müssen die Sidecar-Einträge eigenständig aufräumen.
            :mnesia.delete({S.fold_meta(), {S.utterances(), utt_id, :utterance_edited_text}})
            :mnesia.delete({S.fold_meta(), {S.utterances(), utt_id, :utterance_edited_ts}})
          end)

          :mnesia.index_read(S.markers(), sid, :session_id)
          |> Enum.each(fn row -> :mnesia.delete({S.markers(), elem(row, 1)}) end)

          # Issue #300: Sprecher-Zuordnungen (Single-Source, #19) hängen an
          # session_id — sonst Waisen nach Campaign-Delete.
          :mnesia.index_read(S.speaker_assignments(), sid, :session_id)
          |> Enum.each(fn row ->
            sa_key = elem(row, 1)
            :mnesia.delete({S.speaker_assignments(), sa_key})
            :mnesia.delete({S.fold_meta(), {S.speaker_assignments(), sa_key, :speaker_assigned}})
          end)

          # Issue #766, Drive-by-Fix: session_anchors war HIER bislang gar nicht
          # Teil der Cascade (Pre-#766-Lücke, unabhängig vom Sidecar-Thema) —
          # eine gelöschte Kampagne ließ ihre Session-Datum-Anker verwaist
          # zurück. Billig mitgefixt, da dieselbe Iteration schon da ist.
          :mnesia.delete({S.session_anchors(), sid})
          :mnesia.delete({S.fold_meta(), {S.session_anchors(), sid, :session_in_game_anchor_set}})

          :mnesia.delete({S.sessions(), sid})
        end)

        # Issue #766: member_keys/invite_tokens MÜSSEN vor den
        # delete_by_campaign-Aufrufen gelesen werden — danach sind die Rows
        # weg und index_read liefert nichts mehr, die fold_meta-Cleanup-Loops
        # unten wären sonst stille No-ops.
        member_keys =
          S.campaign_members() |> :mnesia.index_read(id, :campaign_id) |> Enum.map(&elem(&1, 1))

        invite_tokens =
          S.campaign_invites() |> :mnesia.index_read(id, :campaign_id) |> Enum.map(&elem(&1, 1))

        # Campaign-scoped tables.
        delete_by_campaign(S.campaign_members(), id)
        delete_by_campaign(S.campaign_invites(), id)
        delete_by_campaign(S.session_summaries(), id)
        delete_by_campaign(S.session_faithfulness_scores(), id)
        # #863 (+ Drive-by: session_facts fehlte in beiden Cascades, #801-Klasse).
        delete_by_campaign(S.session_facts(), id)
        delete_by_campaign(S.smoothed_blocks(), id)
        # #865: Lücken-Vorschläge + Kurations-Overlay.
        delete_by_campaign(S.luecken_vorschlaege(), id)
        delete_by_campaign(S.luecken_overrides(), id)
        delete_by_campaign(S.chronik_entries(), id)
        # Issue #698 (I7): Clear-Watermarks der Campaign mit wegräumen.
        delete_by_campaign(S.chronik_clear_marks(), id)
        delete_by_campaign(S.epos_entries(), id)
        delete_by_campaign(S.campaign_vorgaben(), id)

        # Issue #832 (Slice C) + zwei Drive-by-Fixes: campaign-id-geschlüsselte
        # Single-Row-Artefakte (Key = campaign_id, KEIN :campaign_id-Index →
        # direkter Delete, kein delete_by_campaign). Ihre fold_meta-Sidecars sind
        # auf DIESEN Tabellen geschlüsselt (record_fold_winner! bekommt
        # S.campaign_calendars()/S.thread_registry() als Table-Arg), nicht auf
        # S.campaigns() — daher hier, nicht in der campaigns-Fold-Schleife unten.
        #   • campaign_calendars-ROW war hier bislang GAR NICHT geräumt (Pre-#832-
        #     Lücke → verwaiste Kalender-Row nach Delete, analog dem #766-
        #     session_anchors-Drive-by); UND ihr :campaign_calendar_set-fold_meta
        #     wurde unten fälschlich auf {S.campaigns(), …} gelöscht (No-op-Leak).
        #   • thread_registry (neu, #832): Row + fold_meta.
        :mnesia.delete({S.campaign_calendars(), id})
        :mnesia.delete({S.fold_meta(), {S.campaign_calendars(), id, :campaign_calendar_set}})
        :mnesia.delete({S.thread_registry(), id})
        :mnesia.delete({S.fold_meta(), {S.thread_registry(), id, :thread_registry_computed}})

        # Issue #836 (Slice D2): Kurations-Overlay — :campaign_id-Index, Composite-
        # Key. Keys VOR dem Row-Delete lesen (danach liefert index_read nichts) für
        # den fold_meta-Cleanup (ein :thread_override_set-Fold je Overlay-Key).
        override_keys =
          S.thread_overrides() |> :mnesia.index_read(id, :campaign_id) |> Enum.map(&elem(&1, 1))

        delete_by_campaign(S.thread_overrides(), id)

        for ov_key <- override_keys do
          :mnesia.delete({S.fold_meta(), {S.thread_overrides(), ov_key, :thread_override_set}})
        end

        # Issue #766: fold_meta-Cleanup für die campaigns-geschlüsselten
        # Single-Row-Folds — feste, kleine Liste bekannter Fold-Namen, kein
        # Table-Scan nötig (row_key ist campaign_id oder eine simple
        # Komposition daraus). (:campaign_calendar_set ist bewusst NICHT hier —
        # er ist auf S.campaign_calendars() geschlüsselt, oben mitgeräumt.)
        for fold <- [
              :campaign_updated,
              :campaign_vocab_updated,
              :campaign_transcript_source_updated,
              :campaign_archived_status
            ] do
          :mnesia.delete({S.fold_meta(), {S.campaigns(), id, fold}})
        end

        for slot <- @flavor_slots do
          :mnesia.delete({S.fold_meta(), {S.campaigns(), {id, slot}, :campaign_flavor_set}})
        end

        for stage <- @vorgabe_stages do
          :mnesia.delete(
            {S.fold_meta(), {S.campaign_vorgaben(), "#{id}:#{stage}", :campaign_vorgabe_set}}
          )
        end

        for key <- member_keys do
          :mnesia.delete({S.fold_meta(), {S.campaign_members(), key, :member_role_promoted}})
          :mnesia.delete({S.fold_meta(), {S.campaign_members(), key, :campaign_alias_set}})
        end

        for token <- invite_tokens do
          :mnesia.delete({S.fold_meta(), {S.campaign_invites(), token, :invite_status}})
        end

        # Epos-Historie ist nach entry_id indiziert (entry_id == campaign_id
        # für die single-entry-pro-campaign-Welt).
        :mnesia.index_read(S.epos_history(), id, :entry_id)
        |> Enum.each(fn row -> :mnesia.delete({S.epos_history(), elem(row, 1)}) end)

        :mnesia.delete({S.campaigns(), id})

        Logger.info(
          "CampaignDeleted id=#{id} — cascade dropped #{length(session_ids)} session(s)"
        )
    end
  end

  # Issue #294: einzelne Session unwiderruflich löschen. Cascade analog zum
  # CampaignDeleted-Pfad, aber begrenzt auf diese eine session_id — Kampagne
  # und andere Sessions bleiben unberührt. Chronik-Einträge haben nur einen
  # :campaign_id-Index (kein :session_id-Index), daher Scan + Filter über
  # die Chronik der Campaign.
  def apply_kind("SessionDeleted", payload, _ts, _meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]

    case :mnesia.read(S.sessions(), sid) do
      [] ->
        Logger.warning("SessionDeleted for unknown session_id=#{sid} — ignoring")

      [_] ->
        :mnesia.index_read(S.utterances(), sid, :session_id)
        |> Enum.each(fn row ->
          utt_id = elem(row, 1)
          :mnesia.delete({S.utterances(), utt_id})
          # Issue #766: fold_meta-Cleanup, unabhängig von CampaignDeleted's
          # eigener Cascade-Iteration (die beiden Löschpfade sind komplett
          # separate Code, siehe Kommentar dort).
          :mnesia.delete({S.fold_meta(), {S.utterances(), utt_id, :utterance_edited_text}})
          :mnesia.delete({S.fold_meta(), {S.utterances(), utt_id, :utterance_edited_ts}})
        end)

        :mnesia.index_read(S.markers(), sid, :session_id)
        |> Enum.each(fn row -> :mnesia.delete({S.markers(), elem(row, 1)}) end)

        :mnesia.index_read(S.speaker_assignments(), sid, :session_id)
        |> Enum.each(fn row ->
          sa_key = elem(row, 1)
          :mnesia.delete({S.speaker_assignments(), sa_key})
          :mnesia.delete({S.fold_meta(), {S.speaker_assignments(), sa_key, :speaker_assigned}})
        end)

        # PK = session_id für alle vier. session_facts + smoothed_blocks: #863
        # (+ Drive-by — session_facts fehlte in BEIDEN Cascades, #801-Klasse).
        :mnesia.delete({S.session_summaries(), sid})
        :mnesia.delete({S.session_faithfulness_scores(), sid})
        :mnesia.delete({S.session_facts(), sid})
        :mnesia.delete({S.smoothed_blocks(), sid})

        # #865: Vorschläge + Overrides sind session-indiziert (PK = block_id
        # bzw. lo_key) → index_read + Einzel-Delete.
        :mnesia.index_read(S.luecken_vorschlaege(), sid, :session_id)
        |> Enum.each(fn row -> :mnesia.delete({S.luecken_vorschlaege(), elem(row, 1)}) end)

        :mnesia.index_read(S.luecken_overrides(), sid, :session_id)
        |> Enum.each(fn row -> :mnesia.delete({S.luecken_overrides(), elem(row, 1)}) end)

        # Issue #766, Drive-by-Fix: session_anchors war HIER bislang gar nicht
        # Teil der Cascade (Pre-#766-Lücke, unabhängig vom Sidecar-Thema, siehe
        # CampaignDeleted-Kommentar).
        :mnesia.delete({S.session_anchors(), sid})
        :mnesia.delete({S.fold_meta(), {S.session_anchors(), sid, :session_in_game_anchor_set}})

        # Chronik hat keinen session_id-Index → Campaign-Einträge scannen +
        # nach session_id filtern. Die session_id-Position im Tupel matched
        # der Attribute-Reihenfolge (siehe Schema): [id, campaign_id,
        # in_game_date, label, summary, session_id, source_refs] → elem 6.
        if is_binary(cid) do
          :mnesia.index_read(S.chronik_entries(), cid, :campaign_id)
          |> Enum.filter(fn row -> elem(row, 6) == sid end)
          |> Enum.each(fn row -> :mnesia.delete({S.chronik_entries(), elem(row, 1)}) end)
        end

        # Issue #698 (I7): Clear-Watermark der Session (PK = session_id) mit weg.
        :mnesia.delete({S.chronik_clear_marks(), sid})

        :mnesia.delete({S.sessions(), sid})

        Logger.info("SessionDeleted session_id=#{sid} (campaign_id=#{cid}) — cascade done")
    end
  end

  # Issue #766 (I7-Bucket-C): LWW-Guard via fold_meta-Sidecar, SLOT-GRANULAR
  # (row_key = {campaign_id, slot}, nicht nur campaign_id). Der Producer
  # (stil.ex maybe_flavor_event/5) schickt PRO SLOT ein eigenes Event — ein
  # gemeinsamer Fold-Key über alle 4 Slots hinweg wäre Partial-Payload und
  # würde zwei unabhängige Slot-Änderungen gegeneinander guarden (siehe
  # #816-Design-Fund 2: Worker A/B divergieren, wenn ein älteres Event für
  # Slot X nach einem neueren Event für Slot Y verworfen wird).
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
