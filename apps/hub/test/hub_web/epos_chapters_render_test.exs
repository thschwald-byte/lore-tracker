defmodule HubWeb.EposChaptersRenderTest do
  @moduledoc """
  Issue #752: die Epos-Spalte rendert drei Zustände — nur Legacy-Buch,
  nur per-Session-Kapitel, und Mixed-State (Legacy-Buch einer Bestands-
  kampagne bleibt ÜBER den Kapiteln sichtbar, verschwindet NICHT beim
  ersten Kapitel). Alles über `render_md_safe/1` (XSS-Regression).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.Components

  defp render_col(assigns) do
    base = %{
      title: "Epos",
      owner?: false,
      can_edit?: false,
      waiting?: false,
      epos: nil,
      epos_chapters: [],
      epos_history: [],
      epos_mode: :view,
      epos_draft: "",
      epos_diff_seq: nil,
      chapter_edit_id: nil,
      chapter_draft: "",
      busy?: false,
      collapsed?: false,
      can_collapse?: true
    }

    render_component(&Components.epos_column/1, Map.merge(base, assigns))
  end

  test "nur Legacy-Buch: rendert ohne Kapitel-Abschnitt und ohne Legacy-Label" do
    html = render_col(%{epos: %{"id" => "c-1", "content_md" => "Das alte Buch."}})

    assert html =~ "Das alte Buch."
    refute html =~ "Alt-Epos"
  end

  test "nur Kapitel: rendert Kapitel in Reihenfolge, kein Legacy-Label" do
    chapters = [
      %{"id" => "s-1", "content_md" => "## Kapitel 1\n\nErstes."},
      %{"id" => "s-2", "content_md" => "## Kapitel 2 — Tag 3\n\nZweites."}
    ]

    html = render_col(%{epos_chapters: chapters})

    assert html =~ "Kapitel 1"
    assert html =~ "Erstes."
    assert html =~ "Kapitel 2 — Tag 3"
    refute html =~ "Alt-Epos"
    refute html =~ "Noch leer"
  end

  test "Mixed-State: Legacy-Buch bleibt ÜBER den Kapiteln sichtbar" do
    html =
      render_col(%{
        epos: %{"id" => "c-1", "content_md" => "Das alte Buch."},
        epos_chapters: [%{"id" => "s-9", "content_md" => "## Kapitel 9\n\nNeu."}]
      })

    assert html =~ "Alt-Epos"
    assert html =~ "Das alte Buch."
    assert html =~ "Kapitel 9"
    # Legacy vor Kapitel (Dokumenten-Reihenfolge).
    assert :binary.match(html, "Das alte Buch.") < :binary.match(html, "Kapitel 9")
  end

  test "leer: weder Buch noch Kapitel → Leer-Hinweis" do
    html = render_col(%{})
    assert html =~ "Noch leer"
  end

  test "XSS: Kapitel-Markdown läuft durch render_md_safe" do
    html =
      render_col(%{
        epos_chapters: [%{"id" => "s-1", "content_md" => "<script>alert(1)</script>Hallo"}]
      })

    refute html =~ "<script>"
    # Der Text-Inhalt bleibt als harmloser Text erhalten (kein aktives Tag).
    assert html =~ "alert(1)"
  end

  # ─── Issue #753: per-Kapitel-Edit ───────────────────────────────────

  test "#753: Edit-Button pro Kapitel nur für can_edit?" do
    chapters = [%{"id" => "s-1", "content_md" => "## Kapitel 1\n\nText."}]

    html_gm = render_col(%{epos_chapters: chapters, can_edit?: true})
    assert html_gm =~ "chapter_edit_start"
    assert html_gm =~ ~s(phx-value-entry_id="s-1")

    html_player = render_col(%{epos_chapters: chapters, can_edit?: false})
    refute html_player =~ "chapter_edit_start"
  end

  test "#753: Kapitel im Edit-Modus rendert Formular mit Draft + hidden entry_id" do
    chapters = [
      %{"id" => "s-1", "content_md" => "## Kapitel 1\n\nOriginal."},
      %{"id" => "s-2", "content_md" => "## Kapitel 2\n\nAnderes."}
    ]

    html =
      render_col(%{
        epos_chapters: chapters,
        can_edit?: true,
        chapter_edit_id: "s-1",
        chapter_draft: "## Kapitel 1\n\nDraft-Fassung."
      })

    assert html =~ "chapter_edit_save"
    assert html =~ ~s(name="entry_id" value="s-1")
    assert html =~ "Draft-Fassung."
    # Das andere Kapitel bleibt im View-Modus.
    assert html =~ "Anderes."
  end

  test "#753: ohne can_edit? kein Edit-Formular trotz gesetztem chapter_edit_id" do
    html =
      render_col(%{
        epos_chapters: [%{"id" => "s-1", "content_md" => "Text."}],
        can_edit?: false,
        chapter_edit_id: "s-1",
        chapter_draft: "x"
      })

    refute html =~ "chapter_edit_save"
  end
end
