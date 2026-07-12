defmodule HubWeb.Plugs.RateLimitTest do
  @moduledoc """
  Issue #629: Plug-Tests für HubWeb.Plugs.RateLimit — insbesondere die
  XFF-Positionslogik (kritischer Trust-Boundary-Pfad).

  async: false — Singleton-ETS-Tabelle (Hub.RateLimit) + geteilter
  Application-Env für die Plug-Config.
  """
  use ExUnit.Case, async: false

  alias Hub.RateLimit
  alias HubWeb.Plugs.RateLimit, as: RateLimitPlug

  import ExUnit.CaptureLog

  defp put_config(overrides) do
    prev = Application.get_env(:hub, RateLimitPlug)
    Application.put_env(:hub, RateLimitPlug, overrides)

    on_exit(fn ->
      if prev do
        Application.put_env(:hub, RateLimitPlug, prev)
      else
        Application.delete_env(:hub, RateLimitPlug)
      end
    end)
  end

  defp conn(remote_ip, xff_header \\ nil) do
    c = Plug.Test.conn(:get, "/test-route") |> Map.put(:remote_ip, remote_ip)
    if xff_header, do: Plug.Conn.put_req_header(c, "x-forwarded-for", xff_header), else: c
  end

  setup do
    on_exit(fn ->
      RateLimit.reset(
        :pt_route,
        "9.9.9.9, 10.0.0.1" |> String.split(",") |> List.last() |> String.trim()
      )

      RateLimit.reset(:pt_route, "10.0.0.1")
      RateLimit.reset(:pt_route, "127.0.0.1")
      RateLimit.reset(:pt_route, "1.2.3.4")
      RateLimit.reset(:pt_direct, "127.0.0.1")
      RateLimit.reset(:xff_length_mismatch, "global")
    end)

    :ok
  end

  describe "XFF-Angriffs-Repro (kritisch, Prod-Semantik: {:trusted_proxies, 1})" do
    test "zwei Requests mit unterschiedlichem leftmost, gleichem rightmost XFF-Wert landen im selben Bucket" do
      put_config(proxy_config: {:trusted_proxies, 1}, limits: %{pt_route: {1, 60_000}})

      conn1 = conn({127, 0, 0, 1}, "9.9.9.9, 10.0.0.1")
      conn2 = conn({127, 0, 0, 1}, "8.8.8.8, 10.0.0.1")

      result1 = RateLimitPlug.call(conn1, RateLimitPlug.init(key: :pt_route))
      refute result1.halted

      result2 = RateLimitPlug.call(conn2, RateLimitPlug.init(key: :pt_route))
      # Gleicher rightmost-Wert (10.0.0.1) → gleicher Bucket → zweiter Call
      # überschreitet limit: 1 und wird geblockt. Wenn dieser Test rot ist,
      # greift der Plug den falschen Index (leftmost statt rightmost) —
      # Merge-Gate.
      assert result2.halted
      assert result2.status == 429
    end
  end

  describe "XFF zu kurz (Länge < N)" do
    test "fällt auf conn.remote_ip zurück + schreibt Frühwarn-Log" do
      put_config(proxy_config: {:trusted_proxies, 2}, limits: %{pt_route: {5, 60_000}})

      c = conn({127, 0, 0, 1}, "1.2.3.4")

      log =
        capture_log(fn ->
          result = RateLimitPlug.call(c, RateLimitPlug.init(key: :pt_route))
          refute result.halted
        end)

      assert log =~ "XFF-Länge 1 < erwartete Hops 2"
      assert log =~ "fallback auf conn.remote_ip"
    end

    test "Frühwarn-Log ist gedrosselt: 100 Mismatch-Requests erzeugen genau 1 Log-Zeile" do
      put_config(proxy_config: {:trusted_proxies, 2}, limits: %{pt_route: {1000, 60_000}})

      log =
        capture_log(fn ->
          for _ <- 1..100 do
            c = conn({127, 0, 0, 1}, "1.2.3.4")
            RateLimitPlug.call(c, RateLimitPlug.init(key: :pt_route))
          end
        end)

      occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&(&1 =~ "XFF-Länge"))

      assert occurrences == 1
    end
  end

  describe "XFF gleich lang wie N" do
    test "XFF mit genau N Einträgen wird per Positions-Extraktion gebucketed" do
      put_config(proxy_config: {:trusted_proxies, 1}, limits: %{pt_route: {1, 60_000}})

      c1 = conn({127, 0, 0, 1}, "1.2.3.4")
      result1 = RateLimitPlug.call(c1, RateLimitPlug.init(key: :pt_route))
      refute result1.halted

      c2 = conn({127, 0, 0, 1}, "1.2.3.4")
      result2 = RateLimitPlug.call(c2, RateLimitPlug.init(key: :pt_route))
      assert result2.halted
    end
  end

  describe ":direct-Mode (PR-Test-Stack-Semantik)" do
    test "XFF-Header wird ignoriert, remote_ip zählt" do
      put_config(proxy_config: :direct, limits: %{pt_direct: {1, 60_000}})

      c1 = conn({127, 0, 0, 1}, "9.9.9.9")
      result1 = RateLimitPlug.call(c1, RateLimitPlug.init(key: :pt_direct))
      refute result1.halted

      c2 = conn({127, 0, 0, 1}, "8.8.8.8")
      result2 = RateLimitPlug.call(c2, RateLimitPlug.init(key: :pt_direct))
      # Trotz unterschiedlichem XFF-Fake-Wert: gleicher remote_ip → gleicher
      # Bucket → 2. Call überschreitet limit: 1.
      assert result2.halted
    end
  end

  describe "kein XFF-Header" do
    test "remote_ip-Fallback greift unabhängig vom proxy_config" do
      put_config(proxy_config: {:trusted_proxies, 1}, limits: %{pt_route: {1, 60_000}})

      c1 = conn({1, 2, 3, 4})
      result1 = RateLimitPlug.call(c1, RateLimitPlug.init(key: :pt_route))
      refute result1.halted

      c2 = conn({1, 2, 3, 4})
      result2 = RateLimitPlug.call(c2, RateLimitPlug.init(key: :pt_route))
      assert result2.halted
    end
  end

  describe "429-Response" do
    test "setzt retry-after: 60" do
      put_config(proxy_config: :direct, limits: %{pt_direct: {1, 60_000}})

      c1 = conn({127, 0, 0, 1})
      RateLimitPlug.call(c1, RateLimitPlug.init(key: :pt_direct))

      c2 = conn({127, 0, 0, 1})
      result = RateLimitPlug.call(c2, RateLimitPlug.init(key: :pt_direct))

      assert result.halted
      assert result.status == 429
      assert Plug.Conn.get_resp_header(result, "retry-after") == ["60"]
    end

    test "429-Log-Drosselung: 100 Requests über Limit erzeugen genau 1 Warn-Zeile" do
      put_config(proxy_config: :direct, limits: %{pt_direct: {1, 60_000}})

      log =
        capture_log(fn ->
          for _ <- 1..100 do
            c = conn({127, 0, 0, 1})
            RateLimitPlug.call(c, RateLimitPlug.init(key: :pt_direct))
          end
        end)

      occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&(&1 =~ "429 name=pt_direct"))

      assert occurrences == 1
    end
  end
end
