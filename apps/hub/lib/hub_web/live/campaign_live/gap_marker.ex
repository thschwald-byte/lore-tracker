defmodule HubWeb.CampaignLive.GapMarker do
  @moduledoc """
  Issue #917 (Epic #911, Cut 3): der reader-sichtbare **Gap-Trust-Marker**.
  „Vertrauen-aber-markieren" statt klemmen — abgeleitete Inhalte (Chronik/Resümee/
  Epos), die über ihre `source_refs` (Block-IDs seit #864) eine unbestätigte
  ASR-Lücke berühren, bekommen ein 🕳-Zeichen. Reiner Hub-seitiger Join gegen den
  `@smoothed`-Snapshot — keine neuen Worker-Daten.

  Ausgelagert aus `HubWeb.CampaignLive.Components` (God-Module-Grenze).
  """

  @doc """
  Die Block-IDs der **unbestätigten** ASR-Lücken einer Kampagne — `hat_luecke AND
  status == nil` (uncuriert), dieselbe Semantik wie der 🕳-Block-Marker + der
  `glatt_blocks`-Kuratieren-Filter. Aus dem `@smoothed`-Snapshot (Per-Session-Views
  mit `"blocks"`). MapSet für O(1)-Joins.
  """
  @spec unbestaetigte_luecke_block_ids([map()] | nil) :: MapSet.t()
  def unbestaetigte_luecke_block_ids(smoothed) do
    for sv <- smoothed || [],
        b <- sv["blocks"] || [],
        b["hat_luecke"] and is_nil(b["status"]),
        into: MapSet.new(),
        do: b["block_id"]
  end

  @doc """
  Berührt ein abgeleiteter Eintrag (Chronik/Resümee/Epos) über seine `source_refs`
  eine unbestätigte Lücke? Treibt den reader-sichtbaren Gap-Trust-Marker.
  """
  @spec derivation_touches_gap?([String.t()] | nil, MapSet.t()) :: boolean()
  def derivation_touches_gap?(source_refs, gap_ids) do
    not MapSet.disjoint?(MapSet.new(source_refs || []), gap_ids)
  end
end
