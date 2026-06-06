defmodule HubWeb.AdminUsersDeleteResolveTest do
  @moduledoc """
  Issue #613: der User-Delete-Resolution-Pfad muss bei fehlgeschlagenem
  Resolution-Publish (kein Worker online) ABBRECHEN statt nach :confirm zu
  gehen — sonst könnte ein nachfolgendes UserDeleted eine Kampagne ohne letzten
  Spielleiter zurücklassen (#57-Lockout). Bare-Socket-Transform-Stil
  (kein Mount/Worker → EventBridge.publish liefert {:error, :no_worker_online}),
  damit ist der Cold-Fail-Pfad direkt testbar.
  """
  use ExUnit.Case, async: true

  alias HubWeb.AdminUsersLive

  defp socket(resolution, sl_campaigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          current_user: %{discord_id: "admin-1"},
          delete_state: %{
            stage: :resolve,
            resolution: resolution,
            preview: %{"last_sl_campaigns" => sl_campaigns}
          },
          flash: %{}
        }
        |> Map.put(:__changed__, %{})
    }
  end

  describe "delete_user_resolve_next — Cold-Fail-Abbruch (#613)" do
    test "vollständige Resolution, aber kein Worker online → Abbruch (bleibt :resolve, Flash)" do
      s0 = socket(%{"camp-1" => :archive}, [%{"id" => "camp-1", "name" => "Test"}])

      {:noreply, s} = AdminUsersLive.handle_event("delete_user_resolve_next", %{}, s0)

      # Kein Übergang nach :confirm — der Delete wird NICHT fortgesetzt.
      assert s.assigns.delete_state.stage == :resolve
      assert s.assigns.flash["error"] =~ "NICHT fortgesetzt"
    end

    test "Promote-Resolution, kein Worker → ebenfalls Abbruch" do
      s0 =
        socket(
          %{"camp-1" => {:promote, "did-other"}},
          [%{"id" => "camp-1", "name" => "Test"}]
        )

      {:noreply, s} = AdminUsersLive.handle_event("delete_user_resolve_next", %{}, s0)

      assert s.assigns.delete_state.stage == :resolve
      assert s.assigns.flash["error"] =~ "NICHT fortgesetzt"
    end
  end

  describe "delete_user_resolve_next — unvollständige Resolution" do
    test "nicht alle Last-SL-Kampagnen entschieden → Flash, kein Stage-Übergang" do
      s0 = socket(%{}, [%{"id" => "camp-1", "name" => "Test"}])

      {:noreply, s} = AdminUsersLive.handle_event("delete_user_resolve_next", %{}, s0)

      assert s.assigns.delete_state.stage == :resolve
      assert s.assigns.flash["error"] =~ "Auswahl treffen"
    end
  end
end
