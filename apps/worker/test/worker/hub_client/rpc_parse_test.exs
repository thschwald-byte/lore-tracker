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

    test "neue pro-Backend-Modell-Keys (#451) sind über die Defaults gewhitelistet" do
      known = Worker.Settings.defaults() |> Map.keys() |> MapSet.new()

      for n <- 2..4, b <- ~w(local anthropic openai google) do
        key = "model_stage#{n}_#{b}"
        assert Rpc.parse_setting_key(key, known) == {:ok, String.to_existing_atom(key)}
      end
    end
  end

  describe "remap_legacy_model_keys/1 — Legacy-Write auf gewinnenden Key spiegeln (#451)" do
    test "model_stage{n} wird zusätzlich auf den pro-Backend-Key des Batch-Backends gelegt" do
      out = Rpc.remap_legacy_model_keys(%{model_stage2: "m", backend_stage2: :anthropic})
      assert out[:model_stage2_anthropic] == "m"
      # Legacy-Key bleibt (Alias-Write, Alt-Leser)
      assert out[:model_stage2] == "m"
    end

    test "ohne Backend im Batch zählt das persistierte backend_stage{n} (Default :local)" do
      out = Rpc.remap_legacy_model_keys(%{model_stage3: "m3"})
      assert out[:model_stage3_local] == "m3"
    end

    test "Batch ohne Legacy-Model-Keys bleibt unverändert" do
      kv = %{http_timeout_ms: 1, model_stage2_google: "g"}
      assert Rpc.remap_legacy_model_keys(kv) == kv
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
