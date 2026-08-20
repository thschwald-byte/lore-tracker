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
    Fortschritt.gesamt(@ctx, "verify", 100)
    Fortschritt.fertig(@ctx, "verify", 1)
    Fortschritt.stufe(@ctx, "verify", "failed")

    assert %{"fertig" => 1, "status" => "fehler"} = stufe(stand(), "verify")
  end

  test "ohne bekannte Gesamtzahl wird keine erfunden" do
    Fortschritt.fertig(@ctx, "smooth", "block-a")
    Fortschritt.stufe(@ctx, "smooth", "ended")

    assert %{"fertig" => 1, "gesamt" => nil} = stufe(stand(), "smooth")
  end

  test "Meldung ohne vorherigen lauf_start geht nicht verloren" do
    sid = "sess-ohne-start-1122"
    Fortschritt.gesamt(%{session_id: sid}, "verify", 4)

    assert %{"gesamt" => 4} = Fortschritt.stand(sid) |> stufe("verify")
  end

  test "unbekannte Session liefert nil statt eines leeren Gerüsts" do
    refute Fortschritt.stand("gibt-es-nicht")
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
