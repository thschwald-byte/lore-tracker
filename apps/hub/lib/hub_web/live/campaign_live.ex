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

  alias Hub.{Commands, EventBridge, Events, Reader}

  # Column-Keys für Collapse-Persistenz (Issue #8). Reihenfolge entspricht
  # dem Render-Layout — wichtig nur als kanonischer Whitelist-Check.
  @col_names ~w(chronik epos summaries protokoll)

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hub.PubSub, Events.topic())
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
      |> assign(:campaign_replay_running?, false)
      |> assign(:campaign_replay_state, nil)
      |> assign(:mic_on?, false)
      |> assign(:mic_streamers, [])
      |> assign(:live_utterances, %{})
      |> assign(:alias_mode, :view)
      |> assign(:alias_draft, "")
      |> assign(:summary_editing, nil)
      |> assign(:summary_draft, "")
      |> assign(:vocab_editing, false)
      |> assign(:vocab_draft, "")
      |> assign(:chronik_editing, nil)
      |> assign(:chronik_draft, %{})
      |> assign(:utterance_editing, nil)
      |> assign(:utterance_draft, "")
      |> assign(:utterance_adding, nil)
      |> assign(:utterance_add_speaker, nil)
      |> assign(:utterance_add_text, "")
      |> assign(:flavor_editing?, false)
      |> assign(:flavor_drafts, %{})
      |> assign(:collapsed_cols, MapSet.new())
      |> assign(:delete_confirming?, false)
      |> assign(:delete_typed_name, "")
      |> assign(:remove_confirm_did, nil)
      |> assign(:demote_confirm_did, nil)
      |> assign(:faithfulness_expanded, MapSet.new())
      |> assign(:expanded_sessions, MapSet.new())
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
      bridge_publish(socket, %{
        "kind" => Shared.Events.marker_added(),
        "id" => UUIDv7.generate(),
        "session_id" => socket.assigns.active_session.id,
        "at_ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "marker_kind" => "plot",
        "label" => "Plot-Moment"
      })
    end

    {:noreply, socket}
  end

  # ─── Pipeline re-run ────────────────────────────────────────────

  def handle_event("rerun_pipeline", %{"session" => session_id}, socket) do
    campaign = perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :regenerate_session, campaign) ->
        {:noreply, socket}

      true ->
        # Issue #121: kein RegenerateRequested-Event mehr — direkter
        # Channel-Push an den Owner-Worker, der dann Pipeline.run_for_session
        # callt. Kein Hub-Event-Roundtrip mehr für reinen Trigger.
        # Issue #140: `owner_discord_id` ist im Snapshot der erste
        # Spielleiter (Recording-Leader-Routing).
        n =
          Hub.Commands.request_session_regenerate(
            snap["owner_discord_id"],
            campaign.id,
            session_id
          )

        if n > 0 do
          {:noreply, put_flash(socket, :info, "Pipeline neu gestartet für Session.")}
        else
          {:noreply,
           put_flash(socket, :error, "Owner-Worker nicht verbunden — Pipeline-Trigger fehlgeschlagen.")}
        end
    end
  end

  # Issue #104: Campaign-Level-Pipeline-Trigger. Engine läuft auf dem
  # Owner-Worker (Worker.Recording.CampaignReplay) — der aufrufende
  # Spielleiter ist möglicherweise nicht selbst Campaign-Owner.
  def handle_event("rerun_campaign", _params, socket) do
    campaign = perm_campaign(socket)
    snap = socket.assigns[:campaign] || %{}

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :regenerate_campaign, campaign) ->
        {:noreply, socket}

      true ->
        n = Hub.Commands.request_campaign_replay(snap["owner_discord_id"], campaign.id)

        if n > 0 do
          {:noreply,
           put_flash(
             socket,
             :info,
             "Pipeline für alle Sessions gestartet — läuft im Worker, Status oben."
           )}
        else
          {:noreply,
           put_flash(socket, :error, "Owner-Worker nicht verbunden — Replay nicht startbar.")}
        end
    end
  end

  # campaign-assign ist ein String-keyed Map vom Snapshot — Permissions
  # erwartet `:id` als Atom. Issue #140: Permission-Gating geht über
  # `user.campaign_role`, nicht mehr über owner_discord_id auf der Campaign.
  defp perm_campaign(socket) do
    c = socket.assigns[:campaign] || %{}
    %{id: c["id"]}
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

  def handle_event("vocab_edit_start", _, socket) do
    hint = get_in(socket.assigns, [:campaign, :vocab_hint]) || ""
    {:noreply, assign(socket, vocab_editing: true, vocab_draft: hint)}
  end

  def handle_event("vocab_edit_cancel", _, socket) do
    {:noreply, assign(socket, vocab_editing: false, vocab_draft: "")}
  end

  def handle_event("vocab_edit_save", %{"vocab_hint" => text}, socket) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :edit_vocab, campaign) do
      Hub.EventBridge.publish(%{
        "kind" => Shared.Events.campaign_vocab_updated(),
        "campaign_id" => campaign.id,
        "vocab_hint" => String.slice(text, 0, 2000),
        "by_discord_id" => user.discord_id
      })
      {:noreply, assign(socket, vocab_editing: false, vocab_draft: "")}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  def handle_event("faithfulness_toggle", %{"session" => sid}, socket) do
    expanded = socket.assigns.faithfulness_expanded

    new_expanded =
      if MapSet.member?(expanded, sid),
        do: MapSet.delete(expanded, sid),
        else: MapSet.put(expanded, sid)

    {:noreply, assign(socket, :faithfulness_expanded, new_expanded)}
  end

  def handle_event("summary_edit_save", %{"content_md" => content_md}, socket) do
    if socket.assigns.can_edit_meta? and socket.assigns.summary_editing do
      bridge_publish(socket, %{
        "kind" => Shared.Events.session_summary_edited(),
        "session_id" => socket.assigns.summary_editing,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id
      })
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

    if socket.assigns.can_edit_meta? and existing do
      bridge_publish(socket, %{
        "kind" => Shared.Events.chronik_entry_changed(),
        "id" => id,
        "campaign_id" => socket.assigns.campaign_id,
        "in_game_date" => attrs["in_game_date"] || existing["in_game_date"],
        "label" => attrs["label"] || existing["label"],
        "summary" => attrs["summary"] || existing["summary"],
        "session_id" => existing["session_id"],
        "edited_by" => socket.assigns.current_user.discord_id,
        "source" => "manual"
      })
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

    if existing && can_edit_utterance?(socket, existing) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.utterance_edited(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "new_text" => text,
        "edited_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def handle_event("utterance_delete", %{"id" => id}, socket) do
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if existing && can_edit_utterance?(socket, existing) do
      bridge_publish(socket, %{
        "kind" => Shared.Events.utterance_deleted(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "deleted_by" => socket.assigns.current_user.discord_id
      })
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
      not socket.assigns.can_edit_meta? ->
        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}

      sid in [nil, ""] or cleaned == "" or speaker not in member_dids ->
        {:noreply, socket}

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.utterance_appended(),
          "id" => UUIDv7.generate(),
          "session_id" => sid,
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => speaker,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "text" => cleaned,
          "confidence" => nil,
          "status" => "manual"
        })

        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
    end
  end

  # ─── Flavor / Stil (LLM Voice) ──────────────────────────────────

  def handle_event("flavor_edit_start", _, socket) do
    current = current_flavors(socket)
    {:noreply, assign(socket, flavor_editing?: true, flavor_drafts: current)}
  end

  def handle_event("flavor_edit_cancel", _, socket) do
    {:noreply, assign(socket, flavor_editing?: false, flavor_drafts: %{})}
  end

  def handle_event("flavor_edit_save", params, socket) do
    if socket.assigns.can_edit_meta? do
      current = current_flavors(socket)

      ~w(base summary epos chronik)
      |> Enum.each(fn slot ->
        old = Map.get(current, slot)
        new = clean_flavor(params[slot])

        if old != new do
          bridge_publish(socket, %{
            "kind" => Shared.Events.campaign_flavor_set(),
            "campaign_id" => socket.assigns.campaign_id,
            "slot" => slot,
            "flavor" => new,
            "edited_by" => socket.assigns.current_user.discord_id
          })
        end
      end)
    end

    {:noreply, assign(socket, flavor_editing?: false, flavor_drafts: %{})}
  end

  # ─── Kampagne löschen (Issue #15) ────────────────────────────────

  def handle_event("campaign_delete_request", _, socket) do
    {:noreply, assign(socket, delete_confirming?: true, delete_typed_name: "")}
  end

  def handle_event("campaign_delete_cancel", _, socket) do
    {:noreply, assign(socket, delete_confirming?: false, delete_typed_name: "")}
  end

  def handle_event("campaign_delete_typing", %{"name" => typed}, socket) do
    {:noreply, assign(socket, delete_typed_name: typed)}
  end

  def handle_event("campaign_delete_confirm", %{"name" => typed}, socket) do
    expected = (socket.assigns.campaign || %{})["name"] || ""

    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply, put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen löschen.")}

      String.trim(typed) != expected ->
        {:noreply,
         put_flash(socket, :error, "Kampagnenname stimmt nicht — Löschung abgebrochen.")}

      true ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.campaign_deleted(),
          "campaign_id" => socket.assigns.campaign_id,
          "deleted_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "Kampagne '#{expected}' gelöscht.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # ─── Member entfernen (Issue #55 / 52A) ─────────────────────────

  def handle_event("member_remove_request", %{"discord_id" => did}, socket) do
    {:noreply, assign(socket, remove_confirm_did: did)}
  end

  def handle_event("member_remove_cancel", _, socket) do
    {:noreply, assign(socket, remove_confirm_did: nil)}
  end

  def handle_event("member_remove_confirm", %{"discord_id" => did}, socket) do
    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply,
         socket
         |> put_flash(:error, "Nur Spielleiter oder Admin dürfen Mitspieler entfernen.")
         |> assign(remove_confirm_did: nil)}

      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Der letzte Spielleiter kann nicht entfernt werden. Befördere erst eine andere Mitspielerin."
         )
         |> assign(remove_confirm_did: nil)}

      true ->
        display =
          display_for(did, socket.assigns.users, socket.assigns.character_names)

        bridge_publish(socket, %{
          "kind" => Shared.Events.member_removed(),
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => did,
          "removed_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "#{display} aus der Kampagne entfernt.")
         |> assign(remove_confirm_did: nil)}
    end
  end

  # ─── Promote / Demote (Issue #140 Phase B) ──────────────────────

  def handle_event("member_promote", %{"discord_id" => did}, socket) do
    handle_role_change(socket, did, :spielleiter)
  end

  def handle_event("member_demote_request", %{"discord_id" => did}, socket) do
    {:noreply, assign(socket, demote_confirm_did: did)}
  end

  def handle_event("member_demote_cancel", _, socket) do
    {:noreply, assign(socket, demote_confirm_did: nil)}
  end

  def handle_event("member_demote_confirm", %{"discord_id" => did}, socket) do
    cond do
      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Letzter Spielleiter — Demote würde die Kampagne führungslos lassen."
         )
         |> assign(demote_confirm_did: nil)}

      true ->
        socket
        |> assign(demote_confirm_did: nil)
        |> handle_role_change(did, :spieler)
    end
  end

  defp handle_role_change(socket, did, new_role)
       when new_role in [:spielleiter, :spieler] do
    cond do
      not HubWeb.Permissions.can?(
        socket.assigns.perm_user,
        :promote_member,
        socket.assigns.campaign
      ) ->
        {:noreply,
         put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Rollen ändern.")}

      true ->
        display = display_for(did, socket.assigns.users, socket.assigns.character_names)

        bridge_publish(socket, %{
          "kind" => Shared.Events.member_role_promoted(),
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => did,
          "new_role" => Atom.to_string(new_role),
          "promoted_by" => socket.assigns.current_user.discord_id
        })

        flash =
          case new_role do
            :spielleiter -> "#{display} ist jetzt Spielleiter dieser Kampagne."
            :spieler -> "#{display} ist jetzt Spieler dieser Kampagne."
          end

        {:noreply, put_flash(socket, :info, flash)}
    end
  end

  defp last_spielleiter?(members, did) do
    sls =
      Enum.filter(members, fn m ->
        m["role"] in ["spielleiter", "owner"]
      end)

    case sls do
      [%{"discord_id" => only_did}] -> only_did == did
      _ -> false
    end
  end

  defp member_sl?(m), do: m["role"] in ["spielleiter", "owner"]

  # Permission-Helper (Issue #36): Spieler darf nur eigene Utterances
  # ändern/löschen. Owner+Admin dürfen alle. Akzeptiert socket ODER
  # assigns-Map (für Template-Aufrufe).
  defp can_edit_utterance?(%{assigns: assigns}, utterance),
    do: can_edit_utterance?(assigns, utterance)

  defp can_edit_utterance?(assigns, utterance) when is_map(assigns) do
    assigns.can_edit_meta? or
      utterance["discord_id"] == assigns.current_user.discord_id
  end

  defp current_flavors(socket) do
    case (socket.assigns.campaign || %{})["flavors"] do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp clean_flavor(nil), do: nil

  defp clean_flavor(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      text -> String.slice(text, 0, 2000)
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
      bridge_publish(socket, %{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => socket.assigns.campaign_id,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id,
        "source" => "manual"
      })
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

  # Issue #207: Protokoll-Sessions kollabier-/aufklappbar. Toggle pro
  # session_id; mehrere parallel offen erlaubt.
  def handle_event("protokoll_session_toggle", %{"session" => sid}, socket) do
    current = socket.assigns.expanded_sessions

    next =
      if MapSet.member?(current, sid),
        do: MapSet.delete(current, sid),
        else: MapSet.put(current, sid)

    {:noreply, assign(socket, :expanded_sessions, next)}
  end

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

      bridge_publish(socket, %{
        "kind" => Shared.Events.invite_created(),
        "token" => token,
        "campaign_id" => socket.assigns.campaign_id,
        "created_by_discord_id" => socket.assigns.current_user.discord_id,
        "expires_at" => nil
      })

      url = HubWeb.Endpoint.url() <> "/invite/#{token}"
      {:noreply, assign(socket, :invite_url, url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_invite_url", _, socket),
    do: {:noreply, assign(socket, :invite_url, nil)}

  def handle_event("revoke_invite", %{"token" => token}, socket) do
    if socket.assigns.owner? do
      bridge_publish(socket, %{
        "kind" => Shared.Events.invite_revoked(),
        "token" => token,
        "campaign_id" => socket.assigns.campaign_id
      })
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
  def handle_info(
        {:event_appended, %{payload: %{"kind" => "UtteranceAppended"} = payload}},
        socket
      ) do
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

  # UtteranceEdited / UtteranceDeleted eager auf die utterances-Liste anwenden
  # damit die geänderte Zeile sofort sichtbar ist — ohne auf den 150ms-Reload
  # (Race mit Worker-Materialisierung) zu warten. Der reguläre Snapshot-Reload
  # passiert trotzdem über den catch-all unten, das ist nur eine Beschleunigung.
  def handle_info({:event_appended, %{payload: %{"kind" => "UtteranceEdited"} = payload}}, socket) do
    if session_in_campaign?(socket, payload["session_id"]) do
      id = payload["id"]
      new_text = payload["new_text"] || ""

      updated =
        Enum.map(socket.assigns.utterances, fn u ->
          if u["id"] == id do
            u |> Map.put("text", new_text) |> Map.put("status", "edited")
          else
            u
          end
        end)

      Process.send_after(self(), :reload, 150)
      {:noreply, assign(socket, :utterances, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:event_appended, %{payload: %{"kind" => "UtteranceDeleted"} = payload}},
        socket
      ) do
    if session_in_campaign?(socket, payload["session_id"]) do
      id = payload["id"]
      updated = Enum.reject(socket.assigns.utterances, fn u -> u["id"] == id end)
      Process.send_after(self(), :reload, 150)
      {:noreply, assign(socket, :utterances, updated)}
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

  def handle_info({:event_appended, %{payload: %{"kind" => "SessionStarted"} = payload}}, socket) do
    Process.send_after(self(), :reload, 150)

    # Issue #207: neue Session sofort expandieren, damit Live-Utterances
    # nicht in einer zugeklappten Sektion landen.
    socket =
      case payload["id"] do
        sid when is_binary(sid) ->
          assign(socket, :expanded_sessions, MapSet.put(socket.assigns.expanded_sessions, sid))

        _ ->
          socket
      end

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
        CampaignFlavorSet
        UserRoleSet AdminMemberAdded
      ) do
    Process.send_after(self(), :reload, 150)
    {:noreply, socket}
  end

  # Wenn die Kampagne gerade gelöscht wird, navigate weg statt zu reloaden
  # (Reload würde "kampagne nicht gefunden" werfen).
  def handle_info(
        {:event_appended, %{payload: %{"kind" => "CampaignDeleted", "campaign_id" => cid}}},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      {:noreply,
       socket
       |> put_flash(:info, "Kampagne wurde gelöscht.")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_appended, _}, socket), do: {:noreply, socket}
  def handle_info(:reload, socket), do: {:noreply, load_snapshot(socket)}

  def handle_info({:workers_changed, _joins, _leaves}, socket),
    do: {:noreply, load_snapshot(socket)}

  def handle_info(
        {:pipeline_status,
         %{"kind" => "pipeline_stage", "campaign_id" => cid, "stage" => stage, "status" => status} =
           payload},
        socket
      ) do
    handle_pipeline_stage(cid, stage, status, payload["error"], socket)
  end

  # Older pipeline_status payloads (no explicit "kind") — keep matching the
  # stage shape so existing emitters that didn't tag a kind still work.
  def handle_info(
        {:pipeline_status,
         %{"campaign_id" => cid, "stage" => stage, "status" => status} = payload},
        socket
      ) do
    handle_pipeline_stage(cid, stage, status, payload["error"], socket)
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

  # Issue #104: Campaign-Replay-Engine broadcastet ihren Fortschritt als
  # kind="campaign_replay" — Banner-Update + Buttons-disable.
  def handle_info(
        {:pipeline_status,
         %{"kind" => "campaign_replay", "campaign_id" => cid, "status" => status} = payload},
        socket
      ) do
    if cid == socket.assigns.campaign_id do
      running? = status in ["started", "session_started", "session_done"]

      state =
        if running? do
          %{
            current: payload["current"] || 0,
            total: payload["total"] || 0,
            session_number: payload["session_number"],
            session_id: payload["session_id"]
          }
        else
          nil
        end

      socket =
        socket
        |> assign(:campaign_replay_running?, running?)
        |> assign(:campaign_replay_state, state)
        |> then(fn s ->
          if status == "finished",
            do: put_flash(s, :info, "Campaign-Replay durch — alle Sessions neu generiert."),
            else: s
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:pipeline_status, _}, socket), do: {:noreply, socket}

  defp handle_pipeline_stage(cid, stage, status, error_msg, socket) do
    if cid == socket.assigns.campaign_id do
      busy =
        case status do
          "started" -> MapSet.put(socket.assigns.busy_stages, stage)
          _ -> MapSet.delete(socket.assigns.busy_stages, stage)
        end

      socket =
        socket
        |> assign(:busy_stages, busy)
        |> maybe_flash_pipeline_error(stage, status, error_msg)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp maybe_flash_pipeline_error(socket, stage, "failed", msg)
       when is_binary(msg) and msg != "" do
    put_flash(socket, :error, "LLM-Pipeline #{stage} fehlgeschlagen: #{msg}")
  end

  defp maybe_flash_pipeline_error(socket, stage, "failed", _) do
    put_flash(socket, :error, "LLM-Pipeline #{stage} fehlgeschlagen — Logs prüfen.")
  end

  defp maybe_flash_pipeline_error(socket, _, _, _), do: socket

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

  # Issue #154 (Etappe 4c.2): Hub-LV erzeugt Events nicht mehr direkt via
  # EventLog.append, sondern delegiert an einen online Worker via
  # Hub.EventBridge. Worker macht Worker-First-Apply + sync zurück. Cold-Fail
  # (kein Worker für die Campaign online) wird nur geloggt — Hub-LV bleibt
  # responsive, das Event ist halt vorerst nicht propagiert. Die Sichtbarkeit
  # im LV passiert async über das nachfolgende event_appended-Broadcast.
  defp bridge_publish(socket, payload) do
    cid = payload["campaign_id"] || socket.assigns[:campaign_id]

    case EventBridge.publish(cid, payload) do
      :ok ->
        :ok

      {:error, :no_worker_online} ->
        require Logger

        Logger.warning(
          "CampaignLive.bridge_publish: kein Worker online (kind=#{payload["kind"]} campaign=#{cid})"
        )

        :ok
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
      bridge_publish(socket, %{
        "kind" => Shared.Events.campaign_alias_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "discord_id" => me,
        "character_name" => character_name
      })
    end

    :ok
  end

  defp ensure_listen_user(socket) do
    case socket.assigns.users do
      %{"__listen__" => "Test-Stream"} ->
        socket

      _ ->
        bridge_publish(socket, %{
          "kind" => Shared.Events.user_upserted(),
          "discord_id" => "__listen__",
          "display_name" => "Test-Stream"
        })

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
        bridge_publish(socket, %{
          "kind" => Shared.Events.user_upserted(),
          "discord_id" => user.discord_id,
          "display_name" => user.display_name
        })

        socket
    end
  end

  defp append_state(socket, state) do
    bridge_publish(socket, %{
      "kind" => Shared.Events.recording_state_changed(),
      "session_id" => socket.assigns.active_session.id,
      "campaign_id" => socket.assigns.campaign_id,
      "state" => state
    })
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
        members = snap["members"] || []

        viewer_member =
          Enum.find(members, fn m ->
            m["discord_id"] == socket.assigns.current_user.discord_id
          end)

        is_member? = viewer_member != nil

        # Issue #140: per-Campaign-Rolle aus der Member-Liste ableiten.
        # `nil` wenn nicht Member; `:spielleiter` | `:spieler` sonst.
        # Backward-Compat: Worker auf Versionen <0.13.0 liefern noch die
        # alten Atoms `:owner` / `:player`. Bei Multi-Worker-Setups (eine
        # Campaign wird vom Worker des Erstellers gehostet) sieht der Hub
        # ggf. einen Mix aus alten + neuen Workern; das Mapping hier
        # toleriert beides. Sobald alle Worker auf >=0.13.0 sind, fallen
        # die Alt-Klauseln still durch.
        campaign_role =
          case viewer_member && viewer_member["role"] do
            "spielleiter" -> :spielleiter
            "owner" -> :spielleiter
            "spieler" -> :spieler
            "player" -> :spieler
            _ -> nil
          end

        role = (snap["viewer_role"] || "spieler") |> String.to_atom()

        perm_user = %{
          discord_id: socket.assigns.current_user.discord_id,
          role: role,
          is_member?: is_member?,
          campaign_role: campaign_role
        }

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
        |> assign(:faithfulness_by_session, faithfulness_index(snap["faithfulness"] || []))
        |> assign(:chronik, snap["chronik"] || [])
        |> assign(:users, snap["users"] || %{})
        |> assign(:character_names, snap["character_names"] || %{})
        |> assign(:transcribe_mode, snap["transcribe_mode"] || "batch")
        |> assign(:viewer_role, role)
        |> assign(:perm_user, perm_user)
        # Issue #140: `@owner?` ist die Phase-A-Bezeichnung für „per-
        # Campaign-:spielleiter dieser Kampagne". Globaler :admin zählt
        # auch hier als GM, damit alle GM-Buttons-Gates konsistent mit
        # Permissions.can?/3 (das :admin als Universal-Allow behandelt)
        # bleiben.
        |> assign(
          :owner?,
          role == :admin or campaign_role == :spielleiter
        )
        |> assign(:is_member?, is_member?)
        |> assign(
          :can_edit_meta?,
          role == :admin or campaign_role == :spielleiter
        )
        |> assign(
          :can_regenerate_session?,
          HubWeb.Permissions.can?(perm_user, :regenerate_session, c)
        )
        |> assign(
          :can_regenerate_campaign?,
          HubWeb.Permissions.can?(perm_user, :regenerate_campaign, c)
        )
        |> backfill_viewer_user(snap["users"] || %{})
        |> ensure_default_session_expanded()

      {:error, :no_worker} ->
        # Issue #146: bei vorübergehendem no_worker NICHT die assigns
        # hart auf Defaults zurücksetzen — sonst verlieren Spielleiter
        # nach kurzem Worker-Aussetzer fälschlich ihre GM-Buttons. Wenn
        # ein früherer Snapshot-Lauf erfolgreich war, bleiben Campaign,
        # Members, Permissions etc. erhalten; nur `waiting?` wird
        # gesetzt, damit die UI einen Banner zeigen kann. Beim nächsten
        # workers_changed-Event triggert ein Re-Load, der die Werte
        # ohnehin frisch füllt.
        socket
        |> assign(:waiting?, true)
        |> merge_or_default_assigns(error_branch_defaults(socket))

      {:error, reason} ->
        # Wie oben: alte assigns überleben den Fehlerzustand, plus Flash
        # damit die Ursache (Timeout etc.) sichtbar wird.
        socket
        |> put_flash(:error, "Snapshot fehlgeschlagen: #{inspect(reason)}")
        |> assign(:waiting?, true)
        |> merge_or_default_assigns(error_branch_defaults(socket))
    end
  end

  # Issue #146: Defaults nur dort einsetzen wo die assigns noch nie
  # belegt waren (= erster Mount, bevor je ein erfolgreicher Snapshot
  # kam). Vorhandene assigns bleiben unangetastet.
  defp merge_or_default_assigns(socket, defaults) do
    Enum.reduce(defaults, socket, fn {key, default}, acc ->
      case Map.fetch(acc.assigns, key) do
        {:ok, _existing} -> acc
        :error -> assign(acc, key, default)
      end
    end)
  end

  defp error_branch_defaults(socket) do
    %{
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
      faithfulness_by_session: %{},
      chronik: [],
      users: %{},
      character_names: %{},
      transcribe_mode: "batch",
      viewer_role: :spieler,
      perm_user: %{
        discord_id: socket.assigns.current_user.discord_id,
        role: :spieler,
        is_member?: false,
        campaign_role: nil
      },
      owner?: false,
      is_member?: false,
      can_edit_meta?: false,
      can_regenerate_session?: false,
      can_regenerate_campaign?: false
    }
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
          <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="clear_invite_url" title="Einladungs-Link ausblenden" />
        </div>
      <% end %>

      <%= if @campaign_replay_running? do %>
        <div class="px-6 py-2 bg-warning/10 border-b border-warning/40 flex items-center gap-3 text-sm">
          <span class="inline-block w-2 h-2 rounded-full bg-warning animate-pulse"></span>
          <span class="text-ink-1">
            Pipeline läuft: Session {(@campaign_replay_state && @campaign_replay_state[:current]) || "?"}
            von {(@campaign_replay_state && @campaign_replay_state[:total]) || "?"}
            <%= if @campaign_replay_state && @campaign_replay_state[:session_number] do %>
              <span class="text-ink-2">(#{@campaign_replay_state[:session_number]})</span>
            <% end %>
          </span>
          <span class="ml-auto text-xs text-ink-2">
            ~2 min pro Session — Resümees / Epos / Chronik werden überschrieben
          </span>
        </div>
      <% end %>

      <%= if @can_regenerate_campaign? do %>
        <div class="px-6 py-2 border-b border-bg-3/40 flex justify-end">
          <.btn
            variant="secondary"
            icon="refresh"
            phx-click="rerun_campaign"
            disabled={@campaign_replay_running?}
            data-confirm={"Pipeline für alle Sessions neu starten? Läuft ~#{length(@sessions)} × ~2 min = ~#{length(@sessions) * 2} min. Resumées / Epos / Chronik werden überschrieben."}
          >
            Pipeline neu starten
          </.btn>
        </div>
      <% end %>

      <.flavor_editor
        flavors={(@campaign && @campaign["flavors"]) || %{}}
        editing?={@flavor_editing?}
        drafts={@flavor_drafts}
        is_member?={@can_edit_meta?}
      />

      <%= if HubWeb.Permissions.can?(@perm_user, :edit_vocab, @campaign) do %>
        <div class="px-6 py-2 border-b border-bg-3/60 bg-bg-1/50 text-xs">
          <div class="text-ink-2/70 uppercase tracking-widest mb-1">Whisper-Vokabular</div>
          <%= if @vocab_editing do %>
            <form phx-submit="vocab_edit_save">
              <textarea
                name="vocab_hint"
                rows="3"
                class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0"
                placeholder="Eigennamen, Orte, NPCs — kommagetrennt. Hilft Whisper beim Erkennen."
              ><%= @vocab_draft %></textarea>
              <div class="flex justify-end gap-2 mt-1">
                <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="vocab_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
              </div>
            </form>
          <% else %>
            <div class="flex items-start gap-2">
              <span class="text-xs text-ink-1 flex-1 whitespace-pre-wrap">
                <%= if @campaign && @campaign["vocab_hint"] && @campaign["vocab_hint"] != "" do %>
                  <%= @campaign["vocab_hint"] %>
                <% else %>
                  <span class="italic text-ink-2/50">Kein Vokabular-Hint gesetzt.</span>
                <% end %>
              </span>
              <.ls_icon_btn_compat kind={:edit} size={:sm} phx-click="vocab_edit_start" title="Vokabular bearbeiten" />
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @can_edit_meta? do %>
        <.delete_zone
          campaign_name={(@campaign && @campaign["name"]) || ""}
          confirming?={@delete_confirming?}
          typed={@delete_typed_name}
        />
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
            <% @waiting? and @chronik == [] -> %>
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
                          <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="chronik_edit_cancel" title="Abbrechen" />
                          <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
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
                        <%= if @can_edit_meta? do %>
                          <.ls_icon_btn_compat
                            kind={:edit}
                            phx-click="chronik_edit_start"
                            phx-value-id={entry["id"]}
                            title="Eintrag bearbeiten"
                          />
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
          can_edit?={@can_edit_meta?}
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
            <% @waiting? and @summaries == [] -> %>
              <.empty_col text="Warte auf Worker." />
            <% @summaries == [] -> %>
              <.empty_col text="Noch keine Session-Resümees. (Stufe-2-LLM erzeugt sie nach jeder Session — bis dahin via /dev/event)" />
            <% true -> %>
              <% sessions_by_id = Map.new(@sessions, &{&1["id"], &1}) %>
              <div class="space-y-4">
                <%= for s <- @summaries do %>
                  <article class="pb-3 border-b border-bg-3/60 last:border-0">
                    <header class="grid grid-cols-3 items-baseline gap-2 mb-1">
                      <div class="flex items-baseline gap-2">
                        <span class="text-ink-2 text-xs font-mono">{format_ts(s["generated_at"])}</span>
                        <span class={["pill", source_pill(s["source"])]}>
                          {s["source"]}
                        </span>
                        <% fscore = @faithfulness_by_session[s["session_id"]] %>
                        <%= if fscore do %>
                          <button
                            type="button"
                            phx-click="faithfulness_toggle"
                            phx-value-session={s["session_id"]}
                            class={["pill text-[10px] cursor-pointer", faithfulness_pill_class(fscore["score"])]}
                            title="Faithfulness-Score (NLI) — klick für Claim-Details"
                          >
                            {faithfulness_label(fscore["score"])}
                          </button>
                        <% end %>
                      </div>
                      <div
                        class="text-center text-[10px] uppercase tracking-widest text-ink-2 truncate"
                        title={session_label(sessions_by_id[s["session_id"]], s["session_id"])}
                      >
                        {session_label(sessions_by_id[s["session_id"]], s["session_id"])}
                      </div>
                      <div class="flex items-baseline justify-end gap-2">
                        <%= if @can_edit_meta? do %>
                          <.ls_icon_btn_compat
                            kind={:edit}
                            phx-click="summary_edit_start"
                            phx-value-session={s["session_id"]}
                            title="Resümee bearbeiten"
                          />
                        <% end %>
                        <%= if @can_regenerate_session? do %>
                          <.ls_icon_btn_compat
                            kind={:regenerate}
                            phx-click="rerun_pipeline"
                            phx-value-session={s["session_id"]}
                            disabled={@campaign_replay_running?}
                            data-confirm="Resümee/Epos/Chronik für diese Session neu generieren?"
                            title="Pipeline (Stages 2-4) für diese Session erneut ausführen"
                          />
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
                          <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="summary_edit_cancel" title="Abbrechen" />
                          <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
                        </div>
                      </form>
                    <% else %>
                      <p class="text-ink-0 text-sm whitespace-pre-wrap">{s["content_md"]}</p>
                      <%= if MapSet.member?(@faithfulness_expanded, s["session_id"]) and fscore do %>
                        <div class="mt-3 pt-2 border-t border-bg-3/40">
                          <div class="text-[10px] uppercase tracking-widest text-ink-2 mb-1">
                            Claims ({length(fscore["claims"] || [])})
                          </div>
                          <ul class="space-y-1 text-xs">
                            <%= for claim <- (fscore["claims"] || []) do %>
                              <li class="flex items-start gap-2">
                                <span class={["mt-0.5 flex-shrink-0 w-2 h-2 rounded-full", faithfulness_claim_dot(claim["label"])]}></span>
                                <span class="text-ink-1">{claim["text"]}</span>
                              </li>
                            <% end %>
                          </ul>
                        </div>
                      <% end %>
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
            <% @waiting? and @utterances == [] -> %>
              <.empty_col text="Warte auf Worker." />
            <% @utterances == [] -> %>
              <.empty_col text={"Noch keine Utterances. Klick REC und feuere `mix lore.fake_session " <> @campaign_id <> "` in einer Shell."} />
            <% true -> %>
              <ol class="space-y-2">
                <%= for {session_label, group} <- group_by_session(@utterances, @sessions) do %>
                  <% sid = List.first(group)["session_id"] %>
                  <% expanded? = MapSet.member?(@expanded_sessions, sid) %>
                  <% active? = !!(@active_session && @active_session.id == sid) %>
                  <li class="pt-3 first:pt-0">
                    <div class="text-[10px] uppercase tracking-widest text-ink-2 mb-1 border-t border-bg-3/60 pt-2 first:border-0 first:pt-0 flex items-center justify-between gap-2">
                      <button
                        type="button"
                        phx-click="protokoll_session_toggle"
                        phx-value-session={sid}
                        class="flex-1 flex items-center gap-1.5 text-left hover:text-ink-0 transition-colors"
                        title={if expanded?, do: "Session zuklappen", else: "Session aufklappen"}
                      >
                        <span class={[
                          "inline-block transition-transform duration-150 text-ink-1",
                          expanded? && "rotate-90"
                        ]}>▸</span>
                        <span>{session_label}</span>
                        <span class="text-ink-2/70 normal-case tracking-normal">({length(group)})</span>
                        <%= if active? and not expanded? do %>
                          <span class="text-accent normal-case tracking-normal animate-pulse">● live</span>
                        <% end %>
                      </button>
                      <%= if expanded? and @can_edit_meta? and @utterance_adding != sid do %>
                        <.ls_icon_btn_compat
                          kind={:add}
                          phx-click="utterance_add_start"
                          phx-value-session={sid}
                          title="Manuellen Eintrag hinzufügen"
                        />
                      <% end %>
                    </div>
                    <ul :if={expanded?} class="space-y-2">
                      <%= for u <- group do %>
                        <li class="text-xs group flex items-baseline gap-1">
                          <%= if @utterance_editing == u["id"] do %>
                            <span class="text-ink-2 font-mono mr-2">{format_ts(u["timestamp"])}</span>
                            <span class="text-accent">{display_for(u["discord_id"], @users, @character_names)}</span>
                            <form phx-submit="utterance_edit_save" class="flex-1 flex gap-1 items-start ml-1">
                              <textarea
                                id={"utterance-edit-#{u["id"]}"}
                                name="text"
                                rows="2"
                                phx-update="ignore"
                                class="flex-1 bg-bg-0 border border-bg-3 rounded px-1.5 py-0.5 text-xs text-ink-0 focus:border-accent focus:ring-0"
                              ><%= @utterance_draft %></textarea>
                              <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Speichern" />
                              <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="utterance_edit_cancel" title="Abbrechen" />
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
                            <%= if can_edit_utterance?(assigns, u) do %>
                              <.ls_icon_btn_compat
                                kind={:edit}
                                phx-click="utterance_edit_start"
                                phx-value-id={u["id"]}
                                title="Eintrag bearbeiten"
                              />
                              <.ls_icon_btn_compat
                                kind={:delete}
                                phx-click="utterance_delete"
                                phx-value-id={u["id"]}
                                data-confirm="Diesen Eintrag wirklich löschen?"
                                title="Eintrag löschen"
                              />
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
                              <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="utterance_add_cancel" title="Abbrechen" />
                              <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Eintrag hinzufügen" />
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
          <span class="inline-flex items-center gap-1">
            <%= if m["discord_id"] == @current_user.discord_id do %>
              <button
                phx-click="alias_edit_start"
                class={[
                  "pill cursor-pointer hover:bg-accent/20",
                  member_sl?(m) && "pill-active"
                ]}
                title={
                  if(member_sl?(m),
                    do: "Spielleiter dieser Kampagne — Charakter-Namen setzen (nur du selbst)",
                    else: "Charakter-Namen setzen (nur du selbst)"
                  )
                }
              >
                {display_for(m["discord_id"], @users, @character_names)} ✎
              </button>
            <% else %>
              <span
                class={["pill", member_sl?(m) && "pill-active"]}
                title={
                  if(member_sl?(m),
                    do: "Spielleiter dieser Kampagne · #{m["discord_id"]}",
                    else: m["discord_id"]
                  )
                }
              >
                {display_for(m["discord_id"], @users, @character_names)}
              </span>
            <% end %>

            <%= if @can_edit_meta? and m["discord_id"] != @current_user.discord_id do %>
              <%= cond do %>
                <% @remove_confirm_did == m["discord_id"] -> %>
                  <span class="text-[10px] text-amber-400">entfernen?</span>
                  <.ls_icon_btn_compat
                    kind={:confirm}
                    size={:sm}
                    phx-click="member_remove_confirm"
                    phx-value-discord_id={m["discord_id"]}
                    title="Ja, entfernen"
                  />
                  <.ls_icon_btn_compat
                    kind={:cancel}
                    size={:sm}
                    phx-click="member_remove_cancel"
                    title="Abbrechen"
                  />
                <% @demote_confirm_did == m["discord_id"] -> %>
                  <span class="text-[10px] text-amber-400">zum Spieler zurückstufen?</span>
                  <.ls_icon_btn_compat
                    kind={:confirm}
                    size={:sm}
                    phx-click="member_demote_confirm"
                    phx-value-discord_id={m["discord_id"]}
                    title="Ja, zurückstufen"
                  />
                  <.ls_icon_btn_compat
                    kind={:cancel}
                    size={:sm}
                    phx-click="member_demote_cancel"
                    title="Abbrechen"
                  />
                <% member_sl?(m) -> %>
                  <%= unless last_spielleiter?(@members, m["discord_id"]) do %>
                    <.ls_icon_btn_compat
                      kind={:demote}
                      size={:sm}
                      phx-click="member_demote_request"
                      phx-value-discord_id={m["discord_id"]}
                      title="Zum Spieler zurückstufen"
                    />
                  <% end %>
                <% true -> %>
                  <.ls_icon_btn_compat
                    kind={:promote}
                    size={:sm}
                    phx-click="member_promote"
                    phx-value-discord_id={m["discord_id"]}
                    title="Zum Spielleiter befördern (Co-GM)"
                  />
                  <.ls_icon_btn_compat
                    kind={:delete}
                    size={:sm}
                    phx-click="member_remove_request"
                    phx-value-discord_id={m["discord_id"]}
                    title="Aus Kampagne entfernen"
                  />
              <% end %>
            <% end %>
          </span>
        <% end %>

        <%= if @owner? do %>
          <div class="flex-1"></div>
          <.ls_icon_btn_compat kind={:invite} size={:sm} phx-click="create_invite" title="Einladung erstellen" />
        <% end %>
      </div>

      <%= if @alias_mode == :edit do %>
        <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center">
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
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="alias_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:reset} size={:md} phx-click="alias_edit_reset" title="Zurücksetzen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
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
              <.ls_icon_btn_compat
                kind={:revoke}
                size={:sm}
                phx-click="revoke_invite"
                phx-value-token={inv["token"]}
                title="Einladung widerrufen"
                class="ml-auto"
              />
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Stil/Voice der LLM-Stages für diese Kampagne. 4 Slots: base (Welt/
  # Setting) + summary/epos/chronik (Voice/Persona pro Spalte). Member-
  # editierbar. Collapsed-View zeigt eine schmale Status-Zeile, Expanded
  # öffnet 4 Textareas als Akkordeon.
  attr(:flavors, :map, default: %{})
  attr(:editing?, :boolean, default: false)
  attr(:drafts, :map, default: %{})
  attr(:is_member?, :boolean, default: false)

  defp flavor_editor(assigns) do
    assigns =
      assign(assigns,
        set_count: flavor_set_count(assigns.flavors),
        slot_labels: flavor_slot_labels()
      )

    ~H"""
    <div class="px-6 py-2 border-b border-bg-3/60 bg-bg-1/50 text-xs">
      <%= cond do %>
        <% @editing? -> %>
          <form phx-submit="flavor_edit_save" class="flex flex-col gap-3">
            <div class="flex items-center gap-2">
              <span class="text-base">🎭</span>
              <span class="uppercase tracking-widest text-ink-2 text-[10px]">
                Stil für diese Kampagne
              </span>
              <span class="text-ink-2/70 text-[10px]">
                — Base = Welt/Setting, dann pro Spalte die Erzähl-Stimme
              </span>
            </div>

            <%= for {slot, label, placeholder} <- @slot_labels do %>
              <div class="flex flex-col gap-1">
                <label class="text-ink-2 text-[10px] uppercase tracking-widest">
                  {label}
                </label>
                <textarea
                  name={slot}
                  rows="2"
                  maxlength="2000"
                  placeholder={placeholder}
                  class="w-full bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0"
                ><%= Map.get(@drafts, slot, "") %></textarea>
              </div>
            <% end %>

            <p class="text-ink-2/60 text-[10px] italic">
              Tipp: Wenn dein lokales Ollama-Modell ein eigenes Modelfile mit System-Prompt hat,
              hat dieser höhere Priorität und kann den Stil überschreiben.
            </p>

            <div class="flex justify-end gap-2">
              <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="flavor_edit_cancel" title="Abbrechen" />
              <.ls_icon_btn_compat kind={:confirm} size={:sm} type="submit" title="Stil speichern" />
            </div>
          </form>
        <% true -> %>
          <div class="flex items-center gap-2">
            <span class="text-base">🎭</span>
            <%= if @set_count == 0 do %>
              <span class="text-ink-2/70 italic flex-1">Kein eigener Stil — neutrale Default-Prompts.</span>
            <% else %>
              <span class="text-ink-1 italic flex-1">
                {@set_count} von 4 Stilen gesetzt
                <span class="text-ink-2/70">({flavor_summary(@flavors)})</span>
              </span>
            <% end %>
            <%= if @is_member? do %>
              <.ls_icon_btn_compat
                kind={:edit}
                size={:sm}
                phx-click="flavor_edit_start"
                title={if @set_count == 0, do: "Stil setzen", else: "Stil bearbeiten"}
              />
            <% end %>
          </div>
      <% end %>

    </div>
    """
  end

  defp flavor_slot_labels do
    [
      {"base", "Welt / Grundstimmung (Base)",
       ~s(z.B. „Im grünen Auenland voller glücklicher Hobbits" / „In den Schützengräben von Verdun" / „Zwischen den Dünen von Tatooine")},
      {"summary", "Resümee-Stimme",
       ~s(z.B. „neutraler Erzähler" / „Reporter eines Boulevardblatts")},
      {"epos", "Epos-Stimme",
       ~s(z.B. „Tolkien-Stil epischer Erzähler, Präteritum" / „grimmiger nordischer Skalde mit vielen Kennings")},
      {"chronik", "Chronik-Stimme", ~s(z.B. „nüchtern und sachlich, Vergangenheitsform")}
    ]
  end

  defp flavor_set_count(flavors) when is_map(flavors) do
    ~w(base summary epos chronik)
    |> Enum.count(fn k ->
      case Map.get(flavors, k) do
        s when is_binary(s) and s != "" -> true
        _ -> false
      end
    end)
  end

  defp flavor_set_count(_), do: 0

  defp flavor_summary(flavors) when is_map(flavors) do
    [
      {"base", "Base"},
      {"summary", "Resümee"},
      {"epos", "Epos"},
      {"chronik", "Chronik"}
    ]
    |> Enum.filter(fn {k, _} ->
      case Map.get(flavors, k) do
        s when is_binary(s) and s != "" -> true
        _ -> false
      end
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.join(" • ")
  end

  defp flavor_summary(_), do: ""

  # Owner-only Danger-Zone: Kampagne löschen mit Name-Bestätigung. Cascade
  # läuft im Worker-Materializer (CampaignDeleted-Event).
  attr(:campaign_name, :string, required: true)
  attr(:confirming?, :boolean, default: false)
  attr(:typed, :string, default: "")

  defp delete_zone(assigns) do
    ~H"""
    <div class="px-6 py-2 border-b border-bg-3/60 bg-bg-1/30 text-xs">
      <%= cond do %>
        <% @confirming? -> %>
          <form phx-submit="campaign_delete_confirm" phx-change="campaign_delete_typing" class="flex flex-col gap-2">
            <div class="flex items-center gap-2 text-rec-soft">
              <span class="text-base">⚠</span>
              <span class="uppercase tracking-widest text-[10px]">
                Kampagne unwiderruflich löschen
              </span>
              <span class="text-ink-2/70 text-[10px]">
                — alle Sessions, Protokolle, Resümees, Epos, Chronik werden mit gelöscht
              </span>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-ink-2 text-[10px]">
                Tippe den Kampagnennamen zur Bestätigung: <code class="text-rec-soft">{@campaign_name}</code>
              </span>
            </div>
            <div class="flex gap-2 items-center">
              <input
                type="text"
                name="name"
                value={@typed}
                autocomplete="off"
                class="flex-1 bg-bg-0 border border-bg-3 rounded px-2 py-1 text-xs text-ink-0 focus:border-accent focus:ring-0 font-mono"
                placeholder={@campaign_name}
              />
              <.btn variant="ghost" phx-click="campaign_delete_cancel">Abbrechen</.btn>
              <.btn
                variant="danger"
                icon="trash"
                type="submit"
                disabled={String.trim(@typed) != @campaign_name}
              >
                Endgültig löschen
              </.btn>
            </div>
          </form>
        <% true -> %>
          <div class="flex items-center gap-2 justify-end">
            <.ls_icon_btn_compat
              kind={:cascade_delete}
              size={:md}
              phx-click="campaign_delete_request"
              title="Kampagne mit allen Einträgen unwiderruflich löschen"
            />
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
          <.ls_icon_btn_compat kind={:rec_pause} size={:md} phx-click="rec_pause" disabled={not @owner?} title="Aufnahme pausieren" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-rec-soft text-xs uppercase tracking-widest">● Aufnahme läuft</span>
        <% :paused -> %>
          <.ls_icon_btn_compat kind={:rec_resume} size={:lg} phx-click="rec_resume" disabled={not @owner?} title="Aufnahme fortsetzen" />
          <.ls_icon_btn_compat kind={:rec_stop} size={:lg} phx-click="rec_stop" disabled={not @owner?} title="Aufnahme stoppen" />
          <.ls_icon_btn_compat kind={:marker} size={:md} phx-click="rec_marker" disabled={not @owner?} title="Szenen-Marker setzen" />
          <span class="ml-2 text-ink-2 text-xs uppercase tracking-widest">|| Pause</span>
        <% _ -> %>
          <.ls_icon_btn_compat
            kind={:rec_start}
            size={:lg}
            phx-click="rec_start"
            disabled={not @owner?}
            title={if @transcribe_mode == "listen", do: "Aufnahme starten (Listen-Modus)", else: "Aufnahme starten"}
          />
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
        <.ls_icon_btn_compat
          kind={:power}
          size={:sm}
          phx-click="shutdown_worker"
          data-confirm="Worker wirklich herunterfahren?"
          title="Worker herunterfahren"
        />
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
          <.ls_icon_btn_compat kind={:mic_off} size={:md} phx-click="mic_leave" title="Mein Mikro stoppen" />
        <% else %>
          <.ls_icon_btn_compat kind={:mic_on} size={:md} phx-click="mic_join" title="Mit Mikro beitreten" />
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
            <.ls_icon_btn_compat kind={:edit} size={:sm} phx-click="epos_edit_start" title="Epos bearbeiten" />
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
          <% @waiting? and is_nil(@epos) -> %>
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
                <.ls_icon_btn_compat kind={:cancel} size={:md} phx-click="epos_edit_cancel" title="Abbrechen" />
                <.ls_icon_btn_compat kind={:confirm} size={:md} type="submit" title="Speichern" />
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
              <.ls_icon_btn_compat
                kind={:diff}
                size={:sm}
                phx-click="epos_diff_open"
                phx-value-seq={h["seq"]}
                title="Diff zur aktuellen Version"
                class="ml-auto"
              />
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
        <.ls_icon_btn_compat kind={:cancel} size={:sm} phx-click="epos_diff_close" title="Zurück zur Epos-Ansicht" />
      </div>
      <div class="text-xs font-mono bg-bg-0 border border-bg-3 rounded p-3 overflow-x-auto whitespace-pre">
        <%= for {op, lines} <- @diff, line <- lines do %>
          <div class={diff_line_class(op)}>{diff_prefix(op)}{line}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp diff_line_class(:eq), do: "text-fg-muted"
  defp diff_line_class(:del), do: "text-danger bg-danger/10"
  defp diff_line_class(:ins), do: "text-success bg-success/10"

  defp diff_prefix(:eq), do: "  "
  defp diff_prefix(:del), do: "- "
  defp diff_prefix(:ins), do: "+ "

  defp source_pill("manual"), do: "pill-archived"
  defp source_pill("llm"), do: "pill-new"
  defp source_pill(_), do: ""

  # ─── Faithfulness (Issue #11 Phase 2) ─────────────────────────
  # Score-Map nach session_id für O(1)-Lookup im Template.
  defp faithfulness_index(list) when is_list(list) do
    Enum.into(list, %{}, fn entry -> {entry["session_id"], entry} end)
  end

  defp faithfulness_index(_), do: %{}

  defp faithfulness_label(score) when is_number(score) do
    pct = round(score * 100)
    "📊 #{pct}%"
  end

  defp faithfulness_label(_), do: "📊 –"

  defp faithfulness_pill_class(score) when is_number(score) and score >= 0.8,
    do: "bg-success/20 text-success border border-success/40"

  defp faithfulness_pill_class(score) when is_number(score) and score >= 0.5,
    do: "bg-warning/20 text-warning border border-warning/40"

  defp faithfulness_pill_class(score) when is_number(score),
    do: "bg-danger/20 text-danger border border-danger/40"

  defp faithfulness_pill_class(_), do: "bg-surface-2/40 text-fg-muted"

  defp faithfulness_claim_dot("entailment"), do: "bg-success"
  defp faithfulness_claim_dot("contradiction"), do: "bg-danger"
  defp faithfulness_claim_dot(_), do: "bg-warning"

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

  defp session_label(%{"number" => n, "name" => name}, _sid) when is_binary(name) and name != "",
    do: "Session #{n} · #{name}"

  defp session_label(%{"number" => n}, _sid), do: "Session #{n}"

  # Sorgt dafür, dass beim ersten Snapshot-Load die höchste Session-Nummer
  # automatisch expanded ist (Issue #207). Nur wenn die User-State-MapSet
  # leer ist — User-Toggles bleiben sonst erhalten.
  defp ensure_default_session_expanded(socket) do
    expanded = socket.assigns.expanded_sessions
    sessions = socket.assigns.sessions || []

    if MapSet.size(expanded) == 0 and sessions != [] do
      top = highest_session(sessions)
      if top, do: assign(socket, :expanded_sessions, MapSet.put(expanded, top["id"])), else: socket
    else
      socket
    end
  end

  defp highest_session(sessions) do
    sessions
    |> Enum.reject(&is_nil(&1["number"]))
    |> Enum.max_by(& &1["number"], fn -> nil end)
  end

  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: "")
  attr(:busy?, :boolean, default: false)
  attr(:collapsed?, :boolean, default: false)
  attr(:can_collapse?, :boolean, default: true)
  slot(:inner_block, required: true)

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
  attr(:name, :string, required: true)
  attr(:title, :string, required: true)
  attr(:busy?, :boolean, default: false)

  defp collapsed_strip(assigns) do
    ~H"""
    <div class="bg-bg-1 flex flex-col items-center justify-between py-2 w-10 transition-all duration-200 border-l border-bg-3/40">
      <.ls_icon_btn_compat
        kind={:expand}
        size={:sm}
        phx-click="col_toggle"
        phx-value-col={@name}
        title="Spalte aufklappen"
      />
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

  attr(:name, :string, required: true)
  attr(:can_collapse?, :boolean, default: true)
  attr(:direction, :atom, values: [:close, :open], default: :close)

  defp collapse_chevron(assigns) do
    ~H"""
    <.ls_icon_btn_compat
      kind={if @direction == :close, do: :collapse, else: :expand}
      size={:sm}
      phx-click="col_toggle"
      phx-value-col={@name}
      disabled={not @can_collapse?}
      title={if @direction == :close, do: "Spalte einklappen", else: "Spalte aufklappen"}
    />
    """
  end

  attr(:show?, :boolean, default: false)

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
