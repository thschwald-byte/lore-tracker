defmodule HubWeb.TransportGcTest do
  @moduledoc """
  Issue #1198 (OOM): der Verbindungsprozess eines Tabs räumt nach großen
  Antworten auf (`HubWeb.TransportGc`, `fullsweep_after: 0` im Endpoint).

  Auf der Teststage gemessen hielt dieser Prozess nach dem Laden von seattleV4
  29–32 MB reinen Müll. Dass die Verdrahtung fehlt, erzeugt keinen Fehler —
  nur einen Hub, der je Tab 30 MB mehr braucht. Deshalb neben dem Verhalten
  auch Quelltext-Wächter. Dass eine LiveView die Verzögerung überlebt, hält
  `transport_gc_liveview_test.exs` fest.
  """
  use ExUnit.Case, async: true

  alias HubWeb.TransportGc

  defp sock(transport_pid, private \\ %{}),
    do: %Phoenix.LiveView.Socket{transport_pid: transport_pid, private: private}

  # Ein Prozess, der viel Müll erzeugt und danach ruht — wie ein
  # Verbindungsprozess nach einem großen Frame. Die Liste muss wirklich
  # entstehen und benutzt werden: ein `for` ohne verwendetes Ergebnis übersetzt
  # Elixir in eine Schleife, die gar keine Liste baut (erster Wurf: 5,6 KB).
  #
  # Der Prozess meldet sich, wenn die Liste steht — keine feste Wartezeit: unter
  # `cover` in CI war er nach 50 ms noch nicht fertig (CI-Lauf 1027).
  defp muell_prozess do
    test = self()

    pid =
      spawn(fn ->
        daten = Enum.map(1..200_000, &{&1, Integer.to_string(&1)})
        laenge = length(daten)
        send(test, {:bereit, self()})

        receive do
          {:laenge, von} -> send(von, laenge)
          :stop -> :ok
        end
      end)

    assert_receive {:bereit, ^pid}, 10_000
    pid
  end

  defp speicher(pid), do: elem(Process.info(pid, :memory), 1)

  describe "aufraeumen/2" do
    test "räumt einen ruhenden Prozess nach der Verzögerung auf" do
      pid = muell_prozess()
      vorher = speicher(pid)
      assert vorher > 5_000_000, "der Testprozess hat keinen Müll erzeugt (#{vorher} B)"

      :ok = TransportGc.aufraeumen(pid, 300)
      assert speicher(pid) > div(vorher, 2), "zu früh aufgeräumt"

      Process.sleep(700)
      assert speicher(pid) < div(vorher, 10)
      send(pid, :stop)
    end

    test "schickt dem Verbindungsprozess keine Nachricht" do
      # Der Test-Client von LiveView kennt `:garbage_collect` nicht und stürzt
      # daran ab (PR #1201, CI-Lauf 1026).
      :ok = TransportGc.aufraeumen(self(), 0)
      refute_receive _, 200
    end

    test "ein inzwischen toter Prozess ist kein Fehler" do
      pid = spawn(fn -> :ok end)
      Process.sleep(20)
      assert :ok = TransportGc.aufraeumen(pid, 0)
    end
  end

  describe "nach_render/2" do
    test "plant das Aufräumen und merkt sich die Sperrfrist" do
      s = TransportGc.nach_render(sock(self()), 0)
      assert s.private[:transport_gc_bis] == TransportGc.verzoegerung_ms()
    end

    test "innerhalb der Sperrfrist wird nichts neu geplant" do
      s = TransportGc.nach_render(sock(self()), 0)
      assert TransportGc.nach_render(s, TransportGc.verzoegerung_ms() - 1) == s
    end

    test "nach der Sperrfrist wird wieder geplant" do
      s = TransportGc.nach_render(sock(self()), 0)
      s2 = TransportGc.nach_render(s, TransportGc.verzoegerung_ms())
      assert s2.private[:transport_gc_bis] == 2 * TransportGc.verzoegerung_ms()
    end

    test "räumt den Verbindungsprozess wirklich auf" do
      pid = muell_prozess()
      vorher = speicher(pid)
      _ = TransportGc.nach_render(sock(pid), 0)

      Process.sleep(TransportGc.verzoegerung_ms() + 300)
      assert speicher(pid) < div(vorher, 10)
      send(pid, :stop)
    end

    test "ohne Verbindung (statischer Render) passiert nichts" do
      s = sock(nil)
      assert TransportGc.nach_render(s, 0) == s
    end
  end

  describe "Quelltext-Wächter" do
    defp quelle(rel), do: File.read!(Path.join([__DIR__, "../..", rel]))

    test "beide Sockets räumen gründlich auf (fullsweep_after: 0)" do
      endpoint = quelle("lib/hub_web/endpoint.ex")

      for pfad <- ["/live", "/worker_socket"] do
        [block] = Regex.run(~r/socket\("#{Regex.escape(pfad)}".*?\n  \)/s, endpoint)

        assert block =~ "fullsweep_after: 0",
               "#{pfad}: ohne fullsweep bleibt der Müll großer Frames im alten Heap (#1198)"
      end
    end

    test "der Haken hängt an der LiveView-Sitzung" do
      assert quelle("lib/hub_web/router.ex") =~ "HubWeb.TransportGc"
    end

    test "keine Nachricht an Verbindungsprozesse" do
      for datei <- ["lib/hub_web/transport_gc.ex", "lib/hub_web/channels/worker_channel.ex"] do
        refute quelle(datei) =~
                 ~r/send(_after)?\((socket\.)?transport_pid|send_after\(pid, :garbage_collect/,
               "#{datei}: eine Nachricht an den Verbindungsprozess bringt den LiveView-Test-Client zum Absturz (PR #1201)"
      end
    end

    test "der Worker-Kanal räumt nach Snapshot-Antworten auf" do
      [klausel] =
        Regex.run(
          ~r/def handle_in\("snapshot_response".*?\n  end\n/s,
          quelle("lib/hub_web/channels/worker_channel.ex")
        )

      assert klausel =~ "TransportGc.aufraeumen(socket.transport_pid",
             "die großen Antworten des Workers bleiben sonst als Müll im Verbindungsprozess"
    end
  end
end
