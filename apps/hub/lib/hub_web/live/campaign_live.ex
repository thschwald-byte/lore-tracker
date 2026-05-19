defmodule HubWeb.CampaignLive do
  @moduledoc """
  Mockup-2 campaign view: 4-column layout (Chronik / Resümee / Epos /
  Protokoll) + recording bar + owner controls.

  Recording state lives in `session.status`
  (`:scheduled → :recording → (:paused ↔ :recording) → :completed`).
  UtteranceAppended events stream into the Protokoll column without a
  full snapshot reload.

  Epos column (M7): owner can edit a single per-campaign Markdown entry;
  every save appends `EposEntryEdited`, the materializer keeps current
  + history rows. Diff is a unified line-by-line view via
  `List.myers_difference/2`.
  """

  use HubWeb, :live_view

  alias Hub.{Commands, EventLog, Reader}

  # Column-Keys für Collapse-Persistenz (Issue #8). Reihenfolge entspricht
  # dem Render-Layout — wichtig nur als kanonischer Whitelist-Check.
  @col_names ~w(chronik epos summaries protokoll)

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, EventLog.topic())
      Phoenix.PubSub.subscribe(Hub.PubSub, "pipeline_status")
      Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    end

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:campaign_id, campaign_id)
      |> assign(:active_nav, :campaign)
      |> assign(:invite_url, nil)
      |> assign(:epos_mode, :view)
      |> assign(:epos_draft, "")
      |> assign(:epos_diff_seq, nil)
      |> assign(:busy_stages, MapSet.new())
      |> assign(:mic_on?, false)
      |> assign(:mic_streamers, [])
      |> assign(:live_utterances, %{})
      |> assign(:alias_mode, :view)
      |> assign(:alias_draft, "")
      |> assign(:summary_editing, nil)
      |> assign(:summary_draft, "")
      |> assign(:chronik_editing, nil)
      |> assign(:chronik_draft, %{})
      |> assign(:utterance_editing, nil)
      |> assign(:utterance_draft, "")
      |> assign(:utterance_adding, nil)
      |> assign(:utterance_add_speaker, nil)
      |> assign(:utterance_add_text, "")
      |> assign(:collapsed_cols, MapSet.new())
      |> load_snapshot()

    cond do
      socket.assigns[:forbidden?] ->
        {:ok, socket |> put_flash(:error, "Kein Zugriff") |> push_navigate(to: ~p"/")}

      socket.assigns[:not_found?] ->
        {:ok, socket |> put_flash(:error, "Kampagne nicht gefunden") |> push_navigate(to: ~p"/")}

      true ->
        {:ok, socket}
    end
  end

  # ─── Recording-bar events ───────────────────────────────────────

  @impl true
  def handle_event("rec_start", _, socket) do
    cond do
      not socket.assigns.owner? ->
        {:noreply, socket}

      socket.assigns.active_session ->
        # Already recording — UI Start is a no-op (Resume is a separate
        # button when state is :paused, see template).
        {:noreply, socket}

      true ->
        n =
          Commands.request_recording_start(
            socket.assigns.current_user.discord_id,
            socket.assigns.campaign_id
          )

        if n == 0 do
          {:noreply, put_flash(socket, :error, "Kein eigener Worker connected.")}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("rec_pause", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "paused")
    end

    {:noreply, socket}
  end

  def handle_event("rec_resume", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      append_state(socket, "recording")
    end

    {:noreply, socket}
  end

  def handle_event("rec_stop", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      Commands.request_recording_stop(
        socket.assigns.current_user.discord_id,
        socket.assigns.campaign_id
      )
    end

    {:noreply, socket}
  end

  def handle_event("rec_marker", _, socket) do
    if socket.assigns.owner? and socket.assigns.active_session do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.marker_added(),
            "id" => UUIDv7.generate(),
            "session_id" => socket.assigns.active_session.id,
            "at_ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "marker_kind" => "plot",
            "label" => "Plot-Moment"
          },
          nil
        )
    end

    {:noreply, socket}
  end

  # ─── Pipeline re-run ────────────────────────────────────────────

  def handle_event("rerun_pipeline", %{"session" => session_id}, socket) do
    if socket.assigns.owner? do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.regenerate_requested(),
            "scope" => "session_pipeline",
            "session_id" => session_id,
            "campaign_id" => socket.assigns.campaign_id
          },
          nil
        )

      {:noreply, put_flash(socket, :info, "Pipeline neu gestartet für Session.")}
    else
      {:noreply, socket}
    end
  end

  # ─── Mic events (M10-BMP: browser MediaRecorder) ────────────────

  def handle_event("mic_join", _, socket) do
    case socket.assigns.active_session do
      nil ->
        {:noreply, put_flash(socket, :error, "Keine aktive Session.")}

      %{id: sid} ->
        {source, socket} =
          if socket.assigns.transcribe_mode == "listen" do
            {"system", ensure_listen_user(socket)}
          else
            {"mic", socket}
          end

        {:noreply,
         socket
         |> assign(:mic_on?, true)
         |> push_event("mic:start", %{session_id: sid, source: source})}
    end
  end

  def handle_event("mic_leave", _, socket) do
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> push_event("mic:stop", %{})}
  end

  def handle_event("audio_chunk", %{"session_id" => sid, "chunk" => chunk}, socket)
      when is_binary(sid) and sid != "" and is_binary(chunk) and chunk != "" do
    case socket.assigns.campaign do
      %{"owner_discord_id" => owner_id} when is_binary(owner_id) ->
        sender_id =
          if socket.assigns.transcribe_mode == "listen" do
            "__listen__"
          else
            socket.assigns.current_user.discord_id
          end

        Commands.forward_audio_chunk(owner_id, sid, sender_id, chunk)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # JS-Hook hat schon mal ein leeres / nil chunk gefeuert (z.B. wenn die
  # MediaRecorder-Slice 0 Bytes hat). Still droppen statt crashen.
  def handle_event("audio_chunk", _payload, socket), do: {:noreply, socket}

  def handle_event("mic_started", _, socket), do: {:noreply, socket}

  def handle_event("mic_error", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:mic_on?, false)
     |> put_flash(:error, "Mikro nicht verfügbar: #{reason}")}
  end

  # ─── Epos events ─────────────────────────────────────────────────

  # ─── Resümee / Chronik / Utterance edit events (Issue #3) ───────

  def handle_event("summary_edit_start", %{"session" => sid}, socket) do
    current =
      Enum.find_value(socket.assigns.summaries, "", fn s ->
        if s["session_id"] == sid, do: s["content_md"], else: nil
      end)

    {:noreply, assign(socket, summary_editing: sid, summary_draft: current || "")}
  end

  def handle_event("summary_edit_cancel", _, socket) do
    {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}
  end

  def handle_event("summary_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.is_member? and socket.assigns.summary_editing do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.session_summary_edited(),
            "session_id" => socket.assigns.summary_editing,
            "campaign_id" => socket.assigns.campaign_id,
            "new_md" => content_md,
            "edited_by" => socket.assigns.current_user.discord_id
          },
          nil
        )
    end

    {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}
  end

  def handle_event("chronik_edit_start", %{"id" => id}, socket) do
    entry =
      Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end) || %{}

    draft = %{
      "in_game_date" => entry["in_game_date"] || "",
      "label" => entry["label"] || "",
      "summary" => entry["summary"] || ""
    }

    {:noreply, assign(socket, chronik_editing: id, chronik_draft: draft)}
  end

  def handle_event("chronik_edit_cancel", _, socket) do
    {:noreply, assign(socket, chronik_editing: nil, chronik_draft: %{})}
  end

  def handle_event("chronik_edit_save", %{"chronik" => attrs}, socket) do
    id = socket.assigns.chronik_editing
    existing = Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end)

    if socket.assigns.is_member? and existing do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.chronik_entry_changed(),
            "id" => id,
            "campaign_id" => socket.assigns.campaign_id,
            "in_game_date" => attrs["in_game_date"] || existing["in_game_date"],
            "in_game_sort_key" => existing["in_game_sort_key"],
            "label" => attrs["label"] || existing["label"],
            "summary" => attrs["summary"] || existing["summary"],
            "session_id" => existing["session_id"],
            "edited_by" => socket.assigns.current_user.discord_id,
            "source" => "manual"
          },
          nil
        )
    end

    {:noreply, assign(socket, chronik_editing: nil, chronik_draft: %{})}
  end

  def handle_event("utterance_edit_start", %{"id" => id}, socket) do
    current =
      Enum.find_value(socket.assigns.utterances, "", fn u ->
        if u["id"] == id, do: u["text"], else: nil
      end)

    {:noreply, assign(socket, utterance_editing: id, utterance_draft: current || "")}
  end

  def handle_event("utterance_edit_cancel", _, socket) do
    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def handle_event("utterance_edit_save", %{"text" => text}, socket) do
    id = socket.assigns.utterance_editing
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if socket.assigns.is_member? and existing do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.utterance_edited(),
            "id" => id,
            "session_id" => existing["session_id"],
            "new_text" => text,
            "edited_by" => socket.assigns.current_user.discord_id
          },
          nil
        )
    end

    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def handle_event("utterance_delete", %{"id" => id}, socket) do
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if socket.assigns.is_member? and existing do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.utterance_deleted(),
            "id" => id,
            "session_id" => existing["session_id"],
            "deleted_by" => socket.assigns.current_user.discord_id
          },
          nil
        )
    end

    {:noreply, socket}
  end

  def handle_event("utterance_add_start", %{"session" => sid}, socket) do
    {:noreply,
     assign(socket,
       utterance_adding: sid,
       utterance_add_speaker: socket.assigns.current_user.discord_id,
       utterance_add_text: ""
     )}
  end

  def handle_event("utterance_add_cancel", _, socket) do
    {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
  end

  def handle_event(
        "utterance_add_save",
        %{"speaker" => speaker, "text" => text},
        socket
      ) do
    sid = socket.assigns.utterance_adding
    cleaned = text |> to_string() |> String.trim()
    member_dids = Enum.map(socket.assigns.members || [], & &1["discord_id"])

    cond do
      not socket.assigns.is_member? ->
        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}

      sid in [nil, ""] or cleaned == "" or speaker not in member_dids ->
        {:noreply, socket}

      true ->
        {:ok, _seq} =
          EventLog.append(
            %{
              "kind" => Shared.Events.utterance_appended(),
              "id" => UUIDv7.generate(),
              "session_id" => sid,
              "discord_id" => speaker,
              "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
              "text" => cleaned,
              "confidence" => nil,
              "status" => "manual"
            },
            nil
          )

        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
    end
  end

  # ─── Alias events (Issue #2) ─────────────────────────────────────

  def handle_event("alias_edit_start", _, socket) do
    current =
      Map.get(socket.assigns.character_names, socket.assigns.current_user.discord_id, "")

    {:noreply, assign(socket, alias_mode: :edit, alias_draft: current)}
  end

  def handle_event("alias_edit_cancel", _, socket) do
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("alias_edit_reset", _, socket) do
    publish_alias(socket, nil)
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("alias_edit_save", %{"character_name" => name}, socket) do
    trimmed = String.trim(name)
    cleaned = if trimmed == "", do: nil, else: String.slice(trimmed, 0, 80)

    publish_alias(socket, cleaned)
    {:noreply, assign(socket, alias_mode: :view, alias_draft: "")}
  end

  def handle_event("epos_edit_start", _, socket) do
    if socket.assigns.is_member? do
      current = (socket.assigns.epos && socket.assigns.epos["content_md"]) || ""
      {:noreply, assign(socket, epos_mode: :edit, epos_draft: current)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("epos_edit_cancel", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.is_member? do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => socket.assigns.campaign_id,
            "campaign_id" => socket.assigns.campaign_id,
            "new_md" => content_md,
            "edited_by" => socket.assigns.current_user.discord_id,
            "source" => "manual"
          },
          nil
        )
    end

    {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
  end

  def handle_event("epos_diff_open", %{"seq" => seq_str}, socket) do
    seq = String.to_integer(seq_str)
    {:noreply, assign(socket, epos_mode: :diff, epos_diff_seq: seq)}
  end

  def handle_event("epos_diff_close", _, socket) do
    {:noreply, assign(socket, epos_mode: :view, epos_diff_seq: nil)}
  end

  # ─── Column collapse/restore (Issue #8) ─────────────────────────

  def handle_event("col_toggle", %{"col" => col}, socket) when col in @col_names do
    current = socket.assigns.collapsed_cols

    next =
      if MapSet.member?(current, col) do
        MapSet.delete(current, col)
      else
        candidate = MapSet.put(current, col)
        # Mindestens eine Spalte muss offen bleiben — sonst Toggle ignorieren.
        if MapSet.size(candidate) >= length(@col_names), do: current, else: candidate
      end

    {:noreply,
     socket
     |> assign(:collapsed_cols, next)
     |> push_event("persist_cols", %{collapsed: MapSet.to_list(next)})}
  end

  def handle_event("col_toggle", _, socket), do: {:noreply, socket}

  def handle_event("col_restore", %{"collapsed" => list}, socket) when is_list(list) do
    valid = list |> Enum.filter(&(&1 in @col_names)) |> MapSet.new()
    # Falls aus LS alle vier kommen, droppe eine — Invariante „mind. 1 offen".
    valid =
      if MapSet.size(valid) >= length(@col_names),
        do: MapSet.delete(valid, "protokoll"),
        else: valid

    {:noreply, assign(socket, :collapsed_cols, valid)}
  end

  def handle_event("col_restore", _, socket), do: {:noreply, socket}

  # ─── Invite + shutdown events (unchanged) ───────────────────────

  def handle_event("create_invite", _, socket) do
    if socket.assigns.owner? do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.invite_created(),
            "token" => token,
            "campaign_id" => socket.assigns.campaign_id,
            "created_by_discord_id" => socket.assigns.current_user.discord_id,
            "expires_at" => nil
          },
          nil
        )

      url = HubWeb.Endpoint.url() <> "/invite/#{token}"
      {:noreply, assign(socket, :invite_url, url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_invite_url", _, socket), do: {:noreply, assign(socket, :invite_url, nil)}

  def handle_event("revoke_invite", %{"token" => token}, socket) do
    if socket.assigns.owner? do
      {:ok, _seq} =
        EventLog.append(
          %{"kind" => Shared.Events.invite_revoked(), "token" => token},
          nil
        )
    end

    {:noreply, socket}
  end

  def handle_event("shutdown_worker", _, socket) do
    if socket.assigns.owner? do
      n = Commands.shutdown_my_workers(socket.assigns.current_user.discord_id)
      {:noreply, put_flash(socket, :info, "Shutdown an #{n} Worker geschickt.")}
    else
      {:noreply, socket}
    end
  end

  # ─── Event stream ────────────────────────────────────────────────

  @impl true
  def handle_info({:event_appended, %{payload: %{"kind" => "UtteranceAppended"} = payload}}, socket) do
    if session_in_campaign?(socket, payload["session_id"]) do
      utterance = %{
        "id" => payload["id"],
        "session_id" => payload["session_id"],
        "discord_id" => payload["discord_id"],
        "timestamp" => payload["timestamp"],
        "text" => payload["text"],
        "confidence" => payload["confidence"],
        "status" => payload["status"] || "confirmed"
      }

      # Confirmed segment for this speaker overrules any in-flight partial.
      live = Map.delete(socket.assigns.live_utterances, payload["discord_id"])

      {:noreply,
       socket
       |> update(:utterances, &(&1 ++ [utterance]))
       |> assign(:live_utterances, live)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "MarkerAdded"} = payload}}, socket) do
    if session_in_campaign?(socket, payload["session_id"]) do
      {:noreply, update(socket, :markers, &(&1 ++ [payload]))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "SessionEnded"}}}, socket) do
    Process.send_after(self(), :reload, 150)

    socket =
      if socket.assigns.mic_on? do
        socket
        |> assign(:mic_on?, false)
        |> push_event("mic:stop", %{})
      else
        socket
      end

    # Live-partials gehören sofort weg, sobald die Session vorbei ist —
    # der Materializer hat die status:"live"-Zeilen via LiveUtterancesCleared
    # schon gedropt, und der Batch-Re-Pass liefert gleich die Confirmed-Variante.
    {:noreply,
     socket
     |> assign(:live_utterances, %{})
     |> push_event("signal:play", %{kind: "session_end"})}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => "SessionStarted"}}}, socket) do
    Process.send_after(self(), :reload, 150)
    {:noreply, push_event(socket, "signal:play", %{kind: "session_start"})}
  end

  def handle_info(
        {:event_appended, %{payload: %{"kind" => "RecordingStateChanged", "state" => state}}},
        socket
      ) do
    Process.send_after(self(), :reload, 150)

    kind =
      case state do
        "recording" -> "rec_start"
        "idle" -> "rec_stop"
        _ -> nil
      end

    socket = if kind, do: push_event(socket, "signal:play", %{kind: kind}), else: socket
    {:noreply, socket}
  end

  def handle_info({:event_appended, %{payload: %{"kind" => kind}}}, socket)
      when kind in ~w(
        CampaignUpdated SessionScheduled
        InviteCreated InviteRevoked InviteRedeemed
        MemberRemoved EposEntryEdited CampaignAliasSet UserUpserted
        SessionSummaryGenerated SessionSummaryEdited ChronikEntryChanged
        UtteranceEdited UtteranceDeleted
      ) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_snapshot(socket)}

  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, load_snapshot(socket)}

  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      busy =
        case status do
          "started" -> MapSet.put(socket.assigns.busy_stages, stage)
          _ -> MapSet.delete(socket.assigns.busy_stages, stage)
        end

      {:noreply, assign(socket, :busy_stages, busy)}
    else
      {:noreply, socket}
    end
  end

  # Older pipeline_status payloads (no explicit "kind") — keep matching the
  # stage shape so existing emitters that didn't tag a kind still work.
  def handle_info(
        {:pipeline_status, %{"campaign_id" => cid, "stage" => stage, "status" => status}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      busy =
        case status do
          "started" -> MapSet.put(socket.assigns.busy_stages, stage)
          _ -> MapSet.delete(socket.assigns.busy_stages, stage)
        end

      {:noreply, assign(socket, :busy_stages, busy)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:pipeline_status,
         %{"kind" => "mic_streamers", "campaign_id" => cid, "discord_ids" => dids}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      {:noreply, assign(socket, :mic_streamers, dids || [])}
    else
      {:noreply, socket}
    end
  end

  # Live-transcription partial — pro discord_id immer nur die jeweils letzte.
  # Transient, NICHT im Event-Log. Wird auf SessionEnded und auf jedem
  # eingehenden UtteranceAppended für den gleichen Sprecher abgeräumt.
  def handle_info(
        {:pipeline_status,
         %{
           "kind" => "transcript_chunk",
           "campaign_id" => cid,
           "discord_id" => did,
           "text" => text,
           "at_ts" => at_ts
         }},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      live = Map.put(socket.assigns.live_utterances, did, %{text: text, at_ts: at_ts})
      {:noreply, assign(socket, :live_utterances, live)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  # ─── Internal helpers ──────────────────────────────────────────

  defp session_in_campaign?(_socket, nil), do: false

  defp session_in_campaign?(socket, sid) do
    Enum.any?(socket.assigns.sessions || [], fn s -> s["id"] == sid end)
  end

  # Resolve a Discord-ID → display name using the snapshot's `users` map.
  # New shape (Issue #6): %{discord_id => %{"display_name" => name, "avatar_url" => url}}.
  # Falls back to raw id if no record exists yet (e.g. legacy campaigns
  # pre-dating the owner-upsert fix).
  defp display_for(discord_id, users) when is_map(users) do
    case Map.get(users, discord_id) do
      %{"display_name" => name} when is_binary(name) -> name
      # Tolerate the old flat-string format during the deploy roll-over.
      name when is_binary(name) -> name
      _ -> discord_id
    end
  end

  defp display_for(discord_id, _), do: discord_id

  # Issue #2: character-name takes precedence over both display_name and
  # raw discord_id. Used in places where the per-campaign alias should win:
  # mainly the Mitspieler-Pill + Protokoll/Mic-Streamer rendering.
  defp display_for(discord_id, users, char_names)
       when is_map(users) and is_map(char_names) do
    case Map.get(char_names, discord_id) do
      name when is_binary(name) and name != "" -> name
      _ -> display_for(discord_id, users)
    end
  end

  # Lazily seed the synthetic `__listen__` sentinel user when the campaign
  # enters Listen mode. Idempotent (Materializer preserves joined_at).
  # Publish a CampaignAliasSet event for the acting user. Permission:
  # only members of the current campaign may set their own alias (and
  # only their own — owner-override is intentionally not implemented per
  # Issue #2 locked decisions).
  defp publish_alias(socket, character_name) do
    me = socket.assigns.current_user.discord_id

    if is_binary(me) and Enum.any?(socket.assigns.members, fn m -> m["discord_id"] == me end) do
      {:ok, _seq} =
        EventLog.append(
          %{
            "kind" => Shared.Events.campaign_alias_set(),
            "campaign_id" => socket.assigns.campaign_id,
            "discord_id" => me,
            "character_name" => character_name
          },
          nil
        )
    end

    :ok
  end

  defp ensure_listen_user(socket) do
    case socket.assigns.users do
      %{"__listen__" => "Test-Stream"} ->
        socket

      _ ->
        {:ok, _seq} =
          EventLog.append(
            %{
              "kind" => Shared.Events.user_upserted(),
              "discord_id" => "__listen__",
              "display_name" => "Test-Stream"
            },
            nil
          )

        socket
    end
  end

  # On every mount/reload: if the viewer isn't in the workers' `users`
  # table yet (or has a stale display_name), append a UserUpserted event
  # so the next snapshot resolves their id → name. Idempotent — Materializer
  # preserves joined_at. Fixes legacy campaigns where the owner created
  # the campaign before owner-upsert existed.
  defp backfill_viewer_user(socket, users) do
    user = socket.assigns.current_user
    snap_display = display_for(user && user.discord_id, users)

    cond do
      is_nil(user) or is_nil(user.discord_id) or is_nil(user.display_name) ->
        socket

      snap_display == user.display_name ->
        socket

      true ->
        {:ok, _seq} =
          EventLog.append(
            %{
              "kind" => Shared.Events.user_upserted(),
              "discord_id" => user.discord_id,
              "display_name" => user.display_name
            },
            nil
          )

        socket
    end
  end

  defp append_state(socket, state) do
    {:ok, _} =
      EventLog.append(
        %{
          "kind" => Shared.Events.recording_state_changed(),
          "session_id" => socket.assigns.active_session.id,
          "state" => state
        },
        nil
      )
  end

  # ─── Snapshot ──────────────────────────────────────────────────

  defp load_snapshot(socket) do
    scope = %{
      "kind" => "campaign",
      "id" => socket.assigns.campaign_id,
      "viewer_discord_id" => socket.assigns.current_user.discord_id
    }

    case Reader.read(scope) do
      {:ok, %{"forbidden" => true}} ->
        assign(socket, forbidden?: true)

      {:ok, %{"not_found" => true}} ->
        assign(socket, not_found?: true)

      {:ok, snap} ->
        c = snap["campaign"]

        socket
        |> assign(:waiting?, false)
        |> assign(:campaign, c)
        |> assign(:current_campaign, c)
        |> assign(:sessions, snap["sessions"] || [])
        |> assign(:members, snap["members"] || [])
        |> assign(:invites, snap["invites"] || [])
        |> assign(:active_session, deserialize_session(snap["active_session"]))
        |> assign(:utterances, snap["utterances"] || [])
        |> assign(:markers, snap["markers"] || [])
        |> assign(:epos, snap["epos"])
        |> assign(:epos_history, snap["epos_history"] || [])
        |> assign(:summaries, snap["summaries"] || [])
        |> assign(:chronik, snap["chronik"] || [])
        |> assign(:users, snap["users"] || %{})
        |> assign(:character_names, snap["character_names"] || %{})
        |> assign(:transcribe_mode, snap["transcribe_mode"] || "batch")
        |> assign(:owner?, c["owner_discord_id"] == socket.assigns.current_user.discord_id)
        |> assign(
          :is_member?,
          Enum.any?(snap["members"] || [], fn m ->
            m["discord_id"] == socket.assigns.current_user.discord_id
          end)
        )
        |> backfill_viewer_user(snap["users"] || %{})

      {:error, :no_worker} ->
        assign(socket, %{
          waiting?: true,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          active_session: nil,
          utterances: [],
          markers: [],
          epos: nil,
          epos_history: [],
          summaries: [],
          chronik: [],
          users: %{},
          character_names: %{},
          transcribe_mode: "batch",
          owner?: false,
          is_member?: false
        })

      {:error, reason} ->
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(%{
          waiting?: false,
          campaign: nil,
          current_campaign: nil,
          sessions: [],
          members: [],
          invites: [],
          active_session: nil,
          utterances: [],
          markers: [],
          epos: nil,
          epos_history: [],
          summaries: [],
          chronik: [],
          users: %{},
          character_names: %{},
          transcribe_mode: "batch",
          owner?: false,
          is_member?: false
        })
    end
  end

  defp deserialize_session(nil), do: nil

  defp deserialize_session(%{} = m) do
    %{
      id: m["id"],
      campaign_id: m["campaign_id"],
      number: m["number"],
      name: m["name"],
      status: String.to_atom(m["status"] || "scheduled"),
      scheduled_for: m["scheduled_for"],
      started_at: m["started_at"],
      ended_at: m["ended_at"]
    }
  end

  # ─── Render ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div id="mic-controls" phx-hook="RecordMic" phx-update="ignore"></div>
      <.recording_bar
        owner?={@owner?}
        active_session={@active_session}
        mic_on?={@mic_on?}
        mic_streamers={@mic_streamers}
        current_discord_id={@current_user.discord_id}
        users={@users}
        transcribe_mode={@transcribe_mode}
      />

      <%= if @invite_url do %>
        <div class="px-6 py-3 bg-accent/10 border-b border-accent/40 flex items-center gap-3">
          <span class="hero-link-mini w-4 h-4 text-accent"></span>
          <span class="text-sm text-ink-1">Einladungs-Link:</span>
          <input
            readonly
            value={@invite_url}
            onclick="this.select()"
            class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-sm text-accent font-mono"
          />
          <button phx-click="clear_invite_url" class="btn !py-1 !px-2">×</button>
        </div>
      <% end %>

      <span
        id="persist-cols"
        phx-hook="PersistCols"
        phx-update="ignore"
        data-campaign-id={@campaign_id}
      >
      </span>
      <div class="flex-1 flex gap-px bg-bg-3/60 overflow-hidden">
        <.column
          name="chronik"
          title="Chronik"
          subtitle=""
          busy?={MapSet.member?(@busy_stages, "stage4")}
          collapsed?={MapSet.member?(@collapsed_cols, "chronik")}
          can_collapse?={can_collapse?(@collapsed_cols, "chronik")}
        >
          <%= cond do %>
            <% @waiting? -> %>
              <.empty_col text="Warte auf Worker." />
            <% @chronik == [] -> %>
              <.empty_col text="Noch keine In-Game-Einträge. (Stufe-4-LLM füllt das — bis dahin via /dev/event)" />
            <% true -> %>
              <ol class="space-y-3">
                <%= for entry <- @chronik do %>
                  <li class="pl-3 border-l border-accent/40 group">
                    <%= if @chronik_editing == entry["id"] do %>
                      <form phx-submit="chronik_edit_save" class="space-y-1">
                        <input
                          type="text"
                          name="chronik[in_game_date]"
                          value={@chronik_draft["in_game_date"]}
                          placeholder="In-Game-Datum (z.B. 552 CY)"
                          class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-accent font-mono focus:border-accent focus:ring-0"
                        />
                        <input
                          type="text"
                          name="chronik[label]"
                          value={@chronik_draft["label"]}
                          placeholder="Titel (max ~50 Zeichen)"
                          maxlength="80"
                          class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-sm text-ink-0 font-medium focus:border-accent focus:ring-0"
                        />
                        <textarea
                          name="chronik[summary]"
                          rows="2"
                          placeholder="Kurze Zusammenfassung"
                          class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-2 focus:border-accent focus:ring-0"
                        ><%= @chronik_draft["summary"] %></textarea>
                        <div class="flex justify-end gap-1">
                          <button type="button" phx-click="chronik_edit_cancel" class="btn !py-0.5 !px-2 text-[10px]">Abbrechen</button>
                          <button type="submit" class="btn btn-primary !py-0.5 !px-2 text-[10px]">Speichern</button>
                        </div>
                      </form>
                    <% else %>
                      <div class="flex items-start justify-between gap-2">
                        <div class="flex-1 min-w-0">
                          <div class="text-xs text-accent font-mono">{entry["in_game_date"]}</div>
                          <div class="text-ink-0 text-sm font-medium">{entry["label"]}</div>
                          <%= if entry["summary"] do %>
                            <div class="text-ink-2 text-xs mt-1 line-clamp-3">{entry["summary"]}</div>
                          <% end %>
                        </div>
                        <%= if @is_member? do %>
                          <button
                            phx-click="chronik_edit_start"
                            phx-value-id={entry["id"]}
                            class="opacity-0 group-hover:opacity-100 transition-opacity text-ink-2 hover:text-accent text-xs"
                            title="Eintrag bearbeiten"
                          >
                            ✎
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </li>
                <% end %>
              </ol>
          <% end %>
        </.column>

        <.epos_column
          owner?={@owner?}
          can_edit?={@is_member?}
          waiting?={@waiting?}
          epos={@epos}
          epos_history={@epos_history}
          epos_mode={@epos_mode}
          epos_draft={@epos_draft}
          epos_diff_seq={@epos_diff_seq}
          busy?={MapSet.member?(@busy_stages, "stage3")}
          collapsed?={MapSet.member?(@collapsed_cols, "epos")}
          can_collapse?={can_collapse?(@collapsed_cols, "epos")}
        />

        <.column
          name="summaries"
          title="Resümee"
          subtitle="Was letztes Mal geschah"
          busy?={MapSet.member?(@busy_stages, "stage2")}
          collapsed?={MapSet.member?(@collapsed_cols, "summaries")}
          can_collapse?={can_collapse?(@collapsed_cols, "summaries")}
        >
          <%= cond do %>
            <% @waiting? -> %>
              <.empty_col text="Warte auf Worker." />
            <% @summaries == [] -> %>
              <.empty_col text="Noch keine Session-Resümees. (Stufe-2-LLM erzeugt sie nach jeder Session — bis dahin via /dev/event)" />
            <% true -> %>
              <div class="space-y-4">
                <%= for s <- @summaries do %>
                  <article class="pb-3 border-b border-bg-3/60 last:border-0">
                    <header class="flex items-baseline gap-2 mb-1">
                      <span class="text-ink-2 text-xs font-mono">{format_ts(s["generated_at"])}</span>
                      <span class={["pill", source_pill(s["source"])]}>
                        {s["source"]}
                      </span>
                      <div class="ml-auto flex items-center gap-2">
                        <%= if @is_member? do %>
                          <button
                            phx-click="summary_edit_start"
                            phx-value-session={s["session_id"]}
                            class="text-[10px] text-ink-2 hover:text-accent"
                            title="Resümee bearbeiten"
                          >
                            ✎ bearbeiten
                          </button>
                        <% end %>
                        <%= if @owner? do %>
                          <button
                            phx-click="rerun_pipeline"
                            phx-value-session={s["session_id"]}
                            data-confirm="Resümee/Epos/Chronik für diese Session neu generieren?"
                            class="text-[10px] text-ink-2 hover:text-accent"
                            title="Pipeline (Stages 2-4) für diese Session erneut ausführen"
                          >
                            🔄 neu generieren
                          </button>
                        <% end %>
                      </div>
                    </header>
                    <%= if @summary_editing == s["session_id"] do %>
                      <form phx-submit="summary_edit_save" class="space-y-2">
                        <textarea
                          name="content_md"
                          class="w-full h-32 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                          phx-update="ignore"
                          id={"summary-edit-#{s["session_id"]}"}
                        ><%= @summary_draft %></textarea>
                        <div class="flex justify-end gap-2">
                          <button type="button" phx-click="summary_edit_cancel" class="btn !py-1 text-xs">Abbrechen</button>
                          <button type="submit" class="btn btn-primary !py-1 text-xs">Speichern</button>
                        </div>
                      </form>
                    <% else %>
                      <p class="text-ink-0 text-sm whitespace-pre-wrap">{s["content_md"]}</p>
                    <% end %>
                  </article>
                <% end %>
              </div>
          <% end %>
        </.column>

        <.column
          name="protokoll"
          title="Protokoll"
          subtitle={protokoll_subtitle(@active_session)}
          busy?={MapSet.member?(@busy_stages, "stage1")}
          collapsed?={MapSet.member?(@collapsed_cols, "protokoll")}
          can_collapse?={can_collapse?(@collapsed_cols, "protokoll")}
        >
          <%= cond do %>
            <% @waiting? -> %>
              <.empty_col text="Warte auf Worker." />
            <% @utterances == [] -> %>
              <.empty_col text={"Noch keine Utterances. Klick REC und feuere `mix lore.fake_session " <> @campaign_id <> "` in einer Shell."} />
            <% true -> %>
              <ol class="space-y-2">
                <%= for {session_label, group} <- group_by_session(@utterances, @sessions) do %>
                  <% sid = List.first(group)["session_id"] %>
                  <li class="pt-3 first:pt-0">
                    <div class="text-[10px] uppercase tracking-widest text-ink-2 mb-1 border-t border-bg-3/60 pt-2 first:border-0 first:pt-0 flex items-center justify-between">
                      <span>{session_label}</span>
                      <%= if @is_member? and @utterance_adding != sid do %>
                        <button
                          phx-click="utterance_add_start"
                          phx-value-session={sid}
                          class="text-accent hover:underline normal-case tracking-normal text-[10px]"
                          title="Manuellen Eintrag hinzufügen"
                        >
                          + Eintrag
                        </button>
                      <% end %>
                    </div>
                    <ul class="space-y-2">
                      <%= for u <- group do %>
                        <li class="text-xs group flex items-baseline gap-1">
                          <%= if @utterance_editing == u["id"] do %>
                            <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                            <span class="text-accent">{display_for(u["discord_id"], @users, @character_names)}</span>
                            <form phx-submit="utterance_edit_save" class="flex-1 flex gap-1 items-start ml-1">
                              <textarea
                                name="text"
                                rows="2"
                                class="flex-1 bg-bg-0 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                              ><%= @utterance_draft %></textarea>
                              <button type="submit" class="btn btn-primary !py-0.5 !px-1.5 text-[10px]">✓</button>
                              <button type="button" phx-click="utterance_edit_cancel" class="btn !py-0.5 !px-1.5 text-[10px]">✗</button>
                            </form>
                          <% else %>
                            <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                            <span class="text-accent">{display_for(u["discord_id"], @users, @character_names)}</span>
                            <%= if u["status"] == "manual" do %>
                              <span class="text-[10px] text-accent/70" title="Manuell hinzugefügt">📝</span>
                            <% end %>
                            <span class={[
                              "ml-1 flex-1",
                              u["status"] == "pending" && "text-ink-2 italic",
                              u["status"] == "live" && "text-ink-1 italic",
                              u["status"] == "edited" && "text-ink-0",
                              u["status"] == "manual" && "text-ink-0"
                            ]}>
                              {u["text"]}
                            </span>
                            <%= if @is_member? do %>
                              <button
                                phx-click="utterance_edit_start"
                                phx-value-id={u["id"]}
                                class="opacity-0 group-hover:opacity-100 transition-opacity text-ink-2 hover:text-accent text-[10px]"
                                title="Bearbeiten"
                              >
                                ✎
                              </button>
                              <button
                                phx-click="utterance_delete"
                                phx-value-id={u["id"]}
                                data-confirm="Diesen Eintrag wirklich löschen?"
                                class="opacity-0 group-hover:opacity-100 transition-opacity text-ink-2 hover:text-red-400 text-[10px]"
                                title="Löschen"
                              >
                                ✕
                              </button>
                            <% end %>
                          <% end %>
                        </li>
                      <% end %>
                      <%= if @utterance_adding == sid do %>
                        <li class="text-xs">
                          <form
                            phx-submit="utterance_add_save"
                            class="flex flex-col gap-1 bg-bg-0 border border-accent/40 rounded p-2"
                          >
                            <div class="flex items-center gap-2">
                              <span class="text-[10px] uppercase tracking-widest text-ink-2">Sprecher</span>
                              <select
                                name="speaker"
                                class="bg-bg-1 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                              >
                                <%= for m <- @members do %>
                                  <option
                                    value={m["discord_id"]}
                                    selected={m["discord_id"] == @utterance_add_speaker}
                                  >
                                    {display_for(m["discord_id"], @users, @character_names)}
                                  </option>
                                <% end %>
                              </select>
                            </div>
                            <textarea
                              name="text"
                              rows="2"
                              autofocus
                              placeholder="Was wurde gesagt / passierte?"
                              class="w-full bg-bg-1 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                            ><%= @utterance_add_text %></textarea>
                            <div class="flex justify-end gap-1">
                              <button type="button" phx-click="utterance_add_cancel" class="btn !py-0.5 !px-2 text-[10px]">Abbrechen</button>
                              <button type="submit" class="btn btn-primary !py-0.5 !px-2 text-[10px]">Hinzufügen</button>
                            </div>
                          </form>
                        </li>
                      <% end %>
                    </ul>
                  </li>
                <% end %>
              </ol>
          <% end %>

          <%= if map_size(@live_utterances) > 0 do %>
            <ul class="mt-3 pt-2 border-t border-dashed border-bg-3/60 space-y-1">
              <%= for {did, %{text: t, at_ts: ts}} <- @live_utterances do %>
                <li class="text-xs italic text-ink-2 opacity-70">
                  <span class="font-mono mr-2">{format_ts(ts)}</span>
                  <span class="text-accent">{display_for(did, @users, @character_names)}</span>
                  <span class="ml-1">
                    {t}<span class="animate-pulse">▍</span>
                  </span>
                </li>
              <% end %>
            </ul>
          <% end %>
        </.column>
      </div>

      <div class="border-t border-bg-3/60 px-4 py-2 text-xs text-ink-2 flex items-center gap-3 bg-bg-1 flex-wrap">
        <span class="uppercase tracking-widest">Mitspieler</span>
        <%= for m <- @members do %>
          <%= if m["discord_id"] == @current_user.discord_id do %>
            <button
              phx-click="alias_edit_start"
              class={[
                "pill cursor-pointer hover:bg-accent/20",
                m["role"] == "owner" && "pill-active"
              ]}
              title="Charakter-Namen setzen (nur du selbst)"
            >
              {display_for(m["discord_id"], @users, @character_names)} ✎
            </button>
          <% else %>
            <span class={["pill", m["role"] == "owner" && "pill-active"]} title={m["discord_id"]}>
              {display_for(m["discord_id"], @users, @character_names)}
            </span>
          <% end %>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <button phx-click="create_invite" class="btn !py-1">
            <span class="hero-link-mini w-3 h-3"></span> Einladung
          </button>
        <% end %>
      </div>

      <%= if @alias_mode == :edit do %>
        <div
          class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center"
          phx-click="alias_edit_cancel"
        >
          <div
            class="panel p-5 w-[420px] max-w-[90vw]"
            phx-click-away="alias_edit_cancel"
            phx-window-keydown="alias_edit_cancel"
            phx-key="escape"
          >
            <h2 class="font-display text-lg mb-2">Charakter-Name</h2>
            <p class="text-xs text-ink-2 mb-3">
              Wird statt deines Discord-Namens in Protokoll, Resümees,
              Epos und Chronik dieser Kampagne angezeigt. Leer = zurücksetzen.
            </p>
            <form phx-submit="alias_edit_save" class="space-y-3">
              <input
                type="text"
                name="character_name"
                value={@alias_draft}
                maxlength="80"
                autofocus
                placeholder="z.B. Tharion der Entdecker"
                class="block w-full bg-bg-0 border border-bg-3 rounded-md px-3 py-2 text-ink-0 text-sm focus:border-accent focus:ring-0"
              />
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="alias_edit_cancel" class="btn !py-1">Abbrechen</button>
                <button type="button" phx-click="alias_edit_reset" class="btn !py-1">Reset</button>
                <button type="submit" class="btn btn-primary !py-1">Speichern</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @owner? and Enum.any?(@invites, & &1["status"] == "active") do %>
        <div class="border-t border-bg-3/60 px-4 py-2 text-xs bg-bg-1">
          <div class="uppercase tracking-widest text-ink-2 mb-1">Offene Einladungen</div>
          <%= for inv <- @invites, inv["status"] == "active" do %>
            <div class="flex items-center gap-2 py-1">
              <span class="text-accent font-mono truncate">{inv["token"]}</span>
              <button
                phx-click="revoke_invite"
                phx-value-token={inv["token"]}
                class="ml-auto text-ink-2 hover:text-rec-soft"
              >
                Widerrufen
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp recording_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 bg-bg-1 border-b border-bg-3/60">
      <%= case rec_state(@active_session) do %>
        <% :recording -> %>
          <button phx-click="rec_pause" class="btn" disabled={not @owner?}>
            <span class="hero-pause w-4 h-4"></span> Pause
          </button>
          <button phx-click="rec_stop" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-stop-circle-solid w-4 h-4"></span> Stopp
          </button>
          <button phx-click="rec_marker" class="btn" disabled={not @owner?}>
            <span class="hero-bookmark w-4 h-4"></span> Marker
          </button>
          <span class="ml-2 text-rec-soft text-xs uppercase tracking-widest">● Aufnahme läuft</span>
        <% :paused -> %>
          <button phx-click="rec_resume" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-play w-4 h-4"></span> Resume
          </button>
          <button phx-click="rec_stop" class="btn" disabled={not @owner?}>
            <span class="hero-stop-circle w-4 h-4"></span> Stopp
          </button>
          <button phx-click="rec_marker" class="btn" disabled={not @owner?}>
            <span class="hero-bookmark w-4 h-4"></span> Marker
          </button>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <button phx-click="rec_start" class="btn btn-rec" disabled={not @owner?}>
            <span class="hero-stop-circle-solid w-4 h-4"></span>
            <%= if @transcribe_mode == "listen", do: "🔊 REC (Listen)", else: "REC" %>
          </button>
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">○ Keine aktive Session</span>
      <% end %>
      <span class={[
        "pill text-[10px]",
        @transcribe_mode in ["live", "listen"] && "pill-active"
      ]} title="Stage-1-Modus (Settings)">
        Stage 1: {@transcribe_mode}
      </span>
      <div class="flex-1"></div>
      <.mic_controls
        active_session={@active_session}
        mic_on?={@mic_on?}
        mic_streamers={@mic_streamers}
        current_discord_id={@current_discord_id}
        users={@users}
      />
      <span class="text-xs text-ink-2 font-mono">{elapsed(@active_session)}</span>
      <%= if @owner? do %>
        <button
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          class="btn"
          title="Worker herunterfahren"
        >
          <span class="hero-power w-4 h-4"></span>
        </button>
      <% end %>
    </div>
    """
  end

  defp mic_controls(assigns) do
    assigns =
      assign(
        assigns,
        :streamer_names,
        Enum.map(assigns.mic_streamers, &display_for(&1, assigns.users))
      )

    ~H"""
    <%= if @active_session do %>
      <div class="flex items-center gap-2">
        <span class="text-xs text-ink-2 font-mono">
          🎙 {length(@mic_streamers)} streamen
        </span>
        <%= if @streamer_names != [] do %>
          <span class="text-[10px] text-ink-2 font-mono truncate max-w-[14rem]" title={Enum.join(@streamer_names, ", ")}>
            ({Enum.join(@streamer_names, ", ")})
          </span>
        <% end %>
        <%= if @mic_on? or @current_discord_id in @mic_streamers do %>
          <button phx-click="mic_leave" class="btn btn-rec !py-1" title="Mein Mikro stoppen">
            <span class="hero-no-symbol w-4 h-4"></span> Mikro aus
          </button>
        <% else %>
          <button phx-click="mic_join" class="btn !py-1" title="Mein Mikro für diese Session aktivieren">
            <span class="hero-microphone w-4 h-4"></span> Mit Mikro beitreten
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  # ─── Epos column ───────────────────────────────────────────────

  defp epos_column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name="epos" title="Epos" busy?={@busy?} />
    <% else %>
    <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
      <div class="col-header">
        <span class="flex items-center gap-2">
          The Epos
          <.busy_dot show?={@busy?} />
        </span>
        <span class="flex items-center gap-2">
        <%= cond do %>
          <% @can_edit? and @epos_mode == :view -> %>
            <button phx-click="epos_edit_start" class="text-accent text-xs hover:underline">
              Bearbeiten
            </button>
          <% @epos_mode == :edit -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Bearbeitet…</span>
          <% true -> %>
            <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">Main Campaign Book</span>
        <% end %>
          <.collapse_chevron name="epos" can_collapse?={@can_collapse?} direction={:close} />
        </span>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        <%= cond do %>
          <% @waiting? -> %>
            <p class="text-ink-2 text-sm italic">Warte auf Worker.</p>
          <% @epos_mode == :diff -> %>
            <.epos_diff history={@epos_history} target_seq={@epos_diff_seq} current={@epos} />
          <% @epos_mode == :edit -> %>
            <form phx-submit="epos_edit_save" class="space-y-2">
              <textarea
                name="content_md"
                class="w-full h-72 bg-bg-0 border border-bg-3 rounded p-2 text-sm font-mono text-ink-0 focus:border-accent focus:ring-0"
                phx-update="ignore"
                id="epos-textarea"
              ><%= @epos_draft %></textarea>
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="epos_edit_cancel" class="btn !py-1">Abbrechen</button>
                <button type="submit" class="btn btn-primary !py-1">Speichern</button>
              </div>
            </form>
          <% @epos == nil or @epos["content_md"] in [nil, ""] -> %>
            <p class="text-ink-2 text-sm italic">
              Noch leer.<%= if @can_edit?, do: " Klick 'Bearbeiten' oben.", else: "" %>
            </p>
            <.epos_history_section history={@epos_history} />
          <% true -> %>
            <article class="text-ink-0 text-sm whitespace-pre-wrap leading-relaxed">{@epos["content_md"]}</article>
            <.epos_history_section history={@epos_history} />
        <% end %>
      </div>
    </div>
    <% end %>
    """
  end

  defp epos_history_section(assigns) do
    ~H"""
    <%= if @history != [] do %>
      <div class="mt-6 pt-3 border-t border-bg-3/60">
        <div class="uppercase tracking-widest text-ink-2 text-[10px] mb-2">Versionen</div>
        <ul class="space-y-1">
          <%= for h <- @history do %>
            <li class="flex items-baseline gap-2 text-xs">
              <span class="font-mono text-ink-2">#{h["seq"]}</span>
              <span class="text-ink-1">{format_ts(h["edited_at"])}</span>
              <span class={["pill", source_pill(h["source"])]}>
                {h["source"] || "?"}
              </span>
              <button
                phx-click="epos_diff_open"
                phx-value-seq={h["seq"]}
                class="ml-auto text-accent hover:underline"
              >
                Diff
              </button>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  defp epos_diff(assigns) do
    current_md = (assigns.current && assigns.current["content_md"]) || ""

    target =
      Enum.find(assigns.history, fn h -> h["seq"] == assigns.target_seq end)

    target_md = (target && target["content_md"]) || ""

    diff =
      List.myers_difference(
        String.split(target_md, "\n"),
        String.split(current_md, "\n")
      )

    assigns = assign(assigns, diff: diff, target: target)

    ~H"""
    <div class="space-y-3">
      <div class="flex items-baseline justify-between">
        <h3 class="font-display text-sm tracking-wide">
          Diff: #{(@target && @target["seq"]) || "?"} → current
        </h3>
        <button phx-click="epos_diff_close" class="text-accent hover:underline text-xs">
          ← zurück zur Ansicht
        </button>
      </div>
      <div class="text-xs font-mono bg-bg-0 border border-bg-3 rounded p-3 overflow-x-auto whitespace-pre">
        <%= for {op, lines} <- @diff, line <- lines do %>
          <div class={diff_line_class(op)}>{diff_prefix(op)}{line}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp diff_line_class(:eq), do: "text-ink-2"
  defp diff_line_class(:del), do: "text-rec-soft bg-rec/10"
  defp diff_line_class(:ins), do: "text-emerald-300 bg-emerald-500/10"

  defp diff_prefix(:eq), do: "  "
  defp diff_prefix(:del), do: "- "
  defp diff_prefix(:ins), do: "+ "

  defp source_pill("manual"), do: "pill-archived"
  defp source_pill("llm"), do: "pill-new"
  defp source_pill(_), do: ""

  # ─── Helpers ──────────────────────────────────────────────────

  defp rec_state(nil), do: :idle
  defp rec_state(%{status: status}), do: status

  defp elapsed(%{started_at: started}) when not is_nil(started) do
    started_dt =
      case started do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %DateTime{} = dt ->
          dt
      end

    case started_dt do
      nil ->
        "00:00:00"

      dt ->
        secs = DateTime.diff(DateTime.utc_now(), dt)
        h = div(secs, 3600)
        m = rem(div(secs, 60), 60)
        s = rem(secs, 60)

        :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s])
        |> IO.iodata_to_binary()
    end
  end

  defp elapsed(_), do: "00:00:00"

  defp format_ts(nil), do: "--:--:--"

  defp format_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso
    end
  end

  defp protokoll_subtitle(nil), do: "Live Transkript"
  defp protokoll_subtitle(%{number: n}), do: "Session #{n} · Live Transkript"

  # Issue #8: ein Toggle ist erlaubt wenn die Spalte schon zu ist (Aufklappen
  # geht immer) oder wenn nach dem Einklappen noch mind. eine andere offen
  # bleibt.
  defp can_collapse?(collapsed_cols, name) do
    MapSet.member?(collapsed_cols, name) or
      MapSet.size(collapsed_cols) < length(@col_names) - 1
  end

  # Returns [{session_label, [utterance, ...]}, ...] preserving the order in
  # which session_ids first appear in `utterances` (i.e. chronological).
  defp group_by_session(utterances, sessions) do
    sess_by_id =
      Enum.into(sessions || [], %{}, fn s -> {s["id"], s} end)

    utterances
    |> Enum.chunk_by(& &1["session_id"])
    |> Enum.map(fn group ->
      sid = List.first(group)["session_id"]
      {session_label(sess_by_id[sid], sid), group}
    end)
  end

  defp session_label(nil, sid), do: "Session ?? · #{String.slice(sid || "", 0, 8)}"
  defp session_label(%{"number" => n, "name" => name}, _sid) when is_binary(name) and name != "", do: "Session #{n} · #{name}"
  defp session_label(%{"number" => n}, _sid), do: "Session #{n}"

  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  attr :busy?, :boolean, default: false
  attr :collapsed?, :boolean, default: false
  attr :can_collapse?, :boolean, default: true
  slot :inner_block, required: true

  defp column(assigns) do
    ~H"""
    <%= if @collapsed? do %>
      <.collapsed_strip name={@name} title={@title} busy?={@busy?} />
    <% else %>
      <div class="bg-bg-1 flex flex-col min-h-0 flex-1 min-w-0 transition-all duration-200">
        <div class="col-header">
          <span class="flex items-center gap-2">
            {@title}
            <.busy_dot show?={@busy?} />
          </span>
          <span class="flex items-center gap-2">
            <%= if @subtitle != "" do %>
              <span class="text-ink-2 text-[10px] font-sans normal-case tracking-normal">
                {@subtitle}
              </span>
            <% end %>
            <.collapse_chevron name={@name} can_collapse?={@can_collapse?} direction={:close} />
          </span>
        </div>
        <div class="flex-1 overflow-y-auto p-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    <% end %>
    """
  end

  # Schmaler vertikaler Strip für eingeklappte Spalten (Issue #8).
  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :busy?, :boolean, default: false

  defp collapsed_strip(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col items-center justify-between py-2 w-10 transition-all duration-200 border-l border-bg-3/40">
      <button
        type="button"
        phx-click="col_toggle"
        phx-value-col={@name}
        class="text-ink-2 hover:text-accent text-sm"
        title="Spalte aufklappen"
      >
        ◀
      </button>
      <span class="flex-1 flex items-center justify-center">
        <span
          class="text-ink-1 text-xs uppercase tracking-widest font-display"
          style="writing-mode: vertical-rl; transform: rotate(180deg);"
        >
          {@title}
        </span>
      </span>
      <.busy_dot show?={@busy?} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :can_collapse?, :boolean, default: true
  attr :direction, :atom, values: [:close, :open], default: :close

  defp collapse_chevron(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="col_toggle"
      phx-value-col={@name}
      disabled={not @can_collapse?}
      class={[
        "text-ink-2 text-xs",
        @can_collapse? && "hover:text-accent",
        not @can_collapse? && "opacity-30 cursor-not-allowed"
      ]}
      title={if @direction == :close, do: "Spalte einklappen", else: "Spalte aufklappen"}
    >
      {if @direction == :close, do: "▶", else: "◀"}
    </button>
    """
  end

  attr :show?, :boolean, default: false

  defp busy_dot(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[10px] font-sans uppercase tracking-wide transition-opacity",
      not @show? && "opacity-0"
    ]}>
      <span class="relative flex h-2 w-2">
        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-accent opacity-75"></span>
        <span class="relative inline-flex rounded-full h-2 w-2 bg-accent"></span>
      </span>
      <span class="text-accent">LLM</span>
    </span>
    """
  end

  defp empty_col(assigns) do
    ~H"""
    <p class="text-ink-2 text-sm italic">{@text}</p>
    """
  end
end
