defmodule HubWeb.CampaignLive.MicCaptureModeTest do
  @moduledoc """
  Issue #987: die session-weite Discord/Browser-Exklusivität auf der Hub-
  Seite — `Mic.join/1`/`join_multi/1` refusen, sobald `capture_mode ==
  "discord"` ist, und `Mic.choose_discord_mode/1` refused, sobald schon
  IRGENDEIN Modus gewählt wurde. `Commands.request_capture_mode/3` ist
  best-effort (kein Worker in Test-Env verbunden) — die Assertions prüfen
  socket-seitiges Verhalten (Flash/show_mic_setup?), nicht den Worker-Call
  selbst.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Mic

  defp socket(active_session) do
    %Phoenix.LiveView.Socket{
      assigns:
        %{
          active_session: active_session,
          campaign_id: "camp-987",
          current_user: %{discord_id: "did-1"},
          recording_here?: false,
          mic_streamers: [],
          audio_consent: nil,
          flash: %{}
        }
        |> Map.put(:__changed__, %{})
    }
  end

  defp session(capture_mode), do: %{id: "sess-987", capture_mode: capture_mode}

  describe "join/1" do
    test "keine aktive Session -> Flash-Error, kein Setup" do
      {:noreply, s} = Mic.join(socket(nil))
      refute s.assigns[:show_mic_setup?]
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Keine aktive Session"
    end

    test "capture_mode == discord -> Flash-Error, kein Setup" do
      {:noreply, s} = Mic.join(socket(session("discord")))
      refute s.assigns[:show_mic_setup?]
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Discord-Bot"
    end

    test "capture_mode nil -> Setup öffnet wie gewohnt" do
      {:noreply, s} = Mic.join(socket(session(nil)))
      assert s.assigns.show_mic_setup?
    end

    test "capture_mode bereits browser -> Setup öffnet weiterhin (single+multi koexistieren)" do
      {:noreply, s} = Mic.join(socket(session("browser")))
      assert s.assigns.show_mic_setup?
    end
  end

  describe "join_multi/1" do
    test "capture_mode == discord -> Flash-Error, kein Setup" do
      {:noreply, s} = Mic.join_multi(socket(session("discord")))
      refute s.assigns[:show_mic_setup?]
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Discord-Bot"
    end

    test "capture_mode nil -> Setup öffnet wie gewohnt" do
      {:noreply, s} = Mic.join_multi(socket(session(nil)))
      assert s.assigns.show_mic_setup?
    end
  end

  describe "choose_discord_mode/1" do
    test "keine aktive Session -> Flash-Error" do
      {:noreply, s} = Mic.choose_discord_mode(socket(nil))
      assert Phoenix.Flash.get(s.assigns.flash, :error) =~ "Keine aktive Session"
    end

    test "capture_mode bereits discord -> No-op, kein Crash" do
      {:noreply, s} = Mic.choose_discord_mode(socket(session("discord")))
      refute Phoenix.Flash.get(s.assigns.flash, :error)
    end

    test "capture_mode bereits browser -> No-op (Exklusivität in beide Richtungen)" do
      {:noreply, s} = Mic.choose_discord_mode(socket(session("browser")))
      refute Phoenix.Flash.get(s.assigns.flash, :error)
    end

    test "capture_mode nil -> feuert best-effort, kein Crash ohne verbundenen Worker" do
      {:noreply, s} = Mic.choose_discord_mode(socket(session(nil)))
      refute Phoenix.Flash.get(s.assigns.flash, :error)
    end
  end
end
