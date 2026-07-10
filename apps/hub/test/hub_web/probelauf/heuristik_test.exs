defmodule HubWeb.Probelauf.HeuristikTest do
  @moduledoc """
  Issue #74 — Probelauf-Heuristik liefert die richtige Empfehlung.
  Reine Datentransformation, deshalb async.
  """

  use ExUnit.Case, async: true

  alias HubWeb.Probelauf.Heuristik

  defp session(num, stage_outcomes) do
    %{
      "number" => num,
      "utterance_count" => 10,
      "stages" =>
        Enum.into(stage_outcomes, %{}, fn {stage, {outcome, ms}} ->
          {stage, %{"outcome" => outcome, "duration_ms" => ms, "output_bytes" => 0}}
        end)
    }
  end

  describe "build/2" do
    test "alle Stages :ok + schnell → 'beibehalten', kein KV" do
      sessions = [
        session(1, %{"stage2" => {"ok", 5_000}, "stage3" => {"ok", 8_000}, "stage4" => {"ok", 6_000}}),
        session(2, %{"stage2" => {"ok", 5_500}, "stage3" => {"ok", 9_000}, "stage4" => {"ok", 6_500}})
      ]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{}
      assert text =~ "**stage2** → ✅"
      assert text =~ "**stage3** → ✅"
      assert text =~ "**stage4** → ✅"
    end

    test "Timeout in Stage 3 → http_timeout_ms-Empfehlung" do
      sessions = [
        session(1, %{"stage2" => {"ok", 3_000}, "stage3" => {"timeout", nil}, "stage4" => {"ok", 2_000}})
      ]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{"http_timeout_ms" => 600_000}
      assert text =~ "**stage3** → ⏱ Timeout"
    end

    test "Stage 4 leer → model_stage4_local-Empfehlung mit installiertem Fallback (#784: pro-Backend-Key)" do
      sessions = [
        session(1, %{"stage2" => {"ok", 4_000}, "stage3" => {"ok", 9_000}, "stage4" => {"empty_output", 800}})
      ]

      {text, kv} = Heuristik.build(sessions, ["qwen2.5:7b", "mistral-nemo:12b"])

      assert kv == %{"model_stage4_local" => "mistral-nemo:12b"}
      assert text =~ "**stage4** → 🚫"
      assert text =~ "mistral-nemo:12b"
    end

    test "Stage 4 parse_error → model_stage4_local-Empfehlung (auch ohne Install-Fallback default)" do
      sessions = [
        session(1, %{"stage2" => {"ok", 4_000}, "stage3" => {"ok", 9_000}, "stage4" => {"parse_error", 1_000}})
      ]

      {_text, kv} = Heuristik.build(sessions, [])

      assert kv == %{"model_stage4_local" => "mistral-nemo:12b"}
    end

    test "Mixed outcomes ohne Timeout/Empty → kein KV, manueller Blick" do
      sessions = [
        session(1, %{"stage2" => {"ok", 4_000}, "stage3" => {"other_error", nil}, "stage4" => {"ok", 6_000}})
      ]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{}
      assert text =~ "**stage3** → ⚠ Mixed"
    end

    test "Timeout in Stage 3 + Empty in Stage 4 → beide KV-Empfehlungen merged" do
      sessions = [
        session(1, %{"stage2" => {"ok", 4_000}, "stage3" => {"timeout", nil}, "stage4" => {"empty_output", nil}})
      ]

      {_text, kv} = Heuristik.build(sessions, ["mistral-nemo:12b"])

      assert kv == %{"http_timeout_ms" => 600_000, "model_stage4_local" => "mistral-nemo:12b"}
    end
  end

  describe "pick_json_capable_model/1" do
    test "wählt mistral-nemo:12b wenn vorhanden" do
      assert Heuristik.pick_json_capable_model(["qwen3:30b-a3b", "mistral-nemo:12b"]) ==
               "mistral-nemo:12b"
    end

    test "wählt command-r:latest wenn mistral-nemo fehlt" do
      assert Heuristik.pick_json_capable_model(["qwen3:30b-a3b", "command-r:latest"]) ==
               "command-r:latest"
    end

    test "fällt auf mistral-nemo:12b zurück wenn nichts installiert" do
      assert Heuristik.pick_json_capable_model([]) == "mistral-nemo:12b"
    end
  end

  describe "median/1" do
    test "leere Liste → nil" do
      assert Heuristik.median([]) == nil
    end

    test "ungerade Länge" do
      assert Heuristik.median([1, 2, 3]) == 2
    end

    test "gerade Länge → arithmetisches Mittel" do
      assert Heuristik.median([1, 2, 3, 4]) == 2.5
    end
  end
end
