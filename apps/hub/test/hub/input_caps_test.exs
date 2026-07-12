defmodule Hub.InputCapsTest do
  @moduledoc """
  Issue #636: pures Testset für Hub.InputCaps — Caps, Check-Grenzen,
  Error-Message-Formatierung, fail-loud bei unbekanntem Schlüssel.
  """
  use ExUnit.Case, async: true

  alias Hub.InputCaps

  describe "cap/1" do
    test "liefert konfigurierten Wert für bekannte Schlüssel" do
      # Werte sind das Issue-Akzeptanzkriterium — Änderung darf nicht stumm
      # passieren.
      assert InputCaps.cap(:campaign_name) == 200
      assert InputCaps.cap(:utterance_text) == 8_000
      assert InputCaps.cap(:summary_body) == 50_000
      assert InputCaps.cap(:epos_body) == 50_000
      assert InputCaps.cap(:chapter_body) == 50_000
      assert InputCaps.cap(:chronik_body) == 50_000
      assert InputCaps.cap(:theme_blurb) == 4_000
    end

    test "unbekannter Schlüssel → FunctionClauseError (fail-loud, kein stiller Passthrough)" do
      assert_raise FunctionClauseError, fn -> InputCaps.cap(:no_such_key) end
    end
  end

  describe "keys/0" do
    test "listet alle bekannten Schlüssel — zur Diagnose in Tests" do
      keys = InputCaps.keys()
      assert :campaign_name in keys
      assert :theme_blurb in keys
      assert :utterance_text in keys
      assert :summary_body in keys
      assert :epos_body in keys
      assert :chapter_body in keys
      assert :chronik_body in keys
    end
  end

  describe "check/2 — Grenzen (Byte-basiert)" do
    test "genau am Cap → :ok" do
      # 200 Bytes ASCII == 200 chars
      text = String.duplicate("x", 200)
      assert InputCaps.check(:campaign_name, text) == :ok
    end

    test "ein Byte über dem Cap → {:error, {:too_long, cap}}" do
      text = String.duplicate("x", 201)
      assert InputCaps.check(:campaign_name, text) == {:error, {:too_long, 200}}
    end

    test "UTF-8-Multibyte-Payload wird nach Bytes, nicht Codepoints gecappt" do
      # "ä" = 2 Bytes UTF-8. 101 mal "ä" = 202 Bytes — Cap für campaign_name (200) verletzt,
      # obwohl String.length == 101.
      text = String.duplicate("ä", 101)
      assert String.length(text) == 101
      assert byte_size(text) == 202
      assert InputCaps.check(:campaign_name, text) == {:error, {:too_long, 200}}
    end

    test "nil → :ok (Save-Handler entscheidet separat über Leere-Semantik)" do
      assert InputCaps.check(:campaign_name, nil) == :ok
    end

    test "Nicht-Binary → :ok (fällt in den Passthrough — der Save-Handler validiert Typ separat)" do
      assert InputCaps.check(:campaign_name, 42) == :ok
      assert InputCaps.check(:campaign_name, %{}) == :ok
    end

    test "Body-Cap: 50_000 Bytes exakt am Cap → :ok, 50_001 → :error" do
      assert InputCaps.check(:summary_body, String.duplicate("a", 50_000)) == :ok

      assert InputCaps.check(:summary_body, String.duplicate("a", 50_001)) ==
               {:error, {:too_long, 50_000}}
    end

    test "unbekannter Schlüssel → FunctionClauseError (cap/1 wirft)" do
      assert_raise FunctionClauseError, fn ->
        InputCaps.check(:no_such_key, "text")
      end
    end
  end

  describe "error_message/2" do
    test "enthält Label + Cap-Wert" do
      msg = InputCaps.error_message(:campaign_name, 200)
      assert msg =~ "Kampagnen-Name"
      assert msg =~ "200"
    end

    test "verschiedene Schlüssel bekommen verschiedene Labels" do
      assert InputCaps.error_message(:utterance_text, 8_000) =~ "Text"
      assert InputCaps.error_message(:summary_body, 50_000) =~ "Resümee"
      assert InputCaps.error_message(:epos_body, 50_000) =~ "Epos"
      assert InputCaps.error_message(:chapter_body, 50_000) =~ "Kapitel"
      assert InputCaps.error_message(:chronik_body, 50_000) =~ "Chronik"
      assert InputCaps.error_message(:theme_blurb, 4_000) =~ "Beschreibung"
    end
  end
end
