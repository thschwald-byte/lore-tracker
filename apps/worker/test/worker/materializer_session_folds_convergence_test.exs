defmodule Worker.MaterializerSessionFoldsConvergenceTest do
  @moduledoc """
  Issue #781 (I7-Bucket-C, Teil 1): SessionFactsExtracted + SessionFaithfulness-
  Scored sind Overwrite-Folds per session_id. Mit LWW-by-event_id gewinnt unter
  Umordnung deterministisch das höhere event_id (spätere Extraktion/Scoring) —
  konvergent statt last-arrival. Permutations-Invarianz wie der #698-Pilot.

  (Der Permutations-Baustein ist hier lokal dupliziert; Konsolidierung nach
  `Worker.TestHelper` ist ein kleiner Folge-Cut.)
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-781"
  @sid "sess-781"

  setup do
    clear_all_tables!()
    reset!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp reset! do
    for t <- [
          S.session_facts(),
          S.session_faithfulness_scores(),
          S.applied_event_ids(),
          S.worker_state()
        ] do
      :mnesia.clear_table(t)
    end
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  defp permutations(events, read_fn) do
    perms = [events, Enum.reverse(events), rotate(events, 1)]

    for perm <- perms do
      reset!()
      Enum.each(perm, &Materializer.apply_event/1)
      read_fn.()
    end
  end

  defp rotate(l, n), do: Enum.drop(l, n) ++ Enum.take(l, n)

  defp facts_ev(event_id, facts) do
    event(
      "SessionFactsExtracted",
      %{"session_id" => @sid, "campaign_id" => @cid, "facts" => facts},
      next_seq(),
      event_id: event_id
    )
  end

  defp score_ev(event_id, score) do
    event(
      "SessionFaithfulnessScored",
      %{"session_id" => @sid, "campaign_id" => @cid, "score" => score, "claims" => []},
      next_seq(),
      event_id: event_id
    )
  end

  test "SessionFactsExtracted: höheres event_id gewinnt, konvergent unter Umordnung" do
    # e01: 1 Fakt (alte Extraktion), e02: 2 Fakten (neue). Egal in welcher
    # Reihenfolge appliziert — die neue (e02 > e01) gewinnt, nie ein Mischmasch.
    events = [
      facts_ev("e01", [%{"claim" => "alt"}]),
      facts_ev("e02", [%{"claim" => "neu-1"}, %{"claim" => "neu-2"}])
    ]

    for n <- permutations(events, fn -> Repo.get_session_facts(@sid).facts |> length() end) do
      assert n == 2, "spätere Extraktion (e02, 2 Fakten) muss immer gewinnen, war: #{n}"
    end
  end

  test "SessionFaithfulnessScored: höheres event_id gewinnt, konvergent unter Umordnung" do
    events = [score_ev("e01", 0.3), score_ev("e02", 0.9)]

    for s <- permutations(events, fn -> Repo.get_faithfulness_score(@sid).score end) do
      assert s == 0.9
    end
  end

  test "event_id-loser Alt-Event überschreibt eine reguläre Row nicht" do
    # Reguläre Extraktion (e05) zuerst, dann ein event_id-loses Event (Seed-
    # Analogon) — Letzteres darf die reguläre Row nicht clobbern.
    reset!()
    Materializer.apply_event(facts_ev("e05", [%{"claim" => "regulär"}]))

    no_id =
      event(
        "SessionFactsExtracted",
        %{"session_id" => @sid, "campaign_id" => @cid, "facts" => [%{"claim" => "seed"}]},
        next_seq()
      )

    Materializer.apply_event(no_id)

    assert [%{"claim" => "regulär"}] = Repo.get_session_facts(@sid).facts
  end
end
