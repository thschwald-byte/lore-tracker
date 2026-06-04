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

  # Issue #473 Cut 2: Membership-Scoping — ein campaign-scopedes Event darf nur
  # durch, wenn die Campaign im subscribed-Set des Absenders ist.
  describe "authorized_campaign?/2 (#473 Cut 2)" do
    test "campaign_id im subscribed-Set → erlaubt" do
      subs = MapSet.new(["camp-a", "camp-b"])
      assert WorkerChannel.authorized_campaign?(%{"campaign_id" => "camp-a"}, subs)
    end

    test "campaign_id NICHT im subscribed-Set → verworfen" do
      subs = MapSet.new(["camp-a"])
      refute WorkerChannel.authorized_campaign?(%{"campaign_id" => "camp-x"}, subs)
    end

    test "leeres subscribed-Set + campaign-scopedes Event → verworfen" do
      refute WorkerChannel.authorized_campaign?(%{"campaign_id" => "camp-a"}, MapSet.new())
    end

    test "kein campaign_id (Global-Event) → erlaubt, egal welches subscribed-Set" do
      assert WorkerChannel.authorized_campaign?(%{"kind" => "UserUpserted"}, MapSet.new())
    end

    test "Genesis: CampaignCreated nutzt payload[\"id\"], kein campaign_id → erlaubt" do
      # genau die Genesis-Sicherheit — neue Campaign, Worker noch nicht subscribed
      payload = %{"kind" => Shared.Events.campaign_created(), "id" => "neue-camp"}
      assert WorkerChannel.authorized_campaign?(payload, MapSet.new())
    end
  end
end
