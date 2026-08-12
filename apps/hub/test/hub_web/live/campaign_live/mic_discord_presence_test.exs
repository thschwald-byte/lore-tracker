defmodule HubWeb.CampaignLive.MicDiscordPresenceTest do
  @moduledoc """
  Issue #988: der Empfangspfad der Discord-Präsenz (5-Hz-Broadcast vom Worker).
  Ephemer wie `mic_level` — nichts wird persistiert.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Mic

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns:
        %{campaign_id: "camp-988", discord_participants: []}
        |> Map.put(:__changed__, %{})
    }
  end

  test "Teilnehmer der eigenen Kampagne landen im Assign" do
    parts = [%{"discord_id" => "111", "consent" => true, "speaking" => true}]

    {:noreply, s} = Mic.on_discord_presence(socket(), "camp-988", parts)

    assert s.assigns.discord_participants == parts
  end

  test "FREMDE Kampagne wird verworfen (dieselbe Schranke wie mic_level)" do
    parts = [%{"discord_id" => "111", "consent" => true, "speaking" => true}]

    {:noreply, s} = Mic.on_discord_presence(socket(), "andere-kampagne", parts)

    assert s.assigns.discord_participants == []
  end

  test "leere Liste (alle haben den Kanal verlassen) leert die Anzeige" do
    s = socket()
    s = %{s | assigns: Map.put(s.assigns, :discord_participants, [%{"discord_id" => "alt"}])}

    {:noreply, out} = Mic.on_discord_presence(s, "camp-988", [])

    assert out.assigns.discord_participants == []
  end

  test "kaputte Nutzlast (keine Liste) wird nicht ins Template durchgereicht" do
    {:noreply, s} = Mic.on_discord_presence(socket(), "camp-988", "unsinn")

    assert s.assigns.discord_participants == []
  end
end
