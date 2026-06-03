defmodule HubWeb.CampaignLive.Meta do
  @moduledoc """
  Kampagnen-/Session-Lebenszyklus der CampaignLive (Issues #15/#294,
  ausgelagert in #434 Cut 4): Kampagne löschen (mit Namens-Bestätigung),
  einzelne Session löschen (Cascade), eigene Worker herunterfahren.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias Hub.Commands
  alias HubWeb.CampaignLive.{Core, Publisher}
  alias Shared.Events

  # ─── Kampagne löschen (Issue #15) ───────────────────────────────

  def delete_request(socket),
    do: {:noreply, assign(socket, delete_confirming?: true, delete_typed_name: "")}

  def delete_cancel(socket),
    do: {:noreply, assign(socket, delete_confirming?: false, delete_typed_name: "")}

  def delete_typing(socket, typed), do: {:noreply, assign(socket, delete_typed_name: typed)}

  def delete_confirm(socket, typed) do
    expected = (socket.assigns.campaign || %{})["name"] || ""

    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply, put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen löschen.")}

      String.trim(typed) != expected ->
        {:noreply,
         put_flash(socket, :error, "Kampagnenname stimmt nicht — Löschung abgebrochen.")}

      true ->
        Publisher.publish(socket, %{
          "kind" => Events.campaign_deleted(),
          "campaign_id" => socket.assigns.campaign_id,
          "deleted_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "Kampagne '#{expected}' gelöscht.")
         |> push_navigate(to: "/")}
    end
  end

  # Issue #294: Einzelne Session unwiderruflich löschen (SessionDeleted-Cascade:
  # Utterances + Marker + Resümee + Faithfulness + Chronik + Speaker-Zuordnungen
  # + Session-Row). Sicherheitsabfrage via `data-confirm` am Button.
  def session_delete(socket, sid) do
    campaign = Core.perm_campaign(socket)

    cond do
      not HubWeb.Permissions.can?(socket.assigns.perm_user, :delete_session, campaign) ->
        {:noreply,
         put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Sessions löschen.")}

      true ->
        Publisher.publish(socket, %{
          "kind" => Events.session_deleted(),
          "session_id" => sid,
          "campaign_id" => campaign.id,
          "deleted_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "Session gelöscht.")
         |> assign(:expanded_sessions, MapSet.delete(socket.assigns.expanded_sessions, sid))}
    end
  end

  def shutdown_worker(socket) do
    if socket.assigns.owner? do
      n = Commands.shutdown_my_workers(socket.assigns.current_user.discord_id)
      {:noreply, put_flash(socket, :info, "Shutdown an #{n} Worker geschickt.")}
    else
      {:noreply, socket}
    end
  end
end
