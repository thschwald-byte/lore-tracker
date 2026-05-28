defmodule Worker.Recording.PipelineVorgabeTest do
  @moduledoc """
  Issue #313: genre-neutraler Stage-3-Locked-Block + Darstellungsform-Branch,
  editierbarer Default-Ton (#308 zieht aus dem gesperrten Teil in den Flavor),
  und die preview_prompt/2-Segment-API für die Hub-Vorschau.

  Reine Funktions-Tests (kein Mnesia): preview_prompt mit `id: nil` umgeht den
  Content-Sample-Repo-Lookup und fällt auf den Platzhalter zurück.
  """
  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  describe "default_flavor/1 + effective_flavor/2" do
    test "epos hat einen Default-Ton, base nicht" do
      assert is_binary(Pipeline.default_flavor("epos"))
      assert Pipeline.default_flavor("base") == nil
    end

    test "campaign-Ton gewinnt, sonst Default, Whitespace fällt auf Default" do
      assert Pipeline.effective_flavor(%{"epos" => "Neon-Noir"}, "epos") == "Neon-Noir"
      assert Pipeline.effective_flavor(%{}, "epos") == Pipeline.default_flavor("epos")
      assert Pipeline.effective_flavor(%{"epos" => "   "}, "epos") == Pipeline.default_flavor("epos")
      assert Pipeline.effective_flavor(%{}, "base") == nil
    end
  end

  describe "epos_structure_block/1 — nur Form, kein Genre-Ton" do
    test "fliesstext = Prosa, stichpunkte = Liste, beide ohne Genre-Ton" do
      f = Pipeline.epos_structure_block("fliesstext")
      s = Pipeline.epos_structure_block("stichpunkte")

      assert f =~ "Fließtext"
      assert s =~ "Liste"

      for block <- [f, s] do
        refute block =~ ~r/novelle/i
        refute block =~ ~r/literarisch/i
        refute block =~ ~r/atmosphär/i
      end
    end
  end

  describe "build_epos_prompt: Default-Ton greift, Form schaltet" do
    test "ohne campaign-Flavor steckt der literarische Default-Ton im Prompt" do
      prompt = Pipeline.build_epos_prompt("", [], %{}, false, "fliesstext")
      assert prompt =~ "atmosphärische"
      assert prompt =~ "Fließtext"
    end

    test "stichpunkte-Form erzeugt Listen-Anweisung statt Fließtext-Regel" do
      prompt = Pipeline.build_epos_prompt("", [], %{}, false, "stichpunkte")
      assert prompt =~ "Liste"
      refute prompt =~ "KEINE Aufzählung"
    end
  end

  describe "preview_prompt/2" do
    test "epos: editable base+epos (epos = Default-Ton) + locked Blöcke" do
      segs = Pipeline.preview_prompt("epos", %{id: nil, flavors: %{}, vorgaben: %{}})

      assert Enum.any?(segs, &match?({:editable, "base", _}, &1))
      {:editable, "epos", epos_ton} = Enum.find(segs, &match?({:editable, "epos", _}, &1))
      assert epos_ton == Pipeline.default_flavor("epos")
      assert Enum.any?(segs, &match?({:locked, _}, &1))
    end

    test "stichpunkte-Vorgabe schlägt in den locked Task-Block durch" do
      camp = %{id: nil, flavors: %{}, vorgaben: %{"epos" => %{darstellungsform: "stichpunkte"}}}
      segs = Pipeline.preview_prompt("epos", camp)

      assert Enum.any?(segs, fn
               {:locked, t} when is_binary(t) -> t =~ "Liste"
               _ -> false
             end)
    end

    test "campaign-Ton überschreibt den Default im editable epos-Segment" do
      camp = %{id: nil, flavors: %{"epos" => "knapp, technisch"}, vorgaben: %{}}
      segs = Pipeline.preview_prompt("epos", camp)

      assert {:editable, "epos", "knapp, technisch"} =
               Enum.find(segs, &match?({:editable, "epos", _}, &1))
    end
  end
end
