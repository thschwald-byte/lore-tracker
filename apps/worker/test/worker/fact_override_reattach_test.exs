defmodule Worker.FactOverrideReattachTest do
  @moduledoc """
  Issue #916 (Epic #911, Cut 2): der Read-Zeit-Merge `apply_fact_curation/2` mit
  Utterance-Mengen-Anker. Gepinnt: (1) claim-Edit überlebt einen Regenerate
  (neue Fakt-ID, gleiche Utterance-Menge → Override re-attacht); (2) character/
  thread/verified? werden gesetzt; (3) „löschen" markiert curation_dismissed;
  (4) Mehrdeutigkeit (zwei Fakten gleiche Menge) — mengen-sichere Felder ja,
  claim/dismissed geblockt + override_mehrdeutig; (5) Undo (leerer value) = kein Effekt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo.Artifacts
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-reattach-916"
  @sid "sess-1"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()

    # Smoothed-Block b1 trägt die Utterance-Menge {u1,u2}; b2 → {u3}.
    snapshot = %{
      "blocks" => [
        %{"id" => "b1", "quell_utterance_ids" => ["u1", "u2"]},
        %{"id" => "b2", "quell_utterance_ids" => ["u3"]}
      ],
      "rules_version" => "v1"
    }

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write(
          {S.smoothed_blocks(), @sid, @cid, Jason.encode!(snapshot), DateTime.utc_now(), "sm-e1"}
        )
      end)

    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp curate(eid, seq, field, value, quell) do
    Materializer.apply_event(
      event(
        "FactCurationSet",
        %{
          "session_id" => @sid,
          "campaign_id" => @cid,
          "anchor_hash" => "h_#{field}",
          "quell_utterance_ids" => quell,
          "field" => field,
          "value" => value,
          "set_by" => "did-k"
        },
        seq,
        event_id: eid
      )
    )
  end

  # Fakt aus Block b1 (Utterance-Menge {u1,u2}).
  defp fact(id, opts \\ []) do
    %{
      "id" => id,
      "source_refs" => Keyword.get(opts, :refs, ["b1"]),
      "claim" => Keyword.get(opts, :claim, "Original-Claim"),
      "character_alias" => Keyword.get(opts, :char, "Unbekannt"),
      "thread" => Keyword.get(opts, :thread, ""),
      "verified?" => Keyword.get(opts, :verified, true)
    }
  end

  defp merged(facts), do: Artifacts.apply_fact_curation(facts, @sid)

  test "claim-Edit überlebt Regenerate: neue Fakt-ID, gleiche Utterance-Menge → re-attach" do
    curate("e1", 1, "claim", "Korrigierter Claim", ["u1", "u2"])

    # Generation 1: Fakt f_alt.
    [g1] = merged([fact("f_alt", claim: "Original")])
    assert g1["claim"] == "Korrigierter Claim"

    # Regenerate → neue content-adressierte ID, ANDERER Roh-Claim, gleiche Menge.
    [g2] = merged([fact("f_neu", claim: "Neu extrahiert")])
    assert g2["claim"] == "Korrigierter Claim", "Override re-attacht über die Utterance-Menge"
  end

  test "character/thread/verified? werden gesetzt" do
    curate("e1", 1, "character", "Sherlock Holmes", ["u1", "u2"])
    curate("e2", 2, "thread", "der brief", ["u1", "u2"])
    curate("e3", 3, "verified", "false", ["u1", "u2"])

    [g] = merged([fact("f1")])
    assert g["character_alias"] == "Sherlock Holmes"
    assert g["thread"] == "der brief"
    assert g["verified?"] == false
  end

  test "löschen markiert curation_dismissed" do
    curate("e1", 1, "dismissed", "true", ["u1", "u2"])
    [g] = merged([fact("f1")])
    assert g["curation_dismissed"] == true
  end

  test "Undo (leerer claim-value) hat keinen Effekt" do
    curate("e1", 1, "claim", "etwas", ["u1", "u2"])
    curate("e2", 2, "claim", "", ["u1", "u2"])
    [g] = merged([fact("f1", claim: "Roh")])
    assert g["claim"] == "Roh", "leerer value = Undo → Roh-Claim bleibt"
  end

  test "Mehrdeutigkeit: character ja, claim geblockt + override_mehrdeutig" do
    curate("e1", 1, "character", "Holmes", ["u1", "u2"])
    curate("e2", 2, "claim", "Fix", ["u1", "u2"])

    # Zwei Fakten teilen die Menge {u1,u2}.
    [a, b] = merged([fact("fa", claim: "A"), fact("fb", claim: "B")])

    # Mengen-sicher: character auf beide.
    assert a["character_alias"] == "Holmes"
    assert b["character_alias"] == "Holmes"
    # claim NICHT angewandt (nicht disambiguierbar), stattdessen Warn-Flag.
    assert a["claim"] == "A"
    assert b["claim"] == "B"
    assert a["override_mehrdeutig"] == true
    assert b["override_mehrdeutig"] == true
  end

  test "Fakt ohne passende Utterance-Menge bleibt unberührt" do
    curate("e1", 1, "claim", "Fix", ["u1", "u2"])
    # Fakt aus b2 (Menge {u3}) — kein Match.
    [g] = merged([fact("f1", refs: ["b2"], claim: "Roh")])
    assert g["claim"] == "Roh"
  end
end
