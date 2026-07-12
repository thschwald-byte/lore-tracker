defmodule Worker.MaterializerFactDateSetTest do
  @moduledoc """
  Issue #724 Slice F: der `SessionFactDateSet`-Fold (GM-Korrektur eines
  Review-Queue-Fakts — Datum setzen oder dauerhaft ausblenden).

  Kritischer Review-Fund am Plan (siehe Issue-Kommentar): der Fold darf
  **niemals** `:mnesia.delete` machen, auch nicht im Undo-Fall
  (`in_game_date_raw == ""`) — sonst ist ein vertauschtes Set→Undo-Paar
  order-sensitiv divergent, exakt die #698-Bucket-D-Klasse (Clear-vs-Entries).
  Die drei `materialize_permutations`-Tests unten sind der Beweis dafür:
  jede Reihenfolge muss auf denselben Endzustand konvergieren. Muster reused
  aus `materializer_chronik_convergence_test.exs` (#698).

  Zusätzlich: der Fold darf die `session_facts`-Row NIE anfassen — Overrides
  leben in einer eigenen Overlay-Tabelle, damit ein Re-Publish durch
  `Verify.verify_session` (neues `SessionFactsExtracted`, Set-Semantik) eine
  GM-Korrektur nicht zermahlt.

  Zweiter Review-Fund: Fakt-IDs sind rein positional (`"f" <> index`), NICHT
  run-eindeutig — der Fold speichert `extraction_event_id` daher UNGEPRÜFT
  (reiner Value-Store, bleibt order-insensitiv); den Generation-Match prüft
  erst der Read-Merge in `Worker.Repo.Artifacts` (getestet in
  `repo_review_facts_test.exs`).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-724-fds"
  @sid "sess-1"
  @fid "f1"
  @ext "ext-01"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp date_set_ev(raw, event_id, opts \\ []) do
    payload = %{
      "session_id" => Keyword.get(opts, :session_id, @sid),
      "campaign_id" => @cid,
      "fact_id" => Keyword.get(opts, :fact_id, @fid),
      "extraction_event_id" => Keyword.get(opts, :extraction_event_id, @ext),
      "in_game_date_raw" => raw,
      "dismissed" => Keyword.get(opts, :dismissed, false),
      "set_by" => "gm-did"
    }

    event("SessionFactDateSet", payload, next_seq(), event_id: event_id)
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  defp override_row(sid \\ @sid, fid \\ @fid) do
    key = "#{sid}:#{fid}"

    case :mnesia.dirty_read(S.session_fact_overrides(), key) do
      [row] -> row
      [] -> nil
    end
  end

  defp materialize_permutations(events) do
    perms = [
      events,
      Enum.reverse(events),
      rotate(events, 1)
    ]

    for perm <- perms do
      clear_all_tables!()
      Enum.each(perm, &Materializer.apply_event/1)
      override_row()
    end
  end

  defp rotate(list, n), do: Enum.drop(list, n) ++ Enum.take(list, n)

  describe "Basis-Fold: Write, niemals Delete" do
    test "Datum setzen schreibt eine Row mit dismissed=false" do
      Materializer.apply_event(date_set_ev("1888-03-20", "e01"))

      table = S.session_fact_overrides()

      assert {^table, key, sid, cid, fid, ext, raw, dismissed, event_id} = override_row()

      assert key == "#{@sid}:#{@fid}"
      assert sid == @sid
      assert cid == @cid
      assert fid == @fid
      assert ext == @ext
      assert raw == "1888-03-20"
      assert dismissed == false
      assert event_id == "e01"
    end

    test "Dismiss schreibt eine Row mit dismissed=true" do
      Materializer.apply_event(date_set_ev("", "e01", dismissed: true))

      assert {_, _, _, _, _, _, "", true, "e01"} = override_row()
    end

    test "Undo (leerer String, not dismissed) schreibt eine LESBARE leere Row — KEIN Delete" do
      Materializer.apply_event(date_set_ev("1888-03-20", "e01"))
      Materializer.apply_event(date_set_ev("", "e02"))

      # Die Row existiert weiterhin (kein Delete!) — nur der Inhalt ist leer.
      assert {_, _, _, _, _, _, "", false, "e02"} = override_row()
    end

    test "LWW: niedrigerer event_id gewinnt NICHT (Set nach Undo mit älterem event_id)" do
      Materializer.apply_event(date_set_ev("", "e05"))
      Materializer.apply_event(date_set_ev("1888-03-20", "e01"))

      # e01 < e05 → der ältere Set-Versuch darf die neuere Undo-Row nicht schlagen.
      assert {_, _, _, _, _, _, "", false, "e05"} = override_row()
    end

    test "Idempotenz: Re-Apply desselben event_id ist ein No-op" do
      ev = date_set_ev("1888-03-20", "e01")
      Materializer.apply_event(ev)
      Materializer.apply_event(ev)

      assert {_, _, _, _, _, _, "1888-03-20", false, "e01"} = override_row()
    end

    test "fehlende session_id/fact_id wird gedroppt (kein Crash, keine Row)" do
      Materializer.apply_event(
        event(
          "SessionFactDateSet",
          %{"campaign_id" => @cid, "in_game_date_raw" => "1888", "set_by" => "gm"},
          next_seq(),
          event_id: "e01"
        )
      )

      assert override_row() == nil
    end

    test "Fold kappt in_game_date_raw fold-seitig auf 200 Bytes (Guard gegen Direktschreiber)" do
      long = String.duplicate("x", 500)
      Materializer.apply_event(date_set_ev(long, "e01"))

      assert {_, _, _, _, _, _, raw, _, _} = override_row()
      assert byte_size(raw) == 200
    end
  end

  describe "Order-Insensitivität — drei Permutationen (kritischer Review-Fund)" do
    test "(a) Set vor/nach der Extraktion — Override konvergiert unabhängig von der Reihenfolge" do
      extracted =
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "facts" => [%{"id" => @fid, "claim" => "X", "verified?" => true}]
          },
          next_seq(),
          event_id: @ext
        )

      events = [extracted, date_set_ev("1888-03-20", "e01")]

      for row <- materialize_permutations(events) do
        assert {_, _, _, _, _, _, "1888-03-20", false, "e01"} = row
      end
    end

    test "(b) Set(\"X\") → Undo(\"\") in beiden Ankunftsreihenfolgen — identischer Endzustand" do
      # Das ist der Bug, den Design C (Upsert-only) verhindert: würde der Fold
      # ein :mnesia.delete machen, käme in der Reihenfolge [undo, set] das ältere
      # Datum NACH dem Delete an, fände keine Row zum LWW-Vergleich und
      # insertete fälschlich "X" statt konvergent leer zu bleiben.
      events = [date_set_ev("1888-03-20", "e01"), date_set_ev("", "e02")]

      for row <- materialize_permutations(events) do
        assert {_, _, _, _, _, _, "", false, "e02"} = row,
               "Set→Undo muss über alle Reihenfolgen auf leer/e02 konvergieren, war: #{inspect(row)}"
      end
    end

    test "(c) Dismiss ↔ Set in beiden Reihenfolgen — identischer Endzustand (letzter event_id gewinnt)" do
      events = [
        date_set_ev("", "e01", dismissed: true),
        date_set_ev("1888-03-20", "e02", dismissed: false)
      ]

      for row <- materialize_permutations(events) do
        assert {_, _, _, _, _, _, "1888-03-20", false, "e02"} = row,
               "Dismiss↔Set muss über alle Reihenfolgen auf e02 konvergieren, war: #{inspect(row)}"
      end
    end
  end

  describe "Verify-Re-Publish zerstört den Override nicht" do
    test "zweites SessionFactsExtracted (Verify, höhere event_id, gleiche fact_id) lässt Override + fact_id unangetastet" do
      extract1 =
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "facts" => [%{"id" => @fid, "claim" => "X", "verified?" => false}]
          },
          next_seq(),
          event_id: @ext
        )

      date_set = date_set_ev("1888-03-20", "e01")

      # Verify.verify_session re-published dieselben fact_ids mit gesetzten
      # Flags (Set-Semantik) — hier simuliert als zweites Extracted-Event mit
      # höherer event_id, IDENTISCHEN fact_ids (Verify ändert nie IDs). Der
      # Fold selbst kennt keine Generation-Prüfung (die läuft am Read-Merge) —
      # dieser Test beweist nur, dass die Override-ROW den Re-Publish überlebt.
      verify_republish =
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "facts" => [%{"id" => @fid, "claim" => "X", "verified?" => true}]
          },
          next_seq(),
          event_id: "ext-02"
        )

      Enum.each([extract1, date_set, verify_republish], &Materializer.apply_event/1)

      # Assertion prüft explizit fact_id-STABILITÄT (nicht nur "Override noch
      # da") — sonst wäre der Test ein False-Positive, falls Verify neue IDs
      # vergeben würde.
      facts =
        case :mnesia.dirty_read(S.session_facts(), @sid) do
          [{_, _, _, facts_json, _, _}] -> Jason.decode!(facts_json)
          [] -> []
        end

      fid = @fid
      assert [%{"id" => ^fid, "verified?" => true}] = facts
      assert {_, _, _, _, ^fid, @ext, "1888-03-20", false, "e01"} = override_row()
    end
  end
end
