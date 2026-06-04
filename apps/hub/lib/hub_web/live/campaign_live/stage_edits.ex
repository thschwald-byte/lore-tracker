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

  alias Hub.EventBridge
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
    if socket.assigns.can_edit_meta? and socket.assigns.summary_editing do
      Publisher.publish(socket, %{
        "kind" => Events.session_summary_edited(),
        "session_id" => socket.assigns.summary_editing,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, assign(socket, summary_editing: nil, summary_draft: "")}
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
      EventBridge.publish(%{
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

    if socket.assigns.can_edit_meta? and existing do
      md = attrs["markdown_body"] || ""
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
    end

    {:noreply, assign(socket, chronik_editing: nil, chronik_draft: "")}
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
    if HubWeb.Permissions.can?(socket.assigns.perm_user, :edit_epos, socket.assigns.campaign) do
      Publisher.publish(socket, %{
        "kind" => Events.epos_entry_edited(),
        "entry_id" => socket.assigns.campaign_id,
        "campaign_id" => socket.assigns.campaign_id,
        "new_md" => content_md,
        "edited_by" => socket.assigns.current_user.discord_id,
        "source" => "manual"
      })

      {:noreply, assign(socket, epos_mode: :view, epos_draft: "")}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Keine Berechtigung")
       |> assign(epos_mode: :view, epos_draft: "")}
    end
  end

  def epos_diff_open(socket, seq_str) do
    seq = String.to_integer(seq_str)
    {:noreply, assign(socket, epos_mode: :diff, epos_diff_seq: seq)}
  end

  def epos_diff_close(socket),
    do: {:noreply, assign(socket, epos_mode: :view, epos_diff_seq: nil)}
end
