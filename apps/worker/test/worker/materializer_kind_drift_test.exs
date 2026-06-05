defmodule Worker.MaterializerKindDriftTest do
  @moduledoc """
  Issue #471: Drift-Guard zwischen Worker.Materializer und Shared.Events.

  Liest die `apply_kind/4`-Klausel-Literale aus dem Materializer-Source und
  stellt sicher, dass jeder ein kanonischer Kind aus `Shared.Events.all()` ist.
  Ein umbenannter/vertippter Kind bricht damit LAUT (Test rot) statt still
  (Materializer-Klausel matcht nie → Event wird kommentarlos ignoriert) — die
  Silent-Failure-Klasse, vor der `Shared.Events` als SSoT eigentlich schützen
  soll.

  Issue #582: die apply_kind/4-Klauseln liegen seit dem God-Module-Split in
  `Worker.Materializer.Apply1`/`Apply2` (public `def` statt `defp`); der Scan
  liest beide Submodul-Sources.
  """

  use ExUnit.Case, async: true

  @apply_paths [
    Path.join([__DIR__, "..", "..", "lib", "worker", "materializer", "apply1.ex"]),
    Path.join([__DIR__, "..", "..", "lib", "worker", "materializer", "apply2.ex"])
  ]

  test "jede apply_kind-Literal-Klausel ist ein kanonischer Shared.Events-Kind" do
    source = @apply_paths |> Enum.map_join("\n", &File.read!/1)

    literal_kinds =
      ~r/def apply_kind\(\s*"([^"]+)"/
      |> Regex.scan(source)
      |> Enum.map(fn [_, k] -> k end)
      |> Enum.uniq()

    known = MapSet.new(Shared.Events.all())
    unknown = Enum.reject(literal_kinds, &MapSet.member?(known, &1))

    assert unknown == [],
           "Materializer matcht Kinds, die nicht in Shared.Events stehen " <>
             "(Wire-Drift/Tippfehler): #{inspect(unknown)}"

    # Sanity: der Materializer deckt überhaupt eine sinnvolle Menge ab (kein
    # leeres Scan-Ergebnis durch geändertes Klausel-Format).
    assert length(literal_kinds) > 30
  end

  test "Shared.Events.all/0: keine Duplikate, nur PascalCase, plausible Größe" do
    kinds = Shared.Events.all()
    assert kinds == Enum.uniq(kinds)
    assert Enum.all?(kinds, &(&1 =~ ~r/^[A-Z][A-Za-z0-9]+$/))
    assert length(kinds) >= 40
  end
end
