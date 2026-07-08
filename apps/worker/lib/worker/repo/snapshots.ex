defmodule Worker.Repo.Snapshots do
  @moduledoc """
  Issue #581 (God-Module-Split aus `Worker.Repo`): die `snapshot/1`-Familie
  (RPC-Antworten an den Hub) + Serialisierung/Aggregation (Spend, Pipeline-Errors,
  Dashboard). `Worker.Repo` delegiert `snapshot/1`, `monthly_spend_usd/1`,
  `last_n_pipeline_errors/1`, `any_active_recording?/0` hierher (Call-Sites
  unverändert). Die zahlreichen Reader (`list_*`, `get_*`, `member?`, …) + die
  geteilten Helfer (`transaction/1`, `fetch_users/1`) bleiben in `Worker.Repo`
  und kommen via `import` rein — `except:` die hier selbst definierten Publics.
  """
  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo,
    except: [
      snapshot: 1,
      monthly_spend_usd: 1,
      last_n_pipeline_errors: 0,
      last_n_pipeline_errors: 1,
      any_active_recording?: 0
    ]

  # ─── snapshot dispatch ──────────────────────────────────────────

  # Issue #430: snapshot/1-Helfer aus dem Klausel-Block ausgelagert (waren
  # dazwischen → „clauses should be grouped together").
  defp serialize_audio_consent(nil), do: nil

  defp serialize_audio_consent(%{version: version, accepted_at: %DateTime{} = at}) do
    %{"version" => version, "accepted_at" => DateTime.to_iso8601(at)}
  end

  defp serialize_audio_consent(%{version: version, accepted_at: at}),
    do: %{"version" => version, "accepted_at" => to_string(at)}

  # Globale Rolle des Viewers (Issue #36) — im Snapshot mitgegeben, damit die LV
  # ohne extra round-trip die richtigen Permissions-Checks machen kann.
  defp viewer_role(discord_id) do
    case get_user(discord_id) do
      %{role: role} -> Atom.to_string(role)
      _ -> "spieler"
    end
  end

  defp serialize_job(%{job_id: jid, label: l, mode: mo, priority: prio}) do
    %{
      "job_id" => jid,
      "label" => l,
      "mode" => Atom.to_string(mo),
      "priority" => Atom.to_string(prio)
    }
  end

  @doc """
  Answer a `snapshot_request` from the Hub. `scope` is a JSON-shaped map
  with a `"kind"` field. Unknown kinds yield `%{"error" => ...}` so the
  caller can decide what to do.
  """
  def snapshot(%{"kind" => "campaigns_for", "discord_id" => did}) do
    campaigns = list_campaigns_for(did)

    %{
      "campaigns" =>
        Enum.map(campaigns, fn c ->
          active_invites = list_invites(c.id) |> Enum.filter(&(&1.status == :active))

          c
          |> Map.put(:active_recording, active_recording_state(c.id))
          |> Map.put(:members, dashboard_members(c.id))
          |> Map.put(:active_invites, active_invites)
          |> serialize()
        end),
      "users" => users_for_dashboard_all_members(campaigns, did),
      "viewer_role" => viewer_role(did)
    }
  end

  def snapshot(%{"kind" => "campaign", "id" => id, "viewer_discord_id" => viewer}) do
    cond do
      not member?(id, viewer) ->
        %{"forbidden" => true}

      true ->
        case get_campaign(id) do
          nil ->
            %{"not_found" => true}

          c ->
            active = active_session_for(id)

            # Protokoll shows the full transcript history across all sessions
            # (chronological). Starting a fresh recording must not blank out
            # prior sessions.
            utterances = list_utterances_for_campaign(id)
            markers = list_markers_for_campaign(id)

            epos =
              case get_epos_entry(id) do
                nil -> nil
                entry -> serialize(entry)
              end

            %{
              "campaign" => serialize(c),
              "sessions" =>
                list_sessions(id) |> Enum.map(&with_session_anchor/1) |> Enum.map(&serialize/1),
              "members" => list_members(id) |> Enum.map(&serialize/1),
              "invites" => list_invites(id) |> Enum.map(&serialize/1),
              "active_session" => active && serialize(active),
              "utterances" => Enum.map(utterances, &serialize/1),
              "speaker_assignments" =>
                Enum.map(list_speaker_assignments_for_campaign(id), fn a ->
                  %{
                    "session_id" => a.session_id,
                    "speaker_label" => a.speaker_label,
                    "discord_id" => a.discord_id
                  }
                end),
              "markers" => Enum.map(markers, &serialize/1),
              "epos" => epos,
              # Issue #752: per-Session-Epos-Kapitel (Wahrheitsbild). Leer bei
              # reinen Chain-Kampagnen; die UI zeigt Legacy-Buch + Kapitel.
              "epos_chapters" => list_epos_chapters(id) |> Enum.map(&serialize/1),
              "epos_history" => list_epos_history(id) |> Enum.map(&serialize/1),
              "summaries" => list_session_summaries(id) |> Enum.map(&serialize/1),
              "faithfulness" => list_faithfulness_scores(id) |> Enum.map(&serialize/1),
              "chronik" => list_chronik_entries(id) |> Enum.map(&serialize/1),
              # Issue #724 Slice F2: aktueller Campaign-Kalender (Default =
              # Gregorian) fürs Config-Formular. Kanonische JSON-Form.
              "calendar" => get_campaign_calendar(id) |> Worker.Timeline.Calendar.to_json(),
              # Issue #746: Review-Queue — verifizierte, aber unplatzierbare Fakten.
              "review_facts" => campaign_review_facts(id) |> Enum.map(&serialize/1),
              "users" => users_for_campaign(id),
              "character_names" => character_names_for(id),
              "viewer_role" => viewer_role(viewer),
              "viewer_audio_consent" => serialize_audio_consent(audio_consent(viewer))
            }
        end
    end
  end

  # Issue #442 Stage 2: schmale scoped Reads — liefern byte-identische Sub-Maps
  # zur "campaign"-Klausel oben, aber NUR den betroffenen Bereich (kein Voll-
  # Snapshot mit allen Utterances aller Sessions). member?-gegated wie die
  # campaign-Klausel. Ein alter Worker ohne diese Klauseln fällt in den Catch-
  # all (`unknown_scope`) → Hub reloadet voll (Cross-Version-sicher).
  def snapshot(%{"kind" => "campaign_summaries", "id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      %{
        "summaries" => list_session_summaries(id) |> Enum.map(&serialize/1),
        "faithfulness" => list_faithfulness_scores(id) |> Enum.map(&serialize/1)
      }
    else
      %{"forbidden" => true}
    end
  end

  def snapshot(%{"kind" => "campaign_chronik", "id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      %{"chronik" => list_chronik_entries(id) |> Enum.map(&serialize/1)}
    else
      %{"forbidden" => true}
    end
  end

  def snapshot(%{"kind" => "campaign_epos", "id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      epos =
        case get_epos_entry(id) do
          nil -> nil
          entry -> serialize(entry)
        end

      %{
        "epos" => epos,
        "epos_chapters" => list_epos_chapters(id) |> Enum.map(&serialize/1),
        "epos_history" => list_epos_history(id) |> Enum.map(&serialize/1)
      }
    else
      %{"forbidden" => true}
    end
  end

  def snapshot(%{"kind" => "campaign_meta", "id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      case get_campaign(id) do
        nil -> %{"not_found" => true}
        c -> %{"campaign" => serialize(c)}
      end
    else
      %{"forbidden" => true}
    end
  end

  # Issue #442: Member-/User-Events (InviteRedeemed, AdminMemberAdded,
  # MemberRemoved, UserUpserted, UserRoleSet) scoped lesen — nur die Member-Liste
  # + die für die Hub-Permission-Re-Derivation nötigen Felder (`campaign` für
  # Permissions.can?/3, `viewer_role` für die globale Rolle). Genau die Sub-Map,
  # die HubWeb.CampaignLive.derive_assigns/2 konsumiert. member?-gegated: wird der
  # Viewer selbst entfernt → forbidden → Hub fällt auf Voll-Reload zurück (der den
  # Verlust des Zugriffs sauber behandelt). Kein Voll-Snapshot mit allen Utterances.
  def snapshot(%{"kind" => "campaign_members", "id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      case get_campaign(id) do
        nil ->
          %{"not_found" => true}

        c ->
          %{
            "members" => list_members(id) |> Enum.map(&serialize/1),
            "campaign" => serialize(c),
            "viewer_role" => viewer_role(viewer)
          }
      end
    else
      %{"forbidden" => true}
    end
  end

  def snapshot(%{"kind" => "active_session", "campaign_id" => cid}) do
    case active_session_for(cid) do
      nil -> %{"session_id" => nil}
      s -> %{"session_id" => s.id}
    end
  end

  # Admin-UI (Issue #35): Liste aller User der Instance + Liste aller
  # Kampagnen für "Zu Kampagne hinzufügen"-Dropdown. Permission-Gate
  # liegt am LV — der ruft das nur wenn Permissions.can?(user, :view_admin).
  def snapshot(%{"kind" => "all_users"}) do
    %{
      "users" => list_all_users() |> Enum.map(&serialize/1),
      "campaigns" =>
        all_campaigns()
        |> Enum.map(fn c ->
          %{id: c.id, name: c.name, owner_discord_id: c.owner_discord_id}
          |> serialize()
        end)
    }
  end

  def snapshot(%{"kind" => "settings"}) do
    {available_models, ollama_error} =
      case Worker.LLM.Local.list_models() do
        {:ok, names} -> {names, nil}
        {:error, reason} -> {[], inspect(reason)}
      end

    # NICHT hier `HubClient.report_models(available_models)` aufrufen —
    # Phoenix.Tracker.update triggert `handle_diff` → `:workers_changed`-
    # Broadcast → LV.reload_settings → snapshot → infinite loop, Reader
    # läuft in :timeout. Der initiale `report_models`-Push aus
    # `handle_join` reicht für die Settings-LV-Aggregation; Folge-Pulls
    # bei `ollama pull` mid-session sind out-of-scope (require Worker-
    # restart oder Folge-Issue für Polling).

    # Issue #463: Live-Modell-Listen für die Cloud-Backends. Pro Backend
    # entweder `[name, …]` (Erfolg) oder `[]` + Error-String (kein Key /
    # API down / Auth fehlgeschlagen). Hub-LV rendert pro Backend die
    # passende Liste; Fehler-String wird als Hint angezeigt.
    {cloud_models, cloud_errors} = collect_cloud_models()

    # Issue #510: Cloud-API-Key-Werte NIE durchreichen — nur Status.
    # Settings-Map wird sanitized (Keys auf `nil` gesetzt), zusätzlicher
    # `cloud_api_keys` liefert nur den Set-Status pro Backend (set_via_settings
    # / set_via_env / unset). Verhindert Key-Leakage via Hub-Reader-Cache
    # + Phoenix-Channel-Frames an alle subscribed LVs.
    settings =
      Worker.Settings.snapshot()
      |> Map.put(:anthropic_api_key, nil)
      |> Map.put(:openai_api_key, nil)
      |> Map.put(:gemini_api_key, nil)
      |> serialize()

    cloud_api_keys = %{
      "anthropic" => Atom.to_string(Worker.LLM.ApiKey.status(:anthropic)),
      "openai" => Atom.to_string(Worker.LLM.ApiKey.status(:openai)),
      "google" => Atom.to_string(Worker.LLM.ApiKey.status(:google))
    }

    %{
      "settings" => settings,
      "any_active_recording" => any_active_recording?(),
      "available_models" => available_models,
      "ollama_error" => ollama_error,
      "cloud_models" => cloud_models,
      "cloud_errors" => cloud_errors,
      "cloud_api_keys" => cloud_api_keys
    }
  end

  def snapshot(%{"kind" => "probelauf"}) do
    %{
      "running" => Worker.Probelauf.running() |> serialize(),
      "last_run" => last_probelauf_run() |> serialize(),
      "last_sweep" => last_probelauf_sweep() |> serialize(),
      # Issue #88 (Phase 2b): mehrere zuletzte Sweeps für Multi-Stage-Anzeige.
      "last_sweeps" => last_n_probelauf_sweeps(3) |> Enum.map(&serialize/1),
      "available_models" =>
        case Worker.LLM.Local.list_models() do
          {:ok, names} -> names
          {:error, _} -> []
        end
    }
  end

  def snapshot(%{"kind" => "invite", "token" => token}) do
    case get_invite(token) do
      nil ->
        %{"not_found" => true}

      invite ->
        campaign =
          case get_campaign(invite.campaign_id) do
            nil -> nil
            c -> serialize(c)
          end

        %{"invite" => serialize(invite), "campaign" => campaign}
    end
  end

  # Issue #177: /admin/spend Dashboard liest aggregierten Cloud-LLM-Spend.
  # `since_iso` / `until_iso` als optionaler ISO8601-Range (default: aktueller
  # Monat). Plus optional Provider-Filter.
  def snapshot(%{"kind" => "llm_spend"} = scope) do
    since = parse_iso(Map.get(scope, "since")) || month_start()
    until_ts = parse_iso(Map.get(scope, "until")) || DateTime.utc_now()

    rows = list_llm_spend(since, until_ts)

    %{
      "since" => DateTime.to_iso8601(since),
      "until" => DateTime.to_iso8601(until_ts),
      "rows" => Enum.map(rows, &serialize/1),
      "totals" => aggregate_llm_spend(rows)
    }
  end

  # Issue #292 (Phase 1): /admin/jobs Live-View. Aktueller GpuQueue-State —
  # running Job + wartende Jobs in FIFO-Reihenfolge. Funs werden bewusst
  # nicht serialisiert.
  def snapshot(%{"kind" => "jobs"}) do
    %{
      running: running,
      live_queue: live_queue,
      bg_queue: bg_queue,
      recording_active?: recording_active?
    } = Worker.GpuQueue.list()

    %{
      "running" =>
        case running do
          nil ->
            nil

          m ->
            %{
              "job_id" => m.job_id,
              "label" => m.label,
              "mode" => Atom.to_string(m.mode),
              "priority" => Atom.to_string(m.priority),
              "started_at" => m.started_at,
              "duration_ms" => m.duration_ms
            }
        end,
      "live_queue" => Enum.map(live_queue, &serialize_job/1),
      "bg_queue" => Enum.map(bg_queue, &serialize_job/1),
      "recording_active?" => recording_active?
    }
  end

  # Issue #68 (Phase 1): /admin/errors Dashboard liest die letzten N Pipeline-
  # Fehler. Optional `n` (default 50).
  def snapshot(%{"kind" => "errors"} = scope) do
    n = Map.get(scope, "n", 50) |> normalize_limit(50)
    rows = last_n_pipeline_errors(n)

    %{
      "errors" => Enum.map(rows, &serialize/1),
      "count" => length(rows)
    }
  end

  # Issue #57: Preview für den User-Delete-Flow. Liefert dem Hub-UI alles
  # was vor dem finalen UserDeleted-Event noch resolved werden muss:
  #   - last_admin?  → Self-Lockout-Schutz (kein Delete möglich)
  #   - last_sl_campaigns → Kampagnen die User als letzter Spielleiter hat;
  #     pro Kampagne ein Spieler-Picker (member-Liste) für Promote-or-Archive
  def snapshot(%{"kind" => "user_delete_preview", "discord_id" => discord_id}) do
    user =
      case get_user(discord_id) do
        nil -> nil
        u -> serialize(u)
      end

    %{
      "user" => user,
      "last_admin" => last_admin?(discord_id),
      "last_sl_campaigns" =>
        last_spielleiter_campaigns_for(discord_id)
        |> Enum.map(fn c ->
          %{
            "id" => c.id,
            "name" => c.name,
            "members" => Enum.map(c.members, &serialize/1)
          }
        end)
    }
  end

  def snapshot(scope), do: %{"error" => "unknown_scope", "scope" => inspect(scope)}

  # Issue #463: list_models pro Cloud-Backend einsammeln für den
  # settings-Snapshot. Hinter allen snapshot/1-Klauseln platziert, damit
  # die Klausel-Gruppierung nicht durch defp-Inserts gebrochen wird
  # (--warnings-as-errors-Gate in CI).
  defp collect_cloud_models do
    backends = [
      {"anthropic", &Worker.LLM.Anthropic.list_models/0},
      {"openai", &Worker.LLM.OpenAI.list_models/0},
      {"google", &Worker.LLM.Google.list_models/0}
    ]

    Enum.reduce(backends, {%{}, %{}}, fn {name, fun}, {models_acc, errors_acc} ->
      case fun.() do
        {:ok, names} ->
          {Map.put(models_acc, name, names), errors_acc}

        # `:no_key_configured` ist KEIN Fehler — der User hat den Provider
        # nur nicht eingerichtet. Hub-UI zeigt dafür einen ruhigen "Setze
        # <ENV_VAR>"-Hint statt einer Fehler-Banner.
        {:error, :no_key_configured} ->
          {Map.put(models_acc, name, []), errors_acc}

        {:error, reason} ->
          {Map.put(models_acc, name, []), Map.put(errors_acc, name, inspect(reason))}
      end
    end)
  end

  @doc """
  Issue #178: Summe des LLM-Spend in USD für `discord_id` im aktuellen
  Kalendermonat (UTC). Gibt 0.0 zurück wenn keine Calls gefunden.
  Wird vom Cap-Check in `Worker.LLM.check_spend_cap/2` vor jedem Cloud-Call
  gerufen — dirty_match_object reicht (Soft-Limit, leichte Race-Toleranz).
  """
  @spec monthly_spend_usd(String.t()) :: float()
  def monthly_spend_usd(discord_id) when is_binary(discord_id) do
    {since, until_ts} = current_month_range()

    :worker_llm_spend
    |> :mnesia.dirty_match_object({:_, :_, :_, :_, :_, :_, :_, :_, discord_id, :_, :_, :_})
    |> Enum.filter(fn {_, _, ts, _, _, _, _, _, _, _, _, _} ->
      DateTime.compare(ts, since) != :lt and DateTime.compare(ts, until_ts) != :gt
    end)
    |> Enum.map(fn {_, _, _, _, _, _, _, cost, _, _, _, _} -> cost || 0.0 end)
    |> Enum.sum()
  end

  defp current_month_range do
    now = DateTime.utc_now()
    since = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    {since, now}
  end

  defp normalize_limit(n, _default) when is_integer(n) and n > 0 and n <= 500, do: n
  defp normalize_limit(_, default), do: default

  @doc """
  Issue #68 (Phase 1): die letzten `n` Pipeline-Fehler, sortiert nach
  `occurred_at` desc (neuester zuerst). Append-only Mnesia-Read.
  """
  @spec last_n_pipeline_errors(pos_integer()) :: [map()]
  def last_n_pipeline_errors(n \\ 50) when is_integer(n) and n > 0 do
    :worker_pipeline_errors
    |> :mnesia.dirty_match_object({:_, :_, :_, :_, :_, :_, :_, :_, :_})
    |> Enum.map(&pipeline_error_row_to_map/1)
    |> Enum.sort_by(fn r ->
      case r.occurred_at do
        %DateTime{} = dt -> -DateTime.to_unix(dt, :microsecond)
        _ -> 0
      end
    end)
    |> Enum.take(n)
  end

  defp pipeline_error_row_to_map(
         {_, error_id, occurred_at, session_id, campaign_id, stage, error_type, message, context}
       ) do
    %{
      error_id: error_id,
      occurred_at: occurred_at,
      session_id: session_id,
      campaign_id: campaign_id,
      stage: stage,
      error_type: error_type,
      message: message,
      context: context || %{}
    }
  end

  # Issue #177: alle LLM-Spend-Einträge im Datums-Range, neueste zuerst.
  defp list_llm_spend(%DateTime{} = since, %DateTime{} = until_ts) do
    :worker_llm_spend
    |> :mnesia.dirty_match_object({:_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_})
    |> Enum.map(&llm_spend_row_to_map/1)
    |> Enum.filter(fn r ->
      DateTime.compare(r.ts, since) != :lt and DateTime.compare(r.ts, until_ts) != :gt
    end)
    |> Enum.sort_by(& &1.ts, {:desc, DateTime})
  end

  defp llm_spend_row_to_map(
         {_, event_id, ts, provider, model, input, output, cost, did, sid, stage, duration_ms}
       ) do
    %{
      event_id: event_id,
      ts: ts,
      provider: provider,
      model: model,
      input_tokens: input,
      output_tokens: output,
      cost_usd: cost,
      requested_by_discord_id: did,
      session_id: sid,
      stage: stage,
      duration_ms: duration_ms
    }
  end

  defp aggregate_llm_spend(rows) do
    total_cost = rows |> Enum.map(& &1.cost_usd) |> Enum.sum()
    total_input = rows |> Enum.map(& &1.input_tokens) |> Enum.sum()
    total_output = rows |> Enum.map(& &1.output_tokens) |> Enum.sum()

    by_provider =
      rows
      |> Enum.group_by(& &1.provider)
      |> Enum.into(%{}, fn {p, rs} ->
        {p,
         %{
           "count" => length(rs),
           "cost_usd" => rs |> Enum.map(& &1.cost_usd) |> Enum.sum()
         }}
      end)

    by_model =
      rows
      |> Enum.group_by(& &1.model)
      |> Enum.into(%{}, fn {m, rs} ->
        {m,
         %{
           "count" => length(rs),
           "cost_usd" => rs |> Enum.map(& &1.cost_usd) |> Enum.sum(),
           "input_tokens" => rs |> Enum.map(& &1.input_tokens) |> Enum.sum(),
           "output_tokens" => rs |> Enum.map(& &1.output_tokens) |> Enum.sum()
         }}
      end)

    %{
      "total_cost_usd" => total_cost,
      "total_input_tokens" => total_input,
      "total_output_tokens" => total_output,
      "total_calls" => length(rows),
      "by_provider" => by_provider,
      "by_model" => by_model
    }
  end

  defp parse_iso(nil), do: nil

  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp month_start do
    now = DateTime.utc_now()
    %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  # ─── helpers ────────────────────────────────────────────────────

  defp active_recording_state(campaign_id) do
    case active_session_for(campaign_id) do
      nil -> nil
      %{status: status} -> Atom.to_string(status)
    end
  end

  defp dashboard_members(campaign_id) do
    Enum.map(list_members(campaign_id), fn m ->
      %{"discord_id" => m.discord_id, "role" => Atom.to_string(m.role)}
    end)
  end

  # Dashboard now needs display_names for every member of every campaign
  # the viewer has access to (not just the owners). Reuse fetch_users/1
  # with the union of all member-discord-ids + the viewer themselves.
  defp users_for_dashboard_all_members(campaigns, viewer_did) do
    ids =
      campaigns
      |> Enum.flat_map(fn c -> list_members(c.id) end)
      |> Enum.map(& &1.discord_id)
      |> Enum.concat([viewer_did])

    fetch_users(ids)
  end

  # True if any campaign on this worker has a session currently in
  @doc """
  True wenn irgendeine Session im Worker `:recording` oder `:paused` ist.
  Wird von `EinstellungenLive` zum Disable von Mid-Session-Mode-Switches
  genutzt — und seit Issue #355 von `Worker.GpuQueue` zum Pausieren
  von Background-Jobs während aktiver Aufnahme.
  """
  @spec any_active_recording?() :: boolean()
  def any_active_recording? do
    transaction(fn ->
      :mnesia.foldl(
        fn {_, _, _, _, _, status, _, _, _}, acc -> acc or status in [:recording, :paused] end,
        false,
        S.sessions()
      )
    end)
  end

  # Issue #724 Slice F: das gesetzte In-Game-Datum der Session (Roh-String +
  # Tageszähler) mit in den Snapshot, damit die Hub-UI es anzeigen + im Anker-
  # Formular vorbelegen kann. Fehlt ein Anker → Felder bleiben nil.
  defp with_session_anchor(%{id: sid} = session) do
    case get_session_anchor(sid) do
      %{in_game_day: day, in_game_date_raw: raw} ->
        Map.merge(session, %{in_game_day: day, in_game_date_raw: raw})

      _ ->
        Map.merge(session, %{in_game_day: nil, in_game_date_raw: nil})
    end
  end

  defp serialize(nil), do: nil

  defp serialize(%{} = m) do
    # Convert DateTime / atoms / nested maps to JSON-friendly values.
    for {k, v} <- m, into: %{}, do: {to_string(k), wire(v)}
  end

  defp wire(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp wire(a) when is_atom(a) and not is_nil(a) and not is_boolean(a), do: Atom.to_string(a)
  defp wire(other), do: other
end
