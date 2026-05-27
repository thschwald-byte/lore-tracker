defmodule Worker.ProbelaufEvalSeedTest do
  @moduledoc """
  Issue #201 Phase 1b: `Worker.Probelauf.seed_eval_campaign/0` lädt den
  committed Goldstandard-Asset aus `apps/worker/priv/probelauf-eval/` und
  publisht Events für eine Eval-Kampagne mit allen 4 Stage-Outputs.

  Smoke-Test: nach seed_eval_campaign/0 sind alle 3 Sessions im Repo +
  jede hat ein session_summary + die Kampagne hat einen epos_entry +
  Chronik-Einträge sind angelegt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Probelauf
  alias Worker.Repo

  setup do
    clear_all_tables!()

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "seed_eval_campaign/0 legt 4 Sessions an (10/30/100/~800, Issue #286)" do
    assert {:ok, %{campaign_id: cid, sessions: sessions}} = Probelauf.seed_eval_campaign()

    assert cid == "probelauf-eval-goldstandard"
    assert length(sessions) == 4
    counts = Enum.map(sessions, & &1.utterance_count)
    assert Enum.take(counts, 3) == [10, 30, 100]
    # Session 4 ("real") wird aus session-4-utterances.jsonl geladen — Größe
    # darf flexibel sein, aber muss > 100 sein (sonst nicht „real-size").
    assert Enum.at(counts, 3) > 100
    assert Enum.map(sessions, & &1.number) == [1, 2, 3, 4]
  end

  test "jede Session hat Goldstandard-Summary nach Seed" do
    {:ok, %{sessions: sessions}} = Probelauf.seed_eval_campaign()

    Enum.each(sessions, fn s ->
      summary = Repo.get_session_summary(s.session_id)

      assert summary,
             "session #{s.number}: kein Resümee im Repo nach seed_eval_campaign"

      assert is_binary(summary.content_md) and summary.content_md != "",
             "session #{s.number}: Resümee-content_md leer"
    end)
  end

  test "Kampagne hat Goldstandard-Epos nach Seed" do
    {:ok, %{campaign_id: cid}} = Probelauf.seed_eval_campaign()

    epos = Repo.get_epos_entry(cid)
    assert epos, "kein Epos im Repo nach seed_eval_campaign"
    assert is_binary(epos.content_md) and epos.content_md != ""
  end

  test "eval_session_id/1 gibt die fixen Eval-Session-IDs zurück" do
    assert Probelauf.eval_session_id(1) == "probelauf-eval-session-1"
    assert Probelauf.eval_session_id(2) == "probelauf-eval-session-2"
    assert Probelauf.eval_session_id(3) == "probelauf-eval-session-3"
    assert Probelauf.eval_session_id(4) == "probelauf-eval-session-4"
  end

  test "seed_eval_campaign/0 ist idempotent — re-running funktioniert" do
    assert {:ok, _} = Probelauf.seed_eval_campaign()
    # Zweiter Lauf soll nicht crashen (LWW-Materializer überschreibt cleanly).
    assert {:ok, %{campaign_id: cid}} = Probelauf.seed_eval_campaign()
    assert cid == "probelauf-eval-goldstandard"

    # Epos-Entry darf nicht weg sein nach dem 2. Lauf
    assert Repo.get_epos_entry(cid)
  end
end
