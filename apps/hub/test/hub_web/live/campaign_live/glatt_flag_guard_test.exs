defmodule HubWeb.CampaignLive.GlattFlagGuardTest do
  @moduledoc """
  Issue #1153: Quelltext-Wächter für die eine Zeile, die Prod umgebracht hat.

  Am 2026-09-07 lud C4 (#1151) die geglätteten Blöcke aus dem Mount aus und
  direkt danach über `campaign_luecken` nach — **ohne** das Fenster-Flag aus
  #1152. Gemessen an seattleV4: der Nachlade-Read holte **3146 KB**, also mehr
  als der Mount-Read, den C4 gerade auf 1202 KB gedrückt hatte. Der Hub starb
  um 13:53 und 13:55, neun Sekunden nach dem Mount.

  **Das Fehlen erzeugte keinen Fehler.** Kein roter Test, keine Warnung — nur
  einen Server, der beim Öffnen einer Seite stirbt. Genau deshalb ein Wächter
  und kein Verhaltenstest: es gibt kein Verhalten zu prüfen, nur eine Zeile,
  die dastehen muss.

  Bauart wie `recorder_stop_order_test.exs` (#1011) und
  `capture_log_flush_guard_test.exs` (#1157).
  """
  use ExUnit.Case, async: true

  @dateien [
    "lib/hub_web/live/campaign_live/snapshot.ex",
    "lib/hub_web/live/campaign_live/updates.ex",
    "lib/hub_web/live/campaign_live.ex",
    "lib/hub_web/live/campaign_live/stage_edits.ex"
  ]

  defp quelle(datei), do: File.read!(Path.join([__DIR__, "../../../..", datei]))

  describe "jeder campaign_luecken-Read trägt das Fenster-Flag" do
    test "kein start_scope_load auf campaign_luecken ohne Zusatzfelder" do
      for datei <- @dateien, zeile <- String.split(quelle(datei), "\n") do
        if String.contains?(zeile, "start_scope_load") and
             String.contains?(zeile, "campaign_luecken") do
          assert String.contains?(zeile, "scope_extra"),
                 """
                 #{datei}: ein `campaign_luecken`-Read ohne `scope_extra/1`.

                 Ohne das Fenster-Flag holt dieser Read die vollen Blöcke — an
                 seattleV4 gemessen 3146 KB statt 1253 KB. Genau daran ist der
                 Prod-Hub am 2026-09-07 gestorben (Issue #1153).

                 Zeile: #{String.trim(zeile)}
                 """
        end
      end
    end

    test "der Wächter findet die Stelle überhaupt — sonst wäre er stumm grün" do
      treffer =
        for datei <- @dateien,
            zeile <- String.split(quelle(datei), "\n"),
            String.contains?(zeile, "start_scope_load") and
              String.contains?(zeile, "campaign_luecken"),
            do: datei

      assert treffer != [],
             "kein campaign_luecken-Read gefunden — der Wächter bewacht nichts"
    end
  end

  describe "scope_extra/1 liefert das Flag" do
    test "campaign_luecken bekommt das Fenster-Flag" do
      assert HubWeb.CampaignLive.Updates.scope_extra("campaign_luecken") == %{
               "glatt" => "fenster"
             }
    end

    test "jeder andere Scope bekommt KEINE Zusatzfelder" do
      for k <- ~w(campaign campaign_facts campaign_flags campaign_pipeline campaign_meta) do
        assert HubWeb.CampaignLive.Updates.scope_extra(k) == %{},
               "#{k} bekäme Zusatzfelder, die der Worker nicht erwartet"
      end
    end
  end
end
