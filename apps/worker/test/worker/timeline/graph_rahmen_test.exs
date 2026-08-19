defmodule Worker.Timeline.GraphRahmenTest do
  @moduledoc """
  Issue #1069 (E7): der Session-Zeitrahmen als zweite Signal-Quelle.

  Die Entscheidung (2026-08-19) lautet: trägt der Rahmen, kippt die Session in
  die Chronik-Vollansicht. Gemessen an Free Seattle S1 sind das 16 → 175
  Einträge. Damit hängt an `rahmen_belegt?/1` mehr als ein Prädikat — es
  entscheidet, welche Sessions kippen. Diese Tests halten die Strenge fest.
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.Graph

  @praesens %{"claim" => "Romeo betritt den Club", "narration_time" => "present"}

  describe "rahmen_belegt?/1 — was als Beleg zählt" do
    test "ein harter DATUMS-Anker genügt" do
      assert Graph.rahmen_belegt?(%{"harte_datums_anker" => 1, "tageszeit" => nil})
    end

    test "drei harte JAHRES-Anker genügen nicht — der reale S1-Fall" do
      # Gemessen an Free Seattle S1: `harte_anker` ist 3, und alle drei sind
      # Jahreszahlen (2080, 2070, 2080). Wer `harte_anker` als Beleg liest,
      # kippt die Session auf drei Ziffernfolgen, von denen eine nachweislich
      # zur erzählten Weltgeschichte gehört und keine einen Tag positioniert.
      refute Graph.rahmen_belegt?(%{
               "harte_anker" => 3,
               "harte_datums_anker" => 0,
               "tageszeit" => nil
             })
    end

    test "eine bestätigte Tageszeit genügt" do
      # Sie entsteht im Vorlauf nur aus >= 2 übereinstimmenden Fundstellen (D2).
      assert Graph.rahmen_belegt?(%{"harte_datums_anker" => 0, "tageszeit" => "abend"})
    end

    test "als Atom genauso wie als String" do
      # Frisch aus dem Vorlauf ist die Tageszeit ein Atom, aus der DB ein
      # String. Beide Wege laufen durch dieselbe Prüfung — ginge einer still
      # als unbelegt durch, kippte die Session je nach Aufrufweg anders.
      assert Graph.rahmen_belegt?(%{tageszeit: :abend, harte_datums_anker: 0})
      assert Graph.rahmen_belegt?(%{"tageszeit" => "abend", "harte_anker" => 0})
    end

    test "NUR degradierte Anker begründen nichts" do
      # Der Block-37-Fall: „um 20.10 Uhr" für die Jahreszahl 2010. Eine
      # Session, deren sämtliche Zeitfundstellen auf wackeligem ASR sitzen,
      # darf die Chronik nicht öffnen — sonst datiert ein ASR-Bruch 175 Fakten.
      refute Graph.rahmen_belegt?(%{
               "harte_datums_anker" => 0,
               "degradierte_anker" => 9,
               "tageszeit" => nil
             })
    end

    test "Jahres-Kandidaten allein reichen NICHT" do
      # Ein Jahr verengt, aber es datiert keinen Tag. Gemessen gehört jeder
      # dritte gefundene Jahres-Anker zur erzählten Weltgeschichte (2070)
      # statt zur Handlungszeit (2080).
      refute Graph.rahmen_belegt?(%{
               "harte_datums_anker" => 0,
               "tageszeit" => nil,
               "jahr_kandidaten" => [[2080, 2], [2070, 1]]
             })
    end

    test "kein Rahmen ist kein Beleg" do
      refute Graph.rahmen_belegt?(nil)
      refute Graph.rahmen_belegt?(%{})
      refute Graph.rahmen_belegt?("abend")
    end
  end

  describe "time_signal?/2 — die Öffnung" do
    test "ohne Rahmen bleibt #958 in Kraft" do
      refute Graph.time_signal?(@praesens, nil)
      refute Graph.time_signal?(@praesens, %{"harte_datums_anker" => 0})
    end

    test "mit belegtem Rahmen zählt auch ein reiner Präsens-Fakt" do
      assert Graph.time_signal?(@praesens, %{"harte_datums_anker" => 2})
    end

    test "ein eigenes Signal trägt weiterhin ohne jeden Rahmen" do
      fakt = Map.put(@praesens, "time_absolute", "24.12.2011")
      assert Graph.time_signal?(fakt, nil)
    end

    test "/1 bleibt unverändert — der Bestandspfad ist nicht betroffen" do
      refute Graph.time_signal?(@praesens)
      assert Graph.time_signal?(Map.put(@praesens, "time_offset", 3))
    end
  end
end
