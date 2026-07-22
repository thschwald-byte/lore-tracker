defmodule Worker.Materializer.Cascade do
  @moduledoc """
  Issue #865 (God-Module-Split aus `Worker.Materializer.Apply1`): die beiden
  Lösch-Kaskaden `CampaignDeleted`/`SessionDeleted` — die mit Abstand längsten
  apply_kind-Bodies. Läuft im selben Prozess + derselben Mnesia-Transaktion
  wie der Materializer (Apply1 delegiert seine Dispatch-Clauses hierher).
  Geteilte Helfer (`delete_by_campaign`, Slot-Listen) kommen via `import
  Worker.Materializer`.
  """
  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  # Single-Source in Worker.Materializer (flavor_slots/0, vorgabe_stages/0) —
  # Apply1 validiert Writes gegen dieselben Listen, die Cascade hier aufräumt.
  @flavor_slots Worker.Materializer.flavor_slots()
  @vorgabe_stages Worker.Materializer.vorgabe_stages()

  def campaign_deleted(payload, meta, ts) do
    id = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    # Issue #894 (I7-Bucket-D-Rest): Campaign-Tombstone IMMER schreiben (max) —
    # auch der `[]`-Zweig (Cold-Start-Global-Replay eines Deletes für eine nie
    # gekannte Campaign muss den Watermark setzen, damit später eintreffende
    # Pre-Delete-Events gegated werden). Die Tabelle wird von KEINER Cascade
    # gelöscht (Watermark überlebt jedes Re-Materialisieren).
    if is_binary(id), do: write_deletion_tombstone!({:campaign, id}, event_id)

    case :mnesia.read(S.campaigns(), id) do
      [] ->
        # Beim Cold-Start-Global-Replay der Normalfall, nicht Warnung: der
        # Delete trifft ein, bevor (oder ohne dass) die Campaign je materialisiert
        # wurde. Tombstone ist gesetzt, es gibt nur nichts zu kaskadieren.
        Logger.debug("CampaignDeleted for unknown id=#{id} — Tombstone gesetzt, keine Rows")

      [campaign] ->
        if reborn_after_delete?(campaign, ts) do
          # Issue #894 (L2): umgekehrte Ordnung — die lokale Campaign ist NEUER
          # (created_at) als dieser Delete → es ist ein Re-Seed/Rebirth, der Delete
          # gehört zur Vor-Inkarnation. Cascade überspringen (sonst reißt der alte
          # Delete die frischen Rows weg), Tombstone bleibt gesetzt (schadet nicht:
          # das Rebirth-CampaignCreated hat eine größere event_id → nicht gated).
          Logger.info(
            "CampaignDeleted id=#{id}: lokale Inkarnation ist neuer (created_at > delete-ts) " <>
              "— Cascade übersprungen, Tombstone gesetzt"
          )
        else
          do_campaign_cascade(id, event_id)
        end
    end
  end

  # Issue #894 (L2): true, wenn die lokale Campaign-Row NEUER ist als das
  # Delete-Event — dann ist der Delete veraltet (Re-Seed/Rebirth), Cascade
  # skippen. `created_at` = elem 6 der campaigns-Row (siehe Schema-Attribute).
  # Beide nicht-DateTime → false (kein Skip, konservativ Richtung Löschen).
  defp reborn_after_delete?(campaign, delete_ts) do
    case {elem(campaign, 6), delete_ts} do
      {%DateTime{} = created_at, %DateTime{} = d} -> DateTime.compare(created_at, d) == :gt
      _ -> false
    end
  end

  defp do_campaign_cascade(id, event_id) do
    # Sessions zuerst — wir brauchen ihre IDs für utterances + markers.
    session_ids =
      S.sessions()
      |> :mnesia.index_read(id, :campaign_id)
      |> Enum.map(&elem(&1, 1))

    # Issue #894 (L3): pro kaskadierter Session einen {:session, sid}-Tombstone
    # setzen — Session-only-Events ohne campaign_id (MarkerAdded,
    # LiveUtterancesCleared, SpeakerAssigned …) würden vom Campaign-Tombstone
    # sonst nicht gegated (die Session-Row für einen Lookup ist gleich weg).
    Enum.each(session_ids, fn sid -> write_deletion_tombstone!({:session, sid}, event_id) end)

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

    Logger.info("CampaignDeleted id=#{id} — cascade dropped #{length(session_ids)} session(s)")
  end

  # Issue #294: einzelne Session unwiderruflich löschen. Cascade analog zum
  # CampaignDeleted-Pfad, aber begrenzt auf diese eine session_id — Kampagne
  # und andere Sessions bleiben unberührt. Chronik-Einträge haben nur einen
  # :campaign_id-Index (kein :session_id-Index), daher Scan + Filter über
  # die Chronik der Campaign.
  def session_deleted(payload, meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    # Issue #894 (I7-Bucket-D-Rest): Session-Tombstone IMMER schreiben (max),
    # auch im `[]`-Zweig (Cold-Start-Replay eines Deletes für eine nie gekannte
    # Session). Kein created_at-Guard wie bei CampaignDeleted — Session-Rows
    # tragen keinen Create-Zeitstempel; Session-Rebirth in umgekehrter Ordnung
    # bleibt dokumentiertes Restrisiko (Bucket D-Variante).
    if is_binary(sid), do: write_deletion_tombstone!({:session, sid}, event_id)

    case :mnesia.read(S.sessions(), sid) do
      [] ->
        Logger.debug(
          "SessionDeleted for unknown session_id=#{sid} — Tombstone gesetzt, keine Rows"
        )

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
end
