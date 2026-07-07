defmodule Worker.Schema.Migrations do
  @moduledoc """
  Idempotente In-Place-Schema-Migrationen der Worker-Mnesia-Tabellen
  (Issue #606, God-Module-Split aus `Worker.Schema.Mnesia`).

  Jede `migrate_*!/0` wird aus `Worker.Schema.Mnesia.bootstrap!/0` direkt nach
  dem `ensure_table!` der jeweiligen Tabelle aufgerufen. Idempotenz: spalten-
  basierte Migrationen skippen, wenn die Ziel-Spalte schon existiert; die
  nicht-spalten-basierten (Rename/Repair) über ein Flag im `worker_state`
  (`migration_done?/1` + `mark_migration_done!/1`).

  Die Tabellen-Atome werden aus den `Worker.Schema.Mnesia`-Accessoren gespiegelt
  (SSoT bleibt dort, kein dupliziertes `:worker_*`-Literal → drift-sicher).
  """
  alias Worker.Schema.Mnesia

  @worker_state Mnesia.worker_state()
  @users Mnesia.users()
  @campaigns Mnesia.campaigns()
  @campaign_members Mnesia.campaign_members()
  @utterances Mnesia.utterances()
  @epos_entries Mnesia.epos_entries()
  @session_summaries Mnesia.session_summaries()
  @chronik_entries Mnesia.chronik_entries()
  @probelauf_runs Mnesia.probelauf_runs()
  @probelauf_sweeps Mnesia.probelauf_sweeps()

  # Idempotent in-place upgrade for the users table to add an :avatar_url
  # column (Issue #6). Old rows have arity 4:
  #   {table, discord_id, display_name, joined_at}
  # New rows have arity 5:
  #   {table, discord_id, display_name, joined_at, avatar_url}
  #
  # Skip-Check ist „avatar_url ist schon in den Spalten" — robust gegen
  # weitere Migrations (z.B. migrate_users_role!), die zusätzliche Spalten
  # *hinter* :avatar_url anhängen. Vergleich gegen die exakte 4-Feld-Zielform
  # würde sonst auf einer schon weiter-migrierten Tabelle erneut feuern und
  # an einem 6-Tuple-Row mit function_clause crashen (Issue #42).
  def migrate_users_avatar_url! do
    current_attrs = :mnesia.table_info(@users, :attributes)

    if :avatar_url in current_attrs do
      :ok
    else
      target_attrs = [:discord_id, :display_name, :joined_at, :avatar_url]
      transform = fn {tbl, did, name, joined_at} -> {tbl, did, name, joined_at, nil} end
      {:atomic, :ok} = :mnesia.transform_table(@users, transform, target_attrs)
      :ok
    end
  end

  # Idempotent in-place upgrade for users to add a :role field (Issue #34).
  # arity 5 → 6. Default für bestehende User: :spieler. Erst-gepairter
  # User pro Instance bekommt :admin per UserRoleSet-Event aus dem
  # Pairing-Flow.
  def migrate_users_role! do
    current_attrs = :mnesia.table_info(@users, :attributes)

    if :role in current_attrs do
      :ok
    else
      target_attrs = [:discord_id, :display_name, :joined_at, :avatar_url, :role]

      transform = fn {tbl, did, name, joined_at, avatar} ->
        {tbl, did, name, joined_at, avatar, :spieler}
      end

      {:atomic, :ok} = :mnesia.transform_table(@users, transform, target_attrs)
      :ok
    end
  end

  # Idempotent in-place upgrade for users to add a :monthly_spend_cap_usd
  # field (Issue #178). arity 6 → 7. Default für bestehende User: nil =
  # kein Cap (unlimited). Admin setzt per /admin/users.
  def migrate_users_monthly_spend_cap_usd! do
    current_attrs = :mnesia.table_info(@users, :attributes)

    if :monthly_spend_cap_usd in current_attrs do
      :ok
    else
      target_attrs = [
        :discord_id,
        :display_name,
        :joined_at,
        :avatar_url,
        :role,
        :monthly_spend_cap_usd
      ]

      transform = fn {tbl, did, name, joined_at, avatar, role} ->
        {tbl, did, name, joined_at, avatar, role, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@users, transform, target_attrs)
      :ok
    end
  end

  # Idempotent in-place upgrade for the campaign_members table to add a
  # :character_name column (Issue #2). Old rows have arity 6:
  #   {table, cm_key, campaign_id, discord_id, role, joined_at}
  # New rows have arity 7 (one extra trailing field):
  #   {table, cm_key, campaign_id, discord_id, role, joined_at, character_name}
  # If the table is already at the new shape, transform_table is a no-op.
  def migrate_campaign_members_character_name! do
    current_attrs = :mnesia.table_info(@campaign_members, :attributes)
    target_attrs = [:cm_key, :campaign_id, :discord_id, :role, :joined_at, :character_name]

    cond do
      # Tabelle ist exakt auf Pre-3d-Form (6 atoms, character_name letztes): nichts zu tun.
      current_attrs == target_attrs ->
        :ok

      # Tabelle ist schon auf 3d-Form oder weiter (≥ 7 atoms inkl. :deleted_at):
      # überspringen — `migrate_campaign_members_deleted_at!/0` handelt das.
      # Verhindert function_clause-Crash in der transform-Funktion unten.
      length(current_attrs) > length(target_attrs) ->
        :ok

      true ->
        transform = fn
          {tbl, key, cid, did, role, joined_at} ->
            {tbl, key, cid, did, role, joined_at, nil}

          already_upgraded when tuple_size(already_upgraded) == 7 ->
            already_upgraded
        end

        {:atomic, :ok} =
          :mnesia.transform_table(@campaign_members, transform, target_attrs)

        :ok
    end
  end

  # Issue #133 (Etappe 3d): tombstone column. arity 7→8 mit deleted_at=nil.
  # MemberRemoved schreibt jetzt deleted_at statt zu :mnesia.delete'n, damit
  # ein verspäteter Sync den Remove respektiert (LWW: jüngere Tombstone
  # gewinnt gegen alte Edit-Events).
  def migrate_campaign_members_deleted_at! do
    current_attrs = :mnesia.table_info(@campaign_members, :attributes)

    target_attrs = [
      :cm_key,
      :campaign_id,
      :discord_id,
      :role,
      :joined_at,
      :character_name,
      :deleted_at
    ]

    if current_attrs == target_attrs do
      :ok
    else
      transform = fn
        {tbl, key, cid, did, role, joined_at, character_name} ->
          {tbl, key, cid, did, role, joined_at, character_name, nil}

        already_upgraded when tuple_size(already_upgraded) == 9 ->
          already_upgraded
      end

      {:atomic, :ok} =
        :mnesia.transform_table(@campaign_members, transform, target_attrs)

      :ok
    end
  end

  # Issue #133 (Etappe 3d): tombstone column für utterances. arity 8→9.
  def migrate_utterances_deleted_at! do
    current_attrs = :mnesia.table_info(@utterances, :attributes)

    target_attrs = [
      :id,
      :session_id,
      :discord_id,
      :timestamp,
      :text,
      :confidence,
      :status,
      :deleted_at
    ]

    if current_attrs == target_attrs do
      :ok
    else
      transform = fn
        {tbl, id, sid, did, ts, text, conf, status} ->
          {tbl, id, sid, did, ts, text, conf, status, nil}

        already_upgraded when tuple_size(already_upgraded) == 10 ->
          already_upgraded
      end

      {:atomic, :ok} =
        :mnesia.transform_table(@utterances, transform, target_attrs)

      :ok
    end
  end

  # Idempotent in-place upgrade für campaigns: trailende :flavor-Spalte
  # (LLM-Stilanweisung). arity 7→8. Default nil. Wird durch
  # migrate_campaigns_flavors! nochmal von :flavor → :flavors aufgewertet;
  # bleibt hier als Zwischenschritt für DBs, die noch auf arity 7 sind.
  def migrate_campaigns_flavor! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    target_attrs_old = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavor
    ]

    target_attrs_new = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavors
    ]

    # Issue #140 post-A hotfix: nach dem owner_discord_id-Drop ist die Tabelle
    # in der Phase-A-Shape; diese Migration darf NICHT mehr feuern (würde
    # arity-8 als „pre-flavor old shape" missinterpretieren und Felder
    # vertauschen — exakter Bug, der Vulpes' worker_prod zerlegt hat).
    target_attrs_post_phase_a = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :created_at,
      :flavors
    ]

    cond do
      :vocab_hint in current_attrs ->
        :ok

      current_attrs == target_attrs_old or
        current_attrs == target_attrs_new or
          current_attrs == target_attrs_post_phase_a ->
        :ok

      true ->
        transform = fn
          {tbl, id, name, icon, blurb, status, owner, created_at} ->
            {tbl, id, name, icon, blurb, status, owner, created_at, nil}

          already_upgraded when tuple_size(already_upgraded) == 9 ->
            already_upgraded
        end

        {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs_old)
        :ok
    end
  end

  # Idempotent in-place upgrade: einzelnes :flavor (string|nil) → :flavors
  # (map). arity bleibt 8, nur das letzte Element wechselt den Shape.
  # Altdaten: string → %{"base" => string}; nil → %{}; map → identity.
  def migrate_campaigns_flavors! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    target_attrs = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :owner_discord_id,
      :created_at,
      :flavors
    ]

    # Issue #140 post-A hotfix: post-Phase-A-Shape (ohne owner_discord_id)
    # ist hier ein no-op. Diese Migration ist Pre-Phase-A; sie würde sonst
    # versuchen, eine 8-tuple Phase-A-Tabelle nach 8-tuple-mit-Owner zu
    # transformieren und dabei Felder vermischen.
    target_attrs_post_phase_a = [
      :id,
      :name,
      :icon_url,
      :theme_blurb,
      :status,
      :created_at,
      :flavors
    ]

    if :vocab_hint in current_attrs or current_attrs == target_attrs or
         current_attrs == target_attrs_post_phase_a do
      :ok
    else
      transform = fn
        {tbl, id, name, icon, blurb, status, owner, created_at, flavor} ->
          new_flavors =
            case flavor do
              nil -> %{}
              "" -> %{}
              s when is_binary(s) -> %{"base" => s}
              m when is_map(m) -> m
              _ -> %{}
            end

          {tbl, id, name, icon, blurb, status, owner, created_at, new_flavors}
      end

      {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs)
      :ok
    end
  end

  # Issue #88 (Phase 2a): probelauf_runs bekommt sweep_id + sweep_variant
  # als optionale Felder. arity 6 → 8. Default für bestehende Runs:
  # beide nil (= waren kein Teil eines Sweeps).
  def migrate_probelauf_runs_sweep_tags! do
    current_attrs = :mnesia.table_info(@probelauf_runs, :attributes)

    if :sweep_id in current_attrs do
      :ok
    else
      target_attrs = [
        :run_id,
        :started_at,
        :finished_at,
        :started_by,
        :sessions,
        :settings_snapshot,
        :sweep_id,
        :sweep_variant
      ]

      transform = fn {tbl, run_id, started_at, finished_at, started_by, sessions, snap} ->
        {tbl, run_id, started_at, finished_at, started_by, sessions, snap, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@probelauf_runs, transform, target_attrs)
      {:atomic, :ok} = :mnesia.add_table_index(@probelauf_runs, :sweep_id)
      :ok
    end
  end

  # Issue #281: probelauf_sweeps bekommt :variants als optionales Feld
  # (nil für non-isolated, Liste %{"model", "sessions"} für isolated).
  # arity 7 → 8.
  def migrate_probelauf_sweeps_add_variants! do
    current_attrs = :mnesia.table_info(@probelauf_sweeps, :attributes)

    if :variants in current_attrs do
      :ok
    else
      target_attrs = [
        :sweep_id,
        :started_at,
        :finished_at,
        :started_by,
        :stage,
        :models,
        :default_model,
        :variants
      ]

      transform = fn {tbl, sid, started_at, finished_at, started_by, stage, models, default_model} ->
        {tbl, sid, started_at, finished_at, started_by, stage, models, default_model, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@probelauf_sweeps, transform, target_attrs)
      :ok
    end
  end

  # Issue #135: in_game_sort_key war ein persistiertes derived value, das aus
  # in_game_date ableitbar ist. Sort passiert jetzt am Read-Path in
  # Worker.Repo.list_chronik_entries/1. arity 8 → 7.
  def migrate_chronik_entries_drop_sort_key! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :in_game_sort_key in current_attrs do
      target_attrs = [:id, :campaign_id, :in_game_date, :label, :summary, :session_id]

      transform = fn {tbl, id, cid, in_game_date, _sort_key, label, summary, sid} ->
        {tbl, id, cid, in_game_date, label, summary, sid}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    else
      :ok
    end
  end

  # Issue #114: source_refs ([utterance_id]) trailing in den drei LLM-Output-
  # Tabellen. Default [] für alle bestehenden Rows — Pipeline-Replay füllt
  # dann selektiv. Idempotent: skip wenn :source_refs schon im Schema.

  def migrate_session_summaries_add_source_refs! do
    current_attrs = :mnesia.table_info(@session_summaries, :attributes)

    if :source_refs in current_attrs do
      :ok
    else
      target_attrs = [
        :session_id,
        :campaign_id,
        :content_md,
        :generated_at,
        :source,
        :source_refs
      ]

      transform = fn {tbl, sid, cid, content, ts, src} ->
        {tbl, sid, cid, content, ts, src, []}
      end

      {:atomic, :ok} = :mnesia.transform_table(@session_summaries, transform, target_attrs)
      :ok
    end
  end

  # Issue #715: flagged_claims trailing an @session_summaries — vom Render-Gate
  # gemerkte, nicht auf verifizierte Fakten zurückführbare Prosa-Claims. Alte
  # Rows bekommen []; Pipeline-Replay füllt selektiv (Wahrheitsbild-Pfad) bzw.
  # bleibt leer (Chain-Pfad, kein Gate-Output). Idempotent: skip wenn schon da.
  def migrate_session_summaries_add_flagged_claims! do
    current_attrs = :mnesia.table_info(@session_summaries, :attributes)

    if :flagged_claims in current_attrs do
      :ok
    else
      target_attrs = [
        :session_id,
        :campaign_id,
        :content_md,
        :generated_at,
        :source,
        :source_refs,
        :flagged_claims
      ]

      transform = fn {tbl, sid, cid, content, ts, src, refs} ->
        {tbl, sid, cid, content, ts, src, refs, []}
      end

      {:atomic, :ok} = :mnesia.transform_table(@session_summaries, transform, target_attrs)
      :ok
    end
  end

  def migrate_epos_entries_add_source_refs! do
    current_attrs = :mnesia.table_info(@epos_entries, :attributes)

    if :source_refs in current_attrs do
      :ok
    else
      target_attrs = [:id, :campaign_id, :parent_id, :content_md, :updated_at, :source_refs]

      transform = fn {tbl, id, cid, parent, content, ts} ->
        {tbl, id, cid, parent, content, ts, []}
      end

      {:atomic, :ok} = :mnesia.transform_table(@epos_entries, transform, target_attrs)
      :ok
    end
  end

  def migrate_chronik_entries_add_source_refs! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :source_refs in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid} ->
        {tbl, id, cid, date, label, summary, sid, []}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #385: markdown_body als 9. Spalte am Ende. Verbatim User-Markdown
  # für die Chronik-Anzeige im Hub. Default nil → Lazy-Migration alter
  # Einträge beim ersten Edit. Idempotent.
  def migrate_chronik_entries_add_markdown_body! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :markdown_body in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs} ->
        {tbl, id, cid, date, label, summary, sid, refs, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #724: Zeitstrahl-Spalten `in_game_day` (Integer|nil, kanonischer
  # Tageszähler = Sort-Schlüssel) + `precision` (String|nil, Rendering). Alte
  # Rows → nil (Familie-1-Sort-Fallback in list_chronik_entries, kein Verhaltens-
  # Change). arity 9 → 11.
  def migrate_chronik_entries_add_timeline! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :in_game_day in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body,
        :in_game_day,
        :precision
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs, md} ->
        {tbl, id, cid, date, label, summary, sid, refs, md, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #140: campaigns.owner_discord_id raus — Spielleiter-Status ergibt
  # sich aus der per-Campaign-Membership-Rolle. arity 9 → 8.
  #
  # Nebeneffekt: falls ein Owner aus historischen CampaignCreated-Events
  # noch keine Membership-Row hat (Materializer fügte sie früher nicht
  # automatisch ein), wird sie hier nachgefüllt mit role :spielleiter.
  def migrate_campaigns_drop_owner_discord_id! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    if :owner_discord_id in current_attrs do
      target_attrs = [:id, :name, :icon_url, :theme_blurb, :status, :created_at, :flavors]

      # Phase 1: Owner-Discord-IDs einsammeln, BEVOR die Spalte verschwindet.
      owners =
        :mnesia.transaction(fn ->
          :mnesia.foldl(
            fn {_tbl, id, _name, _icon, _theme, _status, owner_did, _ts, _flavors}, acc ->
              [{id, owner_did} | acc]
            end,
            [],
            @campaigns
          )
        end)
        |> case do
          {:atomic, list} -> list
          _ -> []
        end

      # Phase 2: Spalte droppen.
      transform = fn {tbl, id, name, icon, theme, status, _owner_did, ts, flavors} ->
        {tbl, id, name, icon, theme, status, ts, flavors}
      end

      {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs)

      # Phase 3: fehlende Owner-Membership-Rows nachfüllen mit role :spielleiter.
      now = DateTime.utc_now()

      # Tx-Result asserten (Issue #462): abortet dieser Backfill still — z.B.
      # durch Arity-Drift am campaign_members-Write —, fehlten Owner-
      # Memberships ohne Log → GM-Rechte weg. Die Phase-2-transform_table oben
      # (:930) ist bereits asserted; diese Phase war die Lücke.
      {:atomic, :ok} =
        :mnesia.transaction(fn ->
          Enum.each(owners, fn {cid, owner_did} ->
            if is_binary(owner_did) and owner_did != "" do
              key = Mnesia.member_key(cid, owner_did)

              case :mnesia.read(@campaign_members, key) do
                [] ->
                  :mnesia.write(
                    {@campaign_members, key, cid, owner_did, :spielleiter, now, nil, nil}
                  )

                _ ->
                  :ok
              end
            end
          end)
        end)

      :ok
    else
      :ok
    end
  end

  # Issue #140: campaign_members.role :owner → :spielleiter, :player → :spieler.
  # arity bleibt — nur Atom-Wert wird umgeschrieben. Idempotent via Read+Write
  # Loop. Setzt voraus, dass die Mnesia-Tabelle bereits geladen ist.
  # Issue #475: One-Shot-Gate für Daten-(Wert-)Migrationen. Die attr-gegateten
  # Schema-Migrationen skippen billig per `table_info(:attributes)`; Wert-Rewrites
  # wie diese hier haben kein solches Signal und scannten daher bei JEDEM Boot die
  # ganze Tabelle (O(alle Rows) read + write-tx). Bei häufigen Self-Update-Restarts
  # (#492/#500/#516) zahlt jeder Boot das. Flag in worker_state (existiert ab Z.92).
  defp migration_done?(flag) do
    case :mnesia.transaction(fn -> :mnesia.read(@worker_state, flag) end) do
      {:atomic, [{_, ^flag, true}]} -> true
      _ -> false
    end
  end

  defp mark_migration_done!(flag) do
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({@worker_state, flag, true}) end)
    :ok
  end

  def migrate_campaign_members_role_rename! do
    if migration_done?(:migrated_member_role_rename) do
      :ok
    else
      rows =
        :mnesia.transaction(fn ->
          :mnesia.foldl(fn row, acc -> [row | acc] end, [], @campaign_members)
        end)
        |> case do
          {:atomic, list} -> list
          _ -> []
        end

      {:atomic, :ok} =
        :mnesia.transaction(fn ->
          Enum.each(rows, fn
            {tbl, key, cid, did, :owner, joined_at, char_name, deleted_at} ->
              :mnesia.write({tbl, key, cid, did, :spielleiter, joined_at, char_name, deleted_at})

            {tbl, key, cid, did, :player, joined_at, char_name, deleted_at} ->
              :mnesia.write({tbl, key, cid, did, :spieler, joined_at, char_name, deleted_at})

            _ ->
              :ok
          end)
        end)

      mark_migration_done!(:migrated_member_role_rename)
    end
  end

  # Issue #140 post-A hotfix: repariert Rows, bei denen Phase-A-Boot
  # zusammen mit den (jetzt geguardeten) Alt-Migrationen `:created_at`
  # und `:flavors` vertauscht hat. Symptom: pos 7 = flavors-Map (statt
  # DateTime), pos 8 = `%{}` (statt der echten Flavors). Ursache: bei
  # einem zweiten Boot der Phase-A-Worker-Version interpretierte
  # `migrate_campaigns_flavor!` die arity-8-Tabelle als pre-flavor
  # old-shape und shiftete die Felder, danach hat `drop_owner_discord_id`
  # den DateTime als „owner" verworfen. Die DateTimes selbst sind
  # damit unrettbar verloren — wir reparieren mit einem UUIDv7-Fallback
  # (die meisten Campaign-IDs sind v7 und enthalten ihren eigenen
  # Erzeugungszeitstempel) und fallen sonst auf `DateTime.utc_now()`.
  # Idempotent: ein bereits-DateTime an pos 7 wird nie angefasst.
  def migrate_campaigns_repair_swapped_created_at_flavors! do
    if migration_done?(:repaired_swapped_created_at_flavors) do
      :ok
    else
      do_repair_swapped_created_at_flavors!()
      mark_migration_done!(:repaired_swapped_created_at_flavors)
    end
  end

  defp do_repair_swapped_created_at_flavors! do
    rows =
      case :mnesia.transaction(fn -> :mnesia.foldl(&[&1 | &2], [], @campaigns) end) do
        {:atomic, list} -> list
        _ -> []
      end

    now = DateTime.utc_now()

    Enum.each(rows, fn row ->
      case row do
        {_tbl, _id, _name, _icon, _theme, _status, %DateTime{}, _flavors} ->
          :ok

        {_tbl, _id, _name, _icon, _theme, _status, %DateTime{}, _flavors, _vocab} ->
          :ok

        # Issue #394: 10-Tupel (mit transcript_source) ist bereits gesund —
        # diese Reparatur ist nur für das alte 8-Tupel-Swap-Artefakt.
        {_tbl, _id, _name, _icon, _theme, _status, %DateTime{}, _flavors, _vocab, _src} ->
          :ok

        {tbl, id, name, icon, theme, status, maybe_flavors, _bogus} ->
          recovered_ts = uuidv7_timestamp(id) || now

          recovered_flavors =
            cond do
              is_map(maybe_flavors) -> maybe_flavors
              true -> %{}
            end

          :mnesia.transaction(fn ->
            :mnesia.write({tbl, id, name, icon, theme, status, recovered_ts, recovered_flavors})
          end)

        # Defensiv: jede andere/neuere Form unangetastet lassen (statt
        # CaseClauseError bei künftigen additiven Feldern).
        _ ->
          :ok
      end
    end)

    :ok
  end

  defp uuidv7_timestamp(<<a::binary-size(8), ?-, b::binary-size(4), ?-, ?7, _::binary>>) do
    case Integer.parse(a <> b, 16) do
      {ms, ""} ->
        case DateTime.from_unix(ms, :millisecond) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp uuidv7_timestamp(_), do: nil

  # Issue #214: vocab_hint-Feld zu campaigns. Arity 8 → 9.
  def migrate_campaigns_add_vocab_hint! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    if :vocab_hint not in current_attrs do
      target_attrs = [
        :id,
        :name,
        :icon_url,
        :theme_blurb,
        :status,
        :created_at,
        :flavors,
        :vocab_hint
      ]

      transform = fn
        {tbl, id, name, icon, theme, status, created_at, flavors} ->
          {tbl, id, name, icon, theme, status, created_at, flavors, nil}

        row ->
          row
      end

      {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs)
    end

    :ok
  end

  # Issue #394: per-Kampagne Quelle für die LLM-Pipeline (live vs. batch).
  # Additiv, Default :confirmed (= bisheriges Verhalten: batch/confirmed-Utts).
  def migrate_campaigns_add_transcript_source! do
    current_attrs = :mnesia.table_info(@campaigns, :attributes)

    if :transcript_source not in current_attrs do
      target_attrs = [
        :id,
        :name,
        :icon_url,
        :theme_blurb,
        :status,
        :created_at,
        :flavors,
        :vocab_hint,
        :transcript_source
      ]

      transform = fn
        {tbl, id, name, icon, theme, status, created_at, flavors, vocab_hint} ->
          {tbl, id, name, icon, theme, status, created_at, flavors, vocab_hint, :confirmed}

        row ->
          row
      end

      {:atomic, :ok} = :mnesia.transform_table(@campaigns, transform, target_attrs)
    end

    :ok
  end
end
