defmodule HubWeb.WorkerChannelIntentTest do
  @moduledoc """
  Issue #473: Trust-Boundary am `publish_intent`. Nur Maps mit einem bekannten
  Shared.Events-`kind` dürfen gebroadcastet werden; alles andere (unbekannter
  kind, fehlender kind, keine Map) wird verworfen statt still in die LV-/Worker-
  Schicht durchgereicht.

  Getestet wird der Validator direkt (es gibt keine Channel-Test-Harness im Hub).
  """

  use ExUnit.Case, async: true

  alias HubWeb.WorkerChannel

  test "akzeptiert eine Map mit bekanntem Shared.Events-kind" do
    kind = Shared.Events.utterance_appended()
    assert WorkerChannel.valid_intent_payload?(%{"kind" => kind, "id" => "u-1"})
  end

  test "akzeptiert mehrere kanonische kinds (Stichprobe quer durch Shared.Events.all/0)" do
    for kind <- Enum.take_every(Shared.Events.all(), 7) do
      assert WorkerChannel.valid_intent_payload?(%{"kind" => kind}),
             "kanonischer kind=#{kind} sollte akzeptiert werden"
    end
  end

  test "verwirft unbekannten/vertippten kind" do
    refute WorkerChannel.valid_intent_payload?(%{"kind" => "TotallyBogusKind"})
    refute WorkerChannel.valid_intent_payload?(%{"kind" => "UtteranceAppendd"})
  end

  test "verwirft Payload ohne kind / mit nicht-binärem kind" do
    refute WorkerChannel.valid_intent_payload?(%{"id" => "u-1"})
    refute WorkerChannel.valid_intent_payload?(%{"kind" => nil})
    refute WorkerChannel.valid_intent_payload?(%{"kind" => 42})
  end

  test "verwirft Nicht-Map-Payloads (kein Crash)" do
    refute WorkerChannel.valid_intent_payload?("UtteranceAppended")
    refute WorkerChannel.valid_intent_payload?(nil)
    refute WorkerChannel.valid_intent_payload?([%{"kind" => Shared.Events.utterance_appended()}])
  end
end
