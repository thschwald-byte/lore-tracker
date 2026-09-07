defmodule Hub.MemoryReporterMarkeTest do
  @moduledoc """
  Issue #1169: die Messzeile zu einem benannten Ereignis.

  **Warum das Logger-Level im Setup auf `:info` geht:** die Testumgebung loggt
  ab `:warning` (config/test.exs). Das ist das PRIMÄR-Level — eine Info-Zeile
  wird dann gar nicht erst erzeugt, und ein `level:`-Argument am `capture_log`
  ändert daran nichts (es filtert nur, was ankommt). Muster aus
  `telemetry_test.exs`; zurückgesetzt im `on_exit`, sonst reden alle folgenden
  Tests plötzlich.

  **Warum Logger.flush/0 im Test Pflicht ist:** `marke/2` ist ein cast, die
  Zeile entsteht im Reporter-Prozess. `capture_log` fängt nur, was bis zu
  seinem Ende geschrieben wurde — ohne flush ist das Rennen genau die
  Flake-Klasse aus #1157 (`capture_log` verlor Logs aus dem Materializer).

  Die beiden Einbaustellen werden zusätzlich per Quelltext gehalten: fällt
  eine weg, misst der Hub beim Mount wieder nichts, und niemand merkt es —
  nichts wird rot, nur die Zeile fehlt beim nächsten Kill.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hub.MemoryReporter

  setup do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)
    :ok
  end

  describe "marke/2" do
    test "schreibt eine hub.memory-Zeile mit der Marke und den Zusatzfeldern" do
      log =
        capture_log(fn ->
          MemoryReporter.marke("test_marke", kind: "campaign", snapshot_words: 12_345)
          # cast → anderer Prozess → auf den Log warten, nicht auf den Return
          :sys.get_state(MemoryReporter)
          Logger.flush()
        end)

      assert log =~ "event=hub.memory"
      assert log =~ "marke=test_marke"
      assert log =~ "kind=campaign"
      assert log =~ "snapshot_words=12345"
      # die Grundfelder reisen mit — sonst ist die Marke ohne Bezug
      assert log =~ ~r/total_mb=\d+/
      assert log =~ ~r/live_views=\d+/
    end

    test "kommt ohne Zusatzfelder aus" do
      log =
        capture_log(fn ->
          MemoryReporter.marke("nackt")
          :sys.get_state(MemoryReporter)
          Logger.flush()
        end)

      assert log =~ "marke=nackt"
    end

    test "blockiert den Aufrufer nicht — es ist ein cast" do
      # Ein Call könnte den Mount um die Messdauer verzögern oder — bei totem
      # Reporter — die LiveView mitreissen. Der Rückgabewert ist sofort da.
      assert MemoryReporter.marke("sofort") == :ok
    end
  end

  describe "die Einbaustellen existieren (Quelltext-Wächter)" do
    defp quelle(p), do: File.read!(Path.join(__DIR__, "../../" <> p))

    test "mount_start vor dem Voll-Read" do
      assert quelle("lib/hub_web/live/campaign_live/snapshot.ex") =~
               ~r/MemoryReporter\.marke\("mount_start"/,
             "snapshot.ex: die Zeile VOR dem Read fehlt (#1169) — sie ist die, die auch bei einem Kill mitten im Mount noch im Log steht"
    end

    test "mount_read_ok nach dem Voll-Read" do
      assert quelle("lib/hub_web/live/campaign_live.ex") =~
               ~r/MemoryReporter\.marke\("mount_read_ok"/,
             "campaign_live.ex: die Zeile NACH dem Read fehlt (#1169)"
    end

    test "die Snapshot-Grösse wird ohne Kopie gemessen" do
      # term_to_binary legte eine zweite Kopie des grössten Terms an, den der
      # Hub kennt — im Moment, in dem der Speicher am knappsten ist.
      src = quelle("lib/hub_web/live/campaign_live.ex")
      assert src =~ ~r/:erts_debug\.size\(result\)/

      refute src =~ ~r/term_to_binary\(result\)/,
             "keine Kopie des Snapshots für die Messung (#1169)"
    end
  end
end
