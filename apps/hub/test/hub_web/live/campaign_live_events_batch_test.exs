defmodule HubWeb.CampaignLiveEventsBatchTest do
  @moduledoc """
  Issue #702: CampaignLive konsumiert `{:events_batch, events}` — alle
  UtteranceAppended eines Batches landen in EINEM update in der
  :utterances-Liste (eine Message = ein Diff), fremde Sessions werden
  gefiltert, Nicht-Utterance-Kinds laufen durch den EventsBatch-Fold.
  """

  use HubWeb.ConnCase, async: false

  defp mount_with_session(conn) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-batch",
        name: "Batch Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Batch Session"}],
        members: [Fixtures.member("did-sp", "spieler")]
      )

    stub_reader!(snap)
    user = Fixtures.user(discord_id: "did-sp", display_name: "Spieler", campaign_role: :spieler)

    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-batch")
    render_async(lv)
    lv
  end

  defp batch_event(kind, payload) do
    %{
      seq: nil,
      event_id: UUIDv7.generate(),
      payload: Map.put(payload, "kind", kind),
      author_worker_id: "w-test",
      ts: DateTime.utc_now()
    }
  end

  defp utt_event(sid, text) do
    batch_event(Shared.Events.utterance_appended(), %{
      "id" => UUIDv7.generate(),
      "session_id" => sid,
      "discord_id" => "did-sp",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "text" => text,
      "confidence" => nil,
      "status" => "confirmed"
    })
  end

  test "Batch mit 2 Utterances → beide in der Protokoll-Spalte (eine Message)", %{conn: conn} do
    lv = mount_with_session(conn)

    send(view_pid(lv), {:events_batch, [utt_event("s-1", "Alpha"), utt_event("s-1", "Beta")]})

    html = render(lv)
    assert html =~ "Session 1 · Batch Session"
    # Gruppen-Zähler "(2)" — die Texte selbst sind hinter dem Collapse-Toggle.
    assert html =~ "(2)"
  end

  test "Utterances fremder Sessions werden gefiltert, unbekannte Kinds crashen nicht", %{
    conn: conn
  } do
    lv = mount_with_session(conn)

    send(
      view_pid(lv),
      {:events_batch,
       [
         utt_event("s-1", "Gamma"),
         utt_event("s-fremd", "Delta"),
         batch_event(Shared.Events.marker_added(), %{"session_id" => "s-fremd"})
       ]}
    )

    html = render(lv)
    # nur die s-1-Utterance zählt
    assert html =~ "(1)"
    refute html =~ "s-fremd"
  end

  defp view_pid(lv), do: lv.pid
end
