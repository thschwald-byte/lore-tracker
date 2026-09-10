defmodule HubWeb.CampaignLive.GlattFlagGuardTest do
  @moduledoc """
  Quelltext-Wächter für die Verhandlung zwischen Hub und Worker.

  **Bis #1198** stand hier der Wächter für die eine Zeile, die Prod am
  2026-09-07 umgebracht hat: ein `campaign_luecken`-Read ohne Fenster-Flag holte
  3146 KB statt 1253 KB (#1153). **Seit #1198** fragt der Hub diesen Scope gar
  nicht mehr — die Geglättet-Spalte kommt anzeigefertig über
  `campaign_glatt_ansicht`, und die Derivationen bringen ihre Quellen aufgelöst
  mit (`"refs" => "aufgeloest"`).

  Bewacht wird deshalb zweierlei, beides still, wenn es bricht: dass kein
  Ladeweg den alten Skelett-Scope wieder anfragt (ein Speicher-Killer, der
  keinen Fehler erzeugt), und dass das `refs`-Flag an genau den Stellen sitzt,
  die es brauchen (ohne es bleiben Popover und Scroll-Sync still leer).
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Updates

  defp quelle(datei), do: File.read!(Path.join([__DIR__, "../../../..", datei]))

  describe "der alte Skelett-Scope ist weg" do
    test "kein Ladeweg im Hub fragt campaign_luecken oder _slice" do
      treffer =
        for f <- Path.wildcard(Path.join([__DIR__, "../../../..", "lib/**/*.{ex,heex}"])),
            File.read!(f) =~ ~r/"campaign_luecken(_slice)?"/,
            do: Path.relative_to_cwd(f)

      assert treffer == [],
             """
             Diese Dateien fragen wieder den Skelett-Scope an: #{inspect(treffer)}

             Er lieferte an seattleV4 5.317 Blöcke, von denen ≤ 600 angezeigt
             werden; am 10.09.2026 hat genau diese Phase einen einzelnen Tab zum
             Hub-Killer gemacht (#1198). Die Geglättet-Spalte lädt über
             `HubWeb.CampaignLive.GlattAnsicht`.
             """
    end
  end

  describe "das refs-Flag" do
    test "die drei Derivations-Scopes bekommen es" do
      for k <- ~w(campaign_summaries campaign_chronik campaign_epos) do
        assert Updates.scope_extra(k) == %{"refs" => "aufgeloest"},
               "#{k} ohne refs-Flag: Popover und Scroll-Sync fänden keine Zeilen (#1198)"
      end
    end

    test "jeder andere Scope bekommt KEINE Zusatzfelder" do
      for k <- ~w(campaign_facts campaign_flags campaign_pipeline campaign_meta campaign_members) do
        assert Updates.scope_extra(k) == %{},
               "#{k} bekäme Zusatzfelder, die der Worker nicht erwartet"
      end
    end

    test "der Haupt-Snapshot fragt es ebenfalls an" do
      [rumpf] =
        Regex.run(
          ~r/defp snapshot_scope\(socket\) do\n(.*?)\n  end\n/s,
          quelle("lib/hub_web/live/campaign_live/snapshot.ex"),
          capture: :all_but_first
        )

      assert rumpf =~ ~r/"refs"\s*=>\s*"aufgeloest"/,
             "ohne das Flag trägt der Voll-Read keine aufgelösten Quellen und keinen 🕳-Marker"

      assert rumpf =~ ~r/"glatt"\s*=>\s*"lazy"/,
             "ohne lazy liefert ein Worker die Blöcke im Haupt-Snapshot mit (#1151)"
    end
  end
end
