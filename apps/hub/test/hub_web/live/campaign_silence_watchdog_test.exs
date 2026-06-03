defmodule HubWeb.CampaignLive.SilenceWatchdogTest do
  @moduledoc """
  Issue #399: server-seitiger Stille-Watchdog. `compute_silent_streamers/4`
  ist der reine Kern — wer noch streamt (in der aktiven Liste, Chunks fließen),
  aber dessen letztes hörbares Signal (`loud_at`) ≥ limit zurückliegt, gilt als
  still. Deterministisch getestet mit expliziten Zeitstempeln.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Mic

  @limit 5 * 60 * 1000
  @now 10_000_000

  test "Streamer ohne hörbares Signal seit ≥ limit wird geflaggt" do
    loud_at = %{"a" => @now - @limit - 1}
    assert Mic.compute_silent_streamers(["a"], loud_at, @now, @limit) == ["a"]
  end

  test "Streamer mit frischem Signal wird NICHT geflaggt" do
    loud_at = %{"a" => @now - 1_000}
    assert Mic.compute_silent_streamers(["a"], loud_at, @now, @limit) == []
  end

  test "exakt am limit (>=) flaggt" do
    loud_at = %{"a" => @now - @limit}
    assert Mic.compute_silent_streamers(["a"], loud_at, @now, @limit) == ["a"]
  end

  test "Streamer ohne loud_at-Eintrag (gerade beigetreten) flaggt nicht" do
    assert Mic.compute_silent_streamers(["a"], %{}, @now, @limit) == []
  end

  test "nur aktive Streamer werden betrachtet — alter loud_at-Eintrag ohne aktiven Stream zählt nicht" do
    # "b" ist nicht (mehr) in der Streamer-Liste, obwohl uralt in loud_at →
    # taucht nicht im Ergebnis auf (Ghost-Sweep-Domäne, nicht Stille).
    loud_at = %{"a" => @now - 1_000, "b" => @now - @limit - 9999}
    assert Mic.compute_silent_streamers(["a"], loud_at, @now, @limit) == []
  end

  test "mehrere stille Streamer, Reihenfolge = Streamer-Liste" do
    loud_at = %{"x" => @now - @limit - 1, "y" => @now - 5, "z" => @now - @limit - 1}

    assert Mic.compute_silent_streamers(["x", "y", "z"], loud_at, @now, @limit) ==
             ["x", "z"]
  end

  test "leere Streamer-Liste → leeres Ergebnis" do
    assert Mic.compute_silent_streamers([], %{"a" => 0}, @now, @limit) == []
  end
end
