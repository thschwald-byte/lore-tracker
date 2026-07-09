defmodule Worker.MaterializerChronikConvergenceTest do
  @moduledoc """
  Issue #698 (I7-Bucket-D): ChronikClearedForSession + ChronikEntryChanged
  müssen unter Umordnung konvergieren.

  Früher löschte der Clear physisch → bei umgeordnetem Cold-Start-Replay (Clear
  vor den Entries eines früheren Runs) lebten die Entries beim späteren Apply
  wieder auf (#698-Zombies, #696-Klasse). Jetzt: Clear-Watermark pro Session,
  ein Eintrag ist live gdw. seine generation >= clear_key (die generation ist
  eine pro Run gemintete UUIDv7, Fallback: Envelope-event_id).

  `materialize_permutations/2` ist der wiederverwendbare I7-Baustein: dasselbe
  Event-Set in mehreren Reihenfolgen in je frische Mnesia → die Reads müssen
  identisch sein. Folge-Slices (Bucket C/C2/…) hängen ihre Folds hier an.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-conv-698"
  @sid "sess-1"

  setup do
    clear_all_tables!()
    reset_convergence_state!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  # Alle für die Chronik-Konvergenz relevanten Tabellen + Dedup/Cursor leeren,
  # damit dasselbe Event-Set pro Permutation frisch appliziert wird.
  defp reset_convergence_state! do
    for t <- [
          S.chronik_entries(),
          S.chronik_clear_marks(),
          S.applied_event_ids(),
          S.worker_state()
        ] do
      :mnesia.clear_table(t)
    end
  end

  defp entry_ev(id, event_id, opts \\ []) do
    payload = %{
      "id" => id,
      "campaign_id" => @cid,
      "in_game_date" => "Tag 1",
      "label" => Keyword.get(opts, :label, "L-#{id}"),
      "summary" => "S-#{id}",
      "session_id" => @sid
    }

    event("ChronikEntryChanged", payload, next_seq(), event_id: event_id)
  end

  defp clear_ev(event_id) do
    event(
      "ChronikClearedForSession",
      %{"campaign_id" => @cid, "session_id" => @sid, "cleared_by" => "llm"},
      next_seq(),
      event_id: event_id
    )
  end

  # seq nur fürs Envelope; die Tests permutieren das APPLY, nicht die seq-Werte.
  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  # Der I7-Baustein: `events` in mehreren Permutationen in je geleerte Mnesia
  # applien, `read_fn`-Ergebnis pro Permutation sammeln.
  defp materialize_permutations(events, read_fn) do
    perms = [
      events,
      Enum.reverse(events),
      rotate(events, 1),
      rotate(events, 2),
      rotate(events, 3)
    ]

    for perm <- perms do
      reset_convergence_state!()
      Enum.each(perm, &Materializer.apply_event/1)
      read_fn.()
    end
  end

  defp rotate(list, n), do: Enum.drop(list, n) ++ Enum.take(list, n)

  defp live_ids do
    Repo.list_chronik_entries(@cid) |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "Re-Run: Clear-Watermark unterdrückt alte Entries, konvergent unter Umordnung (#698)" do
    # Run 1: zwei Entries (e01/e02). Run 2: Clear (e03) + zwei NEUE Entries
    # (e04/e05, andere ids). Erwartung nach JEDER Reihenfolge: nur die Run-2-
    # Entries sind live — Run-1 durch den Clear-Watermark unterdrückt, nie Zombies.
    events = [
      entry_ev("chr-old-1", "e01"),
      entry_ev("chr-old-2", "e02"),
      clear_ev("e03"),
      entry_ev("chr-new-1", "e04"),
      entry_ev("chr-new-2", "e05")
    ]

    for r <- materialize_permutations(events, &live_ids/0) do
      assert r == ["chr-new-1", "chr-new-2"],
             "Chronik muss über alle Reihenfolgen auf die Run-2-Entries konvergieren, war: #{inspect(r)}"
    end
  end

  test "gleiche id, höheres event_id gewinnt (LWW-by-event_id, order-insensitiv)" do
    old = entry_ev("chr-x", "e01", label: "ALT")
    new = entry_ev("chr-x", "e09", label: "NEU")

    for order <- [[old, new], [new, old]] do
      reset_convergence_state!()
      Enum.each(order, &Materializer.apply_event/1)
      assert [%{label: "NEU"}] = Repo.list_chronik_entries(@cid)
    end
  end

  test "Entries desselben Runs (event_id > Clear) überleben den Clear" do
    # Der Producer emittiert den Clear VOR den Run-Entries → deren event_id ist
    # größer → sie bleiben live, egal in welcher Reihenfolge appliziert.
    events = [clear_ev("e01"), entry_ev("chr-a", "e02"), entry_ev("chr-b", "e03")]

    for r <- materialize_permutations(events, &live_ids/0) do
      assert r == ["chr-a", "chr-b"]
    end
  end

  test "ohne Clear-Mark sind alle Entries live (heutiges Verhalten, kein Regress)" do
    events = [entry_ev("chr-a", "e01"), entry_ev("chr-b", "e02")]

    for r <- materialize_permutations(events, &live_ids/0) do
      assert r == ["chr-a", "chr-b"]
    end
  end

  # Pipeline-Semantik: Clear + alle Entries EINES Runs teilen eine `generation`
  # (payload), die Envelope-event_ids sind zufällig (dürfen die Ordnung NICHT
  # bestimmen — das ist der eigentliche #698-Fix gegen UUIDv7-Sub-ms-Nicht-
  # Monotonie im Burst).
  defp entry_gen(id, generation) do
    payload = %{
      "id" => id,
      "campaign_id" => @cid,
      "in_game_date" => "Tag 1",
      "label" => "L-#{id}",
      "summary" => "S-#{id}",
      "session_id" => @sid,
      "generation" => generation
    }

    event("ChronikEntryChanged", payload, next_seq(), event_id: UUIDv7.generate())
  end

  defp clear_gen(generation) do
    event(
      "ChronikClearedForSession",
      %{
        "campaign_id" => @cid,
        "session_id" => @sid,
        "cleared_by" => "llm",
        "generation" => generation
      },
      next_seq(),
      event_id: UUIDv7.generate()
    )
  end

  test "run_id-Pfad: Clear + Entries teilen die Generation, konvergent trotz zufälliger event_ids" do
    # Run 1 (gen-1) + Run 2 (gen-2 > gen-1). Alle Envelope-event_ids zufällig →
    # NUR die payload-generation trägt die Ordnung. Nach JEDER Reihenfolge sind
    # nur die Run-2-Entries live.
    events = [
      clear_gen("gen-1"),
      entry_gen("g1-a", "gen-1"),
      entry_gen("g1-b", "gen-1"),
      clear_gen("gen-2"),
      entry_gen("g2-a", "gen-2"),
      entry_gen("g2-b", "gen-2")
    ]

    for r <- materialize_permutations(events, &live_ids/0) do
      assert r == ["g2-a", "g2-b"],
             "shared-generation-Run muss order-insensitiv auf Run 2 konvergieren, war: #{inspect(r)}"
    end
  end
end
