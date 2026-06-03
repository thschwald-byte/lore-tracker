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
