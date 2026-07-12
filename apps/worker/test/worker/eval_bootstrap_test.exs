defmodule Worker.EvalBootstrapTest do
  @moduledoc """
  Issue #783 Phase 2 (Design D): Backup/Restore-Symmetrie von
  `EvalBootstrap.apply_stage_model!/2` + `restore_stage_model!/2` — die
  generische Stage-3/4-Fassung von `apply_stage2_model!/1`. Deckt nur die
  Settings-Manipulation ab (kein `bootstrap_worker!`/Ollama nötig — die
  Funktionen sind reine `Worker.Settings`-Reads/Writes).
  """

  use ExUnit.Case, async: false

  alias Worker.{EvalBootstrap, Settings}

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  describe "apply_stage_model!/2 + restore_stage_model!/2" do
    test "pinnt backend_stage{n} auf :local + optionales Modell, Restore stellt den Vorzustand her" do
      for n <- [2, 3, 4] do
        Settings.put(:"backend_stage#{n}", :anthropic)
        Settings.put(Settings.model_key(n, :anthropic), "claude-x")

        {backup, label} = EvalBootstrap.apply_stage_model!(n, "eval-model")

        assert Settings.get(:"backend_stage#{n}") == :local
        assert Settings.model_for(n, :local) == "eval-model"
        assert label == "eval-model"

        :ok = EvalBootstrap.restore_stage_model!(n, backup)

        assert Settings.get(:"backend_stage#{n}") == :anthropic
        assert Settings.model_for(n, :anthropic) == "claude-x"
      end
    end

    test "ohne model_override → label ist das bestehende Stage-Modell (oder \"default\")" do
      Settings.put(:backend_stage3, :local)
      Settings.put(Settings.model_key(3, :local), "qwen2.5:7b")

      {_backup, label} = EvalBootstrap.apply_stage_model!(3, nil)

      assert label == "qwen2.5:7b"
    end

    test "restore setzt model_stage{n}_local NICHT, wenn vorher unkonfiguriert (kein Phantom-Write)" do
      Settings.put(:backend_stage4, :openai)

      {backup, _label} = EvalBootstrap.apply_stage_model!(4, "eval-model")
      assert backup.model == nil

      :ok = EvalBootstrap.restore_stage_model!(4, backup)

      assert Settings.get(:backend_stage4) == :openai
      # model_stage4_local bleibt auf "eval-model" stehen (kein Rückschreiben
      # auf nil versucht) — harmlos, weil backend_stage4 nicht mehr :local ist.
      assert Settings.model_for(4, :local) == "eval-model"
    end
  end

  describe "apply_stage2_model!/1 + restore_stage2_model!/1 (dünner Wrapper, #783 Phase 2)" do
    test "Backup/Restore-Symmetrie bleibt erhalten (Callsite-kompatibel)" do
      Settings.put(:backend_stage2, :google)
      Settings.put(Settings.model_key(2, :google), "gemini-x")

      {backup, label} = EvalBootstrap.apply_stage2_model!("eval-model-2")

      assert Settings.get(:backend_stage2) == :local
      assert label == "eval-model-2"
      # backup.model_stage2 spiegelt model_stage2_local (was der Pin anfasst),
      # NICHT das Modell des vorherigen Backends (:google) — das bleibt
      # unangetastet unter seinem eigenen Key (model_stage2_google).
      assert %{backend_stage2: :google, model_stage2: nil} = backup

      :ok = EvalBootstrap.restore_stage2_model!(backup)

      assert Settings.get(:backend_stage2) == :google
      assert Settings.model_for(2, :google) == "gemini-x"
    end
  end
end
