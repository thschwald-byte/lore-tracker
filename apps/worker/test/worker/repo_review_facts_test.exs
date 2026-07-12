defmodule Worker.RepoReviewFactsTest do
  @moduledoc """
  Issue #746: campaign_review_facts/1 — verifizierte, aber unplatzierbare Fakten
  (Flashback/Zukunft/unklar OHNE Datum UND OHNE Offset). Präsens / datiert /
  mit Offset / unverifiziert gehören NICHT in die Queue.

  Issue #724 Slice F: GM-Overrides (`SessionFactDateSet`-Fold-Ergebnis, direkt
  als Row geschrieben statt über den Materializer — der Fold selbst ist in
  `materializer_fact_date_set_test.exs` getestet) werden hier read-seitig
  geprüft: Dismiss raus, Datum raus, Undo wieder rein, gemergte Felder,
  unparsebares Datum bleibt drin + `date_parse_error`.
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
    # Issue #781: session_facts ist ein 6-Tupel (event_id trailing).
    Worker.Schema.Builder.write!(
      {S.session_facts(), session_id, @cid, Jason.encode!(facts), DateTime.utc_now(), nil}
    )
  end

  defp put_override(session_id, fact_id, raw, dismissed, event_id) do
    Worker.Schema.Builder.write!(
      {S.session_fact_overrides(), "#{session_id}:#{fact_id}", session_id, @cid, fact_id, raw,
       dismissed, event_id}
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

  describe "GM-Overrides (#724 Slice F)" do
    test "Dismiss-Override nimmt den Fakt aus der Queue" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "", true, "e01")

      assert Repo.campaign_review_facts(@cid) == []
    end

    test "auflösbares Datum-Override nimmt den Fakt aus der Queue" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "1888-03-20", false, "e01")

      assert Repo.campaign_review_facts(@cid) == []
    end

    test "Undo (leeres Override-Datum) bringt den Fakt zurück in die Queue" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "1888-03-20", false, "e01")
      assert Repo.campaign_review_facts(@cid) == []

      put_override("s-1", "f1", "", false, "e02")
      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == ["Flashback"]
    end

    test "gemergter Fakt trägt time_anchor=absolute + time_absolute (Resolver-Kompatibilität)" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "1888-03-20", false, "e01")

      [merged] = Repo.list_campaign_facts(@cid)
      assert merged["in_game_date"] == "1888-03-20"
      assert merged["time_absolute"] == "1888-03-20"
      assert merged["time_anchor"] == "absolute"
    end

    test "unparsebares Override-Datum bleibt in der Queue MIT date_parse_error" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "32.13.1920", false, "e01")

      assert [%{"claim" => "Flashback", "date_parse_error" => true}] =
               Repo.campaign_review_facts(@cid)
    end

    test "Override auf einen anderen Fakt derselben Session lässt Nachbarn unberührt" do
      put_facts("s-1", [
        fact(%{"id" => "f1", "claim" => "A", "narration_time" => "flashback"}),
        fact(%{"id" => "f2", "claim" => "B", "narration_time" => "flashback"})
      ])

      put_override("s-1", "f1", "1888-03-20", false, "e01")

      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == ["B"]
    end
  end
end
