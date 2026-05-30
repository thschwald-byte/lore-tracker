defmodule HubWeb.KnownIssuesPhase3Test do
  @moduledoc """
  Issue #68 Phase 3: Tests für die 10 zusätzlichen Hints (Ollama, Whisper-Stage-1,
  Spend-Cap, no_worker_token, http_error). Phase-2-Hints werden vom existierenden
  Test-File abgedeckt; dieses File coverage'd nur die Phase-3-Erweiterungen +
  die neue `known_types/0`-Liste.
  """

  use ExUnit.Case, async: true

  alias HubWeb.KnownIssues

  describe "Ollama-Hints" do
    test "ollama_unreachable hat 'ollama serve'-Tipp" do
      h = KnownIssues.hint("ollama_unreachable")
      assert h
      assert h.icon == "🔌"
      assert h.body =~ "ollama serve"
      assert h.body =~ "11434"
    end

    test "model_not_found hat 'ollama pull'-Tipp" do
      h = KnownIssues.hint("model_not_found")
      assert h
      assert h.body =~ "ollama pull"
    end
  end

  describe "Whisper-Hints (Stage 1)" do
    test "whisper_binary_missing verweist auf whisper.cpp" do
      h = KnownIssues.hint("whisper_binary_missing")
      assert h
      assert h.body =~ "whisper.cpp"
    end

    test "whisper_model_missing verweist auf ggml-Modelle" do
      h = KnownIssues.hint("whisper_model_missing")
      assert h
      assert h.body =~ "ggml" or h.body =~ "Modell downloaden"
    end

    test "whisper_failed nennt häufige Ursachen (RAM, korruptes WAV)" do
      h = KnownIssues.hint("whisper_failed")
      assert h
      assert h.body =~ "RAM" or h.body =~ "WAV"
    end

    test "whisper_empty nennt Mikro-Setup" do
      h = KnownIssues.hint("whisper_empty")
      assert h
      assert h.body =~ "Mikro"
    end

    test "whisper_sidecar_offline nennt pyannote/uvicorn" do
      h = KnownIssues.hint("whisper_sidecar_offline")
      assert h
      assert h.body =~ "pyannote" or h.body =~ "Sidecar"
    end
  end

  describe "Sonstige Phase-3-Hints" do
    test "spend_cap_exceeded verlinkt /admin/users" do
      h = KnownIssues.hint("spend_cap_exceeded")
      assert h
      assert h.icon == "💸"
      assert h.body =~ "/admin/users"
    end

    test "no_worker_token verweist auf Re-Pair-Flow" do
      h = KnownIssues.hint("no_worker_token")
      assert h
      assert h.body =~ "pairen"
    end

    test "http_error hat Kontext-Block-Hinweis" do
      h = KnownIssues.hint("http_error")
      assert h
      assert h.body =~ "Kontext" or h.body =~ "Status"
    end
  end

  describe "known_types/0 nach Phase 3" do
    test "enthält alle Phase-3-Codes" do
      types = KnownIssues.known_types()

      for t <- [
            "ollama_unreachable",
            "model_not_found",
            "spend_cap_exceeded",
            "no_worker_token",
            "whisper_binary_missing",
            "whisper_model_missing",
            "whisper_failed",
            "whisper_empty",
            "whisper_sidecar_offline"
          ] do
        assert t in types, "Phase-3-Code #{t} fehlt in known_types/0"
      end
    end

    test "Phase-2-Codes bleiben auch alle drin" do
      types = KnownIssues.known_types()

      for t <- [
            "empty_chronik",
            "no_key_configured",
            "upstream_auth",
            "upstream_rate_limit",
            "network_error",
            "upstream_error",
            "http_error",
            "timeout"
          ] do
        assert t in types, "Phase-2-Code #{t} wurde aus known_types/0 entfernt"
      end
    end
  end

  describe "fallback" do
    test "unknown type bleibt nil" do
      assert KnownIssues.hint("totally_unknown_xyz") == nil
    end

    test "nil-input bleibt nil" do
      assert KnownIssues.hint(nil) == nil
    end
  end
end
