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

  test "bootstrap!/0 migriert arity-6-Row auf 7-Tuple (Regression #42/#43, Migration für #178)" do
    # Bühne: die Tabelle wurde vom Test-App-Start auf das aktuelle Schema
    # (7-Tuple inkl. :monthly_spend_cap_usd) hochgezogen. Um die Migration
    # zu testen, simulieren wir den pre-#178-Zustand via transform_table
    # zurück auf 6-Felder und schreiben dort eine 6-Tuple-Row.
    pre_178_attrs = [:discord_id, :display_name, :joined_at, :avatar_url, :role]

    if length(:mnesia.table_info(S.users(), :attributes)) == 6 do
      downgrade =
        fn {tbl, did, name, joined_at, avatar, role, _cap} ->
          {tbl, did, name, joined_at, avatar, role}
        end

      {:atomic, :ok} = :mnesia.transform_table(S.users(), downgrade, pre_178_attrs)
    end

    joined_at = DateTime.utc_now()

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({S.users(), @did, "Test User", joined_at, nil, :spieler})
      end)

    # Genau das macht jeder Worker-Start: bootstrap!/0 ruft alle migrate-
    # Funktionen. Vor dem #42-Fix flog hier function_clause; mit #178 wird
    # die Row jetzt von 6 auf 7-Tuple gehoben (cap = nil).
    assert :ok = Worker.Schema.Mnesia.bootstrap!()

    # Row hat jetzt 7-Tuple-Form: existing cap = nil (unbegrenzt).
    assert [{_tbl, @did, "Test User", ^joined_at, nil, :spieler, nil}] =
             :mnesia.dirty_read(S.users(), @did)
  end
end
