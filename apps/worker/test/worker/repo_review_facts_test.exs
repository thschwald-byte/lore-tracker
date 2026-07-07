defmodule Worker.RepoReviewFactsTest do
  @moduledoc """
  Issue #746: campaign_review_facts/1 — verifizierte, aber unplatzierbare Fakten
  (Flashback/Zukunft/unklar OHNE Datum UND OHNE Offset). Präsens / datiert /
  mit Offset / unverifiziert gehören NICHT in die Queue.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-review"

  setup do
    clear_all_tables!()
    :ok
  end

  defp put_facts(session_id, facts) do
    Worker.Schema.Builder.write!(
      {S.session_facts(), session_id, @cid, Jason.encode!(facts), DateTime.utc_now()}
    )
  end

  defp fact(attrs),
    do:
      Map.merge(
        %{
          "claim" => "c",
          "narration_time" => "present",
          "verified?" => true,
          "in_game_date" => nil
        },
        attrs
      )

  test "nur verifizierte, unplatzierbare Nicht-Präsens-Fakten landen in der Queue" do
    put_facts("s-1", [
      # unplatzierbar → IN der Queue
      fact(%{"claim" => "Flashback ohne Datum", "narration_time" => "flashback"}),
      fact(%{"claim" => "Zukunft ohne Datum", "narration_time" => "future"}),
      fact(%{"claim" => "unklar", "narration_time" => "unknown"}),
      # platzierbar / irrelevant → NICHT in der Queue
      fact(%{"claim" => "Präsens", "narration_time" => "present"}),
      fact(%{
        "claim" => "Flashback mit Datum",
        "narration_time" => "flashback",
        "in_game_date" => "1850"
      }),
      fact(%{
        "claim" => "Flashback mit Offset",
        "narration_time" => "flashback",
        "time_offset" => %{"value" => -10, "unit" => "year"}
      }),
      fact(%{"claim" => "unverifiziert", "narration_time" => "flashback", "verified?" => false})
    ])

    claims = @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) |> Enum.sort()
    assert claims == ["Flashback ohne Datum", "Zukunft ohne Datum", "unklar"]
  end

  test "leere/kaputte Datums-Strings zählen als undatiert" do
    put_facts("s-1", [
      fact(%{"claim" => "leer", "narration_time" => "flashback", "in_game_date" => "  "})
    ])

    assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == ["leer"]
  end

  test "keine Fakten → leere Queue" do
    assert Repo.campaign_review_facts(@cid) == []
  end
end
