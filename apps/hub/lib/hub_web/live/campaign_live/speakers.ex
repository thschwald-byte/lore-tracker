defmodule HubWeb.CampaignLive.Speakers do
  @moduledoc """
  Sprecher-Zuordnung der CampaignLive (Issue #19, ausgelagert in #434 Cut 4):
  Diarisierungs-Pseudo-Sprecher einem Kampagnen-Mitglied zuordnen / aufheben.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 3]

  alias HubWeb.CampaignLive.{Core, Publisher}
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
end
