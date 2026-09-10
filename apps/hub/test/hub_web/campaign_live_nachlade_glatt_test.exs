defmodule HubWeb.CampaignLiveNachladeGlattTest do
  @moduledoc """
  Was nach einem Voll-Read mit der Geglättet-Spalte passiert.

  Issue #1151 (C4) nahm die Blöcke aus dem Haupt-Snapshot (`"glatt" => "lazy"`)
  und lud sie danach über einen eigenen Scope nach. Seit #1198 ist das die
  Anzeige-Form `campaign_glatt_ansicht` (`GlattAnsicht.lade/2`): geladen wird
  nach JEDEM erfolgreichen Voll-Read, auch wenn ein Alt-Worker `smoothed` doch
  mitliefert — der Hub liest den Schlüssel nicht mehr.

  Und aus #1183: ein **gescheiterter** Voll-Read lädt nichts nach. Der Kreis
  beim Rollover (Voll-Read `no_worker` → Nachlade-Read `no_worker` → Reload)
  darf nicht wiederkommen.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Snapshot

  # Ein Socket-Ersatz, der nur zeigt, ob geladen werden sollte: `lade/2` greift
  # auf Assigns zu — ein Atom statt Socket wirft dort, und genau daran ist der
  # Versuch erkennbar, ohne eine LiveView zu starten.
  defp weiche(snap) do
    Snapshot.nachlade_glatt(:kein_socket, {:ok, snap})
  catch
    _, _ -> :geladen
  end

  describe "reload_dirty? beim Start loeschen (#1183)" do
    test "start_snapshot_load loescht reload_dirty?" do
      src =
        File.read!(Path.join([__DIR__, "../..", "lib/hub_web/live/campaign_live/snapshot.ex"]))

      [rumpf] =
        Regex.run(~r/def start_snapshot_load\(socket, anlass.*?\n  end\n/s, src)

      assert rumpf =~ ~r/assign\(:reload_dirty\?, false\)/,
             "ohne das Loeschen erzwingt ein alter :reload einen zweiten Voll-Read (#1183)"

      assert rumpf =~ ~r/assign\(:reload_state, :running\)/
    end

    test "der Nachlauf-Zweig loescht es weiterhin selbst" do
      src = File.read!(Path.join([__DIR__, "../..", "lib/hub_web/live/campaign_live.ex"]))
      assert src =~ ~r/assign\(:reload_dirty\?, false\)\s*\|>\s*Snapshot\.schedule_reload\(\)/
    end
  end

  describe "die Weiche — Fehler (#1183)" do
    test "ein gescheiterter Voll-Read loest KEINEN Nachlade-Read aus" do
      assert Snapshot.nachlade_glatt(:kein_socket, {:error, :no_worker}) == :kein_socket
      assert Snapshot.nachlade_glatt(:kein_socket, {:error, :queue_timeout}) == :kein_socket
    end

    test "der Aufrufer uebergibt das TUPEL, nicht die Map (Quelltext-Waechter)" do
      src = File.read!(Path.join([__DIR__, "../..", "lib/hub_web/live/campaign_live.ex"]))

      [rumpf] =
        Regex.run(
          ~r/def handle_async\(:reload_snapshot, \{:ok, result\}, socket\) do\n(.*?)\n  end\n/s,
          src,
          capture: :all_but_first
        )

      assert rumpf =~ "Snapshot.nachlade_glatt(result)"

      snap =
        File.read!(Path.join([__DIR__, "../..", "lib/hub_web/live/campaign_live/snapshot.ex"]))

      refute snap =~ ~r/def nachlade_glatt\(socket, %\{/,
             "nachlade_glatt matcht wieder nackte Maps — toter Code (#1183)"
    end
  end

  describe "die Weiche" do
    test "nach einem erfolgreichen Voll-Read wird die Ansicht geladen" do
      assert weiche(%{"campaign" => %{}}) == :geladen
    end

    test "auch wenn ein Alt-Worker smoothed mitliefert (#1198)" do
      # Bis #1198 hieß das „nicht nachladen". Der Hub liest `smoothed` nicht
      # mehr; ohne den Ansicht-Read bliebe die Spalte bei einem alten Worker
      # still leer statt „Worker wird aktualisiert" zu sagen.
      assert weiche(%{"smoothed" => []}) == :geladen
    end

    test "forbidden/not_found lösen keinen zweiten Read aus" do
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"forbidden" => true}}) == :kein_socket
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"not_found" => true}}) == :kein_socket
    end
  end
end
