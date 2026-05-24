defmodule HubWeb.InviteController do
  use HubWeb, :controller

  alias Hub.{Auth, EventBridge, Reader}
  require Logger

  def show(conn, %{"token" => token}) do
    case Auth.current_user(conn) do
      nil ->
        # Not logged in → remember return path, bounce through Discord.
        conn
        |> Auth.put_return_to("/invite/#{token}")
        |> redirect(to: "/auth/discord")

      user ->
        redeem(conn, token, user)
    end
  end

  defp redeem(conn, token, user) do
    case Reader.read(%{"kind" => "invite", "token" => token}) do
      {:error, :no_worker} ->
        conn
        |> put_flash(
          :error,
          "Niemand kann den Einladungs-Token gerade prüfen. Versuch's später nochmal."
        )
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Einladung kaputt: #{inspect(reason)}")
        |> redirect(to: "/")

      {:ok, %{"not_found" => true}} ->
        conn
        |> put_flash(:error, "Einladung existiert nicht (oder noch nicht repliziert).")
        |> redirect(to: "/")

      {:ok, %{"invite" => %{"status" => "revoked"}}} ->
        conn
        |> put_flash(:error, "Einladung wurde zurückgezogen.")
        |> redirect(to: "/")

      {:ok, %{"invite" => %{"status" => "redeemed"} = invite}} ->
        # Already redeemed — if it was by us, just route to the campaign.
        if invite["redeemed_by_discord_id"] == user.discord_id do
          redirect(conn, to: ~p"/campaigns/#{invite["campaign_id"]}")
        else
          conn
          |> put_flash(:error, "Einladung wurde bereits von jemand anderem eingelöst.")
          |> redirect(to: "/")
        end

      {:ok, %{"invite" => %{"status" => "active"} = invite}} ->
        # Issue #154 (Etappe 4c.3): Event-Erzeugung via Worker-Bridge. Cold-Fail:
        # kein Worker für die Campaign online → Spieler kann gerade nicht
        # beitreten (Owner-Worker offline = Snapshot-Reads gehen ohnehin nicht).
        case EventBridge.publish(invite["campaign_id"], %{
               "kind" => Shared.Events.invite_redeemed(),
               "token" => token,
               "campaign_id" => invite["campaign_id"],
               "discord_id" => user.discord_id,
               "display_name" => user.display_name
             }) do
          :ok ->
            conn
            |> put_flash(:info, "Einladung eingelöst.")
            |> redirect(to: ~p"/campaigns/#{invite["campaign_id"]}")

          {:error, :no_worker_online} ->
            Logger.warning(
              "InviteController: kein Worker für campaign=#{invite["campaign_id"]} online — Invite-Redeem verschoben"
            )

            conn
            |> put_flash(
              :error,
              "Owner-Worker für diese Kampagne ist gerade offline — bitte den Owner kontaktieren und es später nochmal versuchen."
            )
            |> redirect(to: "/")
        end
    end
  end
end
