defmodule Worker.LLM.StageDispatchE2ETest do
  @moduledoc """
  Issue #783 Phase 2 (Design G, zweite Plan-Review-Runde): E2E-Cross-Stage-
  Bleed-Test.

  Die Fehlerklasse, die #786 real produziert hat: eine Callsite oder ein
  Mapping-Pfad bleibt auf der falschen Stage hängen (z.B. Render läuft still
  auf Stage-2-Konfiguration statt Stage 4). Isolierte Unit-Tests pro Schicht
  (`model_for`, `CloudHelper.model_for_stage`, `sampling_opts`, Callsite-Atome)
  fangen das einzeln — nicht aber die NAHT zwischen den Schichten, wenn beide
  Seiten je EINZELN korrekt aussehen, aber irgendwo dazwischen ein Copy-Paste-
  Fehler sitzt (Stage-Atom bleibt hängen, `@stage_to_setting`/`@stage_to_n`
  mapped falsch, `model_for_stage` liest die falsche Stage-Nummer).

  Setzt ein Cloud-Backend für Stage 4 (seit J6 #1210 der einzige Render-Slot
  — Stage 5, das Render-Epos, ist entfallen); die
  Zuordnung (`:summary`) ist seit J4 (#1207) fest lokal, auch gegen ein altes
  `backend_stage2` im Store, und Stufe 3 ist entfallen. Jedes Stage-Modell
  bleibt UNKONFIGURIERT, der Test ruft
  `Worker.LLM.complete/3` direkt auf — kein Bypass/HTTP-Mock nötig (keine neue
  Test-Dependency), kein echter Netzwerk-Call. Jeder Call scheitert, aber mit
  einem STAGE- UND BACKEND-SPEZIFISCHEN Fehler-Signal:

  - Local (`Worker.LLM.Local.complete/2`) prüft das Modell VOR dem Endpoint →
    `{:error, {:no_model_configured, :summary}}` — das Tupel trägt das
    Stage-Atom direkt.
  - Cloud-Backends (`CloudHelper.model_for_stage/3`) RAISEN mit einer
    Message, die Provider-Label + Stage-Atom + den exakten
    `model_stage{n}_{backend}`-Settings-Key nennt — beweist, dass Render auf
    Stage 4 (nicht 2 oder 5) UND auf :openai (nicht :google) gelandet ist,
    rein aus der Fehlermeldung, ohne jeden Netzwerk-Call. Ein `:epos` ist
    seit J6 ein `KeyError` wie `:verify`.

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
          :backend_stage4,
          :model_stage2_local,
          :model_stage4_openai,
          # Der Google- und der Anthropic-Test brauchen auch diese Kombos
          # unkonfiguriert — sonst leakt ein Vorgänger-Test einen Wert rein
          # und das erwartete `:no model configured`-Raise bleibt aus
          # (order-abhängige Flake-Klasse #66/#801, real getriggert 2026-07).
          :model_stage4_google,
          :model_stage4_anthropic,
          :admin_discord_id
        ] do
      Worker.Repo.put_state(key, nil)
    end

    on_exit(fn -> Worker.Repo.put_state(:backend_stage2, nil) end)

    Settings.put(:backend_stage4, :openai)
    # Cloud-Backends brauchen einen nicht-nil admin_discord_id, sonst blockt
    # Worker.LLM.check_spend_cap/4 schon VOR dem Backend-Dispatch mit
    # {:error, :no_admin} — das würde den eigentlichen Beweis (welches
    # Backend-Modul dispatcht) verdecken. Frischer discord_id ohne
    # persistierten User → check_cap_estimate fällt auf :ok (kein User-Row).
    Worker.Repo.put_state(:admin_discord_id, "e2e-dispatch-test-did")

    :ok
  end

  test "Zuordnung (:summary) → {:no_model_configured, :summary} — beweist Local-Dispatch" do
    assert {:error, {:no_model_configured, :summary}} =
             Worker.LLM.complete(:summary, "irrelevant prompt")
  end

  test "J4 (#1207): :summary nimmt nie ein Cloud-Backend — auch nicht mit altem backend_stage2 im Store" do
    # Ein Bestandsworker, der die Extraktion früher per Cloud fuhr, trägt den
    # Wert noch roh im Store. Läse Worker.LLM ihn, ginge die Zuordnung an
    # Anthropic (hier: Raise aus CloudHelper bzw. :no_admin), statt lokal zu
    # scheitern. Lokal heißt: fehlendes Modell → {:no_model_configured, :summary}.
    for alt <- [:anthropic, :openai, :google, "anthropic"] do
      Worker.Repo.put_state(:backend_stage2, alt)

      assert {:error, {:no_model_configured, :summary}} =
               Worker.LLM.complete(:summary, "irrelevant prompt")
    end

    # Mit Modell, aber ohne Endpunkt scheitert es am lokalen Endpunkt — der
    # zweite Beweis, dass Worker.LLM.Local den Call bekommt.
    Worker.Repo.put_state(:local_endpoint, nil)
    Settings.put(:model_stage2_local, "jack-modell")
    on_exit(fn -> Worker.Repo.put_state(:model_stage2_local, nil) end)

    assert {:error, :no_local_endpoint_configured} =
             Worker.LLM.complete(:summary, "irrelevant prompt")
  end

  test "Stage 4 (Render, :openai) → Raise nennt OpenAI + :render + model_stage4_openai" do
    assert_raise RuntimeError, ~r/OpenAI-Backend.*:render.*model_stage4_openai/s, fn ->
      Worker.LLM.complete(:render, "irrelevant prompt")
    end
  end

  test "J6 (#1210): Stufe 5 (:epos) ist kein Stage-Atom mehr — laut statt still umgeleitet" do
    assert_raise KeyError, fn -> Worker.LLM.complete(:epos, "irrelevant prompt") end
  end

  test "Anthropic dispatcht ebenso: Stage 4 → :anthropic nennt Anthropic + model_stage4_anthropic" do
    Settings.put(:backend_stage4, :anthropic)

    assert_raise RuntimeError, ~r/Anthropic-Backend.*:render.*model_stage4_anthropic/s, fn ->
      Worker.LLM.complete(:render, "irrelevant prompt")
    end
  end

  test "J4 (#1207): Stufe 3 (:verify) ist kein Stage-Atom mehr — laut statt still umgeleitet" do
    assert_raise KeyError, fn -> Worker.LLM.complete(:verify, "irrelevant prompt") end
  end

  test "kein Bleed: ein anderes Backend für Stage 4 ändert auch die Fehlersignatur" do
    # Gegenprobe zur Bleed-Klasse selbst: zeigt Stage 4 auf :google statt
    # :openai, MUSS sich die Fehlermeldung mitändern — sonst würde ein Bug, der
    # das Backend festhält, vom Test oben nicht gefangen.
    Settings.put(:backend_stage4, :google)

    assert_raise RuntimeError, ~r/Google-Backend.*:render.*model_stage4_google/s, fn ->
      Worker.LLM.complete(:render, "irrelevant prompt")
    end
  end
end
