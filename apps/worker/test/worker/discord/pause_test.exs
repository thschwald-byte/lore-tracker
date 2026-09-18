defmodule Worker.Discord.PauseTest do
  @moduledoc """
  Issue #1058: Pause hält auch den Discord-Bot an.

  Die Runde macht Pause, der Spielleiter drückt Pause, die Oberfläche zeigt
  „pausiert" — und der Bot nahm weiter auf. Alles Gesprochene landete im
  Mitschnitt: über Arbeit, über Privates, über Dinge, die niemand im Protokoll
  haben will. Beim Browser-Mikro endet der Datenstrom an der Quelle; der Bot
  hängt dagegen am Kanal, nicht am Aufnahme-Zustand.

  Die Einwilligung deckt die Aufzeichnung der Spielsitzung. Ob sie das
  Pausengespräch deckt, ist mindestens fragwürdig — und der Knopf suggerierte
  das Gegenteil.

  Geprüft wird beides: die reinen Texte, und per Quelltext die Stellen, an
  denen die Sperre sitzen MUSS (der Prozess ist ohne verbundenen Discord-Bot
  nicht startbar).
  """
  use ExUnit.Case, async: true

  alias Worker.Discord.{AnnounceQueue, Announcement}

  @session File.read!("lib/worker/discord/voice_session.ex")

  describe "Ansagen" do
    test "beide Zustände haben einen kurzen, eindeutigen Satz" do
      assert Announcement.text_for_pause(true) == "Die Aufnahme ist angehalten."
      assert Announcement.text_for_pause(false) == "Die Aufnahme läuft wieder."
    end

    test "sie sagen den Zustand, nicht die Bedienung" do
      # #1032 hat die Redezeit einer Sitzung von 65 auf rund 24 Sekunden
      # gekürzt. Eine Ansage, die erklärt statt zu melden, macht das zunichte.
      for text <- [Announcement.text_for_pause(true), Announcement.text_for_pause(false)] do
        assert String.length(text) < 40
        refute text =~ "Knopf"
        refute text =~ "klick"
      end
    end

    test "die Ansage reiht sich in die bestehende Warteschlange ein" do
      q = AnnounceQueue.push(AnnounceQueue.new(), {:pause, true})
      assert {:pause, true} in q.items
    end
  end

  describe "die Sperre sitzt am Paket, nicht am Wegschreiben" do
    test "der Paket-Pfad prüft den Pausen-Zustand" do
      # Das Ticket ist an dieser Stelle ausdrücklich: verworfen statt
      # gepuffert. Sonst läge das Pausengespräch minutenlang im Speicher, und
      # ein Absturz oder ein Flush dazwischen schriebe genau das weg.
      [_, paket_pfad] = String.split(@session, "def handle_cast({:packet", parts: 2)
      rumpf = String.slice(paket_pfad, 0, 2500)

      assert rumpf =~ "state.pausiert?",
             "Der Paket-Pfad kennt den Pausen-Zustand nicht — dann puffert der Bot weiter (#1058)."
    end

    test "das Zustandsfeld ist im initialen Aufbau angelegt" do
      # Sonst wirft die Map-Update-Syntax einen KeyError, der Prozess stirbt,
      # `restart: :transient` startet ihn neu — die Endlos-Ansage aus #1002.
      # `voice_session_state_test.exs` prüft das allgemein; hier steht, warum
      # es gerade für dieses Feld zählt.
      assert @session =~ "Map.put(:pausiert?, false)"
    end
  end

  describe "Anbindung an den Aufnahme-Zustand" do
    test "der Ereignis-Name kommt aus Shared.Events, nicht als Literal" do
      assert @session =~ "@recording_state_kind Shared.Events.recording_state_changed()"
    end

    test "fremde Ereignisse werden STILL verworfen" do
      # Das Abo liefert jedes angewendete Ereignis, und der Catch-all unten
      # schreibt eine Logger.warning. Ohne diese Klausel würde jeder
      # Mitschnitt das Log fluten.
      assert @session =~ "def handle_info({:applied, _}, state), do: {:noreply, state}"
    end

    test "die Klauseln stehen VOR dem Catch-all" do
      # #1009-Lehre: eine Klausel hinter dem Catch-all matcht nie, und das
      # Feature ist still tot. Genau das ist hier schon einmal passiert.
      applied = :binary.match(@session, "def handle_info({:applied,") |> elem(0)
      catchall = :binary.match(@session, "def handle_info(msg, state) do") |> elem(0)

      assert applied < catchall,
             "Die :applied-Klauseln stehen hinter dem Catch-all — sie matchen nie."
    end

    test "nur die eigene Sitzung schaltet um" do
      # Auf einem Worker können mehrere Sitzungen laufen; ein Pausieren in
      # Kampagne A darf die Aufnahme in B nicht anhalten.
      assert @session =~ ~s|payload["session_id"] == state.session_id|
    end
  end

  describe "Zeitachse" do
    test "beim Fortsetzen beginnt ein frisches Fenster" do
      # Ohne das trüge der erste Clip nach der Pause die ganze Pausenlänge als
      # führende Stille: `FrameBuffer.rebase/2` füllt von `window_start_ms` an
      # auf, und das läge sonst noch vor der Pause.
      assert @session =~ "window_start_ms: elapsed_ms(state)"
    end

    test "beim Anhalten wird das laufende Fenster noch weggeschrieben" do
      # Alles bis zum Pausenbeginn ist gedeckte Aufnahme. Es im Puffer liegen
      # zu lassen hiesse, es bei einem Absturz zu verlieren.
      [_, nach] = String.split(@session, ~s|zustand_wechseln(state, "paused")|, parts: 2)
      assert String.slice(nach, 0, 600) =~ "Flush.window()"
    end
  end
end
