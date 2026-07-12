defmodule HubWeb.CampaignLive.StageEditsInputCapsTest do
  @moduledoc """
  Issue #636: Server-Side-Cap-Gates in den Stage-Save-Handlern.

  Deny-Pfad: überlange User-Strings → Flash-Error + kein Publisher.publish/2.
  Bare-Socket-Transforms wie stage_edits_epos_authz_test — der Publisher wird
  bei :too_long gar nicht erst erreicht (Cap-Check greift davor), also
  kein GenServer-Setup nötig.
  """
  use ExUnit.Case, async: true

  alias Hub.InputCaps
  alias HubWeb.CampaignLive.StageEdits

  # Ein Byte über dem Body-Cap (50_000).
  @overlong_body String.duplicate("x", 50_001)

  defp base_assigns(campaign_role) do
    %{
      current_user: %{discord_id: "did-me"},
      campaign: %{"id" => "camp-1"},
      campaign_id: "camp-1",
      flash: %{},
      perm_user: %{
        discord_id: "did-me",
        role: :spieler,
        campaign_role: campaign_role,
        is_member?: campaign_role != nil
      },
      can_edit_meta?: campaign_role == :spielleiter
    }
  end

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  # ─── summary ────────────────────────────────────────────────────

  describe "summary_edit_save/2 — Cap" do
    test "überlanges new_md → Flash-Error, kein Publish, Draft bleibt (Edit-Mode offen)" do
      s =
        socket(
          Map.merge(base_assigns(:spielleiter), %{
            summaries: [],
            summary_editing: "sess-1",
            summary_draft: @overlong_body
          })
        )

      {:noreply, s2} = StageEdits.summary_edit_save(s, @overlong_body)

      assert s2.assigns.flash["error"] =~ "Resümee"
      assert s2.assigns.flash["error"] =~ "50000"
      # Edit-Mode + Draft nicht verworfen — User kann kürzen.
      assert s2.assigns.summary_editing == "sess-1"
      assert s2.assigns.summary_draft == @overlong_body
    end

    test "am Cap (50_000 Bytes) → kein Flash-Error (Publisher-Call ist der Publish-Pfad — hier nicht instrumentiert)" do
      # Wir prüfen nur, dass der Cap-Check bei genau 50_000 :ok liefert.
      assert InputCaps.check(:summary_body, String.duplicate("x", 50_000)) == :ok
    end
  end

  # ─── chronik ────────────────────────────────────────────────────

  describe "chronik_edit_save/2 — Cap" do
    test "überlanger markdown_body → Flash-Error, kein Publish, Draft bleibt" do
      s =
        socket(
          Map.merge(base_assigns(:spielleiter), %{
            chronik: [%{"id" => "c-1", "session_id" => "sess-1", "summary" => "x"}],
            chronik_editing: "c-1",
            chronik_draft: @overlong_body
          })
        )

      {:noreply, s2} = StageEdits.chronik_edit_save(s, %{"markdown_body" => @overlong_body})

      assert s2.assigns.flash["error"] =~ "Chronik"
      assert s2.assigns.flash["error"] =~ "50000"
      assert s2.assigns.chronik_editing == "c-1"
      assert s2.assigns.chronik_draft == @overlong_body
    end
  end

  # ─── epos (Legacy-Buch) ─────────────────────────────────────────

  describe "epos_edit_save/2 — Cap" do
    test "überlanges new_md (GM) → Flash-Error, kein Publish, Edit-Mode bleibt" do
      s =
        socket(
          Map.merge(base_assigns(:spielleiter), %{
            epos: %{"content_md" => "alt"},
            epos_mode: :edit,
            epos_draft: @overlong_body
          })
        )

      {:noreply, s2} = StageEdits.epos_edit_save(s, @overlong_body)

      assert s2.assigns.flash["error"] =~ "Epos"
      assert s2.assigns.flash["error"] =~ "50000"
      # Edit-Mode nicht geschlossen — User kann kürzen.
      assert s2.assigns.epos_mode == :edit
      assert s2.assigns.epos_draft == @overlong_body
    end

    test "Nicht-GM mit ueberlangem Text bekommt Berechtigungs-Fehler (Permission-Gate vor Cap-Check)" do
      s =
        socket(
          Map.merge(base_assigns(:spieler), %{
            epos: %{"content_md" => "alt"},
            epos_mode: :edit,
            epos_draft: @overlong_body
          })
        )

      {:noreply, s2} = StageEdits.epos_edit_save(s, @overlong_body)

      assert s2.assigns.flash["error"] =~ "Keine Berechtigung"
      # Permission-Deny schließt Edit-Mode (Bestandsverhalten).
      assert s2.assigns.epos_mode == :view
    end
  end

  # ─── chapter (per-Kapitel) ──────────────────────────────────────

  describe "chapter_edit_save/3 — Cap" do
    test "überlanges new_md (GM, bekanntes entry_id) → Flash-Error, kein Publish, Edit-Mode bleibt" do
      s =
        socket(
          Map.merge(base_assigns(:spielleiter), %{
            epos_chapters: [%{"id" => "sess-1", "content_md" => "alt"}],
            chapter_edit_id: "sess-1",
            chapter_draft: @overlong_body
          })
        )

      {:noreply, s2} = StageEdits.chapter_edit_save(s, "sess-1", @overlong_body)

      assert s2.assigns.flash["error"] =~ "Kapitel"
      assert s2.assigns.flash["error"] =~ "50000"
      assert s2.assigns.chapter_edit_id == "sess-1"
      assert s2.assigns.chapter_draft == @overlong_body
    end
  end
end
