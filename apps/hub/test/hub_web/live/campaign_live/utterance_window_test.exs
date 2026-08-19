defmodule HubWeb.CampaignLive.UtteranceWindowTest do
  @moduledoc """
  Issue #1087: das Protokoll wird jetzt auch beim LADEN gefenstert. Das
  verschiebt eine Annahme, auf der #709 aufbaute — dort war die volle Liste im
  Assign garantiert, Offsets und Gesamtzahl waren dasselbe. Jetzt laufen die
  Offsets im Koordinatensystem der geladenen Teilliste, und `utterance_from`
  übersetzt zurück.

  Die beiden Dinge, die dabei still brechen können und deshalb hier festgenagelt
  sind: (1) der „ältere anzeigen"-Anker darf nicht verschwinden, sobald der
  Anfang der geladenen Teilliste erreicht ist — sonst wäre der Rest der Session
  unerreichbar; (2) beim Nachladen muss das Fenster um die Zahl der
  vorangestellten Zeilen mitwandern, sonst springt die Ansicht.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components, as: C
  alias HubWeb.CampaignLive.Layout
  alias HubWeb.CampaignLive.Snapshot

  @sid "s1"

  defp utt(i, sid \\ @sid),
    do: %{"id" => "#{sid}-u#{i}", "session_id" => sid, "timestamp" => ts(i), "text" => "t#{i}"}

  # Fester, sortierbarer Zeitstempel — die Merge-Logik sortiert danach.
  defp ts(i),
    do:
      "2026-08-19T#{String.pad_leading("#{div(i, 60)}", 2, "0")}:" <>
        "#{String.pad_leading("#{rem(i, 60)}", 2, "0")}:00Z"

  defp socket(assigns) do
    base = %{
      utterances: [],
      utterance_windows: %{},
      utterance_from: %{},
      utterance_counts: %{},
      utterance_lookup: %{},
      utterance_indices: %{},
      utterances_loading: MapSet.new(),
      pending_focus: nil,
      campaign_id: "camp-1",
      current_user: %{discord_id: "did-1"}
    }

    %Phoenix.LiveView.Socket{assigns: Map.put(Map.merge(base, assigns), :__changed__, %{})}
  end

  describe "window_slice/4 — hidden_before erzählt die Wahrheit" do
    test "ohne Ladefenster identisch zu window_slice/3" do
      group = Enum.map(1..300, &utt/1)

      assert C.window_slice(group, @sid, %{}, 0) == C.window_slice(group, @sid, %{})
    end

    test "der Anker bleibt sichtbar, wenn nur der geladene Anfang erreicht ist" do
      # 200 geladen von 5.553 — das Fenster steht ganz am Anfang des Geladenen.
      group = Enum.map(1..200, &utt/1)
      windows = %{@sid => {0, 150}}

      {_visible, hidden_before, _after} = C.window_slice(group, @sid, windows, 5353)

      # Ohne das loaded_from-Argument wäre das 0 → der Scroll-Sentinel im
      # Template (`:if={hidden_before > 0}`) verschwände und die restlichen
      # 5.353 Zeilen wären nicht mehr erreichbar.
      assert hidden_before == 5353
    end

    test "hidden_after bleibt relativ zum Geladenen — der Schwanz ist immer da" do
      group = Enum.map(1..200, &utt/1)
      windows = %{@sid => {0, 150}}

      {_visible, _before, hidden_after} = C.window_slice(group, @sid, windows, 5353)

      assert hidden_after == 50
    end

    test "negatives loaded_from wird geklemmt" do
      group = Enum.map(1..10, &utt/1)

      {_v, hidden_before, _a} = C.window_slice(group, @sid, %{@sid => {0, 5}}, -7)
      assert hidden_before == 0
    end
  end

  describe "Layout.utterance_window_step/3 — wann nachgeladen wird" do
    test "kein Nachladen, solange geladene Zeilen davor liegen" do
      s = socket(%{utterances: Enum.map(1..200, &utt/1), utterance_windows: %{@sid => {150, 50}}})

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :older)

      assert out.assigns.utterance_windows[@sid] == {50, 150}
      assert out.assigns.utterances_loading == MapSet.new()
    end

    test "kein Nachladen, wenn die Session vollständig geladen ist" do
      # from == 0 heißt: es gibt nichts Älteres mehr im Worker.
      s =
        socket(%{
          utterances: Enum.map(1..200, &utt/1),
          utterance_windows: %{@sid => {0, 150}},
          utterance_from: %{@sid => 0}
        })

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :older)

      assert out.assigns.utterances_loading == MapSet.new()
    end

    test "Nachladen, sobald der Schritt über den geladenen Anfang hinausliefe" do
      s =
        socket(%{
          utterances: Enum.map(1..200, &utt/1),
          utterance_windows: %{@sid => {0, 150}},
          utterance_from: %{@sid => 5353}
        })

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :older)

      assert MapSet.member?(out.assigns.utterances_loading, @sid)
      # Das Fenster wird NICHT vorab verschoben — sonst zeigte es auf Zeilen,
      # die noch gar nicht da sind.
      assert out.assigns.utterance_windows[@sid] == {0, 150}
    end

    test "ein zweiter Trigger während des Ladens löst keinen zweiten Read aus" do
      s =
        socket(%{
          utterances: Enum.map(1..200, &utt/1),
          utterance_windows: %{@sid => {0, 150}},
          utterance_from: %{@sid => 5353},
          utterances_loading: MapSet.new([@sid])
        })

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :older)

      assert out.assigns.utterances_loading == MapSet.new([@sid])
    end

    test ":newer lädt nie nach — der Schwanz ist immer geladen" do
      s =
        socket(%{
          utterances: Enum.map(1..200, &utt/1),
          utterance_windows: %{@sid => {0, 100}},
          utterance_from: %{@sid => 5353}
        })

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :newer)

      assert out.assigns.utterances_loading == MapSet.new()
      assert out.assigns.utterance_windows[@sid] == {0, 200}
    end
  end

  describe "Snapshot.apply_utterance_load/2 — slice" do
    test "stellt voran, verschiebt das Fenster mit und blättert dann weiter" do
      s =
        socket(%{
          utterances: Enum.map(101..300, &utt/1),
          utterance_windows: %{@sid => {0, 150}},
          utterance_from: %{@sid => 100},
          utterance_counts: %{@sid => 300},
          utterances_loading: MapSet.new([@sid])
        })

      snap = %{
        "mode" => "slice",
        "session_id" => @sid,
        "from" => 0,
        "total" => 300,
        "utterances" => Enum.map(1..100, &utt/1)
      }

      out = Snapshot.apply_utterance_load(s, snap)

      assert length(out.assigns.utterances) == 300
      assert hd(out.assigns.utterances)["id"] == "#{@sid}-u1"
      assert out.assigns.utterance_from[@sid] == 0
      assert out.assigns.utterance_counts[@sid] == 300
      assert out.assigns.utterances_loading == MapSet.new()

      # Vorher {0,150} bei 100 vorangestellten Zeilen → {100,150}, dann ein
      # Schritt nach oben (window_step 100) → {0, 200} (gedeckelt auf max).
      assert out.assigns.utterance_windows[@sid] == {0, 200}
    end

    test "doppelt geliefertes wird nicht doppelt eingehängt" do
      s =
        socket(%{
          utterances: Enum.map(1..10, &utt/1),
          utterance_windows: %{@sid => {0, 10}},
          utterance_from: %{@sid => 0},
          utterances_loading: MapSet.new([@sid])
        })

      snap = %{
        "mode" => "slice",
        "session_id" => @sid,
        "from" => 0,
        "total" => 10,
        "utterances" => Enum.map(1..10, &utt/1)
      }

      out = Snapshot.apply_utterance_load(s, snap)

      assert length(out.assigns.utterances) == 10
    end

    test "im Tail-Modus (kein gespeichertes Fenster) wird trotzdem geblättert" do
      s =
        socket(%{
          utterances: Enum.map(151..300, &utt/1),
          utterance_windows: %{},
          utterance_from: %{@sid => 150},
          utterances_loading: MapSet.new([@sid])
        })

      snap = %{
        "mode" => "slice",
        "session_id" => @sid,
        "from" => 50,
        "total" => 300,
        "utterances" => Enum.map(51..150, &utt/1)
      }

      out = Snapshot.apply_utterance_load(s, snap)

      assert length(out.assigns.utterances) == 250
      # Ohne diesen Zweig bliebe das Fenster im Tail — das Nachladen wäre
      # sichtbar wirkungslos gewesen.
      refute out.assigns.utterance_windows[@sid] == nil
    end
  end

  describe "Snapshot.apply_utterance_load/2 — ids" do
    test "landet im Nachschlag, nicht in der Liste" do
      s = socket(%{utterances: Enum.map(200..210, &utt/1)})

      snap = %{
        "mode" => "ids",
        "utterances" => [utt(3)],
        "indices" => %{"#{@sid}-u3" => 2}
      }

      out = Snapshot.apply_utterance_load(s, snap)

      # Ein Einzelabruf DARF nicht in die Liste — er risse ein Loch hinein und
      # das Fenster zeigte nicht benachbarte Zeilen als benachbart.
      assert length(out.assigns.utterances) == 11
      assert out.assigns.utterance_lookup["#{@sid}-u3"]["text"] == "t3"
      assert out.assigns.utterance_indices["#{@sid}-u3"] == 2
    end
  end

  describe "Alt-Worker ohne #1087" do
    test "volle Liste ohne Zähler verhält sich wie vorher" do
      # Kein utterance_counts/utterance_from im Snapshot → der Hub leitet die
      # Zahlen aus der Liste ab und lädt nie nach.
      s =
        socket(%{
          utterances: Enum.map(1..40, &utt/1),
          utterance_windows: %{@sid => {0, 40}},
          utterance_from: %{}
        })

      {:noreply, out} = Layout.utterance_window_step(s, @sid, :older)

      assert out.assigns.utterances_loading == MapSet.new()
    end
  end
end
