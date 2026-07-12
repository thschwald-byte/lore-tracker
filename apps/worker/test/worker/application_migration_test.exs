defmodule Worker.ApplicationMigrationTest do
  @moduledoc """
  Issue #783 Phase 2 (Design F): `Worker.Application.migrate_stage2_to_stage34_if_unset!/0`
  — der Boot-Migrationspfad für Bestandsworker. Ohne ihn defaulten backend_stage3/4
  auf `:local` mit `model_stage{3,4}_local: :no_default` → Verify/Render scheitern
  mit `:no_model_configured`, obwohl der GM seit dem Update nichts geändert hat.
  """

  use ExUnit.Case, async: false

  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  test "greift bei unset backend_stage3: kopiert Stage 2 nach Stage 3 + 4" do
    Settings.put(:backend_stage2, :anthropic)
    Settings.put(Settings.model_key(2, :anthropic), "claude-haiku-4-5")
    Settings.put(:ctx_stage2, 16_384)
    Settings.put(:temperature_stage2, 0.2)
    Settings.put(:top_p_stage2, 0.8)
    Settings.put(:repeat_penalty_stage2, 1.15)

    :ok = Worker.Application.migrate_stage2_to_stage34_if_unset!()

    for n <- [3, 4] do
      assert Settings.get(:"backend_stage#{n}") == :anthropic
      assert Settings.model_for(n, :anthropic) == "claude-haiku-4-5"
      assert Settings.get(:"ctx_stage#{n}") == 16_384
      assert Settings.get(:"temperature_stage#{n}") == 0.2
      assert Settings.get(:"top_p_stage#{n}") == 0.8
      assert Settings.get(:"repeat_penalty_stage#{n}") == 1.15
    end
  end

  test "No-op wenn backend_stage3 bereits gesetzt (auch auf demselben Wert wie der Default)" do
    Settings.put(:backend_stage2, :openai)
    Settings.put(Settings.model_key(2, :openai), "gpt-4o-mini")
    # Stage 3 explizit auf :local gesetzt (GM hat schon getrennt) — die
    # Migration darf das NICHT mit Stage 2 (:openai) überschreiben.
    Settings.put(:backend_stage3, :local)

    :ok = Worker.Application.migrate_stage2_to_stage34_if_unset!()

    assert Settings.get(:backend_stage3) == :local
    # Stage 4 war ebenfalls unset — greift trotzdem, weil das Gate NUR auf
    # backend_stage3 prüft (Design F: ein einziger Gate-Key für beide).
  end

  test "Idempotenz über zwei Boot-Zyklen: zweiter Lauf überschreibt eine GM-Korrektur nicht" do
    Settings.put(:backend_stage2, :local)
    Settings.put(Settings.model_key(2, :local), "qwen2.5:7b")

    :ok = Worker.Application.migrate_stage2_to_stage34_if_unset!()
    assert Settings.get(:backend_stage3) == :local

    # GM trennt danach manuell in /settings.
    Settings.put(:backend_stage3, :anthropic)
    Settings.put(Settings.model_key(3, :anthropic), "claude-opus")

    # Zweiter Boot (z.B. Neustart) darf die GM-Korrektur nicht zurückrollen.
    :ok = Worker.Application.migrate_stage2_to_stage34_if_unset!()

    assert Settings.get(:backend_stage3) == :anthropic
    assert Settings.model_for(3, :anthropic) == "claude-opus"
  end

  test "kein Stage-2-Modell konfiguriert → kein Phantom-Write auf model_stage{n}_local" do
    Settings.put(:backend_stage2, :local)
    # model_stage2_local bewusst NICHT gesetzt (:no_default).

    :ok = Worker.Application.migrate_stage2_to_stage34_if_unset!()

    assert Settings.get(:backend_stage3) == :local
    assert Settings.model_for(3, :local) == nil
  end
end
