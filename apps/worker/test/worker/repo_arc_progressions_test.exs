defmodule Worker.RepoArcProgressionsTest do
  @moduledoc """
  Issue #838: `Worker.Repo.ArcProgressions` — der Lese-Pfad für Prosa-
  Progressionen. Kern-Test: `get_prior_arc_entry/3` findet den Eintrag mit
  der größten `session_number < before` UNABHÄNGIG von der Einfüge-
  Reihenfolge (die strukturelle Replay-Sicherheit aus dem #838-Plan, Design
  E) — nicht über "zuletzt geschrieben".
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-ap-838"
  @arc "arc-ap-838"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp ev(eid, seq, session_id, session_number, content_md, opts \\ []) do
    event(
      "ArcProgressionGenerated",
      %{
        "campaign_id" => @cid,
        "arc_id" => @arc,
        "session_id" => session_id,
        "session_number" => session_number,
        "content_md" => content_md,
        "flagged_claims" => Keyword.get(opts, :flagged_claims, []),
        "render_backend" => "local",
        "render_model" => "qwen2.5:7b"
      },
      seq,
      event_id: eid
    )
  end

  test "get_prior_arc_entry/3: kein Eintrag -> nil" do
    assert Repo.get_prior_arc_entry(@cid, @arc, 1) == nil
  end

  test "get_prior_arc_entry/3: findet den Eintrag mit größter session_number < before" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "S1"))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "S3"))
    Materializer.apply_event(ev("019-5", 5, "sess-5", 5, "S5"))

    assert %{session_number: 3, content_md: "S3"} = Repo.get_prior_arc_entry(@cid, @arc, 5)
    assert %{session_number: 5, content_md: "S5"} = Repo.get_prior_arc_entry(@cid, @arc, 9)
    assert Repo.get_prior_arc_entry(@cid, @arc, 1) == nil
  end

  test "get_prior_arc_entry/3: Ergebnis ist reihenfolge-unabhängig (Replay-Sicherheit)" do
    # Sitzung 5 wird VOR Sitzung 3 verarbeitet (z.B. Reorder/Replay-Artefakt) —
    # das Ergebnis für "vorheriger Eintrag vor Sitzung 5" darf sich NICHT
    # danach richten, was zuletzt geschrieben wurde.
    Materializer.apply_event(ev("019-5", 5, "sess-5", 5, "S5"))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "S3"))
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "S1"))

    assert %{session_number: 3, content_md: "S3"} = Repo.get_prior_arc_entry(@cid, @arc, 5)
  end

  test "get_prior_arc_entry/3: ein Regenerate einer älteren Session ändert das Ergebnis für spätere Sessions nicht" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "S1 original"))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "S3"))
    # Regenerate von Sitzung 1, NACH Sitzung 3 verarbeitet.
    Materializer.apply_event(ev("019-9", 9, "sess-1", 1, "S1 regenerated"))

    assert %{session_number: 1, content_md: "S1 regenerated"} = Repo.get_prior_arc_entry(@cid, @arc, 3)
  end

  test "list_arc_progression_entries/2: chronologisch sortiert, unabhängig von Einfüge-Reihenfolge" do
    Materializer.apply_event(ev("019-5", 5, "sess-5", 5, "S5"))
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "S1"))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "S3"))

    entries = Repo.list_arc_progression_entries(@cid, @arc)
    assert Enum.map(entries, & &1.session_number) == [1, 3, 5]
    assert Enum.map(entries, & &1.content_md) == ["S1", "S3", "S5"]
  end

  test "list_arc_progression_entries/2: leere Liste ohne Einträge" do
    assert Repo.list_arc_progression_entries(@cid, @arc) == []
  end

  test "flagged_claims werden korrekt dekodiert" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "Text", flagged_claims: ["X", "Y"]))

    [entry] = Repo.list_arc_progression_entries(@cid, @arc)
    assert entry.flagged_claims == ["X", "Y"]
  end
end
