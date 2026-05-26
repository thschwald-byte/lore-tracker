defmodule Hub.TelemetryTest do
  @moduledoc """
  Issue #238: Hub.Telemetry attached Phoenix + Hub-eigene Events und
  schreibt sie als strukturierte Logger-Lines (`[telemetry] event=…`).

  Wir testen die Format-Logik via :telemetry.execute → assert die
  passende Log-Line erscheint. Hub.Telemetry hängt sich beim Application-
  Start automatisch ein (start_link/1 returnt :ignore, Handler bleibt
  global registriert).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    # Hub.Telemetry ist beim App-Start im Application-Tree; falls noch
    # nicht attached, idempotent nachholen.
    _ = Hub.Telemetry.start_link()

    # Test-env hat default `Logger.level: :warning` (config/test.exs Z. 14)
    # — wir brauchen :info damit unsere Telemetry-Lines durchkommen.
    prev_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    :ok
  end

  test "hub.event_bridge.publish — :ok-Result wird formatiert geloggt" do
    log =
      capture_log(fn ->
        :telemetry.execute(
          [:hub, :event_bridge, :publish],
          %{duration: System.convert_time_unit(42, :millisecond, :native)},
          %{kind: "MarkerAdded", campaign_id: "camp-test", result: :ok}
        )
      end)

    assert log =~ "[telemetry] event=hub.event_bridge.publish"
    assert log =~ "kind=MarkerAdded"
    assert log =~ "campaign_id=camp-test"
    assert log =~ "result=ok"
    assert log =~ "duration_ms="
  end

  test "hub.event_bridge.publish — no_worker_online wird geloggt" do
    log =
      capture_log(fn ->
        :telemetry.execute(
          [:hub, :event_bridge, :publish],
          %{duration: 0},
          %{kind: "UserUpserted", campaign_id: nil, result: :no_worker_online}
        )
      end)

    assert log =~ "[telemetry] event=hub.event_bridge.publish"
    assert log =~ "result=no_worker_online"
    # campaign_id=nil wird gefiltert (Hub.Telemetry droppt nil-values)
    refute log =~ "campaign_id="
  end

  test "hub.worker_registry.changed — joins/leaves als Liste formatiert" do
    log =
      capture_log(fn ->
        :telemetry.execute(
          [:hub, :worker_registry, :changed],
          %{joins_count: 2, leaves_count: 0},
          %{joins: ["w-1", "w-2"], leaves: []}
        )
      end)

    assert log =~ "[telemetry] event=hub.worker_registry.changed"
    assert log =~ "joins=[w-1,w-2]"
    assert log =~ "leaves=[]"
  end
end
