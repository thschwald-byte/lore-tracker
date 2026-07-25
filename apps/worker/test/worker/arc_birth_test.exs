defmodule Worker.ArcBirthTest do
  @moduledoc """
  Issue #903 (Epic #900 S2): die maschinelle Arc-Geburt im resolve-Schritt.

  Gepinnt: Geburt NUR für arc-kind-Stränge (context/rauschen nie), der
  Pairing-Guard als Duplikat-Schutz (Doppel-Lauf + Seed-Erweiterung),
  mark_arc-Override gebiert (dieselbe effektive Kind-Logik wie der Reader),
  Content-ID-Determinismus inkl. Cross-Campaign-Disambiguierung, und der
  resolve_campaign_threads-Vollpfad.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Recording.Pipeline.ThreadRegistry
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-birth-903"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1], apply: true)
    :ok
  end

  defp fact(id, thread) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "thread" => thread,
      "verified?" => true,
      "fact_type" => "ereignis"
    }
  end

  defp seed_facts!(facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s1", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-birth-#{seq}"
      )
    )
  end

  defp seed_registry!(kinds, seq, cluster_map \\ %{}) do
    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => cluster_map, "kinds" => kinds},
        seq,
        event_id: "trc-birth-#{seq}"
      )
    )
  end

  defp arcs do
    :mnesia.dirty_index_read(S.arcs(), @cid, :campaign_id)
    |> Enum.map(fn {_t, id, _cid, seeds, draft, _ak, _ag, _aw, _lk} ->
      %{id: id, seeds: seeds, draft: draft}
    end)
  end

  test "Geburt nur für arc-kind — context und rauschen gebären nie" do
    seed_facts!(
      [fact("f1", "der Auftrag"), fact("f2", "die Welt"), fact("f3", "das Protokoll")],
      100
    )

    seed_registry!(
      %{"der auftrag" => "arc", "die welt" => "context", "das protokoll" => "rauschen"},
      101
    )

    assert :ok = ThreadRegistry.birth_arcs(@cid)

    assert [%{seeds: ["der auftrag"], draft: draft}] = arcs()
    assert draft =~ "der Auftrag"
  end

  test "Doppel-Lauf ist idempotent (Pairing-Guard)" do
    seed_facts!([fact("f1", "der Auftrag")], 100)
    seed_registry!(%{"der auftrag" => "arc"}, 101)

    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert [arc1] = arcs()

    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert [^arc1] = arcs()
  end

  test "Seed-Erweiterung gebiert NICHT erneut (Schnittmengen-Pairing)" do
    seed_facts!([fact("f1", "der Auftrag")], 100)
    seed_registry!(%{"der auftrag" => "arc"}, 101)
    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert [%{id: arc_id}] = arcs()

    # Neues Fragment-Label clustert zum selben Kanon-Strang → Label-Menge
    # wächst, Schnittmenge mit den alten Seeds bleibt ≠ ∅ → kein Duplikat.
    seed_facts!([fact("f1", "der Auftrag"), fact("f2", "der Auftrags-Coup")], 102)

    seed_registry!(
      %{"der auftrag" => "arc"},
      103,
      %{"der auftrags-coup" => "der Auftrag"}
    )

    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert [%{id: ^arc_id}] = arcs()
  end

  test "mark_arc-Override gebiert (effektive Kind-Logik wie am Reader)" do
    seed_facts!([fact("f1", "die Welt")], 100)
    seed_registry!(%{"die welt" => "context"}, 101)

    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert arcs() == []

    Materializer.apply_event(
      event(
        "ThreadOverrideSet",
        %{
          "campaign_id" => @cid,
          "canonical" => "die Welt",
          "action" => "mark_arc",
          "set_by" => "did-1"
        },
        102,
        event_id: "tos-birth-1"
      )
    )

    assert :ok = ThreadRegistry.birth_arcs(@cid)
    assert [%{seeds: ["die welt"]}] = arcs()
  end

  test "arc_content_id: deterministisch + Cross-Campaign-disambiguiert" do
    labels = ["a", "b"]
    id1 = ThreadRegistry.arc_content_id("camp-1", labels)

    assert id1 == ThreadRegistry.arc_content_id("camp-1", labels)
    assert String.starts_with?(id1, "arc_")
    assert id1 != ThreadRegistry.arc_content_id("camp-2", labels)
    assert id1 != ThreadRegistry.arc_content_id("camp-1", ["a", "c"])
  end

  test "resolve_campaign_threads-Vollpfad gebiert im selben Schritt" do
    seed_facts!([fact("f1", "der Skandal")], 100)

    cluster_fn = fn _labels ->
      {:ok, %{map: %{"der skandal" => "der Skandal"}, kinds: %{"der skandal" => "arc"}}}
    end

    assert {:ok, _} = ThreadRegistry.resolve_campaign_threads(@cid, cluster_fn)
    assert [%{seeds: ["der skandal"]}] = arcs()
  end
end
