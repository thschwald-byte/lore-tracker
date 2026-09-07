defmodule Hub.MemoryReporterMarkeTest do
  @moduledoc """
  Issue #1169: die Messzeile zu einem benannten Ereignis.

  **Warum das Logger-Level im Setup auf `:info` geht:** die Testumgebung loggt
  ab `:warning` (config/test.exs). Das ist das PRIMÄR-Level — eine Info-Zeile
  wird dann gar nicht erst erzeugt, und ein `level:`-Argument am `capture_log`
  ändert daran nichts (es filtert nur, was ankommt). Muster aus
  `telemetry_test.exs`; zurückgesetzt im `on_exit`, sonst reden alle folgenden
  Tests plötzlich.

  **Warum der Callback direkt im Testprozess läuft:** `marke/2` ist ein cast,
  die Zeile entstünde im Reporter-Prozess — und #1171 zeigt, dass ein Log aus
  einem FREMDEN Prozess trotz garantierter Reihenfolge und `Logger.flush/0`
  im Capture fehlen kann (Mechanismus offen). `handle_cast/2` mit dem echten
  Zustand des laufenden Reporters aufzurufen erzeugt die Zeile im
  Testprozess: kein Rennen, kein Flush. Dass der cast ankommt, prüft der
  „blockiert nicht"-Test daneben.

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
    # Zeile im Testprozess erzeugen (s. Moduledoc), mit dem echten Zustand des
    # laufenden Reporters — kein nachgebauter State (#1005-Klasse).
    defp marke_direkt(label, extra) do
      state = :sys.get_state(MemoryReporter)

      capture_log(fn ->
        {:noreply, _} = MemoryReporter.handle_cast({:marke, label, extra}, state)
      end)
    end

    test "schreibt eine hub.memory-Zeile mit der Marke und den Zusatzfeldern" do
      log = marke_direkt("test_marke", kind: "campaign", snapshot_words: 12_345)

      assert log =~ "event=hub.memory"
      assert log =~ "marke=test_marke"
      assert log =~ "kind=campaign"
      assert log =~ "snapshot_words=12345"
      # die Grundfelder reisen mit — sonst ist die Marke ohne Bezug
      assert log =~ ~r/total_mb=\d+/
      assert log =~ ~r/live_views=\d+/
    end

    test "kommt ohne Zusatzfelder aus" do
      assert marke_direkt("nackt", []) =~ "marke=nackt"
    end

    test "blockiert den Aufrufer nicht — es ist ein cast" do
      # Ein Call könnte den Mount um die Messdauer verzögern oder — bei totem
      # Reporter — die LiveView mitreissen. Der Rückgabewert ist sofort da.
      assert MemoryReporter.marke("sofort") == :ok
    end
  end

  describe "die Einbaustellen existieren (Quelltext-Wächter)" do
    defp quelle(p), do: File.read!(Path.join(__DIR__, "../../" <> p))

    defp snapshot_src, do: quelle("lib/hub_web/live/campaign_live/snapshot.ex")

    test "voll_read_start vor dem Voll-Read, mit Anlass" do
      assert snapshot_src() =~
               ~r/MemoryReporter\.marke\("voll_read_start", kind: [^\n]*anlass: anlass/,
             "snapshot.ex: die Zeile VOR dem Read fehlt oder trägt keinen Anlass (#1169)"
    end

    test "alle drei Anlässe sind unterscheidbar" do
      # mount_load → :mount, workers_changed → :workers_changed, :reload ist der
      # Default. Fehlt einer, sähe ein Worker-Rejoin bei 16 Tabs wie 16 Mounts aus.
      assert snapshot_src() =~ ~r/start_snapshot_load\(socket, :mount\)/

      assert quelle("lib/hub_web/live/campaign_live.ex") =~
               ~r/start_snapshot_load\(socket, :workers_changed\)/
    end

    test "voll_read_ok steht IM {:ok, snap}-Zweig, nicht vor dem case" do
      # Vor dem `case result do` gäbe es eine ok-Zeile auch für
      # {:error, :queue_timeout} — mit snapshot_words=5, wie ein kleiner
      # erfolgreicher Read (Review-Fund PR #1180).
      src = snapshot_src()

      kopf =
        src
        |> String.split("def apply_snapshot(")
        |> Enum.at(1)
        |> String.split("case result do")
        |> hd()

      refute kopf =~ "marke", "keine Messzeile vor dem case in apply_snapshot/2 (#1169)"

      ok_zweig =
        src
        |> String.split("{:ok, snap} ->")
        |> Enum.at(1)
        |> String.split("{:error, :no_worker} ->")
        |> hd()

      assert ok_zweig =~ ~r/lese_marke\(socket, "voll_read_ok"/,
             "die ok-Zeile fehlt im {:ok, snap}-Zweig (#1169)"
    end

    test "die Fehlerzweige melden voll_read_error mit Grund" do
      src = snapshot_src()

      assert length(Regex.scan(~r/lese_marke\(socket, "voll_read_error", reason:/, src)) == 2,
             "beide {:error, …}-Zweige brauchen ihre Zeile (#1169)"
    end

    test "voll_read_rendered: drei Sender, eine handle_info-Klausel, LV-Heap dabei" do
      # Die Nachricht wird erst NACH dem Render verarbeitet — nur so misst die
      # Marke den Heap, den das Render hinterlassen hat (#1181: die Spitze
      # liegt im Render, nicht im Read).
      assert snapshot_src() =~ ~r/send\(self\(\), \{:voll_read_rendered, "campaign"\}\)/

      assert quelle("lib/hub_web/live/campaign_live/updates.ex") =~
               ~r/send\(self\(\), \{:voll_read_rendered, "campaign_luecken"\}\)/

      assert quelle("lib/hub_web/live/campaign_live/glatt_fenster.ex") =~
               ~r/send\(self\(\), \{:voll_read_rendered, "campaign_luecken_slice"\}\)/

      assert quelle("lib/hub_web/live/campaign_live.ex") =~
               ~r/handle_info\(\{:voll_read_rendered, kind\}, socket\)/,
             "ohne die Klausel bringt die Nachricht die CampaignLive zum Absturz (kein Auffangzweig, #1149)"

      assert snapshot_src() =~ ~r/lv_heap_words: heap/
    end

    test "voll_read_gc: GC zwischen der Render-Marke und der zweiten Marke, LV-Kennung dabei (#1185)" do
      src = snapshot_src()

      rumpf =
        src
        |> String.split("def marke_gerendert(socket, kind) do")
        |> Enum.at(1)
        |> String.split("\n  end")
        |> hd()

      [vor, nach] = String.split(rumpf, ":erlang.garbage_collect()")

      assert vor =~ ~r/lese_marke\(socket, "voll_read_rendered"/,
             "die Render-Marke muss VOR dem GC stehen"

      assert nach =~ ~r/lese_marke\(socket, "voll_read_gc"/,
             "die zweite Marke muss NACH dem GC stehen"

      assert src =~ ~r/lv_pid: to_string\(:erlang\.pid_to_list\(self\(\)\)\)/
    end

    test "die Snapshot-Grösse wird ohne Kopie gemessen" do
      # term_to_binary legte eine zweite Kopie des grössten Terms an, den der
      # Hub kennt — im Moment, in dem der Speicher am knappsten ist.
      src = snapshot_src()
      assert src =~ ~r/:erts_debug\.size\(snap\)/

      refute src =~ ~r/term_to_binary\((snap|result)\)/,
             "keine Kopie des Snapshots für die Messung (#1169)"
    end
  end
end
