defmodule HubWeb.CampaignLive.Speakers do
  @moduledoc """
  Sprecher-Zuordnung der CampaignLive (Issue #19, ausgelagert in #434 Cut 4):
  Diarisierungs-Pseudo-Sprecher einem Kampagnen-Mitglied zuordnen / aufheben.

  Dazu die Anzeige-Helfer des Protokolls (`pseudo_speaker?/1`,
  `unassigned_speaker_count/2`, `speaker_display/4`) — seit #1200 hier statt in
  `campaign_live.ex` (God-Module-Budget); die CampaignLive importiert sie, das
  Template ruft sie unqualifiziert auf.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 3]

  alias HubWeb.CampaignLive.{Components, Core, Publisher}
  alias Shared.Events

  def pick_start(socket, label, sid) do
    if HubWeb.Permissions.can?(
         socket.assigns.perm_user,
         :assign_speaker,
         Core.perm_campaign(socket)
       ) do
      {:noreply, assign(socket, :speaker_pick, %{label: label, session_id: sid})}
    else
      {:noreply, socket}
    end
  end

  def pick_cancel(socket), do: {:noreply, assign(socket, :speaker_pick, nil)}

  def assign_speaker(socket, label, sid, did) do
    if HubWeb.Permissions.can?(
         socket.assigns.perm_user,
         :assign_speaker,
         Core.perm_campaign(socket)
       ) do
      Publisher.publish(socket, %{
        "kind" => Events.speaker_assigned(),
        "campaign_id" => socket.assigns.campaign_id,
        "session_id" => sid,
        "speaker_label" => label,
        "discord_id" => did,
        "assigned_by" => socket.assigns.current_user.discord_id
      })

      {:noreply, assign(socket, :speaker_pick, nil)}
    else
      {:noreply, socket}
    end
  end

  # discord_id leer → Zuordnung aufheben.
  def unassign(socket, label, sid) do
    if HubWeb.Permissions.can?(
         socket.assigns.perm_user,
         :assign_speaker,
         Core.perm_campaign(socket)
       ) do
      Publisher.publish(socket, %{
        "kind" => Events.speaker_assigned(),
        "campaign_id" => socket.assigns.campaign_id,
        "session_id" => sid,
        "speaker_label" => label,
        "discord_id" => "",
        "assigned_by" => socket.assigns.current_user.discord_id
      })

      {:noreply, assign(socket, :speaker_pick, nil)}
    else
      {:noreply, socket}
    end
  end

  # ─── Anzeige-Helfer fürs Protokoll-Template ─────────────────────

  @doc """
  True, wenn die discord_id ein Diarisierungs-Pseudo-Label ist
  (`speaker:<session_id>:<n>`), kein echter User.
  """
  def pseudo_speaker?(did) when is_binary(did), do: String.starts_with?(did, "speaker:")
  def pseudo_speaker?(_), do: false

  @doc """
  Anzahl distinkter Pseudo-Sprecher in einer Utterance-Gruppe (= Session), die
  noch keinem echten Mitglied zugeordnet sind. Treibt das Header-Badge.
  """
  def unassigned_speaker_count(group, assignments) do
    group
    |> Enum.map(& &1["discord_id"])
    |> Enum.filter(&pseudo_speaker?/1)
    |> Enum.uniq()
    |> Enum.count(fn label ->
      case Map.get(assignments, label) do
        did when is_binary(did) and did != "" -> false
        _ -> true
      end
    end)
  end

  @doc """
  Auflösung eines Utterance-Sprechers für die Anzeige. Pseudo-Labels werden über
  die Zuordnungs-Map zu echten Namen aufgelöst, sonst „Sprecher N".
  """
  def speaker_display(did, assignments, users, char_names) do
    if pseudo_speaker?(did) do
      case Map.get(assignments, did) do
        real when is_binary(real) and real != "" ->
          Components.display_for(real, users, char_names)

        _ ->
          Components.pseudo_speaker_label(did)
      end
    else
      Components.display_for(did, users, char_names)
    end
  end
end
