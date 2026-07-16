defmodule HubWeb.CampaignLive.StageEdits do
  @moduledoc """
  Bearbeitung der abgeleiteten Inhalte der CampaignLive (Issue #3/#291/#385,
  ausgelagert in #434 Cut 4): Resümee-, Vokabular-, Chronik- und Epos-Edits +
  die Chronik-Markdown-Konvertierung.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  `chronik_entry_to_markdown/1`, `parse_chronik_headings/2` und
  `parse_chronik_card_parts/2` sind public (Tests + Edit-Form + Render).
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Hub.InputCaps
  alias HubWeb.CampaignLive.Publisher
  alias Shared.Events

  # ─── Resümee (Issue #3) ─────────────────────────────────────────

  def summary_edit_start(socket, sid) do
    current =
      Enum.find_value(socket.assigns.summaries, "", fn s ->
        if s["session_id"] == sid, do: s["content_md"], else: nil
      end)

    {:noreply, assign(socket, summary_editing: sid, summary_draft: current || "")}
  end

  def summary_edit_cancel(socket),
    do: {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}

  def summary_edit_save(socket, content_md) do
    cond do
      not socket.assigns.can_edit_meta? or is_nil(socket.assigns.summary_editing) ->
        {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}

      true ->
        case InputCaps.check(:summary_body, content_md) do
          :ok ->
            Publisher.publish(socket, %{
              "kind" => Events.session_summary_edited(),
              "session_id" => socket.assigns.summary_editing,
              "campaign_id" => socket.assigns.campaign_id,
              "new_md" => content_md,
              "edited_by" => socket.assigns.current_user.discord_id
            })

            {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}

          {:error, {:too_long, cap}} ->
            # Issue #636: Draft im Editor lassen — User kürzt und speichert erneut.
            {:noreply, put_flash(socket, :error, InputCaps.error_message(:summary_body, cap))}
        end
    end
  end

  # ─── Vokabular-Hinweis (Issue #313) ─────────────────────────────

  def vocab_edit_start(socket) do
    hint = (socket.assigns.campaign || %{})["vocab_hint"] || ""
    {:noreply, assign(socket, vocab_editing: true, vocab_draft: hint)}
  end

  # Issue #270: schließt auch das Akkordeon-Tab.
  def vocab_edit_cancel(socket),
    do: {:noreply, assign(socket, vocab_editing: false, vocab_draft: "", open_tab: nil)}

  def vocab_edit_save(socket, text) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :edit_vocab, campaign) do
      # Issue #613: Publisher.publish/2 statt rohem EventBridge.publish — bei
      # :no_worker_online Flash statt stillem Datenverlust (Hint nicht
      # persistiert, UI signalisiert aber "gespeichert").
      Publisher.publish(socket, %{
        "kind" => Events.campaign_vocab_updated(),
        "campaign_id" => socket.assigns.campaign_id,
        "vocab_hint" => String.slice(text, 0, 2000),
        "by_discord_id" => user.discord_id
      })

      # Issue #270: nach erfolgreichem Save schließt das Akkordeon-Tab.
      {:noreply, assign(socket, vocab_editing: false, vocab_draft: "", open_tab: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # ─── Kampagnen-Kalender (Issue #724 Slice F2) ───────────────────

  # Monats-Textarea („Name Tage" pro Zeile) + Epoche → CampaignCalendarSet.
  # Der Worker validiert/normalisiert via Calendar.from_json (kaputt → Default).
  def calendar_edit_save(socket, epoch, months_text) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :edit_calendar, campaign) do
      publish_calendar(socket, user, parse_months(months_text), epoch)
      {:noreply, assign(socket, open_tab: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # „Gregorianisch": leere Monatsliste → der Worker fällt auf Calendar.default/0.
  def calendar_reset(socket) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :edit_calendar, campaign) do
      publish_calendar(socket, user, [], "")
      {:noreply, assign(socket, open_tab: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  defp publish_calendar(socket, user, months, epoch) do
    Publisher.publish(socket, %{
      "kind" => Events.campaign_calendar_set(),
      "campaign_id" => socket.assigns.campaign_id,
      "calendar" => %{"months" => months, "epoch_label" => String.slice(epoch || "", 0, 40)},
      "set_by" => user.discord_id
    })
  end

  defp parse_months(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_month_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(24)
  end

  defp parse_months(_), do: []

  # „Januar 31" → %{"name" => "Januar", "days" => 31}. Tag 1..100, sonst raus.
  defp parse_month_line(line) do
    case Regex.run(~r/^\s*(.+?)\s+(\d+)\s*$/u, line) do
      [_, name, days] ->
        d = String.to_integer(days)
        if d > 0 and d <= 100, do: %{"name" => String.trim(name), "days" => d}, else: nil

      _ ->
        nil
    end
  end

  @doc "Monatsliste (aus dem Snapshot-Kalender) als Textarea-Text (Name Tage pro Zeile)."
  def calendar_to_text(%{"months" => months}) when is_list(months) do
    months
    |> Enum.map(fn
      %{"name" => n, "days" => d} -> "#{n} #{d}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def calendar_to_text(_), do: ""

  # ─── Session-In-Game-Datum-Anker (Issue #724 Slice F) ───────────

  def session_date_edit_start(socket, sid),
    do: {:noreply, assign(socket, session_date_editing: sid)}

  def session_date_edit_cancel(socket),
    do: {:noreply, assign(socket, session_date_editing: nil)}

  # Roh-String → SessionInGameAnchorSet; der Worker löst ihn deterministisch
  # gegen den Campaign-Kalender auf (Slice C). Leerer String = Anker löschen.
  def session_date_edit_save(socket, sid, raw) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :set_session_date, campaign) do
      Publisher.publish(socket, %{
        "kind" => Events.session_in_game_anchor_set(),
        "session_id" => sid,
        "campaign_id" => socket.assigns.campaign_id,
        "in_game_date_raw" => String.slice(raw || "", 0, 200),
        "set_by" => user.discord_id
      })

      {:noreply, assign(socket, session_date_editing: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # ─── Review-Queue-Fakt-Korrektur (Issue #724 Slice F) ───────────

  def fact_date_edit_start(socket, sid, fid),
    do: {:noreply, assign(socket, fact_date_editing: {sid, fid})}

  def fact_date_edit_cancel(socket),
    do: {:noreply, assign(socket, fact_date_editing: nil)}

  # `extraction_event_id` kommt aus der Review-Fakt-Serialisierung (hidden
  # Form-Feld, s. heex) — der Read-Merge im Worker wendet den Override nur an,
  # wenn diese Generation zur AKTUELL gespeicherten session_facts-Row passt
  # (Design-Fix gegen Cross-Contamination nach einem Regenerate: Fakt-IDs sind
  # rein positional, nicht run-eindeutig).
  def fact_date_edit_save(socket, sid, fid, extraction_event_id, raw) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :set_fact_date, campaign) do
      Publisher.publish(socket, %{
        "kind" => Events.session_fact_date_set(),
        "session_id" => sid,
        "campaign_id" => socket.assigns.campaign_id,
        "fact_id" => fid,
        "extraction_event_id" => extraction_event_id,
        "in_game_date_raw" => String.slice(raw || "", 0, 200),
        "set_by" => user.discord_id
      })

      {:noreply, assign(socket, fact_date_editing: nil)}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  def fact_dismiss(socket, sid, fid, extraction_event_id) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :set_fact_date, campaign) do
      Publisher.publish(socket, %{
        "kind" => Events.session_fact_date_set(),
        "session_id" => sid,
        "campaign_id" => socket.assigns.campaign_id,
        "fact_id" => fid,
        "extraction_event_id" => extraction_event_id,
        "in_game_date_raw" => "",
        "dismissed" => true,
        "set_by" => user.discord_id
      })

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # ─── Offene Fäden / Handlungsbögen (Issue #836, Slice D2) ───────
  #
  # Member-Kuration (nicht GM-only, s. Permissions :curate_threads). Alle Aktionen
  # publishen ein `ThreadOverrideSet` mit dem ORIGINAL-Label (`key_canonical` aus
  # dem Panel) — Overrides sind darauf geschlüsselt, nicht auf einem umbenannten
  # Anzeige-Label. Overlay am Worker-Read, kein Fakt-Rewrite.

  def thread_curate_edit_start(socket, canonical, mode) when mode in ["rename", "merge"] do
    {:noreply, assign(socket, thread_curate_editing: {canonical, mode})}
  end

  def thread_curate_edit_cancel(socket),
    do: {:noreply, assign(socket, thread_curate_editing: nil)}

  # Die vier Ein-Klick-Aktionen (resolve/dismiss/reactivate/clear_identity) über
  # EINEN Handler — hält die CampaignLive-handle_event-Fläche schmal (#544-Limit).
  @curate_actions ~w(resolve dismiss reactivate clear_identity)
  def thread_curate(socket, canonical, action) when action in @curate_actions,
    do: publish_thread_override(socket, canonical, action)

  def thread_curate(socket, _canonical, _action),
    do: {:noreply, put_flash(socket, :error, "Unbekannte Aktion")}

  def thread_rename_save(socket, canonical, new_name) do
    name = new_name |> to_string() |> String.slice(0, 120) |> String.trim()

    if name == "" do
      {:noreply, put_flash(socket, :error, "Kein Name angegeben")}
    else
      publish_thread_override(socket, canonical, "rename", %{"new_name" => name},
        reset_edit: true
      )
    end
  end

  def thread_merge_save(socket, canonical, merge_into) do
    target = to_string(merge_into)

    cond do
      target == "" ->
        {:noreply, put_flash(socket, :error, "Kein Ziel-Strang gewählt")}

      target == canonical ->
        {:noreply,
         put_flash(socket, :error, "Ein Strang kann nicht mit sich selbst zusammengeführt werden")}

      true ->
        publish_thread_override(socket, canonical, "merge", %{"merge_into" => target},
          reset_edit: true
        )
    end
  end

  defp publish_thread_override(socket, canonical, action, extra \\ %{}, opts \\ []) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    if HubWeb.Permissions.can?(user, :curate_threads, campaign) do
      Publisher.publish(
        socket,
        Map.merge(
          %{
            "kind" => Events.thread_override_set(),
            "campaign_id" => socket.assigns.campaign_id,
            "canonical" => canonical,
            "action" => action,
            "set_by" => user.discord_id
          },
          extra
        )
      )

      socket =
        if Keyword.get(opts, :reset_edit, false),
          do: assign(socket, thread_curate_editing: nil),
          else: socket

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Keine Berechtigung")}
    end
  end

  # ─── Event-Dispatch der Präfix-Familien (God-Module-Grenze #544) ─
  #
  # CampaignLive routet "thread_*"/"luecke_*"-Events als EINE Klausel hierher;
  # das Param-Matching lebt bei den Implementierungen. Unbekannte Event-Namen
  # (Tippfehler im HEEx) → sichtbarer Flash statt FunctionClauseError.

  def thread_event("thread_curate", %{"canonical" => c, "action" => a}, socket),
    do: thread_curate(socket, c, a)

  def thread_event("thread_curate_edit_start", %{"canonical" => c, "mode" => m}, socket),
    do: thread_curate_edit_start(socket, c, m)

  def thread_event("thread_curate_edit_cancel", _params, socket),
    do: thread_curate_edit_cancel(socket)

  def thread_event("thread_rename_save", %{"canonical" => c, "new_name" => n}, socket),
    do: thread_rename_save(socket, c, n)

  def thread_event("thread_merge_save", %{"canonical" => c, "merge_into" => t}, socket),
    do: thread_merge_save(socket, c, t)

  def thread_event(_ev, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Unbekannte Aktion")}

  # bestaetigt (Vorschlag übernehmen) / original_bestaetigt (Rohtext gilt) /
  # unbrauchbar kommen als Ein-Klick mit hidden text-Param aus der
  # Serialisierung (K3: exakt der gesehene Text, keine Hub-Ableitung).
  def luecke_event(
        "luecke_curate",
        %{"session_id" => sid, "block_id" => bid, "status" => st, "text" => text},
        socket
      ),
      do: luecke_curate(socket, sid, bid, st, text)

  # Review-Wunsch 2026-07-16: aus dem Lücken-Panel zur Stelle im Protokoll
  # scrollen — derselbe Sprung wie der Refs-Popover-Jump (#709), additiv
  # (Ziel-Session aufklappen, andere offen lassen).
  def luecke_event("luecke_goto", %{"utt" => uid}, socket),
    do: HubWeb.CampaignLive.Refs.focus_utterance(socket, uid)

  def luecke_event("luecke_edit_start", %{"session_id" => sid, "block_id" => bid}, socket),
    do: luecke_edit_start(socket, sid, bid)

  def luecke_event("luecke_edit_cancel", _params, socket),
    do: luecke_edit_cancel(socket)

  def luecke_event(
        "luecke_edit_save",
        %{"session_id" => sid, "block_id" => bid, "text" => text},
        socket
      ),
      do: luecke_curate(socket, sid, bid, "manuell_korrigiert", text, reset_edit: true)

  def luecke_event(_ev, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Unbekannte Aktion")}

  # ─── Lücken-Kuration (Issue #865, Epic #861 Slice E) ────────────
  #
  # Member-Recht (E4, wie :curate_threads). Der Override snapshottet den EXAKT
  # bestätigten Text (K3) + die sortierten quell_utterance_ids des Blocks (aus
  # dem Worker-Snapshot) — Re-Attach nach Regelwechsel ist damit reine
  # Read-Zeit-Paarung im Worker.

  @luecken_statuses ~w(bestaetigt manuell_korrigiert original_bestaetigt unbrauchbar)

  def luecke_edit_start(socket, sid, bid),
    do: {:noreply, assign(socket, luecke_editing: {sid, bid})}

  def luecke_edit_cancel(socket),
    do: {:noreply, assign(socket, luecke_editing: nil)}

  def luecke_curate(socket, sid, bid, status, text, opts \\ []) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign
    block = find_luecken_block(socket.assigns.luecken, sid, bid)
    bestaetigter_text = if status == "unbrauchbar", do: nil, else: String.trim(text || "")

    cond do
      not HubWeb.Permissions.can?(user, :curate_luecken, campaign) ->
        {:noreply, put_flash(socket, :error, "Keine Berechtigung")}

      status not in @luecken_statuses ->
        {:noreply, put_flash(socket, :error, "Unbekannter Kurations-Status")}

      block == nil ->
        {:noreply, put_flash(socket, :error, "Block nicht (mehr) im Snapshot")}

      status != "unbrauchbar" and bestaetigter_text == "" ->
        {:noreply, put_flash(socket, :error, "Kein Text zum Bestätigen")}

      true ->
        Publisher.publish(socket, %{
          "kind" => Events.luecken_kuration_set(),
          "session_id" => sid,
          "campaign_id" => socket.assigns.campaign_id,
          "block_id" => bid,
          "status" => status,
          "bestaetigter_text" => bestaetigter_text,
          "quell_utterance_ids" => block["quell_utterance_ids"] || [],
          "set_by" => user.discord_id
        })

        socket =
          if Keyword.get(opts, :reset_edit, false),
            do: assign(socket, luecke_editing: nil),
            else: socket

        {:noreply, socket}
    end
  end

  defp find_luecken_block(luecken, sid, bid) do
    Enum.find_value(luecken, fn entry ->
      if entry["session_id"] == sid,
        do: Enum.find(entry["blocks"], &(&1["block_id"] == bid)),
        else: nil
    end)
  end

  # ─── Chronik (Issue #385) ───────────────────────────────────────

  def chronik_edit_start(socket, id) do
    entry = Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end) || %{}
    # Issue #385: Edit-Draft ist ein einziger Markdown-String.
    draft = chronik_entry_to_markdown(entry)
    {:noreply, assign(socket, chronik_editing: id, chronik_draft: draft)}
  end

  def chronik_edit_cancel(socket),
    do: {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}

  def chronik_edit_save(socket, attrs) do
    id = socket.assigns.chronik_editing
    existing = Enum.find(socket.assigns.chronik, fn e -> e["id"] == id end)
    md = attrs["markdown_body"] || ""

    cond do
      not socket.assigns.can_edit_meta? or not is_map(existing) ->
        {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}

      true ->
        case InputCaps.check(:chronik_body, md) do
          :ok ->
            {date, label} = parse_chronik_headings(md, existing)

            Publisher.publish(socket, %{
              "kind" => Events.chronik_entry_changed(),
              "id" => id,
              "campaign_id" => socket.assigns.campaign_id,
              # Issue #385: in_game_date + label aus dem Markdown derived (erste H1/H2).
              # Fehlt eine → alter Wert bleibt (nicht-destruktiv).
              "in_game_date" => date,
              "label" => label,
              # Issue #385: summary NICHT mit Roh-Markdown überschreiben — Plaintext-
              # Vertrag der BC-Spalte wahren.
              "summary" => existing["summary"],
              # Verbatim — kein Roundtrip-Verlust beim Re-Edit.
              "markdown_body" => md,
              "session_id" => existing["session_id"],
              "edited_by" => socket.assigns.current_user.discord_id,
              "source" => "manual"
            })

            {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}

          {:error, {:too_long, cap}} ->
            # Issue #636: Draft behalten — User kürzt und speichert erneut.
            {:noreply, put_flash(socket, :error, InputCaps.error_message(:chronik_body, cap))}
        end
    end
  end

  @doc """
  Issue #385: convertet einen Chronik-Eintrag in seine Markdown-Repräsentation
  für die Edit-Textarea. Konvention: `# in_game_date\\n## label\\n\\nBody`.

  - Vorhandener `markdown_body` wird bevorzugt (verbatim).
  - Sonst aus den drei alten Feldern zusammengesetzt (Lazy-Migration-Start).
  - Leere Felder werden weggelassen.
  """
  @spec chronik_entry_to_markdown(map()) :: String.t()
  def chronik_entry_to_markdown(entry) do
    md = entry["markdown_body"]

    if is_binary(md) and md != "" do
      md
    else
      date = entry["in_game_date"] || ""
      label = entry["label"] || ""
      body = entry["summary"] || ""

      [
        if(date != "", do: "# #{date}", else: nil),
        if(label != "", do: "## #{label}", else: nil),
        if(body != "", do: "\n#{body}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  @doc """
  Issue #385: parsed die ersten H1 + H2 aus dem Edit-Textarea-Markdown
  und liefert das Tupel `{in_game_date, label}` zurück. Beide sind
  unabhängig parsbar (verschiedene Heading-Levels) — kein Mehrdeutigkeits-
  Risiko wie bei einem `: `-Delimiter.

  - Erste line-anchored H1 (`# Text`) → in_game_date
  - Erste line-anchored H2 (`## Text`) → label
  - Fehlt eine → alter Wert aus `existing` (nicht-destruktiv)
  """
  @spec parse_chronik_headings(String.t(), map()) :: {String.t() | nil, String.t() | nil}
  def parse_chronik_headings(md, existing) when is_binary(md) and is_map(existing) do
    date =
      case Regex.run(~r/^#\s+([^\n]+)/m, md) do
        [_, text] -> String.trim(text)
        _ -> existing["in_game_date"]
      end

    label =
      case Regex.run(~r/^##\s+([^\n]+)/m, md) do
        [_, text] -> String.trim(text)
        _ -> existing["label"]
      end

    {date, label}
  end

  @doc """
  Issue #440: zerlegt einen `markdown_body` in `{date, label, body}` für den
  Karten-Stil-Render in der Chronik-Spalte. Spiegelt die H1/H2-Konvention
  von `chronik_entry_to_markdown/1` (Edit-Form-Verträge), so dass editierte
  Einträge optisch identisch zu unbearbeiteten gerendert werden können —
  Datum als cyan-Mono-Header, Titel als bold-Subtitle, Rest als gerendertes
  Markdown.

  - `date` und `label` kommen aus `parse_chronik_headings/2` (gleiche Quelle,
    gleiche Fallbacks auf `existing`).
  - `body` ist `md` ohne die *erste* line-anchored H1 und die *erste*
    line-anchored H2 — getrimmt. Spätere H1/H2 im User-Markdown bleiben
    unangetastet und rendern normal im Body.
  """
  @spec parse_chronik_card_parts(String.t(), map()) ::
          {String.t() | nil, String.t() | nil, String.t()}
  def parse_chronik_card_parts(md, existing) when is_binary(md) and is_map(existing) do
    {date, label} = parse_chronik_headings(md, existing)

    body =
      md
      |> String.replace(~r/^#\s+[^\n]*\n?/m, "", global: false)
      |> String.replace(~r/^##\s+[^\n]*\n?/m, "", global: false)
      |> String.trim()

    {date, label, body}
  end

  # ─── Epos (Issue #3) ────────────────────────────────────────────

  # Issue #359: Epos-Edit ist GM-only (:edit_epos in der Permissions-Rules-Table),
  # nicht member-weit. Vorher gateten beide Handler auf `is_member?` — der
  # UI-Button ist zwar GM-only (can_edit?={@can_edit_meta?}), aber ein Spieler-
  # Member konnte das kampagnenweite Epos via gecraftetem phx-click trotzdem
  # editieren. Server-seitig gegen die korrekte Action prüfen ("never trust the
  # client").
  def epos_edit_start(socket) do
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :edit_epos, socket.assigns.campaign) do
      current = (socket.assigns.epos && socket.assigns.epos["content_md"]) || ""
      {:noreply, assign(socket, epos_mode: :edit, epos_draft: current)}
    else
      {:noreply, socket}
    end
  end

  def epos_edit_cancel(socket), do: {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}

  def epos_edit_save(socket, content_md) do
    cond do
      not HubWeb.Permissions.can?(
        socket.assigns.perm_user,
        :edit_epos,
        socket.assigns.campaign
      ) ->
        {:noreply,
         socket
         |> put_flash(:error, "Keine Berechtigung")
         |> assign(epos_mode: :view, epos_draft: "")}

      true ->
        case InputCaps.check(:epos_body, content_md) do
          :ok ->
            Publisher.publish(socket, %{
              "kind" => Events.epos_entry_edited(),
              "entry_id" => socket.assigns.campaign_id,
              "campaign_id" => socket.assigns.campaign_id,
              "new_md" => content_md,
              "edited_by" => socket.assigns.current_user.discord_id,
              "source" => "manual"
            })

            {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}

          {:error, {:too_long, cap}} ->
            # Issue #636: Edit-Mode + Draft behalten — User kürzt und speichert erneut.
            {:noreply, put_flash(socket, :error, InputCaps.error_message(:epos_body, cap))}
        end
    end
  end

  def epos_diff_open(socket, seq_str) do
    seq = String.to_integer(seq_str)
    {:noreply, assign(socket, epos_mode: :diff, epos_diff_seq: seq)}
  end

  def epos_diff_close(socket),
    do: {:noreply, assign(socket, epos_mode: :view, epos_diff_seq: nil)}

  # ─── Issue #753: per-Kapitel-Edit (Ep_n, entry_id = session_id) ────────
  # Gleiche Permission-Achse wie das Legacy-Buch (:edit_epos, server-seitig
  # geprüft — never trust the client). Der Save publisht EposEntryEdited mit
  # source "manual" — die History-Row ist zugleich der persistente Marker für
  # den Pipeline-LWW-Guard (Re-Run überschreibt GM-editierte Kapitel nicht).

  def chapter_edit_start(socket, entry_id) do
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :edit_epos, socket.assigns.campaign) do
      chapter = Enum.find(socket.assigns.epos_chapters, &(&1["id"] == entry_id))

      {:noreply,
       assign(socket,
         chapter_edit_id: entry_id,
         chapter_draft: (chapter && chapter["content_md"]) || ""
       )}
    else
      {:noreply, socket}
    end
  end

  def chapter_edit_cancel(socket),
    do: {:noreply, assign(socket, chapter_edit_id: nil, chapter_draft: "")}

  def chapter_edit_save(socket, entry_id, content_md) do
    can? = HubWeb.Permissions.can?(socket.assigns.perm_user, :edit_epos, socket.assigns.campaign)
    # Nur existierende Kapitel-Rows editierbar — ein gecraftetes entry_id würde
    # sonst eine neue Row anlegen.
    known? = Enum.any?(socket.assigns.epos_chapters, &(&1["id"] == entry_id))

    cond do
      not (can? and known?) ->
        {:noreply,
         socket
         |> put_flash(:error, "Keine Berechtigung")
         |> assign(chapter_edit_id: nil, chapter_draft: "")}

      true ->
        case InputCaps.check(:chapter_body, content_md) do
          :ok ->
            Publisher.publish(socket, %{
              "kind" => Events.epos_entry_edited(),
              "entry_id" => entry_id,
              "campaign_id" => socket.assigns.campaign_id,
              # parent_id MUSS mit — der Fold schreibt payload["parent_id"] in die
              # Row; ohne verlöre das Kapitel seinen Kapitel-Marker (#752-Datenmodell)
              # und fiele aus list_epos_chapters heraus.
              "parent_id" => socket.assigns.campaign_id,
              "new_md" => content_md,
              "edited_by" => socket.assigns.current_user.discord_id,
              "source" => "manual"
            })

            {:noreply, assign(socket, chapter_edit_id: nil, chapter_draft: "")}

          {:error, {:too_long, cap}} ->
            # Issue #636: Draft behalten — User kürzt und speichert erneut.
            {:noreply, put_flash(socket, :error, InputCaps.error_message(:chapter_body, cap))}
        end
    end
  end
end
