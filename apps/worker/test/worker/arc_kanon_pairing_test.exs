defmodule Worker.ArcKanonPairingTest do
  @moduledoc """
  Issue #1071: Arcs paaren über den KANON, nicht über Roh-Labels.

  Der Anlass ist an `free-seattle-bereinigt` gemessen (worker_prod, 2026-08-20):
  12 Arc-Zeilen für 7 Stränge, 5 davon verwaist. Die Ursache war keine
  Mengen-Änderung, sondern eine **Umformulierung** durch das Modell —
  „auftrag" → „der auftrag", „charakter" → „kodex' charakter". Eine
  Mengen-Schnittmenge sieht darin zwei verschiedene Strings und lässt den alten
  Bogen samt Kuration liegen.

  Die Cluster-Map löst genau diese Synonymie längst auf (sie ist dafür da); die
  Arc-Paarung ging bloß an ihr vorbei.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-arckanon-1071"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1], apply: true)
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
        event_id: "sfe-kanon-#{seq}"
      )
    )
  end

  defp registry!(cluster_map, seq, kinds \\ %{}) do
    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => cluster_map, "kinds" => kinds},
        seq,
        event_id: "trc-kanon-#{seq}"
      )
    )
  end

  defp arc!(arc_id, seeds, seq) do
    Materializer.apply_event(
      event(
        "ArcCreated",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "leitfrage_draft" => "F #{arc_id}?",
          "seed_raw_labels" => seeds
        },
        seq,
        event_id: "ac-kanon-#{seq}"
      )
    )
  end

  defp closed!(arc_id, seq) do
    Materializer.apply_event(
      event(
        "ArcClosed",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "grund" => "geloest",
          "wasserlinie_session" => 9,
          "set_by" => "d"
        },
        seq,
        event_id: "acl-kanon-#{seq}"
      )
    )
  end

  defp leitfrage!(arc_id, text, seq) do
    Materializer.apply_event(
      event(
        "LeitfrageSet",
        %{"arc_id" => arc_id, "campaign_id" => @cid, "text" => text, "set_by" => "d"},
        seq,
        event_id: "lf-kanon-#{seq}"
      )
    )
  end

  defp thread_ov!(action, canonical, seq, extra) do
    Materializer.apply_event(
      event(
        "ThreadOverrideSet",
        Map.merge(
          %{"campaign_id" => @cid, "canonical" => canonical, "action" => action, "set_by" => "d"},
          extra
        ),
        seq,
        event_id: "to-kanon-#{seq}"
      )
    )
  end

  defp find(canonical), do: Enum.find(Repo.campaign_threads(@cid), &(&1.canonical == canonical))

  describe "der eigentliche #1071-Fall: das Modell formuliert um" do
    test "ein Bogen mit ALTEM Label paart weiter, wenn beide auf denselben Kanon zeigen" do
      # Der Bogen wurde geboren, als das Modell noch „auftrag" schrieb.
      arc!("arc_alt", ["auftrag"], 100)

      # Beim nächsten Lauf schreibt es „der Auftrag" — die Cluster-Map führt
      # beide auf denselben Kanon.
      seed_facts!([fact("f1", "der Auftrag")], 101)

      registry!(
        %{"auftrag" => "Auftrags-Management", "der auftrag" => "Auftrags-Management"},
        102
      )

      t = find("Auftrags-Management")
      assert t, "der Strang muss unter dem Kanon existieren"

      # Vor #1071 war das nil: {"auftrag"} ∩ {"der auftrag"} = ∅.
      assert t.arc_id == "arc_alt"
    end

    test "ohne gemeinsamen Kanon paart nichts — kein Fehlgriff auf einen fremden Bogen" do
      arc!("arc_fremd", ["ganz anderes thema"], 100)
      seed_facts!([fact("f1", "der Auftrag")], 101)
      registry!(%{"der auftrag" => "Auftrags-Management"}, 102)

      assert find("Auftrags-Management").arc_id == nil
    end

    test "Label nicht in der Cluster-Map → Rückfall auf das Roh-Label, Paarung wie bisher" do
      arc!("arc_roh", ["der auftrag"], 100)
      seed_facts!([fact("f1", "der Auftrag")], 101)
      # Keine Registry — der Strang heißt wie sein Roh-Label.
      assert find("der Auftrag").arc_id == "arc_roh"
    end
  end

  describe "Gleichstand: die Kuration gewinnt" do
    setup do
      # Zwei Bögen, beide kanonisch auf denselben Strang — der reale
      # Duplikat-Fall aus free-seattle-bereinigt.
      arc!("arc_zzz_kuratiert", ["auftrag"], 100)
      arc!("arc_aaa_leer", ["der auftrag"], 101)
      seed_facts!([fact("f1", "der Auftrag")], 102)

      registry!(
        %{"auftrag" => "Auftrags-Management", "der auftrag" => "Auftrags-Management"},
        103
      )

      :ok
    end

    test "eine kuratierte Leitfrage schlägt die alphabetisch kleinere arc_id" do
      # Ohne Kuration gewänne arc_aaa_leer (kleinere id).
      assert find("Auftrags-Management").arc_id == "arc_aaa_leer"

      leitfrage!("arc_zzz_kuratiert", "Kommt der Auftrag durch?", 104)

      t = find("Auftrags-Management")
      assert t.arc_id == "arc_zzz_kuratiert"
      assert t.leitfrage == "Kommt der Auftrag durch?"
      assert t.leitfrage_kuratiert?
    end

    test "ein gesetzter Akt zählt genauso als Kuration" do
      closed!("arc_zzz_kuratiert", 104)

      t = find("Auftrags-Management")
      assert t.arc_id == "arc_zzz_kuratiert"
      assert t.arc_status == "geschlossen"
    end
  end

  describe "Kurations-Overlays" do
    test "ein merge-Override zieht den Bogen mit — die Paarung hinkt ihm nicht hinterher" do
      seed_facts!([fact("f1", "Nebenstrang"), fact("f2", "Hauptstrang")], 100)
      arc!("arc_haupt", ["nebenstrang"], 101)

      # Der Bogen sitzt auf dem Nebenstrang; ein Member führt diesen in den
      # Hauptstrang zusammen. Der Bogen muss dem Ziel folgen.
      thread_ov!("merge", "Nebenstrang", 102, %{"merge_into" => "Hauptstrang"})

      assert find("Nebenstrang") == nil, "der Nebenstrang ist zusammengeführt"
      assert find("Hauptstrang").arc_id == "arc_haupt"
    end

    test "ein rename-Override trennt den Bogen NICHT von seinem Strang" do
      # `canonical` ist nach einem rename der Anzeigetext; die Identität bleibt
      # `key_canonical`. Auf dem Anzeigetext zu paaren hieße: Umbenennen im
      # Panel wirft den Bogen ab — still.
      seed_facts!([fact("f1", "der Auftrag")], 100)
      arc!("arc_r", ["der auftrag"], 101)
      thread_ov!("rename", "der Auftrag", 102, %{"new_name" => "Der große Coup"})

      t = find("Der große Coup")
      assert t, "der Strang trägt den neuen Anzeigenamen"
      assert t.arc_id == "arc_r"
    end
  end

  describe "Review-Register" do
    test "das Duplikat bekommt einen Merge-Vorschlag auf den paarenden Bogen" do
      arc!("arc_aaa", ["auftrag"], 100)
      arc!("arc_zzz", ["der auftrag"], 101)
      seed_facts!([fact("f1", "der Auftrag")], 102)

      registry!(
        %{"auftrag" => "Auftrags-Management", "der auftrag" => "Auftrags-Management"},
        103
      )

      review = Repo.campaign_threads_with_review(@cid).arc_review
      assert [verwaist] = review.verwaiste

      # Über Roh-Labels fand der Vorschlag das Duplikat gerade dann nicht, wenn
      # es durch eine Umformulierung entstanden war — also im Regelfall.
      assert verwaist.arc_id == "arc_zzz"
      assert verwaist.vorschlag_arc_id == "arc_aaa"
    end
  end
end
