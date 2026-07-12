defmodule Worker.Recording.PipelineVorgabeTest do
  @moduledoc """
  Issue #313/#320: Flavor-/Vorgabe-Mechanik + die preview_prompt/2-Segment-API
  für die Hub-Vorschau. Seit #787 zeigen die Slots `"summary"` und `"epos"` die
  **Render-Prompts** (Resümee/Epos aus verifizierten Fakten — dort wirkt der
  Stil, hinter dem Verify-Gate); die Extraktion ist stilfrei und hat keine
  Vorschau mehr.

  Reine Funktions-Tests (kein Mnesia): preview_prompt mit `id: nil` umgeht den
  Fakten-Sample-Repo-Lookup und fällt auf den Kürzungs-Marker zurück.
  """
  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "default_flavor/1 + effective_flavor/2" do
    test "kein Slot hat einen Default-Ton (der Epos-Render-Prompt trägt seinen Grundton selbst)" do
      assert Pipeline.default_flavor("epos") == nil
      assert Pipeline.default_flavor("summary") == nil
      assert Pipeline.default_flavor("base") == nil
    end

    test "campaign-Ton gewinnt; leer/Whitespace fällt auf den (nil-)Default" do
      assert Pipeline.effective_flavor(%{"summary" => "Neon-Noir"}, "summary") == "Neon-Noir"
      assert Pipeline.effective_flavor(%{}, "summary") == nil
      assert Pipeline.effective_flavor(%{"summary" => "   "}, "summary") == nil
      assert Pipeline.effective_flavor(%{}, "base") == nil
    end
  end

  describe "preview_prompt/2 — Resümee-Render-Prompt (summary-Slot, #787)" do
    test "ohne Flavors: nur locked Blöcke, kein editable-Segment" do
      segs = Pipeline.preview_prompt("summary", %{id: nil, flavors: %{}, vorgaben: %{}})

      assert Enum.any?(segs, &match?({:locked, _}, &1))
      refute Enum.any?(segs, &match?({:editable, _, _}, &1))
      # Der echte Render-Prompt steckt drin (byte-genau derselbe Builder).
      assert Enum.any?(segs, fn
               {:locked, t} when is_binary(t) -> t =~ "GESICHERTEN FAKTEN"
               _ -> false
             end)
    end

    test "base erscheint als editable-Segment, wenn gesetzt" do
      camp = %{id: nil, flavors: %{"base" => "Verona um 1300"}, vorgaben: %{}}
      segs = Pipeline.preview_prompt("summary", camp)

      assert {:editable, "base", "Verona um 1300"} =
               Enum.find(segs, &match?({:editable, "base", _}, &1))
    end

    test "campaign-Summary-Ton erscheint als editable summary-Segment" do
      camp = %{id: nil, flavors: %{"summary" => "knapp, technisch"}, vorgaben: %{}}
      segs = Pipeline.preview_prompt("summary", camp)

      assert {:editable, "summary", "knapp, technisch"} =
               Enum.find(segs, &match?({:editable, "summary", _}, &1))
    end

    test "gesetzte Überschrift (vorgaben.name) erscheint als editable name-Segment" do
      camp = %{id: nil, flavors: %{}, vorgaben: %{"summary" => %{name: "Protokoll"}}}
      segs = Pipeline.preview_prompt("summary", camp)

      assert {:editable, "name", "Protokoll"} =
               Enum.find(segs, &match?({:editable, "name", _}, &1))
    end
  end

  describe "preview_prompt/2 — Epos-Render-Prompt (epos-Slot, #787)" do
    test "epos-Ton erscheint als editable epos-Segment im Epos-Prompt" do
      camp = %{id: nil, flavors: %{"epos" => "hohes Pathos"}, vorgaben: %{}}
      segs = Pipeline.preview_prompt("epos", camp)

      assert {:editable, "epos", "hohes Pathos"} =
               Enum.find(segs, &match?({:editable, "epos", _}, &1))

      assert Enum.any?(segs, fn
               {:locked, t} when is_binary(t) -> t =~ "atmosphärische"
               _ -> false
             end)
    end

    test "KEIN name-Segment beim Epos — Kapitel-Kopf ist deterministisch (#752)" do
      camp = %{id: nil, flavors: %{}, vorgaben: %{"epos" => %{name: "Ballade"}}}
      segs = Pipeline.preview_prompt("epos", camp)

      refute Enum.any?(segs, &match?({:editable, "name", _}, &1))
      # Auch nicht als Text im Prompt gelandet.
      refute Enum.any?(segs, fn
               {:locked, t} when is_binary(t) -> t =~ "Ballade"
               _ -> false
             end)
    end
  end
end
