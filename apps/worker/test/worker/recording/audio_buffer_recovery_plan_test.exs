defmodule Worker.Recording.AudioBufferRecoveryPlanTest do
  @moduledoc """
  Issue #1055: der Recovery-Scan läuft jetzt periodisch, nicht mehr nur beim
  Boot. Damit wird eine Frage sicherheitskritisch, die vorher trivial war —
  welche Verzeichnisse er anfassen darf.

  Beim Boot ist `state.sessions` leer, also ist alles im `audio_dir` verwaist.
  Periodisch liegt dort auch die **laufende** Aufnahme. Ein Scan ohne diese
  Unterscheidung würde sie mitten im Betrieb ein zweites Mal transkribieren und
  ihr ein `SessionEnded` unterschieben.

  `Recovery.plan/4` ist pur, damit genau diese Reihenfolge ohne Dateisystem und
  ohne GenServer prüfbar ist.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.AudioBuffer.Recovery

  defp plan(dirs, opts \\ []) do
    Recovery.plan(
      dirs,
      Keyword.get(opts, :open, []),
      Keyword.get(opts, :pending, []),
      Keyword.get(opts, :attempts, %{})
    )
  end

  describe "die gefährliche Kante: aktive Sitzungen" do
    test "eine offene Session wird NIE aufgegriffen" do
      p = plan([{"live", 2}], open: ["live"])

      assert p.recover == []
      assert p.aktiv == ["live"]
    end

    test "eine Session mit lebendem Transcribe-Task wird NIE aufgegriffen" do
      # `GpuQueue.run/2` blockiert den Task, solange der Job wartet ODER läuft —
      # `pending_transcribes` deckt damit beide Phasen ab. Ohne diesen Zweig
      # liefe dieselbe Session doppelt durch Whisper.
      p = plan([{"queued", 1}], pending: ["queued"])

      assert p.recover == []
      assert p.aktiv == ["queued"]
    end

    test "aktiv schlägt den Versuchsdeckel — kein Aufgeben-Eintrag für Laufendes" do
      p = plan([{"live", 1}], open: ["live"], attempts: %{"live" => 99})

      assert p.aktiv == ["live"]
      assert p.aufgegeben == []
    end

    test "aktiv schlägt auch die Leer-Klasse" do
      # Eine frisch geöffnete Session hat noch keine .webm geschrieben.
      p = plan([{"frisch", 0}], open: ["frisch"])

      assert p.aktiv == ["frisch"]
      assert p.leer == []
    end
  end

  describe "verwaiste Verzeichnisse" do
    test "ein verwaistes Verzeichnis mit Audio wird aufgegriffen" do
      assert %{recover: ["tot"]} = plan([{"tot", 3}])
    end

    test "ohne .webm gibt es nichts zu retten — eigene Klasse, kein Fehlschlag" do
      # Ein Restverzeichnis darf nicht über den Versuchsdeckel als
      # „Transkription aufgegeben" in /admin/errors landen.
      p = plan([{"leer", 0}])

      assert p.leer == ["leer"]
      assert p.recover == []
      assert p.aufgegeben == []
    end

    test "mehrere Verzeichnisse werden getrennt einsortiert" do
      p =
        plan(
          [{"live", 1}, {"tot", 2}, {"leer", 0}, {"hoffnungslos", 1}],
          open: ["live"],
          attempts: %{"hoffnungslos" => 3}
        )

      assert p.aktiv == ["live"]
      assert p.recover == ["tot"]
      assert p.leer == ["leer"]
      assert p.aufgegeben == ["hoffnungslos"]
    end
  end

  describe "Versuchsdeckel" do
    test "unter dem Deckel wird weiter versucht" do
      assert %{recover: ["x"]} = plan([{"x", 1}], attempts: %{"x" => 2})
    end

    test "am Deckel wird aufgegeben" do
      p = plan([{"x", 1}], attempts: %{"x" => 3})

      assert p.aufgegeben == ["x"]
      assert p.recover == []
    end

    test "über dem Deckel bleibt es beim Aufgeben" do
      assert %{aufgegeben: ["x"]} = plan([{"x", 1}], attempts: %{"x" => 17})
    end
  end

  test "leere Eingabe liefert alle vier Klassen leer, nicht eine unvollständige Map" do
    assert plan([]) == %{recover: [], aktiv: [], leer: [], aufgegeben: []}
  end
end
