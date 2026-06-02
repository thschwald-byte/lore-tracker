defmodule HubWeb.UIComponents.VuBarTest do
  @moduledoc """
  Issue #395: der VU-Bar ist eine Pegel-Qualitäts-Ampel — beide Extreme
  (zu leise + zu laut/Clipping) werden über die Fill-Farbe geflaggt, nicht
  nur das obere Ende. Testet die Zonen-Grenzen + den Default-Zonen-Tooltip.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.UIComponents

  defp render_vu(opts), do: render_component(&UIComponents.vu_bar/1, opts)

  describe "Fill-Farbe je Pegel-Zone" do
    test "still (< 0.05) → gedämpft, kein Alarm" do
      html = render_vu(level: 0.0)
      assert html =~ "bg-primary/40"
      assert html =~ "Pegel: still"
    end

    test "zu leise (0.05–0.33) → warning (gelb) + Hinweis" do
      html = render_vu(level: 0.2)
      assert html =~ "bg-warning"
      refute html =~ "bg-success"
      assert html =~ "zu leise"
    end

    test "gut (0.33–0.85) → success (grün)" do
      html = render_vu(level: 0.5)
      assert html =~ "bg-success"
      assert html =~ "Pegel: gut"
    end

    test "zu laut (>= 0.85) → danger (rot) + Hinweis" do
      html = render_vu(level: 0.95)
      assert html =~ "bg-danger"
      assert html =~ "zu laut"
    end
  end

  describe "Grenzen" do
    test "genau 0.33 fällt in die gut-Zone (nicht mehr zu leise)" do
      assert render_vu(level: 0.33) =~ "bg-success"
    end

    test "genau 0.85 fällt in die zu-laut-Zone" do
      assert render_vu(level: 0.85) =~ "bg-danger"
    end

    test "Pegel > 1.0 wird auf 100% / danger geklemmt" do
      html = render_vu(level: 1.5)
      assert html =~ "width: 100%"
      assert html =~ "bg-danger"
    end

    test "negativer Pegel wird auf 0% / still geklemmt" do
      html = render_vu(level: -0.5)
      assert html =~ "width: 0%"
      assert html =~ "bg-primary/40"
    end
  end

  describe "Tooltip" do
    test "expliziter label überschreibt den Zonen-Hinweis" do
      html = render_vu(level: 0.2, label: "Anna")
      assert html =~ ~s(title="Anna")
      refute html =~ "zu leise"
    end
  end
end
