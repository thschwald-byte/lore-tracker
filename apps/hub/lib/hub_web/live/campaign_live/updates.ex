defmodule HubWeb.CampaignLive.Updates do
  @moduledoc """
  Issue #442 (Stage 1): scoped/targeted In-Place-Updates der CampaignLive.

  Für Events, deren PubSub-Payload die Änderung **vollständig** beschreibt,
  aktualisieren wir nur die betroffenen Assigns — **ohne** Voll-Campaign-Snapshot
  vom Worker (der ist der 2–3 s-Flaschenhals: er liest alle Utterances aller
  Sessions neu). Analog zum bereits inkrementellen `UtteranceAppended`-Pfad.

  Pure socket-Transforms, laufen im LiveView-Prozess. Nach Member-Änderungen
  werden die Permission-Assigns über `HubWeb.CampaignLive.derive_assigns/2`
  **identisch zum Voll-Reload** neu abgeleitet → kein Perm-Drift.

  Diese vier Events sind payload-exakt (die Materialisierung tut nichts darüber
  hinaus), daher kein Reconcile-Reload nötig:
  MemberRolePromoted, MemberRemoved (Nicht-Selbst), CampaignAliasSet,
  SpeakerAssigned. Selbst-Removal + alle übrigen Bulk-Events bleiben auf dem
  Voll-Reload-Pfad (siehe `HubWeb.CampaignLive`).

  Member-Maps sind string-keyed (Snapshot-Konvention; `derive_assigns/2` +
  `last_spielleiter?/2` lesen `m["role"]`).
  """
  import Phoenix.Component, only: [assign: 3]

  alias HubWeb.CampaignLive
  alias HubWeb.CampaignLive.{Components, Refs}

  @doc "MemberRolePromoted: Rolle eines Members setzen (#140) + Perms neu ableiten."
  def apply_member_role(socket, %{"discord_id" => did, "new_role" => role}) do
    members =
      Enum.map(socket.assigns.members, fn m ->
        if m["discord_id"] == did, do: Map.put(m, "role", role), else: m
      end)

    assign_members_and_perms(socket, members)
  end

  @doc "MemberRemoved (Nicht-Selbst): Member aus der Liste entfernen (#55) + Perms."
  def apply_member_removed(socket, %{"discord_id" => did}) do
    members = Enum.reject(socket.assigns.members, fn m -> m["discord_id"] == did end)
    assign_members_and_perms(socket, members)
  end

  @doc "CampaignAliasSet: Charaktername setzen/löschen (#2). character_name \"\"/nil = löschen."
  def apply_alias(socket, %{"discord_id" => did, "character_name" => name}) do
    names =
      if is_binary(name) and name != "",
        do: Map.put(socket.assigns.character_names, did, name),
        else: Map.delete(socket.assigns.character_names, did)

    members =
      Enum.map(socket.assigns.members, fn m ->
        if m["discord_id"] == did, do: Map.put(m, "character_name", name), else: m
      end)

    socket
    |> assign(:character_names, names)
    |> assign(:members, members)
  end

  @doc "SpeakerAssigned: Pseudo-Label → Member-discord_id (#19). \"\" = Zuordnung aufheben."
  def apply_speaker(socket, %{"speaker_label" => label, "discord_id" => did}) do
    assignments =
      if is_binary(did) and did != "",
        do: Map.put(socket.assigns.speaker_assignments, label, did),
        else: Map.delete(socket.assigns.speaker_assignments, label)

    assign(socket, :speaker_assignments, assignments)
  end

  # ─── Issue #442 Stage 2: Tier-2 scoped Reloads ──────────────────────────
  #
  # Diese Events beschreiben ihre Änderung NICHT payload-vollständig (z.B. ein
  # ChronikEntryChanged führt zu einem materialisierten Eintrag mit derived
  # Feldern, ein SessionSummaryEdited zu Faithfulness-Neuberechnung). Statt
  # eines Voll-Snapshots holen wir nur den betroffenen Bereich vom Worker
  # (schmaler Read) und mergen genau die betroffenen Assigns.

  @doc """
  Mappt einen Event-`kind` auf den schmalen Worker-Scope, der ihn abdeckt —
  oder `nil`, wenn der Event keinen Tier-2-Scope hat (→ Voll-Reload-Pfad).
  """
  @spec scope_for_event(String.t()) :: String.t() | nil
  def scope_for_event("SessionSummaryGenerated"), do: "campaign_summaries"
  def scope_for_event("SessionSummaryEdited"), do: "campaign_summaries"
  def scope_for_event("ChronikEntryChanged"), do: "campaign_chronik"
  def scope_for_event("EposEntryEdited"), do: "campaign_epos"
  def scope_for_event("CampaignFlavorSet"), do: "campaign_meta"
  def scope_for_event("CampaignVorgabeSet"), do: "campaign_meta"
  def scope_for_event("CampaignVocabUpdated"), do: "campaign_meta"
  def scope_for_event(_), do: nil

  @doc """
  Merged einen scoped Worker-Read in die betroffenen Assigns. `snap` ist die
  schmale Worker-Antwort (bereits ohne error/forbidden — das prüft der Aufrufer
  im handle_async und fällt sonst auf Voll-Reload zurück).

  KRITISCH: summaries/chronik/epos speisen die Sync-/Refs-Indizes — nach jedem
  dieser Scopes werden beide Indizes aus der geänderten Dimension + den
  unveränderten Dimensionen aus `socket.assigns` neu gebaut (sonst bricht
  Autoscroll). `campaign_meta` fasst die Indizes NICHT an.
  """
  def apply_scope(socket, "campaign_summaries", snap) do
    socket
    |> assign(:summaries, snap["summaries"] || [])
    |> assign(:faithfulness_by_session, Components.faithfulness_index(snap["faithfulness"] || []))
    |> rebuild_refs()
  end

  def apply_scope(socket, "campaign_chronik", snap) do
    socket
    |> assign(:chronik, snap["chronik"] || [])
    |> rebuild_refs()
  end

  def apply_scope(socket, "campaign_epos", snap) do
    socket
    |> assign(:epos, snap["epos"])
    |> assign(:epos_history, snap["epos_history"] || [])
    |> rebuild_refs()
  end

  def apply_scope(socket, "campaign_meta", snap) do
    # derive_assigns macht `c = snap["campaign"]` ohne Transformation → direkt
    # assignen ist byte-identisch zum Voll-Reload. Kein Index-Rebuild (Meta
    # speist die Sync-/Refs-Indizes nicht).
    case snap["campaign"] do
      nil -> socket
      c -> socket |> assign(:campaign, c) |> assign(:current_campaign, c)
    end
  end

  # Sync-/Refs-Indizes aus der aktuellen Assign-Oberfläche neu bauen (identisch
  # zu apply_snapshot/2). Geänderte Dimension steht schon im Socket, die übrigen
  # werden unverändert mitgelesen.
  defp rebuild_refs(socket) do
    summaries = socket.assigns.summaries
    epos = socket.assigns.epos
    chronik = socket.assigns.chronik
    utterances = socket.assigns.utterances

    socket
    |> assign(:utterance_refs_index, Refs.build_utterance_refs_index(summaries, epos, chronik))
    |> assign(
      :sync_index_json,
      Jason.encode!(Refs.build_sync_index(summaries, epos, chronik, utterances))
    )
  end

  # Perms exakt wie der Voll-Reload neu ableiten — Quelle der Wahrheit ist
  # `derive_assigns/2`, kein Hand-Nachbau (kein Drift). Setzt genau die Subset-
  # Assigns, die `apply_snapshot/2` aus `derived` setzt.
  defp assign_members_and_perms(socket, members) do
    derived =
      CampaignLive.derive_assigns(
        %{
          "campaign" => socket.assigns.campaign,
          "members" => members,
          # viewer_role ist die GLOBALE Rolle (Atom) — als String durchreichen,
          # derive_assigns parsed sie via parse_viewer_role zurück.
          "viewer_role" => to_string(socket.assigns.viewer_role)
        },
        socket.assigns.current_user.discord_id
      )

    socket
    |> assign(:members, members)
    |> assign(:viewer_role, derived.role)
    |> assign(:perm_user, derived.perm_user)
    |> assign(:owner?, derived.owner?)
    |> assign(:is_member?, derived.is_member?)
    |> assign(:can_edit_meta?, derived.can_edit_meta?)
    |> assign(:can_regenerate_session?, derived.can_regenerate_session?)
    |> assign(:can_regenerate_campaign?, derived.can_regenerate_campaign?)
    |> assign(:can_assign_speaker?, derived.can_assign_speaker?)
  end
end
