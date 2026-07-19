defmodule HubWeb.CampaignLive.GlattViewTest do
  @moduledoc """
  Issue #871: Ansichten der Geglättet-Spalte — Auto-Default (kuratieren,
  solange es Kuratierbares gibt, sonst einfach), Filter pro Ansicht
  (kuratieren leert sich nach Kuration; einfach blendet unbrauchbar aus).
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Components

  defp sm(blocks), do: %{"session_id" => "s1", "blocks" => blocks}

  defp b(id, opts \\ []) do
    %{
      "block_id" => id,
      "hat_luecke" => Keyword.get(opts, :luecke, false),
      "status" => Keyword.get(opts, :status)
    }
  end

  test "Default = kuratieren, solange unkuratierte Lücken existieren; danach einfach" do
    offen = sm([b("b1", luecke: true), b("b2")])
    assert Components.glatt_view_for(%{}, offen) == "kuratieren"

    # Kuration geschehen → kuratieren leert sich → Default fällt auf einfach.
    fertig = sm([b("b1", luecke: true, status: "bestaetigt"), b("b2")])
    assert Components.glatt_view_for(%{}, fertig) == "einfach"
  end

  test "expliziter User-Toggle gewinnt über den Auto-Default" do
    offen = sm([b("b1", luecke: true)])
    assert Components.glatt_view_for(%{"s1" => "alles"}, offen) == "alles"
    assert Components.glatt_view_for(%{"andere" => "alles"}, offen) == "kuratieren"
  end

  test "kuratieren zeigt NUR unkuratierte Lücken — kuratierte verschwinden" do
    blocks = [
      b("b_offen", luecke: true),
      b("b_fertig", luecke: true, status: "original_bestaetigt"),
      b("b_clean")
    ]

    assert Components.glatt_blocks(sm(blocks), "kuratieren") |> Enum.map(& &1["block_id"]) ==
             ["b_offen"]
  end

  test "einfach = Endergebnis: unbrauchbar fällt raus, Rest bleibt" do
    blocks = [b("b_ok"), b("b_tot", luecke: true, status: "unbrauchbar")]

    assert Components.glatt_blocks(sm(blocks), "einfach") |> Enum.map(& &1["block_id"]) ==
             ["b_ok"]
  end

  test "alles zeigt alle Blöcke" do
    blocks = [b("b_ok"), b("b_tot", status: "unbrauchbar"), b("b_offen", luecke: true)]
    assert length(Components.glatt_blocks(sm(blocks), "alles")) == 3
  end
end
