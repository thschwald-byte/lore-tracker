defmodule Worker.MaterializerArcProgressionTest do
  @moduledoc """
  Issue #838: der `ArcProgressionGenerated`-Fold — EIN Row pro
  (arc_id, session_id)-Paar in `worker_arc_progressions`, LWW-by-event_id
  pro zusammengesetztem Key. Kern-Invariante: zwei Einträge verschiedener
  Sessions DESSELBEN Bogens konkurrieren NIE miteinander (die strukturelle
  Replay-Sicherheit aus dem Plan) — jede Session hat ihren eigenen Fold-Key.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-arc-prog-838"
  @arc "arc_test838"

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

  defp read(key), do: :mnesia.dirty_read(S.arc_progressions(), key)

  test "publiziert einen Eintrag, liest ihn über den zusammengesetzten Key zurück" do
    Materializer.apply_event(ev("019-a", 1, "sess-1", 1, "Der Auftrag beginnt."))

    key = @cid <> ":" <> @arc <> ":sess-1"
    assert [{_, ^key, @arc, @cid, "sess-1", 1, "Der Auftrag beginnt.", "[]", "local", "qwen2.5:7b", _ts}] =
             read(key)
  end

  test "LWW: höherer event_id gewinnt für DENSELBEN (arc, session)-Key" do
    Materializer.apply_event(ev("019-b", 1, "sess-1", 1, "Alte Fassung."))
    Materializer.apply_event(ev("019-a", 1, "sess-1", 1, "Sollte nicht gewinnen (kleinerer event_id)."))

    key = @cid <> ":" <> @arc <> ":sess-1"
    assert [{_, ^key, _, _, _, _, "Alte Fassung.", _, _, _, _}] = read(key)
  end

  test "zwei verschiedene Sessions desselben Bogens konkurrieren NICHT miteinander" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "Sitzung 1 Text."))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "Sitzung 3 Text."))

    key1 = @cid <> ":" <> @arc <> ":sess-1"
    key3 = @cid <> ":" <> @arc <> ":sess-3"

    assert [{_, ^key1, _, _, "sess-1", 1, "Sitzung 1 Text.", _, _, _, _}] = read(key1)
    assert [{_, ^key3, _, _, "sess-3", 3, "Sitzung 3 Text.", _, _, _, _}] = read(key3)
  end

  test "Regenerate einer älteren Session (höherer event_id, kleinere session_number) rührt den Eintrag der späteren Session nicht an" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "Sitzung 1, erster Lauf."))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "Sitzung 3 Text."))
    # Regenerate von Sitzung 1 NACH Sitzung 3 verarbeitet — frischer, höherer event_id.
    Materializer.apply_event(ev("019-9", 9, "sess-1", 1, "Sitzung 1, Regenerate."))

    key1 = @cid <> ":" <> @arc <> ":sess-1"
    key3 = @cid <> ":" <> @arc <> ":sess-3"

    assert [{_, ^key1, _, _, "sess-1", 1, "Sitzung 1, Regenerate.", _, _, _, _}] = read(key1)
    # Sitzung 3 ist ein GANZ ANDERER Fold-Key — bleibt exakt wie zuvor.
    assert [{_, ^key3, _, _, "sess-3", 3, "Sitzung 3 Text.", _, _, _, _}] = read(key3)
  end

  test "flagged_claims werden als JSON persistiert" do
    Materializer.apply_event(
      ev("019-f", 1, "sess-1", 1, "Text mit unbelegter Aussage.", flagged_claims: ["Unbelegter Claim"])
    )

    key = @cid <> ":" <> @arc <> ":sess-1"
    assert [{_, ^key, _, _, _, _, _, flagged_json, _, _, _}] = read(key)
    assert Jason.decode!(flagged_json) == ["Unbelegter Claim"]
  end

  test "kaputtes Payload (fehlende IDs) wird verworfen, kein Crash" do
    bad =
      event(
        "ArcProgressionGenerated",
        %{"campaign_id" => @cid, "content_md" => "x"},
        1,
        event_id: "019-bad"
      )

    assert {:applied, 1} = Materializer.apply_event(bad)
  end

  test "CampaignDeleted-Cascade räumt Progressionen + fold_meta auf" do
    Materializer.apply_event(ev("019-1", 1, "sess-1", 1, "Sitzung 1 Text."))
    Materializer.apply_event(ev("019-3", 3, "sess-3", 3, "Sitzung 3 Text."))

    key1 = @cid <> ":" <> @arc <> ":sess-1"
    assert read(key1) != []

    Materializer.apply_event(
      event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 99, event_id: "019-del")
    )

    assert read(key1) == []
    assert :mnesia.dirty_read(S.fold_meta(), {S.arc_progressions(), key1, :arc_progression_generated}) ==
             []
  end
end
