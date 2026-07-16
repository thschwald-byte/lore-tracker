defmodule Worker.Recording.Pipeline.EntityRegistryTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): die alias→entity-Registry
  (`Worker.Recording.Pipeline.EntityRegistry`). Pure Kerne — kein LLM, kein
  Mnesia: distinct_aliases, parse_clustering, apply_registry, resolve (mit
  injiziertem Cluster). Das LLM-Clustering + der Orchestrator sind die I/O-Grenze.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.EntityRegistry, as: ER

  defp fact(alias_name, entity_id, claim) do
    %{"character_alias" => alias_name, "entity_id" => entity_id, "claim" => claim}
  end

  test "distinct_aliases: nicht-leer, unique" do
    facts = [
      fact("König", "könig", "a"),
      fact("König", "könig", "b"),
      fact("", "", "c"),
      fact("Holmes", "holmes", "d")
    ]

    assert ER.distinct_aliases(facts) == ["König", "Holmes"]
  end

  describe "parse_clustering/1" do
    test "Cluster → Registry-Map (Alias + canonical → normalisierte canonical-id)" do
      raw =
        ~s({"entities":[
          {"canonical":"König von Böhmen","aliases":["König","Graf von Kramm","Wilhelm von Ormstein"]},
          {"canonical":"Holmes","aliases":["Holmes"]}
        ]})

      assert {:ok, reg} = ER.parse_clustering(raw)
      assert reg["könig"] == "könig von böhmen"
      assert reg["graf von kramm"] == "könig von böhmen"
      assert reg["wilhelm von ormstein"] == "könig von böhmen"
      # canonical mappt idempotent auf sich
      assert reg["könig von böhmen"] == "könig von böhmen"
      assert reg["holmes"] == "holmes"
    end

    test "Cluster ohne canonical wird übersprungen" do
      raw = ~s({"entities":[{"canonical":"","aliases":["X"]},{"canonical":"Y","aliases":["Y"]}]})
      assert {:ok, reg} = ER.parse_clustering(raw)
      assert reg == %{"y" => "y"}
    end

    test "Fehlerpfade" do
      assert {:error, :no_entities_key} = ER.parse_clustering(~s({"foo":1}))
      assert {:error, :parse_failed} = ER.parse_clustering("kein json")
      assert {:error, :parse_failed} = ER.parse_clustering(nil)
    end
  end

  describe "apply_registry/2" do
    test "re-keyt entity_id; unbekannter Alias behält bestehende entity_id; behält alle Fakten" do
      facts = [
        fact("König", "könig", "a"),
        fact("Graf von Kramm", "graf von kramm", "b"),
        fact("Holmes", "holmes", "c")
      ]

      reg = %{"könig" => "könig von böhmen", "graf von kramm" => "könig von böhmen"}
      out = ER.apply_registry(facts, reg)

      assert length(out) == 3

      assert Enum.map(out, & &1["entity_id"]) == [
               "könig von böhmen",
               "könig von böhmen",
               "holmes"
             ]

      # claims unangetastet
      assert Enum.map(out, & &1["claim"]) == ["a", "b", "c"]
    end
  end

  describe "resolve/2 — Guise-Merging end-to-end (injiziertes Cluster)" do
    test "König + Graf von Kramm → eine entity_id, Holmes bleibt eigen" do
      facts = [
        fact("König", "könig", "beauftragt Holmes"),
        fact("Graf von Kramm", "graf von kramm", "nimmt Maske ab"),
        fact("Holmes", "holmes", "ermittelt")
      ]

      cluster_fn = fn _aliases ->
        {:ok, %{"könig" => "könig von böhmen", "graf von kramm" => "könig von böhmen"}}
      end

      out = ER.resolve(facts, cluster_fn)

      assert Enum.map(out, & &1["entity_id"]) == [
               "könig von böhmen",
               "könig von böhmen",
               "holmes"
             ]
    end

    test "keine Aliase → unverändert" do
      facts = [%{"character_alias" => "", "entity_id" => "", "claim" => "x"}]
      assert ER.resolve(facts, fn _ -> {:ok, %{"a" => "b"}} end) == facts
    end

    test "Cluster-Fehler / leere Registry → unverändert (kein falscher Merge)" do
      facts = [fact("König", "könig", "a")]
      assert ER.resolve(facts, fn _ -> {:error, :boom} end) == facts
      assert ER.resolve(facts, fn _ -> {:ok, %{}} end) == facts
    end
  end
end
