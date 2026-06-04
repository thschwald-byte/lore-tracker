defmodule HubWeb.DashboardIconTest do
  @moduledoc """
  Issue #564: `icon_ok?/2` lehnt ein Icon nur ab, wenn es GEÄNDERT und neu-
  ungültig ist. Ein unverändertes Alt-Icon (URL, großes data:image, …) blockt
  das Speichern anderer Felder nicht mehr.
  """
  use ExUnit.Case, async: true

  alias HubWeb.DashboardLive

  @valid_png "data:image/png;base64,iVBORw0KGgo="
  @too_big "data:image/png;base64," <> String.duplicate("A", 200_001)

  describe "unverändert → immer ok (der #564-Bug)" do
    test "bestehende http-URL, unverändert → ok (obwohl formal invalide)" do
      url = "https://cdn.example.com/icon.png"
      assert DashboardLive.icon_ok?(url, url)
    end

    test "bestehendes zu großes data:image, unverändert → ok" do
      assert DashboardLive.icon_ok?(@too_big, @too_big)
    end

    test "leer ↔ leer → ok (kein Bild)" do
      assert DashboardLive.icon_ok?("", "")
    end
  end

  describe "geändert → reguläre Validierung greift" do
    test "neues valides data:image → ok" do
      assert DashboardLive.icon_ok?(@valid_png, "")
    end

    test "Bild entfernt (auf leer geändert) → ok" do
      assert DashboardLive.icon_ok?("", "https://old.example.com/icon.png")
    end

    test "neu auf URL geändert → NICHT ok" do
      refute DashboardLive.icon_ok?("https://new.example.com/x.png", "")
    end

    test "neues zu großes data:image → NICHT ok" do
      refute DashboardLive.icon_ok?(@too_big, @valid_png)
    end
  end
end
