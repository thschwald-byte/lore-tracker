defmodule Worker.SystemdWatchdogTest do
  @moduledoc """
  Issue #512: der systemd-Watchdog muss `READY=1` beim Start und periodisch
  `WATCHDOG=1` an den `NOTIFY_SOCKET` schicken. Test öffnet einen echten
  AF_UNIX-DGRAM-Empfänger, zeigt NOTIFY_SOCKET darauf und prüft die Datagramme.
  Ohne die systemd-Env startet der Watchdog gar nicht (`:ignore`).
  """
  use ExUnit.Case, async: false

  alias Worker.SystemdWatchdog

  setup do
    on_exit(fn ->
      System.delete_env("NOTIFY_SOCKET")
      System.delete_env("WATCHDOG_USEC")
    end)

    :ok
  end

  test "ohne NOTIFY_SOCKET startet der Watchdog nicht (:ignore)" do
    System.delete_env("NOTIFY_SOCKET")
    assert SystemdWatchdog.start_link([]) == :ignore
  end

  test "sendet READY=1 sofort und periodisch WATCHDOG=1 an den Notify-Socket" do
    # Eindeutiger Socket-Pfad im tmp-Dir (AF_UNIX-Pfadlimit ~108 Zeichen).
    path = Path.join(System.tmp_dir!(), "lore-wd-test-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, recv} = :socket.open(:local, :dgram)
    :ok = :socket.bind(recv, %{family: :local, path: path})

    System.put_env("NOTIFY_SOCKET", path)
    # WATCHDOG_USEC=2_000_000 → Ping-Intervall 1000ms (Hälfte, min 1000).
    System.put_env("WATCHDOG_USEC", "2000000")

    {:ok, pid} = SystemdWatchdog.start_link([])

    assert recv_payload(recv, 1000) == "READY=1"
    # Erster periodischer Ping nach ~1s.
    assert recv_payload(recv, 2000) == "WATCHDOG=1"

    GenServer.stop(pid)
    :socket.close(recv)
    File.rm(path)
  end

  defp recv_payload(sock, timeout_ms) do
    case :socket.recvfrom(sock, [], timeout_ms) do
      {:ok, {_source, data}} -> :erlang.iolist_to_binary(data)
      {:ok, data} when is_binary(data) -> data
      other -> flunk("kein Datagramm: #{inspect(other)}")
    end
  end
end
