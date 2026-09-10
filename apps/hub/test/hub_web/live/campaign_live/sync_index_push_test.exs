defmodule HubWeb.CampaignLive.SyncIndexPushTest do
  @moduledoc """
  Issue #1187: der ColumnSync-Index (#10) reist als Ereignis, nicht als Attribut.
  Issue #1198: und er trägt nur noch, was angezeigt wird — keine Block-Karte im
  Hub, keine `utt_sessions`.

  Beides erzeugt keinen Fehler, wenn es zurückfällt: ein `data-sync-index`-
  Attribut rendert weiter korrekt (nur Megabytes pro Reload, escaped und
  gediffed), und eine Block-Karte im Hub kostet nur Heap. Deshalb
  Quelltext-Wächter.
  """

  use ExUnit.Case, async: true

  defp quelle(rel), do: File.read!(Path.join([__DIR__, "../../../..", rel]))

  defp lib_dateien, do: Path.wildcard(Path.join([__DIR__, "../../../..", "lib/**/*.{ex,heex}"]))

  describe "pushe_sync_index/2 — nur bei Änderung (Review-Fund)" do
    alias HubWeb.CampaignLive.Updates

    defp sock,
      do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{live_temp: %{}}}

    defp events(s), do: Map.get(s.private.live_temp, :push_events, [])

    test "derselbe Index wird kein zweites Mal gepusht" do
      idx = %{"utts_to_entries" => %{"u1" => ["a"]}, "entries_to_utts" => %{"a" => ["u1"]}}
      s1 = Updates.pushe_sync_index(sock(), idx)
      assert length(events(s1)) == 1
      s2 = Updates.pushe_sync_index(s1, idx)
      assert length(events(s2)) == 1, "ein unveränderter Index geht nicht nochmal über den Draht"
    end

    test "ein geänderter Index wird gepusht" do
      s1 = Updates.pushe_sync_index(sock(), %{"a" => 1})
      s2 = Updates.pushe_sync_index(s1, %{"a" => 2})
      assert length(events(s2)) == 2
    end
  end

  describe "Quelltext-Wächter" do
    test "das Wurzel-div trägt kein data-sync-index mehr (#1187)" do
      refute quelle("lib/hub_web/live/campaign_live.html.heex") =~ ~r/data-sync-index=/,
             "der Index ist wieder ein Attribut — pro Reload escaped, gediffed, gepusht (#1187)"
    end

    test "kein sync_index_json-Assign mehr im Hub-Code" do
      for f <- lib_dateien() do
        refute File.read!(f) =~ "sync_index_json",
               "#{Path.relative_to_cwd(f)}: sync_index_json ist zurück (#1187)"
      end
    end

    test "keine Block-Karte mehr im Hub (#1198)" do
      # Die Karte brauchte das Skelett aller Blöcke — genau die Liste, die am
      # 10.09.2026 einen einzelnen Tab zum Hub-Killer gemacht hat. Die Quellen
      # kommen seitdem aufgelöst vom Worker (`Refs.quell/1`).
      for f <- lib_dateien(), src = File.read!(f) do
        refute src =~ "block_source_map(",
               "#{Path.relative_to_cwd(f)}: die Block-Karte ist zurück im Hub (#1198)"

        refute src =~ "resolve_source_refs(",
               "#{Path.relative_to_cwd(f)}: der Hub löst wieder selbst auf (#1198)"
      end
    end

    test "rebuild_refs baut den Sync-Index aus den gerenderten Blöcken (#1198)" do
      [rumpf] =
        Regex.run(
          ~r/def rebuild_refs\(socket\) do\n(.*?)\n  end\n/s,
          quelle("lib/hub_web/live/campaign_live/updates.ex"),
          capture: :all_but_first
        )

      assert rumpf =~ ":glatt_ansicht",
             "der Sync-Index muss aus der Anzeige-Liste gebaut werden, nicht aus einem Skelett"
    end

    test "der JS-Hook hört auf das Ereignis und braucht keine utt_sessions mehr" do
      js = quelle("assets/js/hooks/column_sync.js")
      assert js =~ ~s|handleEvent("sync_index"|
      refute js =~ "dataset.syncIndex"

      refute js =~ ".utt_sessions",
             "tryAutoExpand liest wieder utt_sessions — die kommen nicht mehr (#1198)"
    end
  end
end
