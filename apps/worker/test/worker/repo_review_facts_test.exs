defmodule Worker.RepoReviewFactsTest do
  @moduledoc """
  Issue #746: campaign_review_facts/1 — verifizierte, aber unplatzierbare Fakten
  (Flashback/Zukunft/unklar OHNE Datum UND OHNE Offset). Präsens / datiert /
  mit Offset / unverifiziert gehören NICHT in die Queue — SOFERN die Session
  einen Anker hat.

  Issue #818: Präsens löst ausschließlich relativ zum Session-Anker auf (auch
  mit gesetztem time_offset). Fehlt der Anker der Session komplett, landet
  ein Präsens-Fakt sonst lautlos weder in der Timeline noch in dieser Queue —
  daher zählt "Präsens ohne Session-Anker" seit #818 ebenfalls als
  unplatzierbar (eigene Test-Describe unten).

  Issue #724 Slice F: GM-Overrides (`SessionFactDateSet`-Fold-Ergebnis, direkt
  als Row geschrieben statt über den Materializer — der Fold selbst ist in
  `materializer_fact_date_set_test.exs` getestet) werden hier read-seitig
  geprüft: Dismiss raus, Datum raus, Undo wieder rein, gemergte Felder,
  unparsebares Datum bleibt drin + `date_parse_error`.

  Kritischer Review-Fund: Fakt-IDs sind rein positional (`"f" <> index`),
  NICHT run-eindeutig — ein Override muss an die Extraktions-Generation
  gepinnt sein (`extraction_event_id`), sonst schlägt er nach einem
  Regenerate auf einen unbeteiligten neuen Fakt an derselben Position durch.
  `@ext` ist die Generation, gegen die `put_facts/2` standardmäßig schreibt;
  die Generation-Match-Tests am Ende beweisen, dass ein Override mit ANDERER
  Generation ignoriert wird.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-review"
  @ext "ext-01"

  setup do
    clear_all_tables!()
    :ok
  end

  defp put_facts(session_id, facts, extraction_event_id \\ @ext) do
    # Issue #781: event_id trailing. Issue #783 Phase 2 (Design E):
    # verify_backend/verify_model trailing (Provenance, hier irrelevant → nil).
    Worker.Schema.Builder.write!(
      {S.session_facts(), session_id, @cid, Jason.encode!(facts), DateTime.utc_now(),
       extraction_event_id, nil, nil, nil}
    )
  end

  defp put_override(session_id, fact_id, raw, dismissed, event_id, extraction_event_id \\ @ext) do
    Worker.Schema.Builder.write!(
      {S.session_fact_overrides(), "#{session_id}:#{fact_id}", session_id, @cid, fact_id,
       extraction_event_id, raw, dismissed, event_id}
    )
  end

  defp put_anchor(session_id, in_game_day, raw \\ "irrelevant") do
    Worker.Schema.Builder.write!({S.session_anchors(), session_id, @cid, in_game_day, raw})
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

  test "nur verifizierte, unplatzierbare Fakten landen in der Queue (Session HAT einen Anker)" do
    # #818: mit gesetztem Anker löst Präsens sauber auf — die einzigen
    # unplatzierbaren Fälle bleiben Flashback/Future/Unknown ohne Datum/Offset.
    put_anchor("s-1", 100)

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

  describe "Präsens ohne Session-Anker (#818)" do
    test "Präsens-Fakt OHNE Anker der Session landet in der Queue" do
      # Kein put_anchor/2 für "s-1" — der Resolver kann Präsens ausschließlich
      # relativ zum Session-Anker auflösen, ganz ohne Anker ist der Fakt
      # strukturell unplatzierbar (die reale Skandal-Böhmen-Prod-Kampagne:
      # 0 Session-Anker → 0 datierte Fakten, vorher unsichtbar in der Queue).
      put_facts("s-1", [
        fact(%{"claim" => "Präsens ohne Anker", "narration_time" => "present"})
      ])

      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == [
               "Präsens ohne Anker"
             ]
    end

    test "Präsens-Fakt MIT gesetztem time_offset aber ohne Anker landet trotzdem in der Queue" do
      # Der Resolver braucht für Präsens IMMER einen Anker (resolver.ex:65),
      # auch wenn ein Offset vorliegt — ein Offset allein reicht nicht.
      put_facts("s-1", [
        fact(%{
          "claim" => "Präsens mit Offset, kein Anker",
          "narration_time" => "present",
          "time_offset" => %{"value" => 2, "unit" => "day"}
        })
      ])

      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == [
               "Präsens mit Offset, kein Anker"
             ]
    end

    test "Präsens-Fakt MIT gesetztem in_game_date gilt trotz fehlendem Anker als platziert" do
      # Ein direkt gesetztes Datum (z.B. via GM-Override) macht den Session-
      # Anker irrelevant — die absolute Auflösung greift zuerst.
      put_facts("s-1", [
        fact(%{
          "claim" => "Präsens mit Datum",
          "narration_time" => "present",
          "in_game_date" => "1888-03-20"
        })
      ])

      assert Repo.campaign_review_facts(@cid) == []
    end

    test "Präsens-Fakt MIT Anker der Session bleibt außen vor (Regression zur alten Regel)" do
      put_anchor("s-1", 42)

      put_facts("s-1", [
        fact(%{"claim" => "Präsens mit Anker", "narration_time" => "present"})
      ])

      assert Repo.campaign_review_facts(@cid) == []
    end

    test "Anker gehört pro Session — Fakt in Session OHNE Anker bleibt in der Queue, Nachbar-Session MIT Anker nicht" do
      put_anchor("s-2", 7)

      put_facts("s-1", [fact(%{"claim" => "unverankert", "narration_time" => "present"})])
      put_facts("s-2", [fact(%{"claim" => "verankert", "narration_time" => "present"})])

      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == ["unverankert"]
    end
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

  describe "Generation-Pinning (kritischer Review-Fund — Fakt-IDs sind positional)" do
    test "Override mit ANDERER Extraktions-Generation wird ignoriert (kein Cross-Contamination)" do
      # Simuliert ein Regenerate: die Session_facts-Row trägt jetzt die neue
      # Generation "ext-02", der Override ist noch an "ext-01" (@ext) gepinnt —
      # er darf NICHT auf den neuen Fakt an Position "f1" durchschlagen.
      put_override("s-1", "f1", "1888-03-20", false, "e01", @ext)

      put_facts(
        "s-1",
        [fact(%{"id" => "f1", "claim" => "Neuer Flashback", "narration_time" => "flashback"})],
        "ext-02"
      )

      # Ohne den Generation-Check würde der stale Override "Neuer Flashback"
      # aus der Queue nehmen (fälschlich als datiert gelten) — mit dem Check
      # bleibt der Fakt unplatziert und landet korrekt in der Queue.
      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == [
               "Neuer Flashback"
             ]

      [merged] = Repo.list_campaign_facts(@cid)
      refute merged["time_anchor"] == "absolute"
      refute Map.has_key?(merged, "review_override_date")
    end

    test "Dismiss-Override mit ANDERER Generation lässt den neuen Fakt in der Queue" do
      put_override("s-1", "f1", "", true, "e01", @ext)

      put_facts(
        "s-1",
        [fact(%{"id" => "f1", "claim" => "Neuer Flashback", "narration_time" => "flashback"})],
        "ext-02"
      )

      assert @cid |> Repo.campaign_review_facts() |> Enum.map(& &1["claim"]) == [
               "Neuer Flashback"
             ]
    end

    test "Override mit PASSENDER Generation nach einem Regenerate greift weiterhin" do
      # Gegenprobe: wird dieselbe Generation erneut geschrieben (z.B. weil der
      # GM den Override NACH dem Regenerate setzt), gilt er normal.
      put_facts(
        "s-1",
        [fact(%{"id" => "f1", "claim" => "Flashback", "narration_time" => "flashback"})],
        "ext-02"
      )

      put_override("s-1", "f1", "1888-03-20", false, "e01", "ext-02")

      assert Repo.campaign_review_facts(@cid) == []
    end
  end
end
