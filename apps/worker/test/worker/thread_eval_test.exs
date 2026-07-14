defmodule Worker.ThreadEvalTest do
  use ExUnit.Case, async: true

  alias Worker.ThreadEval

  @entities [
    %{"canonical" => "Sherlock Holmes", "variants" => ["Holmes"]},
    %{"canonical" => "König von Böhmen", "variants" => ["Wilhelm von Ormstein", "der König"]},
    %{"canonical" => "Irene Adler", "variants" => ["Irene", "Irene Norton"]},
    %{"canonical" => "die Fotografie", "variants" => ["das Foto", "Foto"]},
    %{"canonical" => "Godfrey Norton", "variants" => ["Norton"]}
  ]

  # Mini-Ground-Truth, das die Kern-Falle des echten Skandal-Sets spiegelt:
  # Erpressung ↔ Gegenspiel sind entity-untrennbar (Gegenspiel hat keine
  # unterscheidende Entität), Erpressung ist der must_not_resolve-Strang.
  @fact_key %{
    "required_entities" => @entities,
    "threads" => [
      %{
        "canonical" => "Erpressung mit der Fotografie",
        "label_variants" => ["Erpressung", "die Fotografie", "Foto"],
        "core_entities" => [
          "König von Böhmen",
          "Irene Adler",
          "die Fotografie",
          "Sherlock Holmes"
        ],
        "resolved" => false
      },
      %{
        "canonical" => "Irenes Gegenspiel gegen Holmes",
        "label_variants" => ["Irenes Gegenspiel", "Irenes List", "Irene durchschaut Holmes"],
        "core_entities" => ["Irene Adler", "Sherlock Holmes"],
        "resolved" => true
      },
      %{
        "canonical" => "Irenes Heirat mit Norton",
        "label_variants" => ["Heirat mit Norton", "die Trauung"],
        "core_entities" => ["Irene Adler", "Godfrey Norton"],
        "resolved" => true
      }
    ],
    "must_not_merge_threads" => [
      %{"pair" => ["Erpressung mit der Fotografie", "Irenes Gegenspiel gegen Holmes"]}
    ],
    "must_not_resolve" => [%{"thread" => "Erpressung mit der Fotografie"}]
  }

  defp fact(claim, thread, opts \\ []) do
    %{
      "claim" => claim,
      "character_alias" => Keyword.get(opts, :alias, ""),
      "thread" => thread,
      "fact_type" => Keyword.get(opts, :fact_type, "ereignis")
    }
  end

  # Sauber getrennte, konsistent gelabelte Extraktion — der Ideal-Fall.
  # (Funktion statt Modul-Attribut: @-Attribute können `fact/2` nicht aufrufen.)
  defp perfect do
    [
      fact("Der König beauftragt Holmes, das Foto zu beschaffen.", "Erpressung"),
      fact("Irene droht, die Fotografie an die Braut zu senden.", "Erpressung"),
      fact("Holmes plant einen Feueralarm, um das Foto zu finden.", "Erpressung"),
      fact("Irene hatte Holmes durchschaut und ihm verkleidet nachgespürt.", "Irenes List"),
      fact("Irene grüßt Holmes als Mann verkleidet.", "Irenes List"),
      fact("Irene und Norton heiraten in der Kirche.", "Heirat mit Norton", alias: "Norton"),
      fact("Norton eilt zur Trauung.", "Heirat mit Norton", alias: "Norton")
    ]
  end

  describe "distinguishing_entities/1" do
    test "nur Entitäten in genau einem Strang zählen als unterscheidend" do
      dist = ThreadEval.distinguishing_entities(@fact_key["threads"])

      # Erpressung: König + Fotografie sind einzigartig; Irene/Holmes nicht.
      assert MapSet.equal?(
               dist["Erpressung mit der Fotografie"],
               MapSet.new(["König von Böhmen", "die Fotografie"])
             )

      # Gegenspiel: Irene + Holmes tauchen anderswo auf → LEER (nur label-matchbar).
      assert MapSet.equal?(dist["Irenes Gegenspiel gegen Holmes"], MapSet.new())

      # Heirat: Norton ist einzigartig.
      assert MapSet.equal?(dist["Irenes Heirat mit Norton"], MapSet.new(["Godfrey Norton"]))
    end
  end

  describe "group_threads/2" do
    test "gruppiert nach rohem Label, sammelt kanonische Entitäten + Auflösungs-Flag" do
      groups = ThreadEval.group_threads(perfect(), @entities)
      labels = groups |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["Erpressung", "Heirat mit Norton", "Irenes List"]

      erp = Enum.find(groups, &(&1.label == "Erpressung"))
      assert erp.fact_count == 3
      assert "die Fotografie" in erp.entities
      assert "König von Böhmen" in erp.entities
      refute erp.resolved
    end

    test "Fakten ohne thread-Label werden ignoriert (pre-Slice-B)" do
      facts = [%{"claim" => "irgendein Fakt ohne thread-Feld"}]
      assert ThreadEval.group_threads(facts, @entities) == []
    end
  end

  describe "score/2 — Ideal-Fall" do
    test "voller Recall, keine Fragmentierung, kein Merge, keine falsche Auflösung" do
      s = ThreadEval.score(perfect(), @fact_key)

      assert s.thread_recall.rate == 1.0
      assert s.thread_recall.missing == []
      assert s.fragmentation.mean_labels_per_thread == 1.0
      assert s.fragmentation.fragmented == 0
      assert s.false_merge.rate == 0.0
      assert s.false_resolve.rate == 0.0
    end
  end

  describe "score/2 — Fragmentierung" do
    test "ein Soll-Strang über zwei Labels erhöht mean_labels_per_thread" do
      fragmented =
        perfect() ++
          [fact("Der König zahlt Holmes ein hohes Honorar.", "die Fotografie")]

      s = ThreadEval.score(fragmented, @fact_key)

      # Erpressung wird jetzt von "Erpressung" UND "die Fotografie" abgedeckt.
      assert s.thread_recall.rate == 1.0
      assert s.fragmentation.fragmented == 1
      assert s.fragmentation.mean_labels_per_thread > 1.0
    end
  end

  describe "score/2 — false_merge (detektierbar)" do
    test "ein Label, das beide Paar-Glieder trifft, ist ein Merge" do
      # Label matcht Erpressung (enthält "Foto") UND Gegenspiel (enthält "Irenes List").
      merged = [
        fact("Irene durchschaut Holmes und behält das Foto.", "Irenes List um das Foto"),
        fact("Der König sorgt sich um das Foto.", "Irenes List um das Foto")
      ]

      s = ThreadEval.score(merged, @fact_key)

      assert s.false_merge.violated == 1
      assert s.false_merge.rate == 1.0
      [detail] = s.false_merge.details
      assert detail.violated
      assert "Irenes List um das Foto" in detail.offending_labels
    end
  end

  describe "score/2 — false_resolve" do
    test "eine auflösung im Erpressungs-Strang verletzt must_not_resolve" do
      facts =
        perfect() ++
          [
            fact("Der Skandal ist beigelegt, der König ist erleichtert.", "Erpressung",
              fact_type: "auflösung"
            )
          ]

      s = ThreadEval.score(facts, @fact_key)

      assert s.false_resolve.violated == 1
      assert s.false_resolve.rate == 1.0
      [detail] = s.false_resolve.details
      assert detail.thread == "Erpressung mit der Fotografie"
      assert detail.resolved_flagged
    end

    test "eine auflösung im Gegenspiel-Strang verletzt must_not_resolve NICHT" do
      facts =
        perfect() ++
          [fact("Irenes Brief enthüllt alles.", "Irenes List", fact_type: "auflösung")]

      s = ThreadEval.score(facts, @fact_key)
      assert s.false_resolve.rate == 0.0
    end
  end

  describe "score/2 — leere Extraktion (vor Slice B)" do
    test "Fakten ohne thread-Feld → ehrlicher Null-Report, kein Crash" do
      facts = [%{"claim" => "Holmes untersucht den Fall."}, %{"claim" => "Watson hilft."}]
      s = ThreadEval.score(facts, @fact_key)

      assert s.thread_recall.rate == 0.0
      assert s.thread_recall.recalled == 0
      assert s.produced_threads == 0
      assert s.grouped_fact_count == 0
      assert s.total_fact_count == 2
      assert s.false_merge.rate == 0.0
      assert s.false_resolve.rate == 0.0
    end
  end

  describe "score/2 — echter Fact-Key" do
    test "der committed skandal-boehmen-Fact-Key hat die drei Thread-Blöcke" do
      path = "../hub/priv/seeds/skandal-boehmen/fact-key.json"
      fact_key = path |> File.read!() |> Jason.decode!()

      assert length(fact_key["threads"]) == 3
      assert length(fact_key["must_not_merge_threads"]) == 1
      assert length(fact_key["must_not_resolve"]) == 1

      # Scorer läuft sauber gegen den echten Key (leere Produktion = Null-Report).
      s = ThreadEval.score([], fact_key)
      assert s.thread_recall.total == 3
      assert s.thread_recall.rate == 0.0
    end
  end
end
