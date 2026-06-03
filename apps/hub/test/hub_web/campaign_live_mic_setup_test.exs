defmodule HubWeb.CampaignLiveMicSetupTest do
  @moduledoc """
  Issue #391: Pure-Entscheidungslogik des Mic-Setup-Popups (Voice-Test +
  Consent-Gate + Pegel-Clamp + Listen-Whitelist).

  Die Socket-Verdrahtung (push_event mic:start_recording, EventBridge-Publish,
  Modal-Render) wird manuell im PR-Test verifiziert — diese Suite deckt die
  subtilen Branching-Invarianten ab, die in der Plan-Review als fehleranfällig
  markiert waren (sid-Bindung, Voice/Consent-Orthogonalität, Listen-Pegel).
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive
  alias HubWeb.CampaignLive.Components

  describe "mic_setup_finish_decision/3 — Voice + Consent + sid Gate" do
    test ":start wenn Voice ok, Consent ok und gültige sid" do
      assert :start = CampaignLive.mic_setup_finish_decision(true, true, "sess-123")
    end

    test ":wait wenn Voice fehlt (Consent ok)" do
      assert :wait = CampaignLive.mic_setup_finish_decision(false, true, "sess-123")
    end

    test ":wait wenn Consent fehlt (Voice ok) — Häkchen noch nicht gesetzt" do
      assert :wait = CampaignLive.mic_setup_finish_decision(true, false, "sess-123")
    end

    test ":wait wenn beide fehlen" do
      assert :wait = CampaignLive.mic_setup_finish_decision(false, false, "sess-123")
    end

    test ":abort_no_session wenn Voice+Consent ok aber sid nil" do
      assert :abort_no_session = CampaignLive.mic_setup_finish_decision(true, true, nil)
    end

    test ":abort_no_session wenn Voice+Consent ok aber sid leerer String" do
      assert :abort_no_session = CampaignLive.mic_setup_finish_decision(true, true, "")
    end

    test "sid-Guard greift erst NACH dem Voice/Consent-Gate (kein Abort wenn noch wartend)" do
      # Auch mit kaputter sid: solange noch gewartet wird, bleibt es :wait
      # (Modal offen) statt vorschnell abzubrechen.
      assert :wait = CampaignLive.mic_setup_finish_decision(false, true, nil)
      assert :wait = CampaignLive.mic_setup_finish_decision(true, false, "")
    end
  end

  describe "phrase_match?/2 — toleranter Wort-Overlap (Issue #400)" do
    test "exakte Phrase matcht" do
      assert CampaignLive.phrase_match?(
               "Houston, wir haben ein Problem.",
               "Houston wir haben ein Problem"
             )
    end

    test "Case + Satzzeichen werden normalisiert" do
      assert CampaignLive.phrase_match?(
               "Möge die Macht mit dir sein.",
               "MÖGE DIE MACHT MIT DIR SEIN!!!"
             )
    end

    test "Reihenfolge egal" do
      assert CampaignLive.phrase_match?("eins zwei drei vier fünf", "fünf vier drei zwei eins")
    end

    test "Eigennamen-/ASR-Slip wird toleriert (≥60% reichen)" do
      # 4 von 5 erwarteten Wörtern erkannt (0.8 ≥ 0.6).
      assert CampaignLive.phrase_match?(
               "Sag hallo zu meinem Freund",
               "sag hallo zu meinem Freunde da"
             )
    end

    test "knapp über der 60%-Grenze matcht" do
      # 3 von 5 = 0.6 (genau auf der Schwelle, >= gilt).
      assert CampaignLive.phrase_match?("alpha beta gamma delta epsilon", "alpha beta gamma")
    end

    test "knapp unter der 60%-Grenze matcht nicht" do
      # 2 von 5 = 0.4 < 0.6.
      refute CampaignLive.phrase_match?("alpha beta gamma delta epsilon", "alpha beta")
    end

    test "leeres Transkript matcht nie" do
      refute CampaignLive.phrase_match?("Houston wir haben ein Problem", "")
    end

    test "leere erwartete Phrase matcht nie (Defensive)" do
      refute CampaignLive.phrase_match?("", "irgendwas")
    end

    test "komplett falsches Transkript matcht nicht" do
      refute CampaignLive.phrase_match?(
               "Möge die Macht mit dir sein",
               "ich kaufe drei Brötchen und Käse"
             )
    end

    test "nicht-binäre Eingaben → false (kaputter Payload)" do
      refute CampaignLive.phrase_match?(nil, "text")
      refute CampaignLive.phrase_match?("phrase", nil)
    end
  end

  describe "clamp_level/1 — Pegel-Defensive" do
    test "lässt gültige Werte 0.0..1.0 durch" do
      assert CampaignLive.clamp_level(0.0) == 0.0
      assert CampaignLive.clamp_level(0.5) == 0.5
      assert CampaignLive.clamp_level(1.0) == 1.0
    end

    test "clampt über 1.0 auf 1.0" do
      assert CampaignLive.clamp_level(1.7) == 1.0
    end

    test "clampt unter 0.0 auf 0.0" do
      assert CampaignLive.clamp_level(-0.3) == 0.0
    end

    test "Integer-Pegel werden zu Float normalisiert" do
      assert CampaignLive.clamp_level(1) == 1.0
      assert CampaignLive.clamp_level(0) == 0.0
    end

    test "nicht-numerische Werte → 0.0 (kaputter Client-Payload)" do
      assert CampaignLive.clamp_level("0.5") == 0.0
      assert CampaignLive.clamp_level(nil) == 0.0
      assert CampaignLive.clamp_level(%{}) == 0.0
    end
  end

  describe "mic_button_state/3 — Drei-Wege-Mikro-Button (Issue #415)" do
    test "recording_here? → :stop (dieser Browser nimmt auf)" do
      assert Components.mic_button_state(true, "111", ["111"]) == :stop
    end

    test "recording_here? schlägt Streamer-Liste — aufnehmendes Gerät zeigt nie :takeover" do
      assert Components.mic_button_state(true, "111", []) == :stop
    end

    test "Account in Streamer-Liste, aber nicht hier → :takeover (anderes Gerät nimmt auf)" do
      assert Components.mic_button_state(false, "111", ["111", "222"]) == :takeover
    end

    test "niemand auf diesem Account nimmt auf → :join" do
      assert Components.mic_button_state(false, "111", ["222", "333"]) == :join
    end

    test "leere Streamer-Liste → :join" do
      assert Components.mic_button_state(false, "111", []) == :join
    end

    test "nil Streamer-Liste → :join (kein Crash)" do
      assert Components.mic_button_state(false, "111", nil) == :join
    end
  end
end
