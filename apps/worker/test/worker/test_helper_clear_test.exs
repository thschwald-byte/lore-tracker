defmodule Worker.TestHelperClearTest do
  @moduledoc """
  Issue #801: Regression für `Worker.TestHelper.clear_all_tables!/0`.

  Die Liste in `clearable_tables/0` hatte `chronik_clear_marks` (der
  ChronikClearedForSession-Watermark) und `pipeline_errors` NICHT abgedeckt.
  Folge: ein Clear-Mark aus einem Vortest überlebte `clear_all_tables!` (die
  Geschwister-Chronik-Tests clearten die Tabelle selbst, der Markdown-Test
  nicht) und unterdrückte via generation-Watermark fremde Session-Einträge →
  ordering-abhängiger Flake (`materializer_chronik_markdown_test:107`).

  Dieser Test sperrt die Klasse: `clear_all_tables!` MUSS beide Tabellen räumen.
  Shape-agnostisch über `:mnesia.table_info(:arity)`, damit er nicht an
  Schema-Änderungen bricht.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Schema.Mnesia, as: S

  # Schreibt einen Dummy-Record passender Arität (Record-Tag + Key + nil-Felder).
  defp seed_row!(table, key) do
    arity = :mnesia.table_info(table, :arity)
    fields = List.duplicate(nil, arity - 2)
    :ok = :mnesia.dirty_write(List.to_tuple([table, key | fields]))
  end

  test "clear_all_tables! räumt chronik_clear_marks + pipeline_errors (Regression #801)" do
    seed_row!(S.chronik_clear_marks(), "sid-leak")
    seed_row!(S.pipeline_errors(), "err-leak")

    assert :mnesia.dirty_all_keys(S.chronik_clear_marks()) != []
    assert :mnesia.dirty_all_keys(S.pipeline_errors()) != []

    clear_all_tables!()

    assert :mnesia.dirty_all_keys(S.chronik_clear_marks()) == [],
           "chronik_clear_marks leakt zwischen Tests → ChronikClearedForSession-Watermark unterdrückt fremde Einträge (#801)"

    assert :mnesia.dirty_all_keys(S.pipeline_errors()) == [],
           "pipeline_errors leakt zwischen Tests → seed-abhängige Fehler-Reads"
  end
end
