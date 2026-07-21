defmodule Hub.RateLimitTest do
  @moduledoc """
  Issue #629: Unit-Tests für Hub.RateLimit — Fixed-Window-Counter, Atomizität
  von :ets.update_counter/4, Fail-open bei Tabellen-Verlust, Sweep.

  async: false — Singleton-ETS-Tabelle (vom Application-Supervisor gestartet).
  """
  use ExUnit.Case, async: false

  alias Hub.RateLimit

  setup do
    on_exit(fn ->
      RateLimit.reset(:test_route, "1.2.3.4")
      RateLimit.reset(:test_route, "5.6.7.8")
      RateLimit.reset(:other_route, "1.2.3.4")
      RateLimit.reset(:concurrent_test, "9.9.9.9")
    end)

    :ok
  end

  describe "check/4 — Fixed-Window-Counter" do
    test "erste N Calls :ok, N+1-ter {:error, :rate_limited, count}" do
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 3, 60_000)
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 3, 60_000)
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 3, 60_000)
      assert {:error, :rate_limited, 4} = RateLimit.check(:test_route, "1.2.3.4", 3, 60_000)
    end

    test "Fenster-Ablauf: manuelles Löschen des Window-Keys startet frisch (kein Wanduhr-Flake)" do
      window_ms = 60_000
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, window_ms)
      assert {:error, :rate_limited, 2} = RateLimit.check(:test_route, "1.2.3.4", 1, window_ms)

      key = {:test_route, "1.2.3.4", RateLimit.window_start_ms(window_ms)}
      :ets.delete(RateLimit.table(), key)

      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, window_ms)
    end

    test "unabhängige IPs haben eigene Buckets" do
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
      assert {:error, :rate_limited, 2} = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
      assert :ok = RateLimit.check(:test_route, "5.6.7.8", 1, 60_000)
    end

    test "unabhängige Names haben eigene Buckets" do
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
      assert {:error, :rate_limited, 2} = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
      assert :ok = RateLimit.check(:other_route, "1.2.3.4", 1, 60_000)
    end
  end

  describe "check/4 — Atomizität (tragende Design-Entscheidung)" do
    test "1000 parallele Calls: genau N bekommen :ok, Rest :rate_limited" do
      limit = 50

      results =
        1..1000
        |> Task.async_stream(
          fn _ -> RateLimit.check(:concurrent_test, "9.9.9.9", limit, 60_000) end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      ok_count = Enum.count(results, &(&1 == :ok))
      error_count = Enum.count(results, &match?({:error, :rate_limited, _}, &1))

      assert ok_count == limit
      assert error_count == 1000 - limit
    end
  end

  describe "check/4 — Fail-open bei fehlender Tabelle" do
    test "ArgumentError (Tabelle weg) -> :ok statt raise" do
      old_pid = Process.whereis(Hub.RateLimit)
      :ets.delete(RateLimit.table())

      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)

      # WICHTIG: die Tabelle NICHT selbst im Test-Prozess mit :ets.new/2
      # neu anlegen — der Test-Prozess würde dann als Owner registriert und
      # die Tabelle stürbe mit ihm beim Testende (zerstört den Rest der
      # Suite, weil die geteilte Prod-Tabelle dann für alle folgenden Tests
      # weg ist). Stattdessen den echten Supervisor-Owner neu starten lassen
      # — Hub.RateLimit hängt :one_for_one unter Hub.Supervisor, ein Kill
      # triggert den automatischen Restart mit einer neu vom GenServer
      # selbst besessenen Tabelle.
      restart_owner!(old_pid)
    end
  end

  describe "sweep (via :sweep-Message)" do
    test "alte Fenster werden geräumt, aktuelles bleibt" do
      now = System.system_time(:millisecond)
      old_window = now - 2 * 3_600_000
      key_old1 = {:sweep_test, "1.1.1.1", old_window}
      key_old2 = {:sweep_test, "2.2.2.2", old_window - 60_000}
      key_current = {:sweep_test, "3.3.3.3", RateLimit.window_start_ms(60_000)}

      :ets.insert(RateLimit.table(), {key_old1, 5})
      :ets.insert(RateLimit.table(), {key_old2, 5})
      :ets.insert(RateLimit.table(), {key_current, 5})

      pid = Process.whereis(Hub.RateLimit)
      send(pid, :sweep)
      # FIFO-Mailbox-Ordering pro Sender: dieser Call kommt garantiert NACH
      # der :sweep-Message an, weil beide vom selben Test-Prozess gesendet
      # werden. Kein :sys-Trick (Sys-Messages können reguläre Mailbox-
      # Messages überholen).
      RateLimit.sync()

      remaining = :ets.tab2list(RateLimit.table())
      remaining_keys = Enum.map(remaining, fn {k, _v} -> k end)

      refute key_old1 in remaining_keys
      refute key_old2 in remaining_keys
      assert key_current in remaining_keys

      :ets.delete(RateLimit.table(), key_current)
    end
  end

  describe "reset/2" do
    test "löscht alle Fenster für {name, ip}" do
      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
      assert {:error, :rate_limited, 2} = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)

      RateLimit.reset(:test_route, "1.2.3.4")

      assert :ok = RateLimit.check(:test_route, "1.2.3.4", 1, 60_000)
    end
  end

  describe "window_start_ms/1" do
    test "liefert einen Vielfachen von window_ms" do
      ws = RateLimit.window_start_ms(60_000)
      assert rem(ws, 60_000) == 0
    end
  end

  # Wartet bis der Supervisor Hub.RateLimit nach einem Kill neu gestartet hat
  # (neue Pid, ungleich der alten) UND die ETS-Tabelle wieder existiert.
  # Issue #887: nur auf die Pid zu warten war ein Race — bei benannten
  # GenServern ist der Name schon registriert, BEVOR init/1 die Tabelle per
  # :ets.new anlegt; auf lahmen Runnern (Coverage) rannte der nächste Test in
  # dieses Fenster (fail-open statt rate_limited, master-Pipeline 638).
  defp restart_owner!(old_pid) do
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, _reason} -> :ok
    after
      1_000 -> flunk("Hub.RateLimit-Owner hat den Kill nach 1s nicht verarbeitet")
    end

    wait_until(fn ->
      case Process.whereis(Hub.RateLimit) do
        nil -> false
        ^old_pid -> false
        _new_pid -> :ets.info(RateLimit.table()) != :undefined
      end
    end)
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("Hub.RateLimit wurde nicht neugestartet")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
