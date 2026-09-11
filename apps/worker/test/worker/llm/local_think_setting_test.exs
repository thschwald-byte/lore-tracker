defmodule Worker.LLM.LocalThinkSettingTest do
  @moduledoc """
  Issue #874: pro-Stage-Thinking-Level-Setting (`:model_stage{n}_think`,
  Default `:auto`). Für Reasoning-Modelle mit nicht abschaltbarem Thinking
  (gpt-oss) sendet die Payload `think: "<level>"` statt `think: false`.
  Pur testbar über `think_mode_for_stage/1` + `resolve_think/2` — Muster
  `local_endpoint_test.exs` (#736/#855) inkl. Setting-Save/Restore.
  """

  use ExUnit.Case, async: false

  alias Worker.LLM.Local
  alias Worker.Settings

  setup do
    keys = [
      :model_stage2_think,
      :model_stage4_think,
      :model_stage5_think
    ]

    before = Enum.into(keys, %{}, fn k -> {k, Settings.get(k)} end)

    on_exit(fn ->
      Enum.each(keys, fn k ->
        case before[k] do
          nil -> :ok
          v -> Settings.put(k, v)
        end
      end)
    end)

    :ok
  end

  describe "think_mode_for_stage/1" do
    test "H: Default ist :auto (ungesetzt = heutiges #700-Verhalten)" do
      Settings.put(:model_stage2_think, :auto)
      assert Local.think_mode_for_stage(:summary) == :auto
    end

    test "H: gesetztes Level kommt pro Stage-Slot zurück — drei unabhängige Slots" do
      Settings.put(:model_stage2_think, :medium)
      Settings.put(:model_stage4_think, :high)
      Settings.put(:model_stage5_think, :low)

      assert Local.think_mode_for_stage(:summary) == :medium
      assert Local.think_mode_for_stage(:render) == :high
      assert Local.think_mode_for_stage(:epos) == :low
    end

    test "J4 (#1207): Stufe 3 (:verify) ist kein Stage-Atom mehr" do
      assert_raise FunctionClauseError, fn -> Local.think_mode_for_stage(:verify) end
    end

    test "R: String-Werte aus dem UI-Form-Save greifen ebenfalls" do
      Settings.put(:model_stage2_think, "high")
      assert Local.think_mode_for_stage(:summary) == :high

      Settings.put(:model_stage2_think, "auto")
      assert Local.think_mode_for_stage(:summary) == :auto
    end

    test "R: :transcribe fällt konstant auf :auto — kein Local-LLM-Weg" do
      Settings.put(:model_stage2_think, :medium)
      assert Local.think_mode_for_stage(:transcribe) == :auto
    end

    test "F/N: Garbage-Werte fallen auf :auto zurück (defensiv)" do
      Settings.put(:model_stage2_think, "foo")
      assert Local.think_mode_for_stage(:summary) == :auto

      Settings.put(:model_stage2_think, :bogus)
      assert Local.think_mode_for_stage(:summary) == :auto

      Settings.put(:model_stage2_think, nil)
      assert Local.think_mode_for_stage(:summary) == :auto
    end
  end

  describe "resolve_think/2 — Per-Call-Override (Muster #855)" do
    test ":think-Override schlägt das Stage-Setting" do
      Settings.put(:model_stage4_think, :auto)
      assert Local.resolve_think([think: :high], :render) == :high
    end

    test "\"medium\" als String-Override greift ebenfalls" do
      Settings.put(:model_stage4_think, :auto)
      assert Local.resolve_think([think: "medium"], :render) == :medium
    end

    test ":auto-Override schlägt ein gesetztes Level (andere Richtung)" do
      Settings.put(:model_stage4_think, :high)
      assert Local.resolve_think([think: :auto], :render) == :auto
    end

    test "ohne :think-Opt gilt das Stage-Setting (unverändert)" do
      Settings.put(:model_stage4_think, :low)
      assert Local.resolve_think([], :render) == :low
    end

    test "unerwarteter Override-Wert fällt auf das Stage-Setting zurück (defensiv)" do
      Settings.put(:model_stage4_think, :medium)
      assert Local.resolve_think([think: "bogus"], :render) == :medium
      assert Local.resolve_think([think: :nonsense], :render) == :medium
      assert Local.resolve_think([think: nil], :render) == :medium
    end

    test "der Override schreibt NICHTS in die Settings (kein persistenter Leak)" do
      Settings.put(:model_stage4_think, :auto)
      assert Local.resolve_think([think: :high], :render) == :high
      assert Local.think_mode_for_stage(:render) == :auto
    end
  end
end
