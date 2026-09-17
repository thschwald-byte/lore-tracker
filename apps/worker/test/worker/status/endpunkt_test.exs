defmodule Worker.Status.EndpunktTest do
  @moduledoc """
  Issue #1218: der Endpunkt selbst — Pfadwahl, Socket-Hygiene und ein echter
  Abruf über den Unix-Domain-Socket.

  Der Abruf läuft über `:gen_tcp` mit einer von Hand geschriebenen
  HTTP-Anfrage: Erlangs HTTP-Client kann keine Unix-Sockets, und ein Test, der
  den Endpunkt nur indirekt prüft, würde genau das übersehen, worum es hier
  geht — dass er über den Socket erreichbar ist und nicht über einen Port.
  """
  use ExUnit.Case, async: false

  alias Worker.Status.Endpunkt

  setup do
    vorher = System.get_env("LORE_STATUS_SOCKET")
    xdg = System.get_env("XDG_RUNTIME_DIR")

    on_exit(fn ->
      if vorher,
        do: System.put_env("LORE_STATUS_SOCKET", vorher),
        else: System.delete_env("LORE_STATUS_SOCKET")

      if xdg,
        do: System.put_env("XDG_RUNTIME_DIR", xdg),
        else: System.delete_env("XDG_RUNTIME_DIR")
    end)

    :ok
  end

  describe "pfad/0" do
    test "nimmt die ausdrückliche Angabe" do
      System.put_env("LORE_STATUS_SOCKET", "/tmp/eigen.sock")
      assert Endpunkt.pfad() == "/tmp/eigen.sock"
    end

    test "leitet sonst aus dem Laufzeitverzeichnis ab" do
      System.delete_env("LORE_STATUS_SOCKET")
      System.put_env("XDG_RUNTIME_DIR", "/run/user/4242")
      assert Endpunkt.pfad() == "/run/user/4242/lore-tracker/status.sock"
    end

    test "ist aus, wenn es weder Angabe noch Laufzeitverzeichnis gibt" do
      System.delete_env("LORE_STATUS_SOCKET")
      System.delete_env("XDG_RUNTIME_DIR")
      assert Endpunkt.pfad() == nil
    end

    test "lässt sich ausdrücklich abschalten" do
      for wert <- ["", "aus", "0", "off"] do
        System.put_env("LORE_STATUS_SOCKET", wert)
        assert Endpunkt.pfad() == nil, "#{inspect(wert)} sollte abschalten"
      end
    end

    test "ohne Pfad gibt es kein Kind im Baum" do
      System.put_env("LORE_STATUS_SOCKET", "aus")
      assert Endpunkt.kind() == []
    end
  end

  describe "Socket-Hygiene" do
    test "legt das Verzeichnis an" do
      pfad = Path.join([System.tmp_dir!(), "lore-status-#{:rand.uniform(100_000)}", "s.sock"])
      assert :ok = Endpunkt.vorbereiten(pfad)
      assert File.dir?(Path.dirname(pfad))
      File.rm_rf!(Path.dirname(pfad))
    end

    test "weigert sich, eine gewöhnliche Datei zu löschen" do
      # Wer den Pfad verwechselt, soll es merken — nicht seine Datei verlieren.
      pfad = Path.join(System.tmp_dir!(), "lore-status-echte-datei-#{:rand.uniform(100_000)}")
      File.write!(pfad, "wichtig")

      assert {:error, {:kein_socket, :regular}} = Endpunkt.vorbereiten(pfad)
      assert File.read!(pfad) == "wichtig"
      File.rm!(pfad)
    end
  end

  describe "über den Socket" do
    setup do
      # Der Router liest den Lauf-Stand; im Test läuft die Anwendung nicht
      # gepaart, also gibt es den Prozess noch nicht.
      unless Process.whereis(Worker.Recording.Pipeline.Fortschritt) do
        start_supervised!(Worker.Recording.Pipeline.Fortschritt)
      end

      pfad = Path.join(System.tmp_dir!(), "lore-status-#{:rand.uniform(1_000_000)}.sock")
      System.put_env("LORE_STATUS_SOCKET", pfad)

      [kind] = Endpunkt.kind()
      pid = start_supervised!(kind)
      Endpunkt.rechte_setzen(pfad)

      on_exit(fn -> File.rm(pfad) end)
      %{pfad: pfad, pid: pid}
    end

    test "antwortet mit JSON", %{pfad: pfad} do
      {status, koerper} = hole(pfad, "/status")

      assert status == 200
      lage = Jason.decode!(koerper)
      assert is_boolean(lage["aufnahme"])
      assert Map.has_key?(lage, "lauf")
      assert length(lage["gruppen"]) == 6
      assert lage["teilnehmer"] == []
    end

    test "kennt nur diesen einen Pfad", %{pfad: pfad} do
      assert {404, _} = hole(pfad, "/etwas-anderes")
    end

    test "die Socket-Datei gehört nur dem Nutzer", %{pfad: pfad} do
      assert {:ok, %File.Stat{mode: mode, type: :other}} = File.lstat(pfad)
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  defp hole(pfad, weg) do
    {:ok, sock} = :gen_tcp.connect({:local, pfad}, 0, [:binary, active: false, packet: :raw])

    :ok =
      :gen_tcp.send(sock, "GET #{weg} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    antwort = lies(sock, "")
    :gen_tcp.close(sock)

    [kopf, koerper] = String.split(antwort, "\r\n\r\n", parts: 2)
    [status] = Regex.run(~r{HTTP/1\.1 (\d+)}, kopf, capture: :all_but_first)
    {String.to_integer(status), koerper}
  end

  defp lies(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2000) do
      {:ok, teil} -> lies(sock, acc <> teil)
      {:error, :closed} -> acc
      {:error, grund} -> flunk("Socket-Lesefehler: #{inspect(grund)}")
    end
  end
end
