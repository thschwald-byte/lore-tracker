defmodule Worker.PipelineFortschrittTest do
  @moduledoc """
  Issue #1122: das Lauf-Gedächtnis. Geprüft wird, was die Anzeige braucht und
  was ihr sonst still danebengeht.
  """
  use ExUnit.Case, async: false

  alias Worker.Recording.Pipeline.Fortschritt

  @sid "sess-fortschritt-1122"
  @ctx %{run_id: "run-1", session_id: @sid, campaign_id: "camp-1122"}

  setup do
    # Eigene Instanz je Test statt der aus dem Supervisor-Tree: der startet in
    # der Testumgebung nur mit vorhandenem Pairing, und ein geteilter Prozess
    # würde die Läufe der Tests vermischen.
    start_supervised!(Fortschritt)
    Fortschritt.lauf_start(@ctx)
    :ok
  end

  defp stand do
    # Casts sind asynchron — ein Call auf denselben Prozess serialisiert dahinter.
    Fortschritt.stand(@sid)
  end

  defp stufe(stand, name), do: Enum.find(stand["stufen"], &(&1["name"] == name))

  test "kennt alle Stufen, auch die noch nicht gelaufenen" do
    s = stand()

    assert length(s["stufen"]) == Shared.PipelineStufen.anzahl()
    assert Enum.all?(s["stufen"], &(&1["status"] == "offen"))
    assert s["run_id"] == "run-1"
  end

  test "zählt Einheiten als Menge — Doppelmeldung erhöht nicht" do
    Fortschritt.gesamt(@ctx, "extract", 7)
    Fortschritt.fertig(@ctx, "extract", 3)
    Fortschritt.fertig(@ctx, "extract", 3)
    Fortschritt.fertig(@ctx, "extract", 5)

    assert %{"fertig" => 2, "gesamt" => 7} = stufe(stand(), "extract")
  end

  test "Reihenfolge der Einheiten ist egal — verteilt kommt 5 vor 2" do
    Fortschritt.gesamt(@ctx, "extract", 7)
    for id <- [5, 2, 7], do: Fortschritt.fertig(@ctx, "extract", id)

    assert %{"fertig" => 3} = stufe(stand(), "extract")
  end

  test "der Abschluss ist autoritativ: eine verlorene Meldung lässt nichts bei 6/7 stehen" do
    Fortschritt.gesamt(@ctx, "extract", 7)
    for id <- 1..6, do: Fortschritt.fertig(@ctx, "extract", id)
    # Einheit 7 meldet nie (gedrosselt weggefallen / Prozess weg).
    Fortschritt.stufe(@ctx, "extract", "ended")

    assert %{"fertig" => 7, "gesamt" => 7, "status" => "fertig"} = stufe(stand(), "extract")
  end

  test "ein Fehlschlag füllt NICHT auf — er hat nicht alles geschafft" do
    Fortschritt.gesamt(@ctx, "jack_verifikation", 100)
    Fortschritt.fertig(@ctx, "jack_verifikation", 1)
    Fortschritt.stufe(@ctx, "jack_verifikation", "failed")

    assert %{"fertig" => 1, "status" => "fehler"} = stufe(stand(), "jack_verifikation")
  end

  describe "Zählabschnitte (J4, #1207)" do
    test "ein neuer Durchgang beginnt die Zählung neu und nennt sich" do
      Fortschritt.stufe(@ctx, "jack_verifikation", "started")
      Fortschritt.abschnitt(@ctx, "jack_verifikation", 18, 1)
      for n <- 0..17, do: Fortschritt.fertig(@ctx, "jack_verifikation", n, 1)

      assert %{"fertig" => 18, "gesamt" => 18, "durchgang" => 1} =
               stufe(stand(), "jack_verifikation")

      Fortschritt.abschnitt(@ctx, "jack_verifikation", 18, 2)
      for n <- 0..4, do: Fortschritt.fertig(@ctx, "jack_verifikation", n, 2)

      assert %{"fertig" => 5, "gesamt" => 18, "durchgang" => 2, "status" => "laeuft"} =
               stufe(stand(), "jack_verifikation")
    end

    test "ein Nachzügler aus dem vorigen Durchgang zählt nicht mit" do
      Fortschritt.abschnitt(@ctx, "jack_verifikation", 18, 2)
      Fortschritt.fertig(@ctx, "jack_verifikation", 17, 1)
      Fortschritt.fertig(@ctx, "jack_verifikation", 0, 2)

      assert %{"fertig" => 1} = stufe(stand(), "jack_verifikation")
    end

    test "nach dem Abschluss zählt nichts mehr — 18/18 bleibt 18/18" do
      Fortschritt.abschnitt(@ctx, "extract", 18, nil)
      Fortschritt.stufe(@ctx, "extract", "ended")
      # Blocknummer 0 liegt außerhalb der aufgefüllten Menge 1..18.
      Fortschritt.fertig(@ctx, "extract", 0)
      Fortschritt.abschnitt(@ctx, "extract", 18, nil)

      assert %{"fertig" => 18, "gesamt" => 18, "status" => "fertig"} = stufe(stand(), "extract")
    end

    test "andere Stufen tragen keinen Durchgang" do
      Fortschritt.gesamt(@ctx, "smooth", 3)

      assert %{"durchgang" => nil} = stufe(stand(), "smooth")
    end

    test "eine gescheiterte Verifikation lässt den Lauf offen — Resümee und Epos kommen noch" do
      Fortschritt.stufe(@ctx, "jack_verifikation", "failed")

      assert stand()["aktiv"]
    end

    test "ein gescheitertes Gedächtnis beendet ihn" do
      Fortschritt.stufe(@ctx, "jack_gedaechtnis", "failed")

      refute stand()["aktiv"]
    end

    test "noch N Iterationen: nur die Verifikation läuft, der Lauf endet trotzdem" do
      # Glättung, Gedächtnis und Extraktion bleiben offen — das Lauf-Ende hängt
      # an der letzten Stufe, nicht daran, dass alle gelaufen sind.
      for st <- ["jack_verifikation", "render", "timeline", "render_epos"] do
        Fortschritt.stufe(@ctx, st, "started")
        Fortschritt.stufe(@ctx, st, "ended")
      end

      assert stand()["aktiv"]

      Fortschritt.stufe(@ctx, "render_arc_progressions", "ended")
      s = stand()

      refute s["aktiv"]
      assert %{"status" => "offen"} = stufe(s, "extract")
    end
  end

  test "ohne bekannte Gesamtzahl wird keine erfunden" do
    Fortschritt.fertig(@ctx, "smooth", "block-a")
    Fortschritt.stufe(@ctx, "smooth", "ended")

    assert %{"fertig" => 1, "gesamt" => nil} = stufe(stand(), "smooth")
  end

  test "Meldung ohne vorherigen lauf_start geht nicht verloren" do
    sid = "sess-ohne-start-1122"
    Fortschritt.gesamt(%{session_id: sid}, "jack_verifikation", 4)

    assert %{"gesamt" => 4} = Fortschritt.stand(sid) |> stufe("jack_verifikation")
  end

  test "unbekannte Session liefert nil statt eines leeren Gerüsts" do
    refute Fortschritt.stand("gibt-es-nicht")
  end

  describe "Lauf-Ende (abgeleitet, Issue #1122)" do
    test "frischer Lauf ist aktiv" do
      assert stand()["aktiv"]
    end

    test "die letzte Stufe beendet den Lauf" do
      Fortschritt.stufe(@ctx, "render_arc_progressions", "ended")

      refute stand()["aktiv"]
    end

    test "eine gescheiterte PFLICHT-Stufe beendet ihn ebenfalls — es kommt nichts mehr" do
      Fortschritt.stufe(@ctx, "extract", "failed")

      refute stand()["aktiv"]
    end

    test "ein gescheitertes best-effort-Geschwister lässt den Lauf offen" do
      # Chronik und Epos dürfen scheitern, ohne den Lauf zu beenden — die
      # Bogen-Progressionen kommen danach noch.
      Fortschritt.stufe(@ctx, "timeline", "failed")

      assert stand()["aktiv"]
    end
  end

  describe "Snapshot-Scope campaign_pipeline (Issue #1122)" do
    test "Nicht-Mitglieder bekommen den Stand nicht" do
      scope = %{
        "kind" => "campaign_pipeline",
        "id" => "camp-1122",
        "viewer_discord_id" => "fremder-999"
      }

      assert %{"forbidden" => true} = Worker.Repo.snapshot(scope)
    end
  end
end
