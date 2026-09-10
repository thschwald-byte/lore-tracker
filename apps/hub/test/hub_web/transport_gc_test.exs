defmodule HubWeb.TransportGcTest do
  @moduledoc """
  Issue #1198 (OOM): der Verbindungsprozess eines Tabs räumt nach großen
  Antworten auf (`HubWeb.TransportGc`, `fullsweep_after: 0` im Endpoint).

  Auf der Teststage gemessen hielt dieser Prozess nach dem Laden von seattleV4
  29–32 MB reinen Müll. Dass die Verdrahtung fehlt, erzeugt keinen Fehler —
  nur einen Hub, der je Tab 30 MB mehr braucht. Deshalb neben dem Verhalten
  auch Quelltext-Wächter.
  """
  use ExUnit.Case, async: true

  alias HubWeb.TransportGc

  defp sock(transport_pid, private \\ %{}),
    do: %Phoenix.LiveView.Socket{transport_pid: transport_pid, private: private}

  describe "nach_render/2" do
    test "bittet den Verbindungsprozess verzögert ums Aufräumen" do
      TransportGc.nach_render(sock(self()), 0)

      # Nicht sofort — der Diff geht erst NACH after_render an den Prozess.
      refute_received :garbage_collect
      assert_receive :garbage_collect, TransportGc.verzoegerung_ms() + 500
    end

    test "höchstens eine Bitte je Verzögerung" do
      s = TransportGc.nach_render(sock(self()), 0)
      s = TransportGc.nach_render(s, 10)
      _ = TransportGc.nach_render(s, TransportGc.verzoegerung_ms() - 1)

      assert_receive :garbage_collect, TransportGc.verzoegerung_ms() + 500
      refute_receive :garbage_collect, 300
    end

    test "nach Ablauf der Sekunde wieder eine" do
      s = TransportGc.nach_render(sock(self()), 0)
      _ = TransportGc.nach_render(s, TransportGc.verzoegerung_ms())

      assert_receive :garbage_collect, TransportGc.verzoegerung_ms() + 500
      assert_receive :garbage_collect, TransportGc.verzoegerung_ms() + 500
    end

    test "ohne Verbindung (statischer Render) passiert nichts" do
      s = sock(nil)
      assert TransportGc.nach_render(s, 0) == s
      refute_receive :garbage_collect, 50
    end
  end

  describe "Quelltext-Wächter" do
    defp quelle(rel), do: File.read!(Path.join([__DIR__, "../..", rel]))

    test "beide Sockets räumen gründlich auf (fullsweep_after: 0)" do
      endpoint = quelle("lib/hub_web/endpoint.ex")

      for pfad <- ["/live", "/worker_socket"] do
        [block] =
          Regex.run(~r/socket\("#{Regex.escape(pfad)}".*?\n  \)/s, endpoint)

        assert block =~ "fullsweep_after: 0",
               "#{pfad}: ohne fullsweep bleibt der Müll großer Frames im alten Heap (#1198)"
      end
    end

    test "der Haken hängt an der LiveView-Sitzung" do
      assert quelle("lib/hub_web/router.ex") =~ "HubWeb.TransportGc"
    end

    test "der Worker-Kanal räumt nach Snapshot-Antworten auf" do
      [klausel] =
        Regex.run(
          ~r/def handle_in\("snapshot_response".*?\n  end\n/s,
          quelle("lib/hub_web/channels/worker_channel.ex")
        )

      assert klausel =~ "send(socket.transport_pid, :garbage_collect)",
             "die großen Antworten des Workers bleiben sonst als Müll im Verbindungsprozess"
    end
  end
end
