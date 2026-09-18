defmodule Worker.Schema.ChronikMigrationTest do
  @moduledoc """
  Die Chronik-Migration aus #1211 gegen BESTANDSDATEN (nicht gegen eine leere
  Mnesia).

  Warum es diesen Test braucht: Am 18.09.2026 kam `worker_prod` nach dem
  Deploy über zwanzig Neustarts nicht hoch — `:mnesia.transform_table` lehnte
  mit `{"Bad arity", …}` ab, weil die Transform-Funktion fünf `nil` anhängte,
  wo sechs hingehören (18 Attribute heissen 19 Tupel-Elemente).

  **Auf der Teststage war das unsichtbar.** Dort ist die Mnesia leer,
  `ensure_table!` legt die Tabelle gleich vollständig an, und diese Migration
  läuft nie. Sie greift ausschliesslich, wo Bestandsdaten liegen — ein voller
  Pipeline-Lauf über zwei Sitzungen hat sie nicht berührt. Der Test baut die
  Tabelle deshalb auf den Stand VOR #1211 zurück und schreibt eine Alt-Row,
  wie es `mnesia_test.exs` für die User-Tabelle tut (Regression #42/#43).
  """
  use ExUnit.Case, async: false

  alias Worker.Schema.Migrations.Chronik, as: M
  alias Worker.Schema.Mnesia, as: S

  # Der Spaltenstand vor #1211: zwölf Attribute.
  @vor_1211 [
    :id,
    :campaign_id,
    :in_game_date,
    :label,
    :summary,
    :session_id,
    :source_refs,
    :markdown_body,
    :in_game_day,
    :precision,
    :generation,
    :source_pos
  ]

  test "migriert eine Bestands-Row auf die sechs neuen Spalten" do
    tab = S.chronik_entries()
    jetzt = :mnesia.table_info(tab, :attributes)
    assert :sitzungen in jetzt, "Testumgebung ist nicht auf dem #1211-Stand"

    # Zurück auf den Stand vor #1211 — die sechs neuen Felder fallen weg.
    runter = fn row ->
      row |> Tuple.to_list() |> Enum.take(13) |> List.to_tuple()
    end

    {:atomic, :ok} = :mnesia.transform_table(tab, runter, @vor_1211)
    assert length(:mnesia.table_info(tab, :attributes)) == 12

    # Eine Alt-Row, wie sie in Prod lag (Werte aus dem echten Fall, anonym).
    alt =
      {tab, "chronik-alt-1", "c-alt", "1. Januar 2081", "", "Ein Bestands-Eintrag.", "sess-alt",
       ["b_aaaa"], nil, 759_565, "day", "gen-alt", nil}

    :ok = :mnesia.dirty_write(alt)

    # Genau der Aufruf, der in Prod warf.
    assert :ok = M.migrate_chronik_entries_add_phasen!()

    attrs = :mnesia.table_info(tab, :attributes)
    assert length(attrs) == 18
    assert :sitzungen in attrs

    [neu] = :mnesia.dirty_read(tab, "chronik-alt-1")

    # 18 Attribute heissen 19 Tupel-Elemente — das war der Fehler.
    assert tuple_size(neu) == 19

    # Die Bestandswerte überleben unverändert …
    # Indizes: 0 = Tabellenname, dann die Attribute in der Reihenfolge von
    # `@vor_1211` — in_game_day ist 9, precision 10, generation 11.
    assert elem(neu, 3) == "1. Januar 2081"
    assert elem(neu, 9) == 759_565
    assert elem(neu, 10) == "day"
    assert elem(neu, 11) == "gen-alt"

    # … und die sechs neuen Spalten stehen auf nil.
    for i <- 13..18, do: assert(elem(neu, i) == nil, "Spalte #{Enum.at(attrs, i - 1)} nicht nil")

    :ok = :mnesia.dirty_delete(tab, "chronik-alt-1")
  end

  test "ist idempotent: ein zweiter Aufruf tut nichts" do
    assert :ok = M.migrate_chronik_entries_add_phasen!()
    assert length(:mnesia.table_info(S.chronik_entries(), :attributes)) == 18
  end
end
