defmodule HubWeb.CampaignLive.SyncIndexPushTest do
  @moduledoc """
  Issue #1187: der ColumnSync-Index (#10) reist als Ereignis, nicht als Attribut,
  und die `block_source_map` wird in `rebuild_refs` genau einmal gebaut.

  Beides erzeugt keinen Fehler, wenn es zurückfällt: ein `data-sync-index`-
  Attribut rendert weiter korrekt (nur 2,5 MB pro Reload, escaped und
  gediffed), und eine zweite `block_source_map` kostet nur Heap. Deshalb
  Quelltext-Wächter — plus die Gleichheit der neuen Stelligkeiten mit den alten.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Refs

  defp quelle(rel), do: File.read!(Path.join([__DIR__, "../../../..", rel]))

  defp smoothed,
    do: [
      %{
        "session_id" => "s1",
        "blocks" => [%{"block_id" => "b1", "quell_utterance_ids" => ["u1", "u2"]}]
      }
    ]

  defp summaries, do: [%{"session_id" => "s1", "source_refs" => ["b1"]}]

  defp utterances,
    do: [%{"id" => "u1", "session_id" => "s1"}, %{"id" => "u2", "session_id" => "s1"}]

  describe "vorgebaute block_source_map (Hebel 3)" do
    test "build_utterance_refs_index/5 == /4" do
      assert Refs.build_utterance_refs_index(
               summaries(),
               nil,
               [],
               smoothed(),
               Refs.block_source_map(smoothed())
             ) ==
               Refs.build_utterance_refs_index(summaries(), nil, [], smoothed())
    end

    test "build_sync_index/7 == /6" do
      assert Refs.build_sync_index(
               summaries(),
               nil,
               [],
               utterances(),
               smoothed(),
               [],
               Refs.block_source_map(smoothed())
             ) ==
               Refs.build_sync_index(summaries(), nil, [], utterances(), smoothed(), [])
    end
  end

  describe "Quelltext-Wächter" do
    test "das Wurzel-div trägt kein data-sync-index mehr (Hebel 2)" do
      refute quelle("lib/hub_web/live/campaign_live.html.heex") =~ ~r/data-sync-index=/,
             "der 2,5-MB-Index ist wieder ein Attribut — pro Reload escaped, gediffed, gepusht (#1187)"
    end

    test "kein sync_index_json-Assign mehr im Hub-Code" do
      for f <- Path.wildcard(Path.join([__DIR__, "../../../..", "lib/**/*.{ex,heex}"])) do
        refute File.read!(f) =~ "sync_index_json",
               "#{Path.relative_to_cwd(f)}: sync_index_json ist zurück (#1187)"
      end
    end

    test "rebuild_refs baut die block_source_map genau einmal" do
      src = quelle("lib/hub_web/live/campaign_live/updates.ex")

      [rumpf] =
        Regex.run(~r/defp rebuild_refs\(socket\) do\n(.*?)\n  end\n/s, src,
          capture: :all_but_first
        )

      assert length(Regex.scan(~r/block_source_map\(/, rumpf)) == 1
      assert rumpf =~ ~r/build_utterance_refs_index\([^)]*block_map\)/s
      assert rumpf =~ ~r/build_sync_index\([^)]*block_map\s*\)/s
    end

    test "der JS-Hook hört auf das Ereignis und liest kein dataset mehr" do
      js = quelle("assets/js/hooks/column_sync.js")
      assert js =~ ~s|handleEvent("sync_index"|
      refute js =~ "dataset.syncIndex"
    end
  end
end
