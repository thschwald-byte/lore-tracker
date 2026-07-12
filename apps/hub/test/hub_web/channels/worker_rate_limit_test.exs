defmodule HubWeb.WorkerRateLimitTest do
  @moduledoc """
  Issue #630: Token-Bucket-Logik für `WorkerChannel.publish_intent(_batch)`.

  Rein getestet über explizite `now_ms`-Werte (kein `Process.sleep`/Timing-
  Flake) — `check/3` nimmt die Zeit als Parameter, nicht via versteckte Clock.
  """

  # Application.put_env(:hub, ...) ist Prozess-globaler Mutable-State — analog
  # worker_jwt_test.exs async: false, um Races mit anderen :hub-Config-Tests zu
  # vermeiden.
  use ExUnit.Case, async: false

  alias HubWeb.WorkerRateLimit

  setup do
    # Deterministische Test-Config statt Produktions-Defaults (200/2000) —
    # kleine Zahlen machen Burst-Erschöpfung + Refill-Arithmetik lesbar.
    Application.put_env(:hub, :worker_publish_rate_per_sec, 10)
    Application.put_env(:hub, :worker_publish_burst, 20)

    on_exit(fn ->
      Application.delete_env(:hub, :worker_publish_rate_per_sec)
      Application.delete_env(:hub, :worker_publish_burst)
    end)

    :ok
  end

  test "frischer Bucket ist voll (Burst-Kapazität)" do
    bucket = WorkerRateLimit.new(0)
    assert {:ok, %{tokens: 19.0}} = WorkerRateLimit.check(bucket, 1, 0)
  end

  test "verbraucht cost Tokens pro Aufruf" do
    bucket = WorkerRateLimit.new(0)
    {:ok, bucket} = WorkerRateLimit.check(bucket, 5, 0)
    assert bucket.tokens == 15.0
  end

  test "erschöpfter Burst → :error, kein Abzug" do
    bucket = WorkerRateLimit.new(0)

    # Burst = 20, sofort verbrauchen (kein Refill, gleiches now_ms).
    {:ok, bucket} = WorkerRateLimit.check(bucket, 20, 0)
    assert bucket.tokens == 0.0

    assert {:error, after_bucket} = WorkerRateLimit.check(bucket, 1, 0)
    # Kein Abzug bei Ablehnung — Tokens bleiben bei 0 (nur Refill angewandt).
    assert after_bucket.tokens == 0.0
  end

  test "Refill linear über die Zeit, gedeckelt auf Burst" do
    bucket = WorkerRateLimit.new(0)
    {:ok, bucket} = WorkerRateLimit.check(bucket, 20, 0)
    assert bucket.tokens == 0.0

    # rate=10/s → nach 500ms sind 5 Tokens zurück.
    assert {:ok, bucket} = WorkerRateLimit.check(bucket, 5, 500)
    assert bucket.tokens == 0.0

    # Ohne weiteren Verbrauch: nach weiteren 10s (deutlich > Burst/rate) auf
    # den Burst gedeckelt, nicht unbegrenzt weiter aufgefüllt.
    {:error, capped} = WorkerRateLimit.check(bucket, 999, 500 + 10_000)
    assert capped.tokens == 20.0
  end

  test "cost größer als aktuell verfügbare Tokens → :error, Refill trotzdem angewandt" do
    bucket = WorkerRateLimit.new(0)
    {:ok, bucket} = WorkerRateLimit.check(bucket, 20, 0)

    # 100ms später: rate=10/s → 1 Token zurück, aber cost=5 reicht nicht.
    assert {:error, refilled} = WorkerRateLimit.check(bucket, 5, 100)
    assert refilled.tokens == 1.0
  end

  test "burst()/rate_per_sec() lesen die Application-Config mit Default-Fallback" do
    assert WorkerRateLimit.rate_per_sec() == 10
    assert WorkerRateLimit.burst() == 20

    Application.delete_env(:hub, :worker_publish_rate_per_sec)
    Application.delete_env(:hub, :worker_publish_burst)
    assert WorkerRateLimit.rate_per_sec() == 200
    assert WorkerRateLimit.burst() == 2000
  end

  test "burst()/rate_per_sec() fallen auf Default zurück wenn der Config-Wert nil ist (runtime.exs env!/3 ohne gesetzte Env-Var)" do
    Application.put_env(:hub, :worker_publish_rate_per_sec, nil)
    Application.put_env(:hub, :worker_publish_burst, nil)
    assert WorkerRateLimit.rate_per_sec() == 200
    assert WorkerRateLimit.burst() == 2000
  end
end
