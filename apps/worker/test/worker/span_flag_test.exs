defmodule Worker.SpanFlagTest do
  @moduledoc """
  Issue #916 (Epic #911, Cut 2): der Span-Granularitäts-Upgrade der Flags.
  Gepinnt: (1) `span`-Flag ist offen, solange die gemeldete Utterance-Menge eine
  aktuelle Fakt-Utterance berührt; (2) berührt sie keine mehr (disjoint) →
  auto_resolved; (3) bestehende `fact`-Flags unberührt; (4) `span` ist ein
  gültiges target_kind (write-Pfad).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-span-916"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp raise_span(eid, tid) do
    Materializer.apply_event(
      event(
        "FlagRaised",
        %{
          "campaign_id" => @cid,
          "target_kind" => "span",
          "target_id" => tid,
          "note" => "hier stimmt was nicht",
          "set_by" => "did-melder"
        },
        1,
        event_id: eid
      )
    )
  end

  defp eff(fact_ids, covered) do
    Worker.Repo.flags_effective(@cid, MapSet.new(fact_ids), MapSet.new(covered))
    |> Map.new(&{&1["target_id"], &1["effective_status"]})
  end

  test "span-Flag bleibt offen, solange eine Utterance berührt wird" do
    raise_span("e1", "u1,u2")
    # covered_utts enthält u2 → Berührung → offen.
    assert eff([], ["u2", "u9"])["u1,u2"] == "raised"
  end

  test "span-Flag auto-resolved, wenn die Utterance-Menge disjunkt ist" do
    raise_span("e1", "u1,u2")
    # keine der gemeldeten Utterances mehr abgedeckt → auto_resolved.
    assert eff([], ["u7", "u8"])["u1,u2"] == "auto_resolved"
  end

  test "span ist ein gültiges target_kind (write-Pfad schreibt die Row)" do
    raise_span("e1", "u1")

    assert [{_, _, _, "span", "u1", _, _, "raised", _}] =
             :mnesia.dirty_read(S.flags(), "#{@cid}:span:u1")
  end

  test "bestehende fact-Flags bleiben unberührt (content-id-Auto-Resolve)" do
    Materializer.apply_event(
      event(
        "FlagRaised",
        %{
          "campaign_id" => @cid,
          "target_kind" => "fact",
          "target_id" => "f_weg",
          "set_by" => "d"
        },
        1,
        event_id: "e1"
      )
    )

    # f_weg nicht in fact_ids → auto_resolved (covered_utts irrelevant für fact).
    assert eff(["f_da"], [])["f_weg"] == "auto_resolved"
  end
end
