defmodule HubWeb.UIComponents.TablerTest do
  @moduledoc """
  Issue #611: die `tabler/1`-Icon-Komponente muss jeden gültigen Icon-Namen
  robust rendern — auch solche, die im Code NUR als String vorkommen (nie als
  Literal-Atom). Vorher nutzte sie `String.to_existing_atom/1` und crashte im
  Dev-Lazy-Loading mit `ArgumentError: not an already existing atom`, sobald das
  TablerIcons-Modul (und damit der Funktions-Atom) noch nicht geladen war —
  z.B. `icon="bell"` auf dem Dashboard (GET /).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.UIComponents

  defp render_tabler(name), do: render_component(&UIComponents.tabler/1, name: name)

  test "rendert ein nur-als-String genutztes Icon (#611: bell) ohne Crash" do
    html = render_tabler("bell")
    assert html =~ "<svg"
  end

  test "rendert ein Icon mit Bindestrich (→ underscore)" do
    # arrow-right → TablerIcons.arrow_right/1
    html = render_tabler("arrow-right")
    assert html =~ "<svg"
  end

  test "default class wird gesetzt" do
    assert render_tabler("bell") =~ "w-4 h-4"
  end
end
