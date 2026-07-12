defmodule Worker.TestHelperClearTest do
  @moduledoc """
  Issue #801: Klassen-Sperre für `Worker.TestHelper.clear_all_tables!/0`.

  Motivierender Bug: `clearable_tables/0` deckte `chronik_clear_marks` (den
  ChronikClearedForSession-generation-Watermark) und `pipeline_errors` nicht ab
  → ein Clear-Mark aus einem Vortest überlebte und unterdrückte via Watermark
  fremde Session-Einträge (`materializer_chronik_markdown_test:107`, ordering-
  abhängiger Flake). #66 hatte schon einmal vergessene Tabellen nachgezogen —
  diese zwei entwischten.

  Die eigentliche Defekt-KLASSE ist aber nicht „diese zwei Tabellen fehlen",
  sondern „eine Tabelle existiert, die `clearable_tables/0` nicht kennt". Ein
  hart benannter Zwei-Tabellen-Test würde nur diese zwei Instanzen sperren;
  ein Drittes könnte still wieder passieren.

  Dieser Test enumeriert deshalb die Tabellen zur LAUFZEIT
  (`:mnesia.system_info(:tables)`), zieht die dokumentierten Ausnahmen ab und
  assertet, dass `clear_all_tables!` jede übrige Tabelle tatsächlich leert. Die
  nächste vergessene Tabelle rotet damit automatisch beim Hinzufügen — ohne dass
  jemand daran denken muss, diesen Test zu erweitern.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Schema.Mnesia, as: S

  # Dokumentierte Ausnahmen (dürfen NICHT in clearable_tables/0 sein):
  #   :schema      — Mnesia-Metatabelle, keine Domänendaten.
  #   worker_state — bewusst draußen (Tests clearen es explizit, weil manche
  #                  setup_all-Settings persistieren; siehe clearable_tables/0).
  # Dynamische per-Campaign-Event-Tabellen (`:"worker_campaign_events_<slug>"`,
  # Worker.Schema.DynamicTables) sind ebenfalls bewusst nicht in der Liste — der
  # no_exists-tolerante Loop in clear_all_tables! deckt sie separat ab.
  defp excepted?(table) do
    table in [:schema, S.worker_state()] or
      table |> Atom.to_string() |> String.starts_with?("worker_campaign_events_")
  end

  # Schreibt einen Dummy-Record passender Arität (Record-Tag + Key + nil-Felder).
  # Shape-agnostisch über table_info(:arity) → übersteht Schema-Änderungen.
  defp seed_row!(table, key) do
    arity = :mnesia.table_info(table, :arity)
    fields = List.duplicate(nil, arity - 2)
    :ok = :mnesia.dirty_write(List.to_tuple([table, key | fields]))
  end

  test "clear_all_tables! leert JEDE statische Worker-Tabelle (Klassen-Sperre #801)" do
    static_tables =
      :mnesia.system_info(:tables)
      |> Enum.reject(&excepted?/1)

    # Vorbedingung: die Enumeration findet überhaupt Tabellen (Bootstrap lief).
    assert static_tables != []

    Enum.each(static_tables, fn t -> seed_row!(t, {:__leak_probe_801__, t}) end)

    clear_all_tables!()

    leaked = Enum.filter(static_tables, fn t -> :mnesia.dirty_all_keys(t) != [] end)

    assert leaked == [],
           "clear_all_tables! lässt statische Tabelle(n) ungeräumt — neue Tabelle nicht " <>
             "in clearable_tables/0 ergänzt (oder bewusste Ausnahme in excepted?/1 " <>
             "nachtragen)? Betroffen: #{inspect(leaked)}"
  end
end
