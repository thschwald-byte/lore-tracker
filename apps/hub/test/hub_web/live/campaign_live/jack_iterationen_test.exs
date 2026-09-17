defmodule HubWeb.CampaignLive.JackIterationenTest do
  # J4 (#1207): „noch N Iterationen“ — die Zahl aus dem Formular.
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Recording

  test "die Zahl aus dem Formular, begrenzt auf 1..8" do
    assert Recording.iterationen_zahl("3") == 3
    assert Recording.iterationen_zahl("8") == 8
    assert Recording.iterationen_zahl("99") == 8
    assert Recording.iterationen_zahl("0") == 1
    assert Recording.iterationen_zahl("-2") == 1
    assert Recording.iterationen_zahl("x") == 1
    assert Recording.iterationen_zahl(nil) == 1
  end
end
