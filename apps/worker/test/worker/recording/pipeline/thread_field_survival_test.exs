defmodule Worker.Recording.Pipeline.ThreadFieldSurvivalTest do
  @moduledoc """
  Vorab-Verifikation für Epic #829 Slice B (Issue #831): nagelt **Befund 1** am
  laufenden Code fest, BEVOR der Rest gebaut wird — ein `thread`/`fact_type`-Feld
  in einem Fakt überlebt beide Republish-Transforme (`Verify.verify_facts` +
  `EntityRegistry.apply_registry`) UND die Materializer-Persistenz/Read-Runde.

  Der Kern der Slice-B-Architektur: Rekonstruktion aus fixer Feldliste passiert
  an GENAU EINER Stelle — `Parsing.normalize_fact/4` (der Extraktions-Parse).
  Alle Republish-Pfade sind feldkonservativ (`Map.put`). Erweitert Slice B also
  `normalize_fact`, reichen die Felder von selbst durch — KEIN Overlay nötig.
  Bricht dieser Test wider Erwarten, ändert sich die Slice-B/C-Strategie
  (`thread` bräuchte dann doch das Overlay-Muster).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Pipeline.{EntityRegistry, Verify}
  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-thread-survival-831"
  @s1 "sess-831-1"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp themed_fact do
    %{
      "id" => "f1",
      "claim" => "Der König beauftragt Holmes, das Foto zu beschaffen.",
      "entity_id" => "könig",
      "character_alias" => "König",
      "in_game_date" => nil,
      "narration_time" => "present",
      "source_refs" => ["u3"],
      "verified?" => false,
      # die neuen Slice-B-Felder — hier schon vorhanden, um zu prüfen, dass die
      # nachgelagerten Transforme sie NICHT droppen.
      "fact_type" => "absicht",
      "thread" => "Erpressung mit der Fotografie"
    }
  end

  test "Verify.verify_facts erhält fact_type + thread (feldkonservativer Map.put)" do
    # Stub-Fns → deterministisch, kein LLM/Sidecar.
    [verified] =
      Verify.verify_facts([themed_fact()], [],
        ground_fn: fn _fact, _utts -> true end,
        attr_fn: fn _fact, _utts, _aliases -> true end
      )

    assert verified["thread"] == "Erpressung mit der Fotografie"
    assert verified["fact_type"] == "absicht"
    # Die Verify-Flags kommen additiv dazu, die Bestandsfelder bleiben.
    assert verified["verified?"] == true
    assert verified["claim"] == "Der König beauftragt Holmes, das Foto zu beschaffen."
  end

  test "EntityRegistry.apply_registry erhält fact_type + thread (re-keyt nur entity_id)" do
    registry = %{"könig" => "canonical-koenig"}
    [rekeyed] = EntityRegistry.apply_registry([themed_fact()], registry)

    assert rekeyed["entity_id"] == "canonical-koenig"
    assert rekeyed["thread"] == "Erpressung mit der Fotografie"
    assert rekeyed["fact_type"] == "absicht"
  end

  test "Materializer-Persist → get_session_facts: fact_type + thread überleben die Runde" do
    assert {:applied, 1} =
             Materializer.apply_event(
               event(
                 "SessionFactsExtracted",
                 %{"session_id" => @s1, "campaign_id" => @cid, "facts" => [themed_fact()]},
                 1
               )
             )

    got = Repo.get_session_facts(@s1)
    assert length(got.facts) == 1
    [f] = got.facts
    assert f["thread"] == "Erpressung mit der Fotografie"
    assert f["fact_type"] == "absicht"
  end
end
