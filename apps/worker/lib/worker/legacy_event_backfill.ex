defmodule Worker.LegacyEventBackfill do
  @moduledoc """
  Issue #696: schreibt den **Pre-Migration-Domain-Zustand** einer Kampagne als
  synthetische Events in die pullbaren Logs nach.

  Alt-Kampagnen (vor der Event-Store-Ära, z.B. der Folger-Import #58) existieren
  nur als materialisierter Mnesia-Zustand auf dem Besitz-Worker — ihre Events
  liegen in keinem Log. Der #693-Pull-Sync kann sie deshalb nicht replizieren:
  frische Worker bekommen leere Hüllen. Dieser Backfill liest die Domain-Rows
  (Campaign, Members, Sessions, Utterances, Marker, Speaker-Assignments,
  Summaries, Faithfulness, Epos, Chronik) und wendet daraus synthetische Events
  via `Worker.Materializer.apply_local/1` an — eine Tx pro Event schreibt den
  `applied_event_ids`-Marker, den (auf dem Quell-Worker idempotenten)
  Domain-Apply und den Event in den passenden Store (`worker_events_global`
  bzw. per-Campaign). Kein Hub-Push — die Verteilung an andere Worker
  übernimmt der normale Pull-Sync (#693) beim nächsten Tick/Join.

  Design-Invarianten:
  - **event_ids = Jetzt-Zeit** (`UUIDv7.generate/0`, monoton in
    Abhängigkeits-Reihenfolge). NICHT backdatiert — backdatierte IDs lägen
    unterhalb bestehender Sync-Wasserlinien und würden nie gepullt.
  - **Original-Zeiten wandern ins Event-`ts`**: der Materializer setzt
    `created_at`/`started_at`/`ended_at`/`joined_at` aus dem Event-`ts`.
    Utterance-Reihenfolge hängt am payload-`timestamp`, Sessions an `number` —
    die Log-Position ist für die Darstellung egal.
  - **Payloads sind JSON-kompatibel** (DateTime → ISO8601, Atom → String) —
    sie gehen beim Pull-Sync übers Wire.
  - **Task-Idempotenz grob-granular**: eine Kampagne gilt als migriert, wenn
    ihr `CampaignCreated` bereits im Global-Log liegt (`migrated?/1`).
  """

  alias Shared.Events
  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  # Kind-Konstante aus der SSoT für die Pattern-Match-Stelle in
  # created_ids_in_global_log/0 — im Pattern ist kein Funktionsaufruf erlaubt,
  # ein Modul-Attribut (Compile-Zeit-Inlining aus Shared.Events) ist es.
  @campaign_created Events.campaign_created()

  @doc """
  Kampagnen, deren `CampaignCreated` NICHT im Global-Log liegt — Kandidaten
  für den Backfill. Probelauf-Kampagnen sind ausgenommen.
  """
  @spec legacy_campaigns() :: [String.t()]
  def legacy_campaigns do
    known = created_ids_in_global_log()

    :mnesia.dirty_all_keys(S.campaigns())
    |> Enum.reject(&String.starts_with?(&1, "probelauf-"))
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.sort()
  end

  @doc "Liegt für die Kampagne schon ein CampaignCreated im Global-Log?"
  @spec migrated?(String.t()) :: boolean()
  def migrated?(campaign_id) do
    MapSet.member?(created_ids_in_global_log(), campaign_id)
  end

  defp created_ids_in_global_log do
    # Voll-Scan über worker_events_global (ordered_set, ~15k Rows — ein
    # einmaliger Migrations-Task darf das). Row: {tab, event_id, hub_seq, payload, ts}
    :mnesia.dirty_select(S.events_global(), [{:"$1", [], [:"$1"]}])
    |> Enum.reduce(MapSet.new(), fn row, acc ->
      payload = elem(row, 3)

      case payload do
        %{"kind" => @campaign_created, "id" => id} when is_binary(id) -> MapSet.put(acc, id)
        _ -> acc
      end
    end)
  end

  @doc """
  Synthetisiert die Event-Liste für eine Kampagne aus ihrem Domain-Zustand.
  Rein lesend (dirty reads), deterministisch für einen gegebenen DB-Stand;
  event_ids werden erst beim Anwenden (`run/2`) generiert. Jeder Eintrag:
  `%{"payload" => map, "ts" => iso8601}` in Abhängigkeits-Reihenfolge.
  """
  @spec plan(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def plan(campaign_id) do
    case :mnesia.dirty_read(S.campaigns(), campaign_id) do
      [] ->
        {:error, :not_found}

      [
        {_, id, name, icon_url, theme_blurb, _status, created_at, flavors, vocab_hint,
         transcript_source}
      ] ->
        members = members(id)
        {owner, other_members} = split_owner(members)

        events =
          [campaign_created(id, name, icon_url, theme_blurb, created_at, owner)] ++
            member_events(id, other_members) ++
            promotion_events(id, other_members) ++
            alias_events(id, members) ++
            removed_events(id, members) ++
            flavor_events(id, flavors) ++
            vocab_events(id, vocab_hint) ++
            transcript_source_events(id, transcript_source) ++
            vorgabe_events(id) ++
            session_events(id) ++
            artefact_events(id)

        {:ok, events}
    end
  end

  @doc """
  Wendet den Backfill für die Kampagnen an. `opts`: `force: true` überspringt
  den `migrated?`-Check. Gibt pro Kampagne `{campaign_id, :applied, n}`,
  `{campaign_id, :skipped_migrated}` oder `{campaign_id, :not_found}` zurück.
  """
  @spec run([String.t()], keyword()) :: [tuple()]
  def run(campaign_ids, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    Enum.map(campaign_ids, fn cid ->
      cond do
        not force? and migrated?(cid) ->
          {cid, :skipped_migrated}

        true ->
          case plan(cid) do
            {:error, :not_found} ->
              {cid, :not_found}

            {:ok, events} ->
              Enum.each(events, fn %{"payload" => payload, "ts" => ts} ->
                :ok =
                  Materializer.apply_local(%{
                    "event_id" => UUIDv7.generate(),
                    "payload" => payload,
                    "ts" => ts,
                    "author_worker_id" => nil
                  })
              end)

              {cid, :applied, length(events)}
          end
      end
    end)
  end

  # ─── Synthese: Campaign + Members ─────────────────────────────────

  defp campaign_created(id, name, icon_url, theme_blurb, created_at, owner) do
    {owner_did, owner_name} =
      case owner do
        {_, _key, _cid, did, _role, _joined, _char, _del} -> {did, display_name(did)}
        nil -> {"legacy-backfill-unknown-owner", "Unbekannt (Backfill)"}
      end

    event(
      %{
        "kind" => Events.campaign_created(),
        "id" => id,
        "name" => name,
        "icon_url" => icon_url,
        "theme_blurb" => theme_blurb,
        "owner_discord_id" => owner_did,
        "owner_display_name" => owner_name
      },
      created_at
    )
  end

  defp members(campaign_id) do
    :mnesia.dirty_index_read(S.campaign_members(), campaign_id, :campaign_id)
    |> Enum.sort_by(
      fn {_, _key, _cid, _did, _role, joined_at, _char, _del} -> joined_at end,
      &datetime_leq?/2
    )
  end

  # Owner = frühester (noch aktiver) Spielleiter — Muster von
  # Worker.Repo.get_campaign/1 (abgeleiteter Owner seit #140).
  defp split_owner(members) do
    owner =
      Enum.find(members, fn {_, _k, _c, _d, role, _j, _ch, del} ->
        role == :spielleiter and is_nil(del)
      end) || List.first(members)

    {owner, Enum.reject(members, &(&1 == owner))}
  end

  # Alle Nicht-Owner-Member als AdminMemberAdded (role=:spieler, joined_at=ts).
  # Tombstoned Members werden trotzdem angelegt (dann per MemberRemoved
  # tombstoned) — so trägt der Log die volle Wahrheit.
  defp member_events(campaign_id, members) do
    Enum.map(members, fn {_, _key, _cid, did, _role, joined_at, _char, _del} ->
      event(
        %{
          "kind" => Events.admin_member_added(),
          "campaign_id" => campaign_id,
          "discord_id" => did,
          "display_name" => display_name(did)
        },
        joined_at
      )
    end)
  end

  # AdminMemberAdded legt alle als :spieler an — Spielleiter nachziehen.
  defp promotion_events(campaign_id, members) do
    members
    |> Enum.filter(fn {_, _k, _c, _d, role, _j, _ch, _del} -> role == :spielleiter end)
    |> Enum.map(fn {_, _k, _c, did, _role, joined_at, _ch, _del} ->
      event(
        %{
          "kind" => Events.member_role_promoted(),
          "campaign_id" => campaign_id,
          "discord_id" => did,
          "new_role" => "spielleiter"
        },
        joined_at
      )
    end)
  end

  defp alias_events(campaign_id, members) do
    members
    |> Enum.filter(fn {_, _k, _c, _d, _role, _j, char, _del} ->
      is_binary(char) and char != ""
    end)
    |> Enum.map(fn {_, _k, _c, did, _role, joined_at, char, _del} ->
      event(
        %{
          "kind" => Events.campaign_alias_set(),
          "campaign_id" => campaign_id,
          "discord_id" => did,
          "character_name" => char
        },
        joined_at
      )
    end)
  end

  defp removed_events(campaign_id, members) do
    members
    |> Enum.filter(fn {_, _k, _c, _d, _role, _j, _ch, del} -> not is_nil(del) end)
    |> Enum.map(fn {_, _k, _c, did, _role, _j, _ch, deleted_at} ->
      event(
        %{"kind" => Events.member_removed(), "campaign_id" => campaign_id, "discord_id" => did},
        deleted_at
      )
    end)
  end

  # ─── Synthese: Campaign-Meta ──────────────────────────────────────

  defp flavor_events(campaign_id, flavors) when is_map(flavors) do
    flavors
    |> Enum.filter(fn {slot, flavor} ->
      slot in ~w(base summary epos chronik) and is_binary(flavor) and flavor != ""
    end)
    |> Enum.map(fn {slot, flavor} ->
      event(
        %{
          "kind" => Events.campaign_flavor_set(),
          "campaign_id" => campaign_id,
          "slot" => slot,
          "flavor" => flavor
        },
        nil
      )
    end)
  end

  # Legacy-Form: flavors war früher ein bloßer String (= base-Flavor).
  defp flavor_events(campaign_id, flavor) when is_binary(flavor) and flavor != "" do
    flavor_events(campaign_id, %{"base" => flavor})
  end

  defp flavor_events(_campaign_id, _), do: []

  defp vocab_events(_campaign_id, nil), do: []
  defp vocab_events(_campaign_id, ""), do: []

  defp vocab_events(campaign_id, vocab_hint) do
    [
      event(
        %{
          "kind" => Events.campaign_vocab_updated(),
          "campaign_id" => campaign_id,
          "vocab_hint" => vocab_hint
        },
        nil
      )
    ]
  end

  # :confirmed ist der CampaignCreated-Default — nur Abweichung nachziehen.
  defp transcript_source_events(campaign_id, :live) do
    [
      event(
        %{
          "kind" => Events.campaign_transcript_source_updated(),
          "campaign_id" => campaign_id,
          "transcript_source" => "live"
        },
        nil
      )
    ]
  end

  defp transcript_source_events(_campaign_id, _), do: []

  defp vorgabe_events(campaign_id) do
    :mnesia.dirty_index_read(S.campaign_vorgaben(), campaign_id, :campaign_id)
    |> Enum.map(fn {_, _key, _cid, stage, name, form} ->
      event(
        %{
          "kind" => Events.campaign_vorgabe_set(),
          "campaign_id" => campaign_id,
          "stage" => stage,
          "name" => name,
          "darstellungsform" => form
        },
        nil
      )
    end)
  end

  # ─── Synthese: Sessions + Utterances + Marker + Speaker ───────────

  defp session_events(campaign_id) do
    :mnesia.dirty_index_read(S.sessions(), campaign_id, :campaign_id)
    |> Enum.sort_by(fn {_, _id, _cid, number, _name, _st, _sched, _start, _end} -> number end)
    |> Enum.flat_map(fn {_, sid, cid, number, name, _status, scheduled_for, started_at, ended_at} ->
      scheduled =
        event(
          %{
            "kind" => Events.session_scheduled(),
            "id" => sid,
            "campaign_id" => cid,
            "number" => number,
            "name" => name,
            "scheduled_for" => iso(scheduled_for)
          },
          scheduled_for || started_at
        )

      started =
        if started_at,
          do: [event(%{"kind" => Events.session_started(), "id" => sid}, started_at)],
          else: []

      ended =
        if ended_at,
          do: [event(%{"kind" => Events.session_ended(), "id" => sid}, ended_at)],
          else: []

      [scheduled] ++
        started ++
        ended ++
        utterance_events(sid) ++
        marker_events(sid) ++
        speaker_events(sid)
    end)
  end

  defp utterance_events(session_id) do
    :mnesia.dirty_index_read(S.utterances(), session_id, :session_id)
    |> Enum.sort_by(
      fn {_, _id, _sid, _did, ts, _text, _conf, _st, _del} -> ts end,
      &datetime_leq?/2
    )
    |> Enum.flat_map(fn {_, uid, sid, did, ts, text, confidence, status, deleted_at} ->
      appended =
        event(
          %{
            "kind" => Events.utterance_appended(),
            "id" => uid,
            "session_id" => sid,
            "discord_id" => did,
            "timestamp" => iso(ts),
            "text" => text,
            "confidence" => confidence,
            "status" => to_string(status || :confirmed)
          },
          ts
        )

      deleted =
        if deleted_at,
          do: [event(%{"kind" => Events.utterance_deleted(), "id" => uid}, deleted_at)],
          else: []

      [appended] ++ deleted
    end)
  end

  defp marker_events(session_id) do
    :mnesia.dirty_index_read(S.markers(), session_id, :session_id)
    |> Enum.map(fn {_, mid, sid, at_ts, kind, label} ->
      event(
        %{
          "kind" => Events.marker_added(),
          "id" => mid,
          "session_id" => sid,
          "at_ts" => iso(at_ts),
          "marker_kind" => to_string(kind),
          "label" => label
        },
        at_ts
      )
    end)
  end

  defp speaker_events(session_id) do
    :mnesia.dirty_index_read(S.speaker_assignments(), session_id, :session_id)
    |> Enum.map(fn {_, _key, sid, label, did, assigned_at} ->
      event(
        %{
          "kind" => Events.speaker_assigned(),
          "session_id" => sid,
          "speaker_label" => label,
          "discord_id" => did
        },
        assigned_at
      )
    end)
  end

  # ─── Synthese: Pipeline-Artefakte ─────────────────────────────────

  defp artefact_events(campaign_id) do
    summaries(campaign_id) ++
      faithfulness(campaign_id) ++ epos(campaign_id) ++ chronik(campaign_id)
  end

  defp summaries(campaign_id) do
    :mnesia.dirty_index_read(S.session_summaries(), campaign_id, :campaign_id)
    |> Enum.map(fn {_, sid, cid, content_md, generated_at, source, source_refs, flagged,
                    render_backend, render_model} ->
      event(
        %{
          "kind" => Events.session_summary_generated(),
          "session_id" => sid,
          "campaign_id" => cid,
          "content_md" => content_md,
          "source" => to_string(source || :llm),
          "source_refs" => source_refs || [],
          "flagged_claims" => flagged || [],
          "render_backend" => render_backend,
          "render_model" => render_model
        },
        generated_at
      )
    end)
  end

  defp faithfulness(campaign_id) do
    :mnesia.dirty_index_read(S.session_faithfulness_scores(), campaign_id, :campaign_id)
    |> Enum.map(fn {_, sid, cid, score, claims_json, scored_at, _event_id} ->
      event(
        %{
          "kind" => Events.session_faithfulness_scored(),
          "session_id" => sid,
          "campaign_id" => cid,
          "score" => score,
          "claims" => decode_json_list(claims_json)
        },
        scored_at
      )
    end)
  end

  # Nur der finale Epos-Stand — die epos_history ist bewusst Nicht-Ziel (#696).
  defp epos(campaign_id) do
    :mnesia.dirty_index_read(S.epos_entries(), campaign_id, :campaign_id)
    |> Enum.sort_by(
      fn {_, _id, _cid, _parent, _md, updated_at, _refs, _backend, _model} -> updated_at end,
      &datetime_leq?/2
    )
    |> Enum.map(fn {_, entry_id, cid, parent_id, content_md, updated_at, source_refs,
                    epos_backend, epos_model} ->
      event(
        %{
          "kind" => Events.epos_entry_edited(),
          "entry_id" => entry_id,
          "campaign_id" => cid,
          "parent_id" => parent_id,
          "new_md" => content_md,
          "source" => "llm",
          "source_refs" => source_refs || [],
          "epos_backend" => epos_backend,
          "epos_model" => epos_model
        },
        updated_at
      )
    end)
  end

  defp chronik(campaign_id) do
    :mnesia.dirty_index_read(S.chronik_entries(), campaign_id, :campaign_id)
    # Issue #724: chronik_entries ist ein 12-Tupel (in_game_day/precision +
    # Issue #698 event_id trailing) — die Zeitstrahl-Felder im Backfill-Event
    # mitführen. `event_id` NICHT (der Re-Emit bekommt via `event/2` ein
    # frisches UUIDv7 zur Publish-Zeit — der alte Watermark-Schlüssel wäre für
    # ein neues Event bedeutungslos).
    |> Enum.map(fn {_, id, cid, in_game_date, label, summary, session_id, source_refs, md_body,
                    in_game_day, precision, _event_id} ->
      event(
        %{
          "kind" => Events.chronik_entry_changed(),
          "id" => id,
          "campaign_id" => cid,
          "in_game_date" => in_game_date,
          "label" => label,
          "summary" => summary,
          "session_id" => session_id,
          "source_refs" => source_refs || [],
          "markdown_body" => md_body,
          "in_game_day" => in_game_day,
          "precision" => precision
        },
        nil
      )
    end)
  end

  # ─── Helpers ──────────────────────────────────────────────────────

  defp event(payload, ts) do
    %{"payload" => payload, "ts" => iso(ts) || iso(DateTime.utc_now())}
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp display_name(discord_id) do
    case :mnesia.dirty_read(S.users(), discord_id) do
      [{_, _, name, _j, _a, _r, _c}] when is_binary(name) -> name
      _ -> discord_id
    end
  end

  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(_), do: []

  defp datetime_leq?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp datetime_leq?(nil, _), do: true
  defp datetime_leq?(_, nil), do: false
  defp datetime_leq?(a, b), do: a <= b
end
