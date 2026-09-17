defmodule HubWeb.CampaignLive.StufenTitelTest do
  # J4 (#1207): die Fehler-Meldung einer Pipeline-Stufe nennt den Titel aus
  # Shared.PipelineStufen, nicht den internen Namen.
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Snapshot

  test "bekannte Stufen erscheinen mit ihrem Titel" do
    assert Snapshot.stufen_titel("jack_verifikation") == "Verifikation"
    assert Snapshot.stufen_titel("jack_gedaechtnis") == "Gedächtnis"
    assert Snapshot.stufen_titel("extract") == "Extraktion"
  end

  test "Stufen, die es nicht mehr gibt, behalten ihren Rohnamen" do
    assert Snapshot.stufen_titel("verify") == "verify"
  end
end
