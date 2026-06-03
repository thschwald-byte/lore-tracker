defmodule HubWeb.CampaignLive.Members do
  @moduledoc """
  Mitspieler-Verwaltung der CampaignLive (Issue #434, Cut 4): Member-Popup,
  Entfernen (#55/#52A), Promote/Demote (#140 Phase B).

  Kontext-Modul mit Delegations-Pattern: jede Funktion nimmt den LiveView-Socket
  und liefert `{:noreply, socket}` zurück, die `handle_event`-Klauseln in
  `HubWeb.CampaignLive` sind dünne Einzeiler. Läuft im LiveView-Prozess —
  `put_flash`/`Publisher.publish` (→ Self-Message) funktionieren wie zuvor.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias HubWeb.CampaignLive.{Components, Publisher}
  alias Shared.Events

  def open_popup(socket, did), do: {:noreply, assign(socket, :member_popup_open_for, did)}
  def close_popup(socket), do: {:noreply, assign(socket, :member_popup_open_for, nil)}

  # ─── Member entfernen (Issue #55 / 52A) ─────────────────────────

  def remove_request(socket, did), do: {:noreply, assign(socket, remove_confirm_did: did)}
  def remove_cancel(socket), do: {:noreply, assign(socket, remove_confirm_did: nil)}

  def remove_confirm(socket, did) do
    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply,
         socket
         |> put_flash(:error, "Nur Spielleiter oder Admin dürfen Mitspieler entfernen.")
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}

      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Der letzte Spielleiter kann nicht entfernt werden. Befördere erst eine andere Mitspielerin."
         )
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}

      true ->
        display =
          Components.display_for(did, socket.assigns.users, socket.assigns.character_names)

        Publisher.publish(socket, %{
          "kind" => Events.member_removed(),
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => did,
          "removed_by" => socket.assigns.current_user.discord_id
        })

        {:noreply,
         socket
         |> put_flash(:info, "#{display} aus der Kampagne entfernt.")
         |> assign(remove_confirm_did: nil, member_popup_open_for: nil)}
    end
  end

  # ─── Promote / Demote (Issue #140 Phase B) ──────────────────────

  def promote(socket, did) do
    socket
    |> assign(:member_popup_open_for, nil)
    |> role_change(did, :spielleiter)
  end

  def demote_request(socket, did), do: {:noreply, assign(socket, demote_confirm_did: did)}
  def demote_cancel(socket), do: {:noreply, assign(socket, demote_confirm_did: nil)}

  def demote_confirm(socket, did) do
    cond do
      last_spielleiter?(socket.assigns.members, did) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Letzter Spielleiter — Demote würde die Kampagne führungslos lassen."
         )
         |> assign(demote_confirm_did: nil, member_popup_open_for: nil)}

      true ->
        socket
        |> assign(demote_confirm_did: nil, member_popup_open_for: nil)
        |> role_change(did, :spieler)
    end
  end

  defp role_change(socket, did, new_role)
       when new_role in [:spielleiter, :spieler] do
    cond do
      not HubWeb.Permissions.can?(
        socket.assigns.perm_user,
        :promote_member,
        socket.assigns.campaign
      ) ->
        {:noreply, put_flash(socket, :error, "Nur Spielleiter oder Admin dürfen Rollen ändern.")}

      true ->
        display =
          Components.display_for(did, socket.assigns.users, socket.assigns.character_names)

        Publisher.publish(socket, %{
          "kind" => Events.member_role_promoted(),
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

  @doc false
  def last_spielleiter?(members, did) do
    sls =
      Enum.filter(members, fn m ->
        m["role"] in ["spielleiter", "owner"]
      end)

    case sls do
      [%{"discord_id" => only_did}] -> only_did == did
      _ -> false
    end
  end
end
