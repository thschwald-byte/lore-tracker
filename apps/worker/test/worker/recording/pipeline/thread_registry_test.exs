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

    test "rauschen wird als dritter kind erkannt; echte Unbekannte bleiben arc (#901)" do
      assert %{kinds: kinds} =
               ThreadRegistry.build_map([
                 %{
                   "canonical" => "das Protokoll",
                   "labels" => ["die Testdaten sammeln"],
                   "kind" => "rauschen"
                 },
                 %{"canonical" => "der Auftrag", "labels" => [], "kind" => "arc"},
                 %{"canonical" => "Kaputt", "labels" => [], "kind" => "quatsch"}
               ])

      # "rauschen" ist explizit erkannt; die Fail-Safe-Semantik für ECHTE
      # Unbekannte (→ arc, sichtbar) bleibt unangetastet.
      assert kinds == %{
               "das protokoll" => "rauschen",
               "der auftrag" => "arc",
               "kaputt" => "arc"
             }
    end

    test "Clustering-Prompt + Schema kennen die rauschen-Klasse (#901)" do
      prompt = ThreadRegistry.build_clustering_prompt(["das Protokoll"])
      assert prompt =~ ~s("rauschen")
      assert prompt =~ "Meta-/Tisch-/Werkzeug-Gerede"
      # Zweifels-Regel: nie rauschen für Spielwelt-Wissen.
      assert prompt =~ "nie `\"rauschen\"`"
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

  describe "new_raw_labels/2 (#842)" do
    test "trennt bereits bekannte (normalisiert) von neuen Roh-Labels" do
      persisted = %{"der skandal" => "die Fotografie", "der brief" => "der Brief"}

      assert ThreadRegistry.new_raw_labels(
               ["der Skandal", "  Der Brief  ", "der Verrat"],
               persisted
             ) == ["der Verrat"]
    end

    test "leere persistierte Map → alles ist neu" do
      assert ThreadRegistry.new_raw_labels(["a", "b"], %{}) == ["a", "b"]
    end
  end

  describe "existing_anchors/1 (#842)" do
    test "distinkte ROHE Kanon-Texte, keine Duplikate" do
      persisted = %{
        "der skandal" => "die Fotografie",
        "auftrag des königs" => "die Fotografie",
        "der brief" => "der Brief"
      }

      assert Enum.sort(ThreadRegistry.existing_anchors(persisted)) ==
               Enum.sort(["die Fotografie", "der Brief"])
    end
  end

  describe "cap_anchors/3 (#842)" do
    test "größte Cluster zuerst, Tie-Break alphabetisch (deterministisch)" do
      persisted = %{
        "a1" => "Groß",
        "a2" => "Groß",
        "a3" => "Groß",
        "b1" => "Mittel",
        "b2" => "Mittel",
        "c1" => "Klein",
        "z1" => "AuchKlein"
      }

      anchors = ThreadRegistry.existing_anchors(persisted)

      assert ThreadRegistry.cap_anchors(anchors, persisted, 2) == ["Groß", "Mittel"]
      # Tie-Break bei Größen-Gleichstand ("Klein"/"AuchKlein" je 1 Label):
      # alphabetisch, damit der Index-Vertrag zum Prompt deterministisch bleibt.
      assert ThreadRegistry.cap_anchors(anchors, persisted, 4) ==
               ["Groß", "Mittel", "AuchKlein", "Klein"]
    end

    test "n ≥ Anzahl Anker → unveränderte (sortierte) Liste" do
      persisted = %{"a" => "Eins", "b" => "Zwei"}
      anchors = ThreadRegistry.existing_anchors(persisted)

      assert length(ThreadRegistry.cap_anchors(anchors, persisted, 200)) == 2
    end
  end

  describe "merge_incremental_result/4 (#842)" do
    test "Anker-Treffer: nur labels werden zugeordnet, Text+kind bleiben unangetastet" do
      existing_map = %{"der skandal" => "die Fotografie"}
      existing_kinds = %{"die fotografie" => "arc"}
      anchors = ["die Fotografie"]

      groups = [
        %{"anchor_index" => 1, "canonical" => "IGNORIERT", "kind" => "rauschen", "labels" => ["der Verrat"]}
      ]

      result = ThreadRegistry.merge_incremental_result(existing_map, existing_kinds, groups, anchors)

      assert result.map["der verrat"] == "die Fotografie"
      # Bestehender Eintrag unangetastet.
      assert result.map["der skandal"] == "die Fotografie"
      # kind NICHT geflippt trotz "rauschen" in der Response.
      assert result.kinds == %{"die fotografie" => "arc"}
    end

    test "anchor_index 0 (oder out-of-range) ohne Kollision → echte neue Gruppe" do
      existing_map = %{"der skandal" => "die Fotografie"}
      existing_kinds = %{"die fotografie" => "arc"}
      anchors = ["die Fotografie"]

      groups = [
        %{
          "anchor_index" => 0,
          "canonical" => "der Verrat des Barons",
          "kind" => "arc",
          "labels" => ["der Verrat"]
        },
        # Out-of-range-Index degradiert identisch zu anchor_index: 0.
        %{
          "anchor_index" => 99,
          "canonical" => "das Bündnis",
          "kind" => "context",
          "labels" => ["das Bündnis"]
        }
      ]

      result = ThreadRegistry.merge_incremental_result(existing_map, existing_kinds, groups, anchors)

      assert result.map["der verrat"] == "der Verrat des Barons"
      assert result.map["der verrat des barons"] == "der Verrat des Barons"
      assert result.kinds["der verrat des barons"] == "arc"
      assert result.map["das bündnis"] == "das Bündnis"
      assert result.kinds["das bündnis"] == "context"
    end

    test "Kollisions-Guard: neue Gruppe normalisiert gleich einem bestehenden (auch gecappten) Kanon → Attach, kein Kind-Flip" do
      # "Die Fotografie" existiert bereits, ist aber NICHT unter den (gecappten)
      # sichtbaren Ankern — genau der Fall, den der Guard abdecken muss.
      existing_map = %{"der skandal" => "die Fotografie"}
      existing_kinds = %{"die fotografie" => "arc"}
      anchors = []

      groups = [
        %{
          "anchor_index" => 0,
          "canonical" => "die fotografie",
          "kind" => "rauschen",
          "labels" => ["der Beweis"]
        }
      ]

      result = ThreadRegistry.merge_incremental_result(existing_map, existing_kinds, groups, anchors)

      assert result.map["der beweis"] == "die Fotografie"
      # Kein Schatten-Strang, kein Kind-Flip — kinds bleibt exakt der alte Stand.
      assert result.kinds == %{"die fotografie" => "arc"}
    end

    test "Within-Batch-Dedupe: zwei neue Gruppen derselben Response normalisieren gleich → vereinigt" do
      groups = [
        %{"anchor_index" => 0, "canonical" => "Der Kult", "kind" => "arc", "labels" => ["Kult A"]},
        %{"anchor_index" => 0, "canonical" => "der kult", "kind" => "arc", "labels" => ["Kult B"]}
      ]

      result = ThreadRegistry.merge_incremental_result(%{}, %{}, groups, [])

      # Beide Labels landen unter EINEM Kanon-Text (dem der ersten Gruppe).
      assert result.map["kult a"] == "Der Kult"
      assert result.map["kult b"] == "Der Kult"
      assert map_size(result.kinds) == 1
    end

    test "leerer canonical bei neuer Gruppe wird übersprungen (analog build_map/1)" do
      groups = [%{"anchor_index" => 0, "canonical" => "", "kind" => "arc", "labels" => ["x"]}]

      assert ThreadRegistry.merge_incremental_result(%{}, %{}, groups, []) == %{map: %{}, kinds: %{}}
    end
  end

  describe "build_incremental_prompt/2 + incremental_clustering_json_schema (#842)" do
    test "Prompt enthält numerierte neue Labels + numerierte Anker + rauschen-Klasse" do
      prompt = ThreadRegistry.build_incremental_prompt(["der Verrat"], ["die Fotografie"])

      assert prompt =~ "1. der Verrat"
      assert prompt =~ "1. die Fotografie"
      assert prompt =~ "anchor_index"
      assert prompt =~ "rauschen"
    end

    test "leere Anker-Liste → expliziter Hinweis statt leerer Sektion" do
      prompt = ThreadRegistry.build_incremental_prompt(["a"], [])
      assert prompt =~ "noch keine bestehenden Stränge"
    end
  end

  describe "parse_incremental_clustering/2 (#842)" do
    test "gültige Response → Gruppen mit anchor_index" do
      raw =
        ~s({"threads":[{"anchor_index":1,"canonical":"ignoriert","kind":"arc","labels":["der Verrat"]}]})

      assert {:ok, [group]} = ThreadRegistry.parse_incremental_clustering(raw, ["der Verrat"])
      assert group["anchor_index"] == 1
      assert group["labels"] == ["der Verrat"]
    end

    test "halluziniertes Label (nicht angefragt) wird aus der Gruppe gefiltert" do
      raw =
        ~s({"threads":[{"anchor_index":0,"canonical":"X","kind":"arc","labels":["der Verrat","erfundenes Label"]}]})

      assert {:ok, [group]} = ThreadRegistry.parse_incremental_clustering(raw, ["der Verrat"])
      assert group["labels"] == ["der Verrat"]
    end

    test "Gruppe komplett halluziniert (keine echten Labels übrig) wird verworfen" do
      raw = ~s({"threads":[{"anchor_index":0,"canonical":"X","kind":"arc","labels":["erfunden"]}]})

      assert {:ok, []} = ThreadRegistry.parse_incremental_clustering(raw, ["der Verrat"])
    end

    test "JSON ohne threads-Key / Garbage / nil → eigene Fehler-Atome (getrennt von parse_clustering/1)" do
      assert {:error, :no_incremental_threads_key} =
               ThreadRegistry.parse_incremental_clustering(~s({"foo":1}), [])

      assert {:error, :incremental_thread_parse_failed} =
               ThreadRegistry.parse_incremental_clustering("kein json {{{", [])

      assert {:error, :incremental_thread_parse_failed} =
               ThreadRegistry.parse_incremental_clustering(nil, [])
    end
  end

  describe "resolve_campaign_threads/2 (#842, inkrementell)" do
    test "erster Lauf: alles neu, leere Anker-Liste an cluster_fn" do
      seed_facts!(1, [
        %{"id" => "f1", "claim" => "a", "thread" => "der Skandal"},
        %{"id" => "f2", "claim" => "b", "thread" => "der Brief"}
      ])

      cluster_fn = fn new_labels, anchors ->
        assert Enum.sort(new_labels) == ["der Brief", "der Skandal"]
        assert anchors == []

        {:ok,
         [
           %{
             "anchor_index" => 0,
             "canonical" => "die Fotografie",
             "kind" => "arc",
             "labels" => ["der Skandal", "der Brief"]
           }
         ]}
      end

      assert {:ok, registry} = ThreadRegistry.resolve_campaign_threads(@cid, cluster_fn)
      assert registry["der skandal"] == "die Fotografie"
      assert registry["der brief"] == "die Fotografie"
      assert Repo.get_thread_registry(@cid) == registry
    end

    test "zweiter Lauf: nur das neue Label an cluster_fn, bestehende Einträge unverändert" do
      seed_facts!(1, [%{"id" => "f1", "claim" => "a", "thread" => "der Skandal"}])

      assert {:ok, _} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _new, _anchors ->
                 {:ok,
                  [
                    %{
                      "anchor_index" => 0,
                      "canonical" => "die Fotografie",
                      "kind" => "arc",
                      "labels" => ["der Skandal"]
                    }
                  ]}
               end)

      seed_facts!(2, [%{"id" => "f2", "claim" => "b", "thread" => "der Verrat"}])

      cluster_fn = fn new_labels, anchors ->
        assert new_labels == ["der Verrat"]
        assert anchors == ["die Fotografie"]

        {:ok,
         [
           %{
             "anchor_index" => 1,
             "canonical" => "IGNORIERT",
             "kind" => "rauschen",
             "labels" => ["der Verrat"]
           }
         ]}
      end

      assert {:ok, registry} = ThreadRegistry.resolve_campaign_threads(@cid, cluster_fn)
      assert registry["der skandal"] == "die Fotografie"
      assert registry["der verrat"] == "die Fotografie"
      assert Repo.get_thread_kinds(@cid) == %{"die fotografie" => "arc"}
    end

    test "Null-Diff-Lauf: keine neuen Labels → cluster_fn NICHT aufgerufen" do
      seed_facts!(1, [%{"id" => "f1", "claim" => "a", "thread" => "der Skandal"}])

      assert {:ok, _} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _new, _anchors ->
                 {:ok,
                  [
                    %{
                      "anchor_index" => 0,
                      "canonical" => "die Fotografie",
                      "kind" => "arc",
                      "labels" => ["der Skandal"]
                    }
                  ]}
               end)

      assert {:ok, registry} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _new, _anchors ->
                 flunk("cluster_fn darf ohne neue Labels nicht gerufen werden")
               end)

      assert registry["der skandal"] == "die Fotografie"
    end

    test "ausgelassenes Label (Modell deckt nicht alle new_labels ab) → Selbstheilung beim nächsten Lauf" do
      seed_facts!(1, [
        %{"id" => "f1", "claim" => "a", "thread" => "der Skandal"},
        %{"id" => "f2", "claim" => "b", "thread" => "der Brief"}
      ])

      # Modell "vergisst" "der Brief" komplett in seiner Antwort.
      assert {:ok, registry} =
               ThreadRegistry.resolve_campaign_threads(@cid, fn _new, _anchors ->
                 {:ok,
                  [
                    %{
                      "anchor_index" => 0,
                      "canonical" => "die Fotografie",
                      "kind" => "arc",
                      "labels" => ["der Skandal"]
                    }
                  ]}
               end)

      refute Map.has_key?(registry, "der brief")

      # Nächster Lauf (keine neuen Fakten) erkennt "der Brief" erneut als neu —
      # der Diff basiert auf der persistierten Map, kein separates Tracking.
      cluster_fn = fn new_labels, _anchors ->
        assert new_labels == ["der Brief"]

        {:ok,
         [
           %{"anchor_index" => 0, "canonical" => "der Brief", "kind" => "context", "labels" => ["der Brief"]}
         ]}
      end

      assert {:ok, registry2} = ThreadRegistry.resolve_campaign_threads(@cid, cluster_fn)
      assert registry2["der brief"] == "der Brief"
      assert registry2["der skandal"] == "die Fotografie"
    end
  end

  describe "full_recluster_campaign_threads/2" do
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

      assert {:ok, registry} = ThreadRegistry.full_recluster_campaign_threads(@cid, cluster_fn)
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
               ThreadRegistry.full_recluster_campaign_threads(@cid, fn _ ->
                 flunk("cluster_fn darf ohne Labels nicht gerufen werden")
               end)

      assert Repo.get_thread_registry(@cid) == %{}
    end

    test "Cluster-Fehler → {:error, reason}, nichts persistiert" do
      seed_facts!(1, [%{"id" => "f1", "claim" => "a", "thread" => "der Skandal"}])

      assert {:error, :thread_parse_failed} =
               ThreadRegistry.full_recluster_campaign_threads(@cid, fn _ ->
                 {:error, :thread_parse_failed}
               end)

      assert Repo.get_thread_registry(@cid) == %{}
    end
  end
end
