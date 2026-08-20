defmodule Worker.Recording.CampaignReplayProgressTest do
  @moduledoc """
  Issue #1062: der Wächter des Kampagnen-Replays misst **Stille**, nicht
  Gesamtdauer.

  Vorher galt „Session seit 30 min nicht fertig ⇒ abbrechen". Eine echte
  Session braucht 80–110 min (gemessen 81), der Replay brach damit
  *strukturell* nach der ersten Session ab — und sah dabei wie Erfolg aus.

  Der Wächter ist Avalanche-Schutz: er soll verhindern, dass sich
  `Pipeline.running` aufstapelt. Die dafür richtige Frage ist „hängt die
  Pipeline?", nicht „wie lange läuft sie schon?". Genau diese Unterscheidung
  prüfen die Tests hier — mit kurzen Fristen statt echter Modell-Laufzeit.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.CampaignReplay

  @sid "sess-1"
  @cid "camp-1"

  defp stufe(stage, status \\ "started", cid \\ @cid) do
    {:pipeline_stage, %{"campaign_id" => cid, "stage" => stage, "status" => status}}
  end

  describe "Fortschritt hält den Wächter am Leben" do
    test "Statusmeldungen über die Frist hinaus brechen NICHT ab" do
      # Frist 250 ms, Meldungen alle 50 ms, Gesamtdauer ~500 ms. Ohne das
      # Zurücksetzen wäre bei 250 ms Schluss — und ohne das Abonnement auf
      # `pipeline_status` (der Zustand vor #1062) käme gar keine Meldung an.
      #
      # Das Verhältnis 5:1 zwischen Frist und Sende-Intervall ist Absicht: der
      # Test bräuchte zwar rechnerisch nur ein Intervall knapp unter der Frist,
      # aber der Sender ist ein gewöhnlicher Prozess auf einem geteilten
      # CI-Runner. Verzögert der Scheduler ein `Process.sleep/1` über die Frist
      # hinaus, bricht der Wächter zu Recht ab und der Test wäre falsch rot.
      me = self()

      Task.start_link(fn ->
        Enum.each(["smooth", "extract", "verify", "render", "timeline"], fn st ->
          Process.sleep(50)
          send(me, stufe(st))
        end)

        Process.sleep(50)
        send(me, {:pipeline_session_done, @sid})
      end)

      assert :ok = CampaignReplay.wait_done(@sid, @cid, 250, nil)
    end

    test "eine fremde Session macht den Wächter nicht taub" do
      me = self()

      Task.start_link(fn ->
        Process.sleep(30)
        send(me, {:pipeline_session_done, "andere-session"})
        Process.sleep(30)
        send(me, {:pipeline_session_done, @sid})
      end)

      # Die Frist ist hier bewusst weit: sie sichert nur ab, dass der Wächter
      # nicht vor der zweiten Meldung abbricht. Bei Erfolg endet der Test nach
      # ~60 ms, eine weite Frist kostet also nichts und nimmt dem Test den
      # Scheduler-Jitter als Fehlerquelle.
      assert :ok = CampaignReplay.wait_done(@sid, @cid, 2_000, nil)
    end
  end

  describe "Stille bricht weiterhin ab (der Avalanche-Schutz bleibt scharf)" do
    test "ohne jede Meldung: Abbruch, Stufe unbekannt" do
      assert {:error, {:stage_timeout, nil}} = CampaignReplay.wait_done(@sid, @cid, 30, nil)
    end

    test "der Abbruch nennt die zuletzt gesehene Stufe" do
      # Die alte Meldung behauptete pauschal „vermutlich Stage 3"; real war es
      # Stage 1.1 (Gap-Fill). Die Stufe wird jetzt mitgeführt statt geraten.
      send(self(), stufe("smooth", "ended"))

      assert {:error, {:stage_timeout, "smooth (ended)"}} =
               CampaignReplay.wait_done(@sid, @cid, 30, nil)
    end

    # Diese beiden Tests messen die DAUER, nicht nur das Ergebnis. Der Grund
    # ist ein Fehler, den die erste Fassung dieses Tests durchgehen liess: wer
    # bei jeder Nachricht rekursiv mit der vollen Frist erneut eintritt, setzt
    # die Uhr auch für Nachrichten zurück, die gar kein Fortschritt sind. Der
    # Lauf brach am Ende trotzdem ab — nur eben viel später, und der
    # Avalanche-Schutz wäre still ausgehebelt gewesen. Auf das blosse
    # `{:error, …}` zu prüfen, hätte das nie gezeigt.
    #
    # Issue #1120: die Trennschärfe darf dabei aber nicht an einer knappen
    # Wall-Clock-Schranke hängen. Die erste Fassung schickte zehn Nachrichten
    # und verlangte den Abbruch in unter 150 ms bei 60 ms Frist — 90 ms Puffer
    # für Scheduler- und Timer-Jitter. Auf dem geteilten CI-Runner reichte das
    # nicht (Lauf #925: 424 ms), und die Fehlermeldung behauptete dabei einen
    # Defekt am Avalanche-Schutz, den es nicht gab: `letzte_stufe` war `nil`,
    # und erneuert wird die Frist in `schleife/5` nur zusammen mit einer Stufe.
    #
    # Die Trennschärfe kommt jetzt aus dem Nachrichtenstrom selbst: er endet
    # NIE. Ohne Fristerneuerung bricht der Wächter nach der Frist ab; mit
    # Fristerneuerung kehrt `wait_done/4` überhaupt nicht mehr zurück, und der
    # Test läuft in den ExUnit-Timeout statt in einen Millisekunden-Vergleich.
    # Die Schranke bleibt als Fang für einen TEILWEISEN Bug (Frist wird nur
    # manchmal erneuert) — jetzt aber weit statt knapp.
    @spaetestens_ms 2_000

    defp dauer_bis_abbruch(nachricht, frist_ms) do
      me = self()
      Task.start_link(fn -> dauerstrom(me, nachricht) end)
      t0 = System.monotonic_time(:millisecond)
      ergebnis = CampaignReplay.wait_done(@sid, @cid, frist_ms, nil)
      {ergebnis, System.monotonic_time(:millisecond) - t0}
    end

    # Endlos, mit Absicht. Der Task ist an den Testprozess gelinkt und stirbt
    # mit ihm — der Strom hört also genau dann auf, wenn der Test endet.
    defp dauerstrom(me, nachricht) do
      Process.sleep(20)
      send(me, nachricht)
      dauerstrom(me, nachricht)
    end

    test "eine Meldung einer FREMDEN Kampagne erneuert die Frist nicht" do
      {ergebnis, dauer} =
        dauer_bis_abbruch(stufe("extract", "started", "fremde-kampagne"), 60)

      assert {:error, {:stage_timeout, nil}} = ergebnis

      assert dauer < @spaetestens_ms,
             "der Abbruch kam erst nach #{dauer} ms — eine fremde Kampagne hat die " <>
               "Frist erneuert und den Avalanche-Schutz ausgehebelt"
    end

    test "der eigene Replay-Banner erneuert die Frist nicht (kein Selbstgespräch)" do
      # `notify/4` broadcastet auf denselben Topic. Zählte das als Fortschritt,
      # hielte sich der Wächter mit seiner eigenen Meldung endlos am Leben.
      {ergebnis, dauer} =
        dauer_bis_abbruch(
          {:pipeline_stage,
           %{"kind" => "campaign_replay", "campaign_id" => @cid, "status" => "session_done"}},
          60
        )

      assert {:error, {:stage_timeout, nil}} = ergebnis

      assert dauer < @spaetestens_ms,
             "der Abbruch kam erst nach #{dauer} ms — der Wächter hat sich mit seiner " <>
               "eigenen Meldung am Leben gehalten"
    end
  end
end
