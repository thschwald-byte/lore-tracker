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
  alias HubWeb.CampaignLive.Refs

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

  # ─── Issue #442 Final Cut: payload-exakte Tier-1 In-Place (Invites/Sessions) ──
  #
  # InviteCreated/Revoked + SessionScheduled tragen ihre Änderung vollständig im
  # Payload (bzw. die angezeigten Felder) → in-place ohne Worker-Roundtrip UND
  # ohne Reconcile-Reload. Dedup-Guard gegen PubSub-Re-Delivery (kein
  # Doppel-Append). Shapes string-keyed = Snapshot-Konvention.

  @doc """
  Dispatch der payload-exakten Tier-1-In-Place-Events (vom `kind`-Routing in
  `HubWeb.CampaignLive`). Literal-Match auf den `kind`-ARG (nicht `"kind" =>`
  im Map-Pattern) → kein hardcoded-event-kind-Audit-Treffer.
  """
  def apply_inplace(socket, "InviteCreated", payload), do: apply_invite_created(socket, payload)
  def apply_inplace(socket, "InviteRevoked", payload), do: apply_invite_revoked(socket, payload)

  def apply_inplace(socket, "SessionScheduled", payload),
    do: apply_session_scheduled(socket, payload)

  @doc "InviteCreated: aktiven Invite anhängen (#442). created_at (= Event-ts) wird im Template nicht gezeigt → nil ok."
  def apply_invite_created(socket, %{"token" => token} = payload) do
    if Enum.any?(socket.assigns.invites, &(&1["token"] == token)) do
      socket
    else
      invite = %{
        "token" => token,
        "campaign_id" => payload["campaign_id"],
        "created_by_discord_id" => payload["created_by_discord_id"],
        "created_at" => nil,
        "expires_at" => payload["expires_at"],
        "status" => "active",
        "redeemed_by_discord_id" => nil
      }

      assign(socket, :invites, socket.assigns.invites ++ [invite])
    end
  end

  @doc "InviteRevoked: Invite per token auf status=revoked (#442). Template filtert status==active → fällt raus."
  def apply_invite_revoked(socket, %{"token" => token}) do
    invites =
      Enum.map(socket.assigns.invites, fn inv ->
        if inv["token"] == token, do: Map.put(inv, "status", "revoked"), else: inv
      end)

    assign(socket, :invites, invites)
  end

  @doc "SessionScheduled: geplante Session anhängen (#442). Payload-vollständig (id/number/name/scheduled_for)."
  def apply_session_scheduled(socket, %{"id" => id} = payload) do
    if Enum.any?(socket.assigns.sessions, &(&1["id"] == id)) do
      socket
    else
      session = %{
        "id" => id,
        "campaign_id" => payload["campaign_id"],
        "number" => payload["number"],
        "name" => payload["name"],
        "status" => "scheduled",
        "scheduled_for" => payload["scheduled_for"],
        "started_at" => nil,
        "ended_at" => nil
      }

      assign(socket, :sessions, socket.assigns.sessions ++ [session])
    end
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
  # Issue #442 Final Cut: CampaignUpdated (Name/Vorgaben-Änderungen) ist eine
  # reine Campaign-Feld-Änderung → derselbe schmale campaign_meta-Scope wie
  # Flavor/Vorgabe/Vocab statt Voll-Snapshot.
  def scope_for_event("CampaignUpdated"), do: "campaign_meta"
  # Issue #442: Member-ADD / globale User-Änderungen — der Event-Payload trägt
  # NICHT die volle Member-Daten (Display-Name/Avatar/Rolle), daher scoped Read
  # statt targeted-apply (anders als MemberRolePromoted/MemberRemoved, die
  # payload-exakt sind und in-place laufen).
  def scope_for_event("InviteRedeemed"), do: "campaign_members"
  def scope_for_event("AdminMemberAdded"), do: "campaign_members"
  def scope_for_event("UserUpserted"), do: "campaign_members"
  def scope_for_event("UserRoleSet"), do: "campaign_members"
  # Issue #724 Slice F: Review-Queue-Fakt-Korrektur — schmaler Scope statt
  # Voll-Reload (Muster campaign_chronik).
  def scope_for_event("SessionFactDateSet"), do: "campaign_review_facts"
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

  # Issue #442: Member-Liste neu + ALLE Viewer-Permission-Assigns über denselben
  # Helper wie die targeted Member-Updates (assign_members_and_perms →
  # derive_assigns) neu ableiten. Der Viewer könnte selbst betroffen sein (eigene
  # Rolle/Membership) — die Re-Derivation läuft über Permissions.can?/3 (eine
  # Stelle, #464), kein Hand-Nachbau → kein Privilege-Escalation-Drift. Snap ohne
  # members (Worker-Fehler) → unverändert; forbidden/error fängt handle_async ab.
  def apply_scope(socket, "campaign_members", %{"members" => members}) when is_list(members) do
    assign_members_and_perms(socket, members)
  end

  def apply_scope(socket, "campaign_members", _snap), do: socket

  # Issue #724 Slice F: Review-Facts speisen keine Sync-/Refs-Indizes — kein
  # rebuild_refs nötig (anders als summaries/chronik/epos oben).
  def apply_scope(socket, "campaign_review_facts", snap) do
    assign(socket, :review_facts, snap["review_facts"] || [])
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
          # derive_assigns parsed sie via HubWeb.Permissions.parse_role/1 zurück.
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
