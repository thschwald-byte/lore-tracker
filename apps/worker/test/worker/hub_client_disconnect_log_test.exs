defmodule Worker.HubClientDisconnectLogTest do
  @moduledoc """
  Issue #1020 (Mess-Vorstufe zu #927): die Disconnect-Logzeile ist das
  Diagnose-Instrument für die `:closed`-Reconnects — ihre Uptime-Arithmetik
  und die Fall-Unterscheidungen sind die Substanz, deshalb pure + hier
  festgenagelt. Was die Zeile aussagen können muss (Ziel der Messung):

  - „reißt immer nach exakt 5m0s" → Idle-Timeout am Ingress/Proxy,
  - „Sekunden-Uptimes, hoher Zähler" → chaotischer Churn,
  - „nie verbunden seit Prozessstart" → gar keine gerissene Verbindung,
    sondern ein von Anfang an unerreichbarer Hub (ANDERE Diagnose).
  """

  use ExUnit.Case, async: true

  alias Worker.HubClient

  test "gerissene Verbindung: Grund + Uptime + Zähler in einer Zeile" do
    line = HubClient.disconnect_log_line(:closed, 1_000, 3, 301_000)

    assert line =~ ":closed"
    assert line =~ "nach 5m0s Verbindungs-Uptime"
    assert line =~ "Disconnect Nr. 3"
  end

  test "das Idle-Timeout-Muster ist ablesbar (immer exakt gleiche Minuten-Uptime)" do
    # Zwei Risse mit identischer Uptime → identischer Uptime-Text. Genau diese
    # Wiederholung im Log IST der Idle-Timeout-Beleg.
    l1 = HubClient.disconnect_log_line(:closed, 0, 1, 300_000)
    l2 = HubClient.disconnect_log_line(:closed, 500_000, 2, 800_000)

    assert l1 =~ "5m0s"
    assert l2 =~ "5m0s"
  end

  test "nie verbunden: eigene Benennung statt erfundener Uptime" do
    line = HubClient.disconnect_log_line({:error, :econnrefused}, nil, 1, 12_345)

    assert line =~ "nie verbunden seit Prozessstart"
    refute line =~ "Verbindungs-Uptime"
  end

  test "Uptime-Formatierung: ms / Sekunden / Minuten" do
    assert HubClient.disconnect_log_line(:x, 0, 1, 750) =~ "nach 750ms"
    assert HubClient.disconnect_log_line(:x, 0, 1, 12_300) =~ "nach 12.3s"
    assert HubClient.disconnect_log_line(:x, 0, 1, 3_723_000) =~ "nach 62m3s"
  end

  test "der Grund reist als inspect mit (auch Tupel-Gründe)" do
    line = HubClient.disconnect_log_line({:remote, 1006, "abnormal"}, 0, 1, 1_000)
    assert line =~ ~s({:remote, 1006, "abnormal"})
  end
end
