defmodule Worker.ApplicationMigrationTest do
  @moduledoc """
  Issue #783 Phase 2 (Design F) + Nachtrag, seit J4 (#1207) umgebaut: die
  Boot-Migrationspfade für Bestandsworker.

  `migrate_stage2_to_stage4_if_unset!/0` — ohne ihn defaultet backend_stage4
  auf `:local` mit `model_stage4_local: :no_default` → der Render scheitert
  mit `:no_model_configured`, obwohl der GM seit dem Update nichts geändert
  hat. Seit J4 stehen die Stufe-2-Keys nicht mehr in `Worker.Settings`; die
  Migration liest sie roh aus dem Store, der Stufe-3-Teil ist entfallen.

  `migrate_stage4_to_stage5_if_unset!/0` (Nachtrag, Resümee/Epos-Trennung) —
  analoges Muster, kopiert Stage 4 (Resümee) nach Stage 5 (Epos).
  """

  use ExUnit.Case, async: false

  alias Worker.{Repo, Settings}

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  # Ein sehr alter Worker: Stufe-2-Werte liegen roh im Store, wie sie vor J4
  # geschrieben wurden — `Worker.Settings` kennt die Keys nicht mehr.
  defp alter_worker!(kv), do: Enum.each(kv, fn {k, v} -> :ok = Repo.put_state(k, v) end)

  describe "migrate_stage2_to_stage4_if_unset!/0" do
    test "greift bei unset backend_stage4: übernimmt die alten Stufe-2-Werte roh aus dem Store" do
      alter_worker!(
        backend_stage2: :anthropic,
        model_stage2_anthropic: "claude-haiku-4-5",
        ctx_stage2: 16_384,
        temperature_stage2: 0.2,
        top_p_stage2: 0.8,
        repeat_penalty_stage2: 1.15
      )

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Settings.get(:backend_stage4) == :anthropic
      assert Settings.model_for(4, :anthropic) == "claude-haiku-4-5"
      assert Settings.get(:ctx_stage4) == 16_384
      assert Settings.get(:temperature_stage4) == 0.2
      assert Settings.get(:top_p_stage4) == 0.8
      assert Settings.get(:repeat_penalty_stage4) == 1.15
    end

    test "ohne Stufe-2-Werte im Store: Stufe 4 bekommt die damaligen Defaults, kein Phantom-Modell" do
      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Settings.get(:backend_stage4) == :local
      assert Settings.model_for(4, :local) == nil
      assert Settings.source(:ctx_stage4) == :store
      assert Settings.get(:ctx_stage4) == 8192
      assert Settings.get(:temperature_stage4) == 0.15
      assert Settings.get(:top_p_stage4) == 0.7
      assert Settings.get(:repeat_penalty_stage4) == 1.1
    end

    test "J4: schreibt nichts mehr für Stufe 3; ein leeres Stufe-2-Modell zählt als keins" do
      alter_worker!(backend_stage2: :local, model_stage2_local: "qwen2.5:7b")

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Settings.model_for(4, :local) == "qwen2.5:7b"

      for key <- [:backend_stage3, :model_stage3_local, :ctx_stage3, :temperature_stage3] do
        assert Repo.get_state(key) == nil, "#{key} wurde noch geschrieben"
      end

      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
      alter_worker!(backend_stage2: "google", model_stage2_google: "  ")

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Repo.get_state(:model_stage4_google) == nil
    end

    test "No-op wenn backend_stage4 bereits gesetzt (auch auf demselben Wert wie der Default)" do
      alter_worker!(backend_stage2: :openai, model_stage2_openai: "gpt-4o-mini")
      # Stage 4 explizit auf :local gesetzt (GM hat schon getrennt) — die
      # Migration darf das NICHT mit der alten Stage 2 (:openai) überschreiben.
      Settings.put(:backend_stage4, :local)

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Settings.get(:backend_stage4) == :local
      assert Settings.model_for(4, :openai) == nil
    end

    test "Idempotenz über zwei Boot-Zyklen: zweiter Lauf überschreibt eine GM-Korrektur nicht" do
      alter_worker!(backend_stage2: :local, model_stage2_local: "qwen2.5:7b")

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()
      assert Settings.get(:backend_stage4) == :local

      # GM trennt danach manuell in /settings.
      Settings.put(:backend_stage4, :anthropic)
      Settings.put(Settings.model_key(4, :anthropic), "claude-opus")

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()

      assert Settings.get(:backend_stage4) == :anthropic
      assert Settings.model_for(4, :anthropic) == "claude-opus"
    end
  end

  describe "migrate_stage4_to_stage5_if_unset!/0 (#783 Phase 2 Nachtrag — Epos-eigener Slot)" do
    test "greift bei unset backend_stage5: kopiert Stage 4 (Resümee) nach Stage 5 (Epos)" do
      Settings.put(:backend_stage4, :anthropic)
      Settings.put(Settings.model_key(4, :anthropic), "claude-haiku-4-5")
      Settings.put(:ctx_stage4, 16_384)
      Settings.put(:temperature_stage4, 0.2)
      Settings.put(:top_p_stage4, 0.8)
      Settings.put(:repeat_penalty_stage4, 1.15)

      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()

      assert Settings.get(:backend_stage5) == :anthropic
      assert Settings.model_for(5, :anthropic) == "claude-haiku-4-5"
      assert Settings.get(:ctx_stage5) == 16_384
      assert Settings.get(:temperature_stage5) == 0.2
      assert Settings.get(:top_p_stage5) == 0.8
      assert Settings.get(:repeat_penalty_stage5) == 1.15
    end

    test "No-op wenn backend_stage5 bereits gesetzt (GM hat schon getrennt)" do
      Settings.put(:backend_stage4, :openai)
      Settings.put(Settings.model_key(4, :openai), "gpt-4o-mini")
      Settings.put(:backend_stage5, :local)

      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()

      assert Settings.get(:backend_stage5) == :local
    end

    test "Idempotenz: zweiter Boot überschreibt eine GM-Korrektur nicht" do
      Settings.put(:backend_stage4, :local)
      Settings.put(Settings.model_key(4, :local), "qwen2.5:7b")

      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()
      assert Settings.get(:backend_stage5) == :local

      Settings.put(:backend_stage5, :anthropic)
      Settings.put(Settings.model_key(5, :anthropic), "claude-opus")

      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()

      assert Settings.get(:backend_stage5) == :anthropic
      assert Settings.model_for(5, :anthropic) == "claude-opus"
    end

    test "kein Stage-4-Modell konfiguriert → kein Phantom-Write auf model_stage5_local" do
      Settings.put(:backend_stage4, :local)

      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()

      assert Settings.get(:backend_stage5) == :local
      assert Settings.model_for(5, :local) == nil
    end

    test "sehr alter Worker: beide Migrationen hintereinander tragen Stufe 2 bis Stufe 5 durch" do
      alter_worker!(backend_stage2: :local, model_stage2_local: "qwen2.5:7b", ctx_stage2: 24_576)

      :ok = Worker.Application.migrate_stage2_to_stage4_if_unset!()
      :ok = Worker.Application.migrate_stage4_to_stage5_if_unset!()

      assert Settings.model_for(5, :local) == "qwen2.5:7b"
      assert Settings.get(:ctx_stage5) == 24_576
    end
  end
end
