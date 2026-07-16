defmodule Hub.ReaderOrderTest do
  @moduledoc """
  Issue #366: `Hub.Reader.order_candidates/2` ordnet die Worker-Kandidaten für
  einen Snapshot-Read deterministisch. Pure Funktion → kein Tracker, läuft im
  CI-Gate (im Gegensatz zum `:integration`-getaggten reader_test.exs).

  Verträge:
  - deterministische Default-Reihenfolge `{-applied_seq, id}` (kein Switchen
    zwischen Reloads mehr);
  - `prefer_discord_id:` stellt die eigenen Worker des Viewers nach vorn, behält
    den Rest als Fallback-Kaskade;
  - `worker_id:` ist Hard-Pin (Issue #451) und schlägt `prefer_discord_id:`.
  """
  use ExUnit.Case, async: true

  alias Hub.Reader

  defp w(id, seq, admin), do: {id, %{applied_seq: seq, admin_discord_id: admin}}

  defp ids(candidates), do: Enum.map(candidates, fn {id, _} -> id end)

  describe "Default-Reihenfolge (keine Opts)" do
    test "sortiert applied_seq desc, Tie-Breaker id asc" do
      workers = [w("c", 100, "x"), w("a", 100, "x"), w("b", 300, "y")]
      assert ids(Reader.order_candidates(workers, [])) == ["b", "a", "c"]
    end

    test "ist stabil über mehrere Aufrufe (egal welche Eingangs-Reihenfolge)" do
      base = [w("a", 50, "x"), w("b", 50, "y"), w("c", 50, "z")]
      expected = ids(Reader.order_candidates(base, []))
      # Permutationen liefern dieselbe Reihenfolge → kein „Switchen".
      assert ids(Reader.order_candidates(Enum.reverse(base), [])) == expected

      assert ids(
               Reader.order_candidates(
                 [Enum.at(base, 1) | [Enum.at(base, 0), Enum.at(base, 2)]],
                 []
               )
             ) == expected
    end

    test "fehlendes applied_seq zählt als 0" do
      workers = [{"a", %{admin_discord_id: "x"}}, w("b", 10, "y")]
      assert ids(Reader.order_candidates(workers, [])) == ["b", "a"]
    end
  end

  describe "prefer_discord_id: — eigener Worker zuerst, Rest als Fallback" do
    test "stellt den eigenen Worker an Position 0, Fremde folgen" do
      workers = [w("other-hi", 500, "bob"), w("mine", 100, "tom")]
      result = ids(Reader.order_candidates(workers, prefer_discord_id: "tom"))
      assert result == ["mine", "other-hi"]
    end

    test "mehrere eigene Worker → untereinander seq desc, dann id" do
      workers = [
        w("mine-lo", 100, "tom"),
        w("other", 999, "bob"),
        w("mine-hi", 400, "tom"),
        w("mine-tie", 400, "tom")
      ]

      result = ids(Reader.order_candidates(workers, prefer_discord_id: "tom"))
      # eigene zuerst (400/mine-hi, 400/mine-tie per id, 100), dann der Fremde.
      assert result == ["mine-hi", "mine-tie", "mine-lo", "other"]
    end

    test "kein eigener Worker → identisch zur Default-Reihenfolge (reiner Fallback)" do
      workers = [w("a", 300, "bob"), w("b", 100, "carol")]

      assert Reader.order_candidates(workers, prefer_discord_id: "tom") ==
               Reader.order_candidates(workers, [])
    end
  end

  describe "worker_id: — Hard-Pin (Issue #451)" do
    test "filtert auf genau einen Worker" do
      workers = [w("a", 300, "bob"), w("b", 100, "tom")]
      assert ids(Reader.order_candidates(workers, worker_id: "b")) == ["b"]
    end

    test "unbekannte worker_id → leere Kandidatenliste (kein Fallback)" do
      workers = [w("a", 300, "bob")]
      assert Reader.order_candidates(workers, worker_id: "ghost") == []
    end

    test "worker_id schlägt prefer_discord_id" do
      workers = [w("mine", 100, "tom"), w("pinned", 999, "bob")]

      result =
        Reader.order_candidates(workers, worker_id: "pinned", prefer_discord_id: "tom")

      assert ids(result) == ["pinned"]
    end
  end
end
