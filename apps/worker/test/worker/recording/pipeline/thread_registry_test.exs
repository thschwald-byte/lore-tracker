defmodule Worker.Recording.Pipeline.ThreadRegistryTest do
  @moduledoc """
  Issue #832 (Epic #829 Slice C): die campaign-weite Handlungsbogen-Cluster-Map.
  Pure Kerne (distinct_threads/parse_clustering/build_map) + die Orchestrierung
  `resolve_campaign_threads/2` mit injizierter cluster_fn (kein LLM) — inkl. dem
  Beweis, dass die Fakten NICHT re-keyt werden (Whole-Snapshot-Artefakt).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Pipeline.ThreadRegistry
  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-thr-reg-832"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp seed_facts!(seq, facts) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{seq}", "campaign_id" => @cid, "facts" => facts},
        seq
      )
    )
  end

  describe "distinct_threads/1" do
    test "distinkte, nicht-leere, getrimmte thread-Labels" do
      facts = [
        %{"thread" => "der Skandal"},
        %{"thread" => "  der Skandal  "},
        %{"thread" => "der Brief"},
        %{"thread" => ""},
        %{"claim" => "kein thread-Feld"}
      ]

      assert ThreadRegistry.distinct_threads(facts) == ["der Skandal", "der Brief"]
    end
  end

  describe "parse_clustering/1 + build_map/1" do
    test "gültiger Cluster-Output → normalisiertes-Label→canonical-Map + kinds (#885)" do
      raw =
        ~s({"threads":[{"canonical":"die Fotografie","labels":["der Skandal","Auftrag des Königs"],"kind":"arc"},{"canonical":"das viktorianische London","labels":["das viktorianische London"],"kind":"context"}]})

      assert {:ok, %{map: map, kinds: kinds}} = ThreadRegistry.parse_clustering(raw)
      # Schlüssel normalisiert (lowercase), Wert = menschenlesbare canonical-Form;
      # canonical mappt auf sich selbst (idempotent).
      assert map["die fotografie"] == "die Fotografie"
      assert map["der skandal"] == "die Fotografie"
      assert map["auftrag des königs"] == "die Fotografie"
      # kinds keyed auf normalisiertem canonical.
      assert kinds["die fotografie"] == "arc"
      assert kinds["das viktorianische london"] == "context"
    end

    test "fehlendes/unbekanntes kind → \"arc\" (fail-safe: bleibt im Fäden-Panel)" do
      assert %{kinds: kinds} =
               ThreadRegistry.build_map([
                 %{"canonical" => "Ohne Kind", "labels" => []},
                 %{"canonical" => "Kaputt", "labels" => [], "kind" => "quatsch"}
               ])

      assert kinds == %{"ohne kind" => "arc", "kaputt" => "arc"}
    end

    test "JSON ohne threads-Key → :no_threads_key; Garbage/nil → :thread_parse_failed" do
      assert {:error, :no_threads_key} = ThreadRegistry.parse_clustering(~s({"foo":1}))
      assert {:error, :thread_parse_failed} = ThreadRegistry.parse_clustering("kein json {{{")
      assert {:error, :thread_parse_failed} = ThreadRegistry.parse_clustering(nil)
    end

    test "Cluster ohne canonical wird übersprungen" do
      assert ThreadRegistry.build_map([%{"canonical" => "", "labels" => ["x"]}]) ==
               %{map: %{}, kinds: %{}}
    end
  end

  describe "resolve_campaign_threads/2" do
    test "clustert campaign-weite Roh-Labels + persistiert die Map (KEIN Fakt-Re-Key)" do
      seed_facts!(1, [
        %{"id" => "f1", "claim" => "a", "thread" => "der Skandal"},
        %{"id" => "f2", "claim" => "b", "thread" => "der Brief"}
      ])

      seed_facts!(2, [%{"id" => "f1", "claim" => "c", "thread" => "Auftrag des Königs"}])

      cluster_fn = fn labels ->
        assert Enum.sort(labels) == ["Auftrag des Königs", "der Brief", "der Skandal"]

        {:ok,
         %{
           map: %{
             "der skandal" => "die Fotografie",
             "auftrag des königs" => "die Fotografie",
             "der brief" => "der Brief"
           },
           kinds: %{"die fotografie" => "arc", "der brief" => "context"}
         }}
      end

      assert {:ok, registry} = ThreadRegistry.resolve_campaign_threads(@cid, cluster_fn)
      assert map_size(registry) == 3

      # Persistiert via Intents-local-apply → ThreadRegistryComputed → Tabelle;
      # die #885-Klassifikation reist im selben Snapshot.
      assert Repo.get_thread_registry(@cid) == registry
      assert Repo.get_thread_kinds(@cid) == %{"die fotografie" => "arc", "der brief" => "context"}

      # Fakten UNVERÄNDERT — thread bleibt das Roh-Label (Whole-Snapshot, kein Re-Key).
      [f | _] = Repo.get_session_facts("#{@cid}-s1").facts
      assert f["thread"] == "der Skandal"
    end

    test "keine Labels → {:ok, %{}}, cluster_fn nicht gerufen, nichts persistiert" do
      seed_facts!(1, [%{"id" => "f1", "claim" => "a", "thread" => ""}])

      assert {:ok, %{}} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _ ->
                 flunk("cluster_fn darf ohne Labels nicht gerufen werden")
               end)

      assert Repo.get_thread_registry(@cid) == %{}
    end

    test "Cluster-Fehler → {:error, reason}, nichts persistiert" do
      seed_facts!(1, [%{"id" => "f1", "claim" => "a", "thread" => "der Skandal"}])

      assert {:error, :thread_parse_failed} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _ ->
                 {:error, :thread_parse_failed}
               end)

      assert Repo.get_thread_registry(@cid) == %{}
    end
  end
end
