defmodule Worker.Schema.RenderSlotsFelderTest do
  @moduledoc """
  Issue #1246 (Vorarbeit): Die Spaltenlisten in `Worker.Materializer.RenderSlots`
  müssen den echten Mnesia-Tabellen entsprechen — Länge **und** Reihenfolge.

  `read_epos/1` zippt das Mnesia-Tupel gegen `@epos_fields`, `write_epos/1` baut
  das Tupel daraus. Beides ist rein **positional**: Eine Spalte, die an der
  Tabelle dazukommt, aber nicht in der Liste steht, erzeugt beim nächsten
  Kapitel-Publish ein zu kurzes Tupel; eine vertauschte Reihenfolge schreibt
  Werte in die falschen Spalten, ohne dass irgendetwas wirft.

  **Warum das ein eigener Test ist und kein Kommentar:** Am 18.09.2026 kam
  `worker_prod` nach dem Deploy über zwanzig Neustarts nicht hoch, weil die
  Chronik-Migration fünf `nil` anhängte, wo sechs hingehörten (#1211). Auf der
  leeren Teststage war das unsichtbar — dort legt `ensure_table!` die Tabelle
  gleich vollständig an. Dieser Test prüft die Zusicherung, die dort gefehlt
  hat, und er prüft sie gegen die **laufende** Tabelle statt gegen eine zweite
  Liste im Testcode: eine Kopie der Erwartung würde beim nächsten Umbau
  mitgepflegt und wäre wieder blind.

  Er kostet nichts und greift bei jeder künftigen Spalte — auch bei der
  `rang`-Spalte, die #1246 für die Kapitel-Ordnung braucht.
  """
  use ExUnit.Case, async: false

  alias Worker.Materializer.RenderSlots
  alias Worker.Schema.Mnesia, as: S

  test "epos_fields deckt sich mit den Attributen von worker_epos_entries" do
    tabelle = :mnesia.table_info(S.epos_entries(), :attributes)

    assert RenderSlots.epos_fields() == tabelle, """
    Die Spaltenliste in RenderSlots weicht von der Tabelle ab.

    Tabelle:     #{inspect(tabelle)}
    RenderSlots: #{inspect(RenderSlots.epos_fields())}

    Wer eine Spalte an `worker_epos_entries` ergänzt, ergänzt sie auch in
    `@epos_fields` — an derselben Position. Sonst schreibt `write_epos/1` ein
    zu kurzes oder verschobenes Tupel (#1211-Klasse).
    """
  end

  test "summary_fields deckt sich mit den Attributen der Resümee-Tabelle" do
    # Dieselbe Mechanik, dieselbe Falle — nur eine Tabelle weiter.
    tabelle = :mnesia.table_info(S.session_summaries(), :attributes)

    assert RenderSlots.summary_fields() == tabelle, """
    Die Spaltenliste in RenderSlots weicht von der Resümee-Tabelle ab.

    Tabelle:     #{inspect(tabelle)}
    RenderSlots: #{inspect(RenderSlots.summary_fields())}
    """
  end
end
