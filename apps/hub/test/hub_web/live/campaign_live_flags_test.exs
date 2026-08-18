defmodule HubWeb.CampaignLiveFlagsTest do
  @moduledoc """
  Issue #915 (Epic #911, Cut 1): die Falsifikations-Flag-UI + das SERVERSEITIGE
  Permission-Gate. Gepinnt: (1) Melden = Member-Recht, Lösen = GM-only; (2) ein
  Member sieht den Melden-Button, ein geflaggtes Objekt zeigt den ⚠-Marker;
  (3) die Kurator-Queue erscheint nur GM im Bearbeiten-Modus; (4) ein gecrafteter
  flag_resolve ohne Berechtigung wird serverseitig geblockt (Flash, kein Publish).

  Issue #1082: `:resolve_flag` war in Cut 1 GM-only („Kurator == GM"). Es ist
  jetzt Mitglieder-Recht — das Lösen einer Unstimmigkeits-Meldung ist Pflege,
  keine unumkehrbare Handlung, und die Kuration ist in diesem Projekt ohnehin
  kollaborativ (`:curate_threads`, `:curate_luecken`, `:curate_facts`). Die
  Schranke greift weiterhin gegen Nicht-Mitglieder.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.Permissions

  describe "Permissions (Autz-Wahrheit)" do
    test "flag_raise und resolve_flag sind beide Mitglieder-Recht (#1082)" do
      member = %{role: :spieler, campaign_role: :spieler}
      gm = %{role: :spieler, campaign_role: :spielleiter}
      fremd = %{role: :spieler, campaign_role: nil}
      c = %{"id" => "c"}

      assert Permissions.can?(member, :flag_raise, c)
      assert Permissions.can?(gm, :flag_raise, c)
      refute Permissions.can?(fremd, :flag_raise, c)

      assert Permissions.can?(gm, :resolve_flag, c)
      assert Permissions.can?(member, :resolve_flag, c)
      # Die Grenze bleibt — sie verläuft jetzt an der Mitgliedschaft.
      refute Permissions.can?(fremd, :resolve_flag, c)
    end
  end

  defp summary(sid) do
    %{
      "session_id" => sid,
      "campaign_id" => "c-flag",
      "content_md" => "Resümee-Text",
      "generated_at" => "2026-01-01T00:00:00Z",
      "source" => "llm",
      "source_refs" => [],
      "flagged_claims" => []
    }
  end

  defp flag(sid, opts \\ []) do
    %{
      "flag_key" => "c-flag:session:#{sid}",
      "target_kind" => "session",
      "target_id" => sid,
      "raised_by" => Keyword.get(opts, :by, "did-a"),
      "note" => Keyword.get(opts, :note, "das stimmt nicht"),
      "status" => "raised",
      "effective_status" => "raised",
      "event_id" => "e1"
    }
  end

  defp mount(conn, role, opts \\ []) do
    snap =
      Fixtures.snapshot(
        campaign_id: "c-flag",
        name: "Flag Kampagne",
        sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
        summaries: [summary("s-1")],
        members: [Fixtures.member("did-a", "spieler"), Fixtures.member("did-gm", "spielleiter")]
      )
      |> Map.put("flags", Keyword.get(opts, :flags, []))

    stub_reader!(snap)
    did = if role == :gm, do: "did-gm", else: "did-a"
    cr = if role == :gm, do: :spielleiter, else: :spieler
    user = Fixtures.user(discord_id: did, display_name: did, campaign_role: cr)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-flag")
    render_async(lv)
    lv
  end

  test "Member sieht den Melden-Button (kein offenes Flag)", %{conn: conn} do
    html = render(mount(conn, :member))
    assert html =~ "⚠ melden"
    refute html =~ "⚠ gemeldet"
  end

  test "geflaggte Session zeigt den ⚠-Marker statt des Melden-Buttons", %{conn: conn} do
    html = render(mount(conn, :member, flags: [flag("s-1")]))
    assert html =~ "⚠ gemeldet"
    refute html =~ "⚠ melden"
  end

  test "Kurator-Queue: Member im Bearbeiten-Modus sieht sie (seit #1082)", %{conn: conn} do
    lv = mount(conn, :member, flags: [flag("s-1", note: "Datum falsch")])
    html = render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    assert html =~ "offene Unstimmigkeits-Meldung"
    assert html =~ "Datum falsch"
  end

  test "Kurator-Queue: GM im Bearbeiten-Modus sieht die offenen Meldungen + Notiz", %{conn: conn} do
    lv = mount(conn, :gm, flags: [flag("s-1", note: "Datum falsch")])
    html = render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
    assert html =~ "offene Unstimmigkeits-Meldung"
    assert html =~ "Datum falsch"
  end

  test "flag_resolve als Member geht durch und crasht nicht (seit #1082)", %{conn: conn} do
    lv = mount(conn, :member, flags: [flag("s-1")])
    html = render_click(lv, "flag_resolve", %{"target_kind" => "session", "target_id" => "s-1"})
    refute html =~ "Keine Berechtigung"
    assert Process.alive?(lv.pid)
  end

  test "flag_raise als Member crasht nicht (kein Worker → Flash-Pfad)", %{conn: conn} do
    lv = mount(conn, :member)
    # Kein Worker online im Test → EventBridge → Self-Message, kein Crash.
    render_click(lv, "flag_raise", %{"target_kind" => "session", "target_id" => "s-1"})
    assert Process.alive?(lv.pid)
  end
end
