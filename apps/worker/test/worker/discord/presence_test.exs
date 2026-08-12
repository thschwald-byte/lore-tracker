defmodule Worker.Discord.PresenceTest do
  @moduledoc """
  Issue #988: der pure Präsenz-Kern — wer sitzt im Kanal, wer spricht, wessen
  Spur wird gespeichert. Ohne Nostrum-Verbindung und ohne GenServer testbar
  (Muster `ConsentGate` #1002).
  """
  use ExUnit.Case, async: true

  alias Worker.Discord.Presence

  describe "speaking?/2 — Nachlauf statt Flackern" do
    test "gerade eben ein Paket -> spricht" do
      assert Presence.speaking?(1_000, 1_000)
      assert Presence.speaking?(1_000, 1_100)
    end

    test "kurz vor Ablauf des Nachlaufs -> spricht noch" do
      grace = Presence.speaking_grace_ms()
      assert Presence.speaking?(1_000, 1_000 + grace - 1)
    end

    test "genau am Nachlauf-Ende -> still" do
      grace = Presence.speaking_grace_ms()
      refute Presence.speaking?(1_000, 1_000 + grace)
    end

    test "nie ein Paket gesehen -> still (kein Puls für stumme Zuhörer)" do
      refute Presence.speaking?(nil, 5_000)
    end

    test "Zeitstempel aus der Zukunft (Uhr-Sprung) friert die Anzeige nicht ein" do
      assert Presence.speaking?(9_999, 1_000)
    end
  end

  describe "snapshot/4" do
    test "kombiniert Anwesenheit, Sprechen und Consent" do
      now = 10_000

      out =
        Presence.snapshot(
          ["b-still-ok", "a-spricht-ok", "c-kein-consent"],
          %{"a-spricht-ok" => now - 50, "c-kein-consent" => now - 50},
          %{"a-spricht-ok" => true, "b-still-ok" => true, "c-kein-consent" => false},
          now
        )

      assert out == [
               %{"discord_id" => "a-spricht-ok", "speaking" => true, "consent" => true},
               %{"discord_id" => "b-still-ok", "speaking" => false, "consent" => true},
               %{"discord_id" => "c-kein-consent", "speaking" => true, "consent" => false}
             ]
    end

    test "deterministisch sortiert — sonst springen die Icons bei jedem Tick" do
      a = Presence.snapshot(["zzz", "aaa", "mmm"], %{}, %{}, 0)
      b = Presence.snapshot(["mmm", "zzz", "aaa"], %{}, %{}, 0)

      assert a == b
      assert Enum.map(a, & &1["discord_id"]) == ["aaa", "mmm", "zzz"]
    end

    test "fehlendes Consent-Urteil zählt als KEIN Consent (fail-closed wie das Gate)" do
      [p] = Presence.snapshot(["unbekannt"], %{}, %{}, 0)
      assert p["consent"] == false
    end

    test "Duplikate im Kanal-Bestand werden entdoppelt" do
      out = Presence.snapshot(["x", "x", "x"], %{}, %{}, 0)
      assert length(out) == 1
    end

    test "leerer Kanal -> leere Liste, kein Crash" do
      assert Presence.snapshot([], %{}, %{}, 0) == []
    end
  end

  describe "prune/2 — kein unbegrenzt wachsender RAM-State" do
    test "Zeitstempel von Personen, die den Kanal verlassen haben, fallen raus" do
      assert Presence.prune(%{"bleibt" => 1, "weg" => 2}, ["bleibt"]) == %{"bleibt" => 1}
    end

    test "leerer Kanal -> leere Map" do
      assert Presence.prune(%{"a" => 1}, []) == %{}
    end
  end

  describe "initial_participants/3 — Anfangsbestand aus Nostrums voice_states" do
    defp vs(user_id, channel_id), do: %{user_id: user_id, channel_id: channel_id}

    test "nur User im Ziel-Channel, Bot ausgefiltert, als Strings" do
      states = [
        vs(111, 500),
        vs(222, 500),
        # anderer Voice-Channel derselben Guild
        vs(333, 999),
        # der Bot selbst (sitzt seit #989 ungemutet mit im Kanal)
        vs(42, 500)
      ]

      assert Presence.initial_participants(states, 500, 42) == ["111", "222"]
    end

    test "leere/fehlende voice_states -> leere Liste" do
      assert Presence.initial_participants([], 500, 42) == []
      assert Presence.initial_participants(nil, 500, 42) == []
    end

    test "unbekannte Bot-Identität (nil) filtert niemanden weg" do
      assert Presence.initial_participants([vs(111, 500)], 500, nil) == ["111"]
    end

    test "Einträge ohne user_id werden übersprungen statt zu crashen" do
      assert Presence.initial_participants([%{channel_id: 500}, vs(7, 500)], 500, nil) == ["7"]
    end
  end
end
