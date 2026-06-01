defmodule HubWeb.MicLiveTest do
  @moduledoc """
  Issue #405: State-Maschine der sticky MicLive (Capture-Owner). Getrieben
  über handle_info/handle_event auf einem Bare-Socket — der Hub hat kein
  LiveViewTest/ConnCase-Harness, das Verhalten im Browser deckt der PR-Test ab.
  Hier: die kritischen Übergänge (start, stop, Multi-Kampagne-Switch,
  SessionEnded matcht nur die laufende Session).
  """

  use ExUnit.Case, async: true

  alias HubWeb.MicLive

  defp socket(assigns \\ %{}) do
    base = %{
      current_user: %{discord_id: "did-me"},
      recording_campaign_id: nil,
      recording_session_id: nil,
      capture_source: nil,
      mic_on?: false,
      show_silence_modal?: false
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, assigns) |> Map.put(:__changed__, %{})
    }
  end

  describe "topic helpers" do
    test "command + state topics sind per-User getrennt" do
      assert MicLive.mic_topic("123") == "user_mic:123"
      assert MicLive.mic_state_topic("123") == "user_mic_state:123"
      refute MicLive.mic_topic("123") == MicLive.mic_state_topic("123")
    end
  end

  describe "start/stop capture" do
    test ":start_capture setzt das Recording-Tupel + mic_on?" do
      {:noreply, s} =
        MicLive.handle_info({:start_capture, "camp-a", "sess-1", "dev-x", "mic"}, socket())

      assert s.assigns.recording_campaign_id == "camp-a"
      assert s.assigns.recording_session_id == "sess-1"
      assert s.assigns.capture_source == "mic"
      assert s.assigns.mic_on? == true
    end

    test ":stop_capture leert das Tupel" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      {:noreply, s} = MicLive.handle_info({:stop_capture}, s0)

      assert s.assigns.recording_campaign_id == nil
      assert s.assigns.recording_session_id == nil
      assert s.assigns.mic_on? == false
    end
  end

  describe "Multi-Kampagne-Switch" do
    test ":start_capture für B überschreibt das laufende A (ein Mikro pro User)" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-a",
          capture_source: "mic",
          mic_on?: true
        })

      {:noreply, s} =
        MicLive.handle_info({:start_capture, "camp-b", "sess-b", "dev-y", "mic"}, s0)

      assert s.assigns.recording_campaign_id == "camp-b"
      assert s.assigns.recording_session_id == "sess-b"
      assert s.assigns.mic_on? == true
    end
  end

  describe "SessionEnded-Auto-Stop" do
    test "stoppt wenn die beendete Session die laufende ist" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      ev = {:event_appended, %{payload: %{"kind" => "SessionEnded", "id" => "sess-1"}}}
      {:noreply, s} = MicLive.handle_info(ev, s0)

      assert s.assigns.mic_on? == false
      assert s.assigns.recording_session_id == nil
    end

    test "ignoriert SessionEnded einer FREMDEN Session" do
      s0 =
        socket(%{
          recording_campaign_id: "camp-a",
          recording_session_id: "sess-1",
          capture_source: "mic",
          mic_on?: true
        })

      ev = {:event_appended, %{payload: %{"kind" => "SessionEnded", "id" => "sess-OTHER"}}}
      {:noreply, s} = MicLive.handle_info(ev, s0)

      # läuft unverändert weiter
      assert s.assigns.mic_on? == true
      assert s.assigns.recording_session_id == "sess-1"
    end
  end

  describe "Silence-Modal" do
    test "mic_silence_warning öffnet das Modal, dismiss schließt" do
      {:noreply, s1} = MicLive.handle_event("mic_silence_warning", %{}, socket())
      assert s1.assigns.show_silence_modal? == true

      {:noreply, s2} = MicLive.handle_event("mic_silence_dismiss", %{}, s1)
      assert s2.assigns.show_silence_modal? == false
    end
  end

  describe "audio_chunk guard" do
    test "leerer/fehlender chunk crasht nicht (no-op)" do
      s = socket(%{recording_campaign_id: "camp-a", capture_source: "mic"})
      assert {:noreply, ^s} = MicLive.handle_event("audio_chunk", %{"foo" => "bar"}, s)
    end
  end
end
