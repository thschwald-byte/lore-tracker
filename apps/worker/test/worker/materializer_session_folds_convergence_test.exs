defmodule Worker.MaterializerSessionFoldsConvergenceTest do
  @moduledoc """
  Issue #781 (I7-Bucket-C, Teil 1): SessionFactsExtracted + SessionFaithfulness-
  Scored sind Overwrite-Folds per session_id. Mit LWW-by-event_id gewinnt unter
  Umordnung deterministisch das höhere event_id (spätere Extraktion/Scoring) —
  konvergent statt last-arrival. Permutations-Invarianz wie der #698-Pilot.

  `materialize_permutations/2` ist seit #766 in `Worker.TestHelper`
  konsolidiert (war hier lokal fast identisch dupliziert).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo

  @cid "camp-781"
  @sid "sess-781"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

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

    for n <-
          materialize_permutations(events, fn ->
            Repo.get_session_facts(@sid).facts |> length()
          end) do
      assert n == 2, "spätere Extraktion (e02, 2 Fakten) muss immer gewinnen, war: #{n}"
    end
  end

  test "SessionFaithfulnessScored: höheres event_id gewinnt, konvergent unter Umordnung" do
    events = [score_ev("e01", 0.3), score_ev("e02", 0.9)]

    for s <- materialize_permutations(events, fn -> Repo.get_faithfulness_score(@sid).score end) do
      assert s == 0.9
    end
  end

  test "event_id-loser Alt-Event überschreibt eine reguläre Row nicht" do
    # Reguläre Extraktion (e05) zuerst, dann ein event_id-loses Event (Seed-
    # Analogon) — Letzteres darf die reguläre Row nicht clobbern.
    reset_for_permutation!()
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
