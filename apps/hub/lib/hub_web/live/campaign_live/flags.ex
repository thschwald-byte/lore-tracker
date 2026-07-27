defmodule HubWeb.CampaignLive.Flags do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): der Publish-Pfad der Falsifikations-Flags —
  der einzige erlaubte Spieler-Signal-Pfad („stimmt nicht"). Melden = Member-
  Recht (`:flag_raise`), Lösen/Verwerfen = Kurator-Recht (`:resolve_flag`,
  GM-only in Cut 1).

  **Serverseitiges Gate** (never trust the client): jeder Pfad prüft sein
  `can?/3`-Recht + validiert `target_kind`, bevor das Event publisht wird — ein
  gecrafteter phx-click ohne Recht bekommt einen Flash statt eines Events.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias HubWeb.CampaignLive.Publisher
  alias HubWeb.Permissions
  alias Shared.Events

  # #916 (Cut 2): "span" = Utterance-Mengen-granulares Melden (von einer Fakt-Zeile).
  @target_kinds ~w(session arc fact span)
  @note_max 500

  @doc "Dispatch der `flag_*`-Events aus dem CampaignLive-handle_event."
  def flag_event(socket, "flag_raise", %{"target_kind" => tk, "target_id" => tid} = params) do
    note = params["note"] |> to_string() |> String.slice(0, @note_max)
    publish(socket, :flag_raise, Events.flag_raised(), tk, tid, %{"note" => note})
  end

  def flag_event(socket, "flag_resolve", %{"target_kind" => tk, "target_id" => tid}),
    do: publish(socket, :resolve_flag, Events.flag_resolved(), tk, tid, %{})

  def flag_event(socket, "flag_dismiss", %{"target_kind" => tk, "target_id" => tid}),
    do: publish(socket, :resolve_flag, Events.flag_dismissed(), tk, tid, %{})

  def flag_event(socket, _other, _params), do: {:noreply, socket}

  defp publish(socket, perm, kind, tk, tid, extra) do
    user = socket.assigns.perm_user
    campaign = socket.assigns.campaign

    cond do
      tk not in @target_kinds or not is_binary(tid) or tid == "" ->
        {:noreply, socket}

      not Permissions.can?(user, perm, campaign) ->
        {:noreply, put_flash(socket, :error, "Keine Berechtigung")}

      true ->
        Publisher.publish(
          socket,
          Map.merge(
            %{
              "kind" => kind,
              "campaign_id" => socket.assigns.campaign_id,
              "target_kind" => tk,
              "target_id" => tid,
              "set_by" => user.discord_id
            },
            extra
          )
        )

        {:noreply, socket}
    end
  end
end
