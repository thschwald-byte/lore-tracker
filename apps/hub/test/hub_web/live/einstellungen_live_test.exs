defmodule HubWeb.EinstellungenLiveTest do
  @moduledoc """
  Issue #451 (Track A): `/settings` ist ein Admin-only Bereich. Spieler/
  Spielleiter ohne globale Admin-Rolle werden beim Mount auf "/" geleitet,
  Admins kommen rein.

  Der SidebarContext-on_mount-Hook (Issue #387) liest die globale Rolle
  via `Reader.read(%{"kind" => "all_users"})`. Im Test gibt der ReaderStub
  diese Antwort an alle Reader-Calls weiter — sowohl an den Hook als auch
  an `load_settings/1`. Settings-relevante Felder bleiben leer; das LV
  fällt im Reader-Pfad auf den Default-Branch und mountet wartend, was
  für den Permission-Test reicht.
  """

  use HubWeb.ConnCase, async: false

  defp stub_with_role(role) when role in [:admin, :spielleiter, :spieler] do
    stub_reader!(%{
      "users" => [
        %{
          "discord_id" => "did-test",
          "role" => Atom.to_string(role),
          "display_name" => "Test"
        }
      ]
    })
  end

  test "Spieler mountet /settings → redirect zu / mit Flash", %{conn: conn} do
    stub_with_role(:spieler)
    user = Fixtures.user(discord_id: "did-test", role: :spieler)

    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             conn |> log_in(user) |> live("/settings")

    assert flash["error"] =~ "Admin-only"
  end

  test "Spielleiter (ohne globale Admin-Rolle) wird ebenfalls weggeschickt", %{conn: conn} do
    stub_with_role(:spielleiter)
    user = Fixtures.user(discord_id: "did-test", role: :spielleiter)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> log_in(user) |> live("/settings")
  end

  test "Admin mountet /settings — kein Redirect, Seite rendert", %{conn: conn} do
    stub_with_role(:admin)
    user = Fixtures.user(discord_id: "did-test", role: :admin)

    {:ok, _lv, html} =
      conn |> log_in(user) |> live("/settings")

    # Heading der Einstellungen-LV ist im Test sichtbar — kein Redirect.
    assert html =~ "Einstellungen" or html =~ "Worker"
  end
end
