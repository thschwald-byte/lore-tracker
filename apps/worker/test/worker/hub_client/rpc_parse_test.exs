defmodule Worker.HubClient.RpcParseTest do
  @moduledoc """
  Issue #608: Drift-Guard für die reinen Wire-Transform-Helfer der Hub→Worker-
  RPCs (`Worker.HubClient.Rpc`). Diese kodieren das Wire-Vokabular: die Preview-
  Segment-Shape (Hub rendert sie), die Settings-Key/Value-Coercion (String→Atom
  übers Wire) und die Secret-Redaction vor dem Logging. Drift hier entkoppelt
  Hub und Worker still.
  """
  use ExUnit.Case, async: true

  alias Worker.HubClient.Rpc

  describe "serialize_preview_segment/1 — Preview-Wire-Shape" do
    test "locked → %{kind: \"locked\", text}" do
      assert Rpc.serialize_preview_segment({:locked, "Hallo"}) == %{kind: "locked", text: "Hallo"}
    end

    test "heading_frame → %{kind: \"heading_frame\", text}" do
      assert Rpc.serialize_preview_segment({:heading_frame, "Titel"}) ==
               %{kind: "heading_frame", text: "Titel"}
    end

    test "editable → %{kind: \"editable\", slot, text} (slot + text als String)" do
      assert Rpc.serialize_preview_segment({:editable, :base, "Inhalt"}) ==
               %{kind: "editable", slot: "base", text: "Inhalt"}
    end
  end

  describe "coerce_setting_value/1 — Wire-Vokabular der Backend-Enums" do
    test "bekannte Backend-Strings → Atome" do
      assert Rpc.coerce_setting_value("local") == :local
      assert Rpc.coerce_setting_value("bundled") == :bundled
      assert Rpc.coerce_setting_value("anthropic") == :anthropic
      assert Rpc.coerce_setting_value("batch") == :batch
      # #451: fehlten vorher — backend_stage{n}="openai"/"google" blieb String
      # und Worker.LLM fiel still auf :local zurück.
      assert Rpc.coerce_setting_value("openai") == :openai
      assert Rpc.coerce_setting_value("google") == :google
    end

    test "unbekannter String bleibt String" do
      assert Rpc.coerce_setting_value("qwen2.5:7b") == "qwen2.5:7b"
    end

    test "Nicht-String bleibt unverändert" do
      assert Rpc.coerce_setting_value(600_000) == 600_000
      assert Rpc.coerce_setting_value(true) == true
    end
  end

  describe "parse_setting_key/2 — nur bekannte Keys passieren" do
    test "bekannter Key → {:ok, atom}" do
      known = MapSet.new([:backend_stage2, :http_timeout_ms])
      assert Rpc.parse_setting_key("backend_stage2", known) == {:ok, :backend_stage2}
    end

    test "existierendes Atom aber NICHT in known_keys → :error" do
      known = MapSet.new([:backend_stage2])
      # :node existiert garantiert als Atom, ist aber kein bekannter Setting-Key.
      assert Rpc.parse_setting_key("node", known) == :error
    end

    test "String ohne existierendes Atom → :error (kein Atom-Leak via to_existing_atom)" do
      known = MapSet.new([:backend_stage2])
      assert Rpc.parse_setting_key("definitiv_kein_existierendes_atom_xyz_608", known) == :error
    end

    test "Nicht-String → :error" do
      assert Rpc.parse_setting_key(123, MapSet.new()) == :error
    end

    test "pro-Backend-Modell-Keys (#451; seit #786 nur Slot 2) sind über known_keys gewhitelistet" do
      # #784: die per-Backend-Keys sind :no_default → NICHT mehr in defaults(),
      # aber weiter in der Write-Whitelist known_keys().
      known = Worker.Settings.known_keys()

      for b <- ~w(local anthropic openai google) do
        key = "model_stage2_#{b}"
        assert Rpc.parse_setting_key(key, known) == {:ok, String.to_existing_atom(key)}
      end
    end

    test "entfernter Legacy-Key (#784) wird verworfen" do
      known = Worker.Settings.known_keys()

      assert Rpc.parse_setting_key("model_stage2", known) == :error
    end

    test "#783 Phase 2: Stage-3/4-Keys sind jetzt bekannt (Verify/Render eigene Slots)" do
      known = Worker.Settings.known_keys()

      assert Rpc.parse_setting_key("model_stage3_local", known) ==
               {:ok, :model_stage3_local}

      assert Rpc.parse_setting_key("model_stage4_google", known) ==
               {:ok, :model_stage4_google}

      assert Rpc.parse_setting_key("backend_stage3", known) == {:ok, :backend_stage3}
    end
  end

  describe "clamp_ms/2 — Range-Sanity für *_ms-Keys (#784)" do
    test "Wert über dem 24h-Ceiling wird geclamped" do
      # 1_200_000_000 = ~13 Tage (real auf worker_prod passiert)
      assert Rpc.clamp_ms(:http_timeout_ms, 1_200_000_000) == 86_400_000
    end

    test "negativer Wert wird auf 0 geclamped" do
      assert Rpc.clamp_ms(:sync_tick_ms, -5) == 0
    end

    test "legitimer Wert bleibt unverändert" do
      assert Rpc.clamp_ms(:http_timeout_ms, 600_000) == 600_000
      assert Rpc.clamp_ms(:http_timeout_ms, 0) == 0
      assert Rpc.clamp_ms(:http_timeout_ms, 86_400_000) == 86_400_000
    end

    test "Nicht-_ms-Keys werden nie geclamped" do
      assert Rpc.clamp_ms(:ctx_stage2, 1_200_000_000) == 1_200_000_000
    end

    test "Nicht-Integer-Werte passieren unverändert" do
      assert Rpc.clamp_ms(:http_timeout_ms, "600000") == "600000"
      assert Rpc.clamp_ms(:local_endpoint, nil) == nil
    end
  end

  describe "redact_secrets/1 — API-Keys vor dem Logging maskieren" do
    test "Secret-Keys werden durch Längen-Notiz ersetzt, Key-Name bleibt" do
      out = Rpc.redact_secrets(%{anthropic_api_key: "sk-ant-123456"})
      assert out == %{anthropic_api_key: "<redacted 13 chars>"}
    end

    test "alle drei Secret-Keys werden erfasst" do
      out =
        Rpc.redact_secrets(%{
          anthropic_api_key: "a",
          openai_api_key: "bb",
          gemini_api_key: "ccc"
        })

      assert out.anthropic_api_key == "<redacted 1 chars>"
      assert out.openai_api_key == "<redacted 2 chars>"
      assert out.gemini_api_key == "<redacted 3 chars>"
    end

    test "Nicht-Secret-Keys bleiben unverändert" do
      assert Rpc.redact_secrets(%{backend_stage2: :anthropic}) == %{backend_stage2: :anthropic}
    end
  end
end
