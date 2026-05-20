defmodule Worker.Schema.MnesiaTest do
  @moduledoc """
  Issue #43 / #42: Regression-Schutz für die User-Tabellen-Migrations.

  Die Migrations vergleichen heute „Zielfeld ∈ current_attrs" statt einer
  exakten Spalten-Liste. Wenn jemand das wieder auf List-Equality umstellt,
  bricht der Worker-Boot auf jeder schon-migrierten Mnesia mit
  `function_clause` weil `:mnesia.transform_table` auf einen arity-6-Row
  läuft den die alte Transform-fn nicht matchen kann.
  """

  use ExUnit.Case, async: false

  alias Worker.Schema.Mnesia, as: S

  @did "schema-migration-test-did"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.users())
    :ok
  end

  test "bootstrap!/0 crasht nicht auf arity-6-Row (Regression #42/#43)" do
    # Bühne: eine paired-User-Row im aktuellen 5-Felder-Schema
    # (1 Tag + discord_id + display_name + joined_at + avatar_url + role = 6-Tuple).
    # Genau dieser Zustand lag in der prod-worker-Mnesia + pr-4003-worker-Mnesia
    # und hat den Worker beim Restart in den function_clause-Crash geschickt.
    joined_at = DateTime.utc_now()

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({S.users(), @did, "Test User", joined_at, nil, :spieler})
      end)

    # Genau das macht jeder Worker-Start: bootstrap!/0 ruft beide private
    # migrate-Funktionen. Vor dem #42-Fix flog hier function_clause.
    assert :ok = Worker.Schema.Mnesia.bootstrap!()

    # Row ist unverändert lesbar, kein Daten-Verlust durch eine unnötige
    # transform_table-Reise.
    assert [{_tbl, @did, "Test User", ^joined_at, nil, :spieler}] =
             :mnesia.dirty_read(S.users(), @did)
  end
end
