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

  # Issue #702: Batch-Partitionierung entlang derselben Trust-Boundary.
  describe "split_valid_intents/2 (#702)" do
    defp ev(kind, extra \\ %{}) do
      %{"event_id" => UUIDv7.generate(), "payload" => Map.merge(%{"kind" => kind}, extra)}
    end

    test "gemischter Batch: valid + unbekannter kind + fremde Campaign partitioniert korrekt" do
      subs = MapSet.new(["camp-a"])
      ok1 = ev(Shared.Events.utterance_appended(), %{"campaign_id" => "camp-a"})
      ok2 = ev(Shared.Events.utterance_appended())
      bad_kind = ev("TotallyBogusKind")
      bad_camp = ev(Shared.Events.utterance_appended(), %{"campaign_id" => "camp-x"})

      {accepted, rejected} =
        WorkerChannel.split_valid_intents([ok1, bad_kind, ok2, bad_camp], subs)

      assert accepted == [ok1, ok2]
      assert rejected == [bad_kind, bad_camp]
    end

    test "alle valid → rejected leer" do
      subs = MapSet.new(["camp-a"])
      events = for i <- 1..3, do: ev(Shared.Events.utterance_appended(), %{"id" => "u-#{i}"})
      assert {^events, []} = WorkerChannel.split_valid_intents(events, subs)
    end

    test "alle invalid → accepted leer" do
      events = [ev("Bogus1"), ev("Bogus2")]
      assert {[], ^events} = WorkerChannel.split_valid_intents(events, MapSet.new())
    end

    test "Non-Map-Einträge landen in rejected ohne Crash" do
      valid = ev(Shared.Events.utterance_appended())

      {accepted, rejected} =
        WorkerChannel.split_valid_intents([nil, "kaputt", 42, valid], MapSet.new())

      assert accepted == [valid]
      assert rejected == [nil, "kaputt", 42]
    end

    test "Map ohne payload-Key landet in rejected" do
      {[], [%{"event_id" => _}]} =
        WorkerChannel.split_valid_intents([%{"event_id" => "e-1"}], MapSet.new())
    end
  end

  # Issue #772: der Hub routet einen Wrong-Worker-audio_nack an die MicLive des
  # Senders (per-User mic_topic). handle_in/3 broadcastet nur aus dem Payload und
  # liest den Socket nicht → direkt mit einem Bare-Socket aufrufbar (kein
  # Channel-Harness nötig, s. Moduldoc).
  describe "handle_in(\"audio_nack\") (#772)" do
    test "routet den Drop an mic_topic des Senders" do
      Phoenix.PubSub.subscribe(Hub.PubSub, HubWeb.MicLive.mic_topic("did-alice"))

      assert {:noreply, %Phoenix.Socket{}} =
               WorkerChannel.handle_in(
                 "audio_nack",
                 %{"session_id" => "sess-1", "discord_id" => "did-alice"},
                 %Phoenix.Socket{}
               )

      assert_receive {:audio_nack, "sess-1"}
    end
  end
end
