defmodule HubWeb.Probelauf.HeuristikTest do
  @moduledoc """
  Issue #74 / #786 — Probelauf-Heuristik (Wahrheitsbild-nativ) liefert die
  richtige Empfehlung. Reine Datentransformation, deshalb async.
  """

  use ExUnit.Case, async: true

  alias HubWeb.Probelauf.Heuristik

  @ok {"ok", 5_000, nil}

  defp session(
         num,
         step_outcomes,
         facts \\ %{"n_facts" => 10, "n_grounded" => 8, "n_verified" => 6}
       ) do
    defaults = %{
      "extract" => @ok,
      "verify" => @ok,
      "render" => @ok,
      "timeline" => {"ok", 100, nil},
      "render_epos" => @ok
    }

    stages =
      defaults
      |> Map.merge(step_outcomes)
      |> Enum.into(%{}, fn {step, {outcome, ms, error_type}} ->
        {step, %{"outcome" => outcome, "duration_ms" => ms, "error_type" => error_type}}
      end)

    %{"number" => num, "utterance_count" => 10, "stages" => stages, "facts" => facts}
  end

  describe "build/3 — Wahrheitsbild-Regeln" do
    test "alle Schritte ok → 'beibehalten', kein KV, Trichter-Zeile enthalten" do
      {text, kv} = Heuristik.build([session(1, %{}), session(2, %{})], [])

      assert kv == %{}
      assert text =~ "✅ Alle Schritte"
      assert text =~ "Verify-Trichter"
      assert text =~ "20 Fakten → 16 geerdet → 12 verifiziert"
    end

    test "Timeout in extract → http_timeout_ms-KV + extract_chunk_tokens-Hint" do
      {text, kv} = Heuristik.build([session(1, %{"extract" => {"timeout", nil, nil}})], [])

      assert kv == %{"http_timeout_ms" => 600_000}
      assert text =~ "⏱ Timeout in extract"
      assert text =~ "extract_chunk_tokens"
    end

    test "extract-failed mit extraction_empty → Extraktor-Modell-KV auf pro-Backend-Key" do
      sessions = [session(1, %{"extract" => {"failed", 2_000, "extraction_empty"}})]

      {text, kv} = Heuristik.build(sessions, ["qwen2.5:7b", "mistral-nemo:12b"], "local")

      assert kv == %{"model_stage2_local" => "mistral-nemo:12b"}
      assert text =~ "🚫 Extraktion"
    end

    test "extract-failed mit all_chunks_failed + fremdem Backend → sanitized auf local" do
      sessions = [session(1, %{"extract" => {"failed", 2_000, "all_chunks_failed"}})]

      {_text, kv} = Heuristik.build(sessions, [], "b0rken")

      assert kv == %{"model_stage2_local" => "mistral-nemo:12b"}
    end

    test "verify-failed mit sidecar_offline → Text-Hint ohne KV" do
      sessions = [session(1, %{"verify" => {"failed", 100, "sidecar_offline"}})]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{}
      assert text =~ "🔌"
      assert text =~ "faithfulness_sidecar_url"
    end

    test "niedrige Verify-Rate → judge_model-Hint ohne KV" do
      sessions = [session(1, %{}, %{"n_facts" => 100, "n_grounded" => 50, "n_verified" => 10})]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{}
      assert text =~ "⚖ Verify-Rate niedrig"
      assert text =~ "judge_model"
    end

    test "timeline-failed → Bug-Hinweis (deterministischer Schritt), kein KV" do
      sessions = [session(1, %{"timeline" => {"failed", 50, "other"}})]

      {text, kv} = Heuristik.build(sessions, [])

      assert kv == %{}
      assert text =~ "🐛 Timeline"
    end

    test "render_epos mit no_verified_facts → Verweis auf den Trichter" do
      sessions = [
        session(
          1,
          %{"render_epos" => {"failed", 10, "no_verified_facts"}},
          %{"n_facts" => 5, "n_grounded" => 0, "n_verified" => 0}
        )
      ]

      {text, _kv} = Heuristik.build(sessions, [])

      assert text =~ "🪫 Render ohne verifizierte Fakten"
    end

    test "Timeout + Extraktions-Fail → beide KV-Empfehlungen merged" do
      sessions = [
        session(1, %{
          "extract" => {"failed", 2_000, "extraction_empty"},
          "render" => {"timeout", nil, nil}
        })
      ]

      {_text, kv} = Heuristik.build(sessions, ["mistral-nemo:12b"])

      assert kv == %{
               "http_timeout_ms" => 600_000,
               "model_stage2_local" => "mistral-nemo:12b"
             }
    end

    test "Alt-Chain-Report (ohne facts-Key) → nur Hinweis, kein KV" do
      chain_session = %{
        "number" => 1,
        "utterance_count" => 10,
        "stages" => %{"stage2" => %{"outcome" => "ok", "duration_ms" => 5_000}}
      }

      {text, kv} = Heuristik.build([chain_session], [])

      assert kv == %{}
      assert text =~ "Alt-Report"
    end

    test "leere Sessions-Liste → Hinweis, kein KV" do
      {text, kv} = Heuristik.build([], [])
      assert kv == %{}
      assert text =~ "Keine Sessions"
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
