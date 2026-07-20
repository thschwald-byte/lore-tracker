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

  describe "republish_payload/3 — feldkonservativ (Issue #879)" do
    # Der Re-Key-Republish ersetzt die Row per LWW. Ließ er extraction_saw
    # weg, verlor die Dirty-Weiche (#866) ihre Zeit-Adresse und die erste
    # Kuration routete IMMER in die Voll-Adoption (Prod-Repro: changed=744
    # bei 4 kuratierten Blöcken). Dieser Test pinnt die Konservierung.
    test "extraction_saw + verify_backend/verify_model reisen mit" do
      row = %{
        session_id: "s1",
        campaign_id: "c1",
        facts: [fact("König", "könig", "a")],
        extraction_saw: %{"b_abc" => "hash1"},
        verify_backend: "local",
        verify_model: "qwen3:30b"
      }

      payload = ER.republish_payload(row, "c1", %{"könig" => "könig von böhmen"})

      assert payload["extraction_saw"] == %{"b_abc" => "hash1"}
      assert payload["verify_backend"] == "local"
      assert payload["verify_model"] == "qwen3:30b"
      # Re-Key wirkt weiterhin
      assert [%{"entity_id" => "könig von böhmen"}] = payload["facts"]
    end

    test "Alt-Row ohne Zeit-Adresse → leere Map, nie nil (Materializer-Vertrag)" do
      row = %{session_id: "s1", campaign_id: "c1", facts: [fact("A", "a", "x")]}
      payload = ER.republish_payload(row, "c1", %{})

      assert payload["extraction_saw"] == %{}
      assert payload["verify_backend"] == nil
    end
  end

  describe "Publisher-Tripwire (Issue #879)" do
    # Jeder SessionFactsExtracted-Publisher MUSS extraction_saw mitgeben —
    # ein neuer Publisher ohne das Feld clobbert die Zeit-Adresse per LWW
    # (exakt der #879-Bug). Grobkörniger Source-Scan als Stolperdraht:
    # jede Datei, die den Event-Kind publisht, muss extraction_saw erwähnen.
    test "jede Publisher-Datei trägt extraction_saw" do
      lib = Path.expand("../../../lib", __DIR__)

      publisher_files =
        Path.wildcard(Path.join(lib, "**/*.ex"))
        |> Enum.filter(fn f ->
          src = File.read!(f)

          String.contains?(src, "Shared.Events.session_facts_extracted()") and
            String.contains?(src, "publish")
        end)

      assert publisher_files != [], "Source-Scan fand keine Publisher — Pfad kaputt?"

      offenders =
        Enum.reject(publisher_files, &String.contains?(File.read!(&1), "extraction_saw"))

      assert offenders == [],
             "SessionFactsExtracted-Publisher ohne extraction_saw (clobbert die " <>
               "Zeit-Adresse der Dirty-Weiche per LWW, #879): #{inspect(offenders)}"
    end
  end
end
