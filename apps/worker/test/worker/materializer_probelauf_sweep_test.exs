defmodule Worker.MaterializerProbelaufSweepTest do
  @moduledoc """
  Issue #281: ProbelaufSweepFinished persistiert die `variants`-Liste
  für isolated-Sweeps. Vorher wurde das Feld vom Materializer ignoriert —
  43 min Sweep-Laufzeit waren nach Worker-Restart verloren.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  describe "ProbelaufSweepFinished" do
    test "persistiert variants für isolated-Sweep" do
      sweep_id = "sweep-isolated-281"

      variants = [
        %{
          "model" => "m1",
          "sessions" => [
            %{
              "number" => 1,
              "session_id" => "s1",
              "stage" => "stage2",
              "duration_ms" => 100,
              "outcome" => "ok"
            }
          ]
        },
        %{
          "model" => "m2",
          "sessions" => [
            %{
              "number" => 1,
              "session_id" => "s1",
              "stage" => "stage2",
              "duration_ms" => 200,
              "outcome" => "ok"
            }
          ]
        }
      ]

      assert {:applied, 200} =
               Materializer.apply_event(
                 event(
                   "ProbelaufSweepStarted",
                   %{
                     "sweep_id" => sweep_id,
                     "stage" => 2,
                     "models" => ["m1", "m2"],
                     "default_model" => "m1",
                     "started_by" => "did-tester"
                   },
                   200
                 )
               )

      assert {:applied, 201} =
               Materializer.apply_event(
                 event(
                   "ProbelaufSweepFinished",
                   %{
                     "sweep_id" => sweep_id,
                     "isolated" => true,
                     "stage" => 2,
                     "variants" => variants
                   },
                   201
                 )
               )

      sweep = Repo.last_probelauf_sweep()
      assert sweep != nil
      assert sweep.sweep_id == sweep_id
      assert sweep.variants == variants
      assert sweep.runs == []
    end

    test "behält variants=nil für non-isolated Sweep" do
      sweep_id = "sweep-non-isolated-281"

      assert {:applied, 300} =
               Materializer.apply_event(
                 event(
                   "ProbelaufSweepStarted",
                   %{
                     "sweep_id" => sweep_id,
                     "stage" => 2,
                     "models" => ["m1"],
                     "default_model" => "m1",
                     "started_by" => "did-tester"
                   },
                   300
                 )
               )

      assert {:applied, 301} =
               Materializer.apply_event(
                 event(
                   "ProbelaufSweepFinished",
                   %{"sweep_id" => sweep_id, "stage" => 2},
                   301
                 )
               )

      sweep = Repo.last_probelauf_sweep()
      assert sweep.variants == nil
    end
  end
end
