defmodule Worker.MaterializerDeletionTombstoneConvergenceTest do
  @moduledoc """
  Issue #894 (I7-Bucket-D-Rest): Lösch-Tombstones müssen unter Umordnung
  zwischen ≥2 Workern konvergieren — ein Pre-Delete-Event darf nach einem
  CampaignDeleted/SessionDeleted/LiveUtterancesCleared nie wieder auferstehen,
  aber ein legitimes Rebirth (Re-Seed derselben ID, größere event_id) muss
  durch.

  Watermark-Semantik (max event_id pro Scope): `deletion_gated?` droppt einen
  Fold gdw. ein Tombstone existiert UND `not event_id_supersedes?(incoming,
  tombstone)`. Konvergenz = derselbe Read über jede Ankunftsreihenfolge
  (`materialize_permutations/2`, der geteilte I7-Baustein).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.DynamicTables
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-drest-894"
  @sid "sess-drest-1"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
      # CampaignCreated-Events legen einen per-Campaign-Store an (Seiteneffekt
      # von maybe_create_campaign_store) — nach dem Test wieder droppen.
      for cid <- [@cid, @cid <> "-x"] do
        if DynamicTables.exists?(cid), do: DynamicTables.drop_campaign_store!(cid)
      end
    end)

    :ok
  end

  # seq nur fürs Envelope; die Tests permutieren das APPLY, nicht die seq-Werte.
  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  defp campaign_created(cid, event_id, ts) do
    event("CampaignCreated", %{"id" => cid, "name" => "C-#{cid}", "owner_discord_id" => "owner"},
      next_seq(),
      event_id: event_id,
      ts: ts
    )
  end

  defp session_scheduled(sid, cid, event_id) do
    event(
      "SessionScheduled",
      %{"id" => sid, "campaign_id" => cid, "number" => 1, "name" => "S1"},
      next_seq(),
      event_id: event_id
    )
  end

  defp utterance_appended(id, sid, cid, event_id, status \\ "confirmed") do
    event(
      "UtteranceAppended",
      %{
        "id" => id,
        "session_id" => sid,
        "campaign_id" => cid,
        "discord_id" => "u",
        "text" => "hi",
        "status" => status
      },
      next_seq(),
      event_id: event_id
    )
  end

  defp live_cleared(sid, event_id) do
    event("LiveUtterancesCleared", %{"session_id" => sid}, next_seq(), event_id: event_id)
  end

  defp marker_added(id, sid, event_id) do
    event(
      "MarkerAdded",
      %{"id" => id, "session_id" => sid, "marker_kind" => "plot", "label" => "m"},
      next_seq(),
      event_id: event_id
    )
  end

  defp session_summary(sid, cid, event_id) do
    event(
      "SessionSummaryGenerated",
      %{"session_id" => sid, "campaign_id" => cid, "content_md" => "sum", "source" => "llm"},
      next_seq(),
      event_id: event_id
    )
  end

  defp campaign_deleted(cid, event_id, ts) do
    event("CampaignDeleted", %{"campaign_id" => cid, "deleted_by" => "owner"}, next_seq(),
      event_id: event_id,
      ts: ts
    )
  end

  defp session_deleted(sid, cid, event_id) do
    event("SessionDeleted", %{"session_id" => sid, "campaign_id" => cid, "deleted_by" => "owner"},
      next_seq(),
      event_id: event_id
    )
  end

  # ── Reads (direkt auf Mnesia, wie im #15-Cascade-Test) ───────────────
  defp campaign_exists?, do: :mnesia.dirty_read(S.campaigns(), @cid) != []

  defp session_ids,
    do: :mnesia.dirty_index_read(S.sessions(), @cid, :campaign_id) |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  defp utt_ids(sid),
    do: :mnesia.dirty_index_read(S.utterances(), sid, :session_id) |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  defp marker_count(sid), do: :mnesia.dirty_index_read(S.markers(), sid, :session_id) |> length()

  @early "2026-01-01T00:00:00Z"
  @late "2026-02-01T00:00:00Z"

  test "CampaignDeleted: Campaign + Sessions weg über jede Reihenfolge (delete-before-data & data-before-delete)" do
    # Utterances hängen an session_id (KEINE campaign_id-Spalte) → ihre Konvergenz
    # deckt der SessionDeleted-Test ab (dort ist session_id der Anker). Hier: die
    # campaign-id-verankerte Hierarchie (Campaign + Sessions).
    events = [
      campaign_created(@cid, "e01", @early),
      session_scheduled(@sid, @cid, "e02"),
      session_scheduled(@sid <> "-2", @cid, "e03"),
      campaign_deleted(@cid, "e05", @late)
    ]

    read = fn -> {campaign_exists?(), session_ids()} end

    for r <- materialize_permutations(events, read) do
      assert r == {false, []},
             "gelöschte Campaign + Sessions müssen über alle Reihenfolgen leer bleiben, war: #{inspect(r)}"
    end
  end

  test "Replayed alter CampaignCreated (event_id < Tombstone) belebt nichts" do
    for order <- [
          [campaign_created(@cid, "e01", @early), campaign_deleted(@cid, "e05", @late)],
          [campaign_deleted(@cid, "e05", @late), campaign_created(@cid, "e01", @early)]
        ] do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)

      refute campaign_exists?(),
             "alter Create (event_id < Tombstone) darf die Campaign nicht wiederbeleben"
    end
  end

  test "Rebirth: CampaignCreated mit größerer event_id nach dem Delete lebt (Re-Seed-Regression)" do
    # Delete e05 @early, Rebirth-Create e09 @late (später in Zeit UND event_id).
    for order <- [
          [campaign_deleted(@cid, "e05", @early), campaign_created(@cid, "e09", @late)],
          [campaign_created(@cid, "e09", @late), campaign_deleted(@cid, "e05", @early)]
        ] do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)

      assert campaign_exists?(),
             "Rebirth-Campaign (event_id > Tombstone) muss leben — der --reset-Seed-Flow"
    end
  end

  test "SessionDeleted: Session + Utterances + Summary weg, Nachbar-Session unberührt, order-insensitiv" do
    events = [
      campaign_created(@cid, "e01", @early),
      session_scheduled(@sid, @cid, "e02"),
      session_scheduled("sess-keep", @cid, "e02b"),
      utterance_appended("u1", @sid, @cid, "e03"),
      utterance_appended("keep-u", "sess-keep", @cid, "e03b"),
      session_summary(@sid, @cid, "e04"),
      session_deleted(@sid, @cid, "e05")
    ]

    read = fn ->
      {session_ids(), utt_ids(@sid), utt_ids("sess-keep"),
       :mnesia.dirty_read(S.session_summaries(), @sid) != []}
    end

    for r <- materialize_permutations(events, read) do
      assert r == {["sess-keep"], [], ["keep-u"], false},
             "gelöschte Session muss leer sein, Nachbar-Session bleibt, war: #{inspect(r)}"
    end
  end

  test "MarkerAdded (nur session_id) nach SessionDeleted wird nie zur Row (Session-Tombstone ohne campaign_id)" do
    # Der Session-Tombstone wird auch im []-Zweig geschrieben → gilt für
    # Session-only-Events (kein campaign_id) über jede Reihenfolge.
    events = [
      session_scheduled(@sid, @cid, "e02"),
      marker_added("m1", @sid, "e03"),
      session_deleted(@sid, @cid, "e05")
    ]

    for r <- materialize_permutations(events, fn -> marker_count(@sid) end) do
      assert r == 0, "Marker einer gelöschten Session darf nie überleben, war: #{r}"
    end
  end

  test "MarkerAdded nach CampaignDeleted (materialisierte Campaign) gegated (L3-Session-Tombstone)" do
    # Realistischer Pfad: der Worker HÄLT die Campaign und löscht sie → die
    # Cascade schreibt pro Session einen Tombstone (L3). Explizite Ordnungen mit
    # Create vor Delete (der []-Zweig-Kaltstart mit Session-only-Event ist ein
    # dokumentierter, benigner Orphan — unsichtbar, keine Resurrection).
    for order <- [
          [
            campaign_created(@cid, "e01", @early),
            session_scheduled(@sid, @cid, "e02"),
            marker_added("m1", @sid, "e03"),
            campaign_deleted(@cid, "e05", @late)
          ],
          [
            campaign_created(@cid, "e01", @early),
            session_scheduled(@sid, @cid, "e02"),
            campaign_deleted(@cid, "e05", @late),
            marker_added("m1", @sid, "e03")
          ]
        ] do
      reset_for_permutation!()
      Enum.each(order, &Materializer.apply_event/1)
      assert marker_count(@sid) == 0
    end
  end

  test "LiveUtterancesCleared: nur Pre-Clear-Live weg, Post-Clear-Live + confirmed bleiben, order-insensitiv" do
    # ids so gewählt, dass "a1"/"a2" < clear-event_id "m5" < "z9".
    events = [
      utterance_appended("a1", @sid, @cid, "ea1", "live"),
      utterance_appended("a2", @sid, @cid, "ea2", "live"),
      utterance_appended("c1", @sid, @cid, "ec1", "confirmed"),
      live_cleared(@sid, "m5"),
      utterance_appended("z9", @sid, @cid, "ez9", "live")
    ]

    for r <- materialize_permutations(events, fn -> utt_ids(@sid) end) do
      assert r == ["c1", "z9"],
             "nur Pre-Clear-Live (id <= watermark) fällt, war: #{inspect(r)}"
    end
  end

  test "LiveUtterancesCleared: Doppel-Clear nimmt das Maximum (order-insensitiv)" do
    events = [
      utterance_appended("a1", @sid, @cid, "ea1", "live"),
      live_cleared(@sid, "m3"),
      utterance_appended("m5", @sid, @cid, "em5", "live"),
      live_cleared(@sid, "m7"),
      utterance_appended("z9", @sid, @cid, "ez9", "live")
    ]

    for r <- materialize_permutations(events, fn -> utt_ids(@sid) end) do
      assert r == ["z9"], "Watermark = max(m3,m7) → nur id > m7 überlebt, war: #{inspect(r)}"
    end
  end

  test "Cascades löschen die Tombstones NICHT (Watermark überlebt)" do
    [
      campaign_created(@cid, "e01", @early),
      session_scheduled(@sid, @cid, "e02"),
      campaign_deleted(@cid, "e05", @late)
    ]
    |> Enum.each(&Materializer.apply_event/1)

    assert :mnesia.dirty_read(S.deletion_tombstones(), {:campaign, @cid}) != []
    assert :mnesia.dirty_read(S.deletion_tombstones(), {:session, @sid}) != []
  end
end
