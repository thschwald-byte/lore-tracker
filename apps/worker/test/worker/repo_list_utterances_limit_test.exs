defmodule Worker.RepoListUtterancesLimitTest do
  @moduledoc """
  Issue #506: `list_utterances/2` cappt per Default auf die letzten 200 Utts
  (sinnvoll für UI-/Snapshot-Reader). Der Stage-2-Pipeline-Pfad braucht aber
  die GANZE Session — `limit: :all` umgeht das Cap. Ohne das summte Stage 2 nur
  das Sitzungs-Ende langer Sessions (trunkiertes Resümee, vergiftet Epos +
  Chronik downstream).
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Builder

  @cid "camp-utt-limit"
  @sid "sess-utt-limit"

  setup do
    clear_all_tables!()
    Builder.write!(Builder.campaign(@cid, name: "Test"))
    Builder.write!(Builder.session(@sid, @cid, number: 1, status: :completed))

    base = ~U[2026-01-01 00:00:00Z]

    Builder.write_many!(
      for i <- 1..250 do
        Builder.utterance("u#{String.pad_leading("#{i}", 4, "0")}", @sid,
          text: "Utterance #{i}",
          timestamp: DateTime.add(base, i, :second)
        )
      end
    )

    :ok
  end

  test "Default-Limit cappt auf die letzten 200" do
    utts = Repo.list_utterances(@sid)
    assert length(utts) == 200
    # letzte 200 → erstes Element ist u0051, letztes u0250 (chronologisch sortiert)
    assert hd(utts).text == "Utterance 51"
    assert List.last(utts).text == "Utterance 250"
  end

  test "limit: :all lädt die ganze Session" do
    utts = Repo.list_utterances(@sid, limit: :all)
    assert length(utts) == 250
    assert hd(utts).text == "Utterance 1"
    assert List.last(utts).text == "Utterance 250"
  end

  test "expliziter Integer-Limit bleibt respektiert" do
    assert length(Repo.list_utterances(@sid, limit: 10)) == 10
  end
end
