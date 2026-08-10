defmodule HubWeb.CampaignLive.MicControlsCaptureModeTest do
  @moduledoc """
  Issue #987: die 3-Wege-Modus-Wahl (Discord/Single/Multi) im
  `mic_controls/1`-Function-Component. Discord XOR Browser-Mikro muss sich
  im gerenderten Markup widerspiegeln, nicht nur in der Backend-Logik.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.MicComponents

  defp render_mic(active_session) do
    render_component(&MicComponents.mic_controls/1,
      active_session: active_session,
      mic_on?: false,
      recording_here?: false,
      mic_streamers: [],
      mic_levels: %{},
      current_discord_id: "d1",
      users: %{}
    )
  end

  test "keine aktive Session -> nichts gerendert" do
    html = render_mic(nil)
    refute html =~ "mic_choose_discord"
    refute html =~ "mic_join"
  end

  test "capture_mode nil -> alle 3 Buttons (Discord/Single/Multi)" do
    html = render_mic(%{id: "s1", capture_mode: nil})

    assert html =~ ~s(phx-click="mic_choose_discord")
    assert html =~ ~s(phx-click="mic_join")
    assert html =~ ~s(phx-click="mic_join_multi")
  end

  test "capture_mode discord -> nur der Indikator, keine Join-Buttons" do
    html = render_mic(%{id: "s1", capture_mode: "discord"})

    refute html =~ ~s(phx-click="mic_choose_discord")
    refute html =~ ~s(phx-click="mic_join")
    refute html =~ ~s(phx-click="mic_join_multi")
    assert html =~ "Discord nimmt auf"
  end

  test "capture_mode browser -> Single+Multi, KEIN Discord-Button mehr" do
    html = render_mic(%{id: "s1", capture_mode: "browser"})

    refute html =~ ~s(phx-click="mic_choose_discord")
    assert html =~ ~s(phx-click="mic_join")
    assert html =~ ~s(phx-click="mic_join_multi")
  end
end
