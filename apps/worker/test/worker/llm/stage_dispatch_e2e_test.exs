defmodule Worker.LLM.StageDispatchE2ETest do
  @moduledoc """
  Issue #783 Phase 2 (Design G, zweite Plan-Review-Runde): E2E-Cross-Stage-
  Bleed-Test.

  Die Fehlerklasse, die #786 real produziert hat: eine Callsite oder ein
  Mapping-Pfad bleibt auf der falschen Stage hängen (z.B. Verify läuft still
  auf Stage-2-Konfiguration statt Stage 3). Isolierte Unit-Tests pro Schicht
  (`model_for`, `CloudHelper.model_for_stage`, `sampling_opts`, Callsite-Atome)
  fangen das einzeln — nicht aber die NAHT zwischen den Schichten, wenn beide
  Seiten je EINZELN korrekt aussehen, aber irgendwo dazwischen ein Copy-Paste-
  Fehler sitzt (Stage-Atom bleibt hängen, `@stage_to_setting`/`@stage_to_n`
  mapped falsch, `model_for_stage` liest die falsche Stage-Nummer).

  Setzt DREI unterschiedliche Backends für Stage 2/3/4 (lokal/anthropic/
  openai), lässt jedes Stage-Modell UNKONFIGURIERT und ruft
  `Worker.LLM.complete/3` direkt auf — kein Bypass/HTTP-Mock nötig (keine neue
  Test-Dependency), kein echter Netzwerk-Call. Jeder Call scheitert, aber mit
  einem STAGE- UND BACKEND-SPEZIFISCHEN Fehler-Signal:

  - Local (`Worker.LLM.Local.complete/2`) prüft das Modell VOR dem Endpoint →
    `{:error, {:no_model_configured, :summary}}` — das Tupel trägt das
    Stage-Atom direkt.
  - Cloud-Backends (`CloudHelper.model_for_stage/3`) RAISEN mit einer
    Message, die Provider-Label + Stage-Atom + den exakten
    `model_stage{n}_{backend}`-Settings-Key nennt — beweist, dass Verify auf
    Stage 3 (nicht 2 oder 4) UND auf :anthropic (nicht :openai) gelandet ist,
    rein aus der Fehlermeldung, ohne jeden Netzwerk-Call.

  Das beweist die komplette Dispatch-Kette Callsite → `@stage_to_setting` →
  `module_for` → Backend-Modul → `model_for_stage`, ohne echten LLM-Call.
  """

  use ExUnit.Case, async: false

  alias Worker.Settings

  setup do
    # worker_state ist NICHT in clear_all_tables! enthalten (hält den Seq-
    # Cursor, siehe test_helper.ex) — jeden hier relevanten Key explizit
    # zurücksetzen, damit dieser Test unabhängig von der Suite-Reihenfolge
    # ist (gleiche Flake-Klasse wie #66/#801, siehe llm_spend_cap_test.exs).
    for key <- [
          :backend_stage2,
          :backend_stage3,
          :backend_stage4,
          :model_stage2_local,
          :model_stage3_anthropic,
          :model_stage4_openai,
          :admin_discord_id
        ] do
      Worker.Repo.put_state(key, nil)
    end

    Settings.put(:backend_stage2, :local)
    Settings.put(:backend_stage3, :anthropic)
    Settings.put(:backend_stage4, :openai)
    # Cloud-Backends brauchen einen nicht-nil admin_discord_id, sonst blockt
    # Worker.LLM.check_spend_cap/4 schon VOR dem Backend-Dispatch mit
    # {:error, :no_admin} — das würde den eigentlichen Beweis (welches
    # Backend-Modul dispatcht) verdecken. Frischer discord_id ohne
    # persistierten User → check_cap_estimate fällt auf :ok (kein User-Row).
    Worker.Repo.put_state(:admin_discord_id, "e2e-dispatch-test-did")

    :ok
  end

  test "Stage 2 (Extraktion, :local) → {:no_model_configured, :summary} — beweist Local-Dispatch" do
    assert {:error, {:no_model_configured, :summary}} =
             Worker.LLM.complete(:summary, "irrelevant prompt")
  end

  test "Stage 3 (Verify, :anthropic) → Raise nennt Anthropic + :verify + model_stage3_anthropic" do
    assert_raise RuntimeError, ~r/Anthropic-Backend.*:verify.*model_stage3_anthropic/s, fn ->
      Worker.LLM.complete(:verify, "irrelevant prompt")
    end
  end

  test "Stage 4 (Render, :openai) → Raise nennt OpenAI + :render + model_stage4_openai" do
    assert_raise RuntimeError, ~r/OpenAI-Backend.*:render.*model_stage4_openai/s, fn ->
      Worker.LLM.complete(:render, "irrelevant prompt")
    end
  end

  test "kein Cross-Stage-Bleed: Vertauschen der Backends vertauscht auch die Fehlersignatur" do
    # Gegenprobe zur Bleed-Klasse selbst: wenn Stage 3 stattdessen auf
    # :openai und Stage 4 auf :anthropic zeigt, MUSS sich die Fehlermeldung
    # entsprechend vertauschen — sonst würde ein Bug, der die Backends
    # vertauscht, von den beiden Tests oben nicht gefangen.
    Settings.put(:backend_stage3, :openai)
    Settings.put(:backend_stage4, :anthropic)

    assert_raise RuntimeError, ~r/OpenAI-Backend.*:verify.*model_stage3_openai/s, fn ->
      Worker.LLM.complete(:verify, "irrelevant prompt")
    end

    assert_raise RuntimeError, ~r/Anthropic-Backend.*:render.*model_stage4_anthropic/s, fn ->
      Worker.LLM.complete(:render, "irrelevant prompt")
    end
  end
end
