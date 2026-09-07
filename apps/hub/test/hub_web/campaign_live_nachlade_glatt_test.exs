defmodule HubWeb.CampaignLiveNachladeGlattTest do
  @moduledoc """
  Issue #1151 (Epic #1146, C4): die Hub-Seite der Flag-Verhandlung.

  Der Worker lässt `smoothed` weg, wenn er `"glatt" => "lazy"` sieht. Der Hub
  muss daraus zwei Dinge ableiten:

  1. **fehlt der Schlüssel → nachladen.** Sonst bliebe die Geglättet-Spalte
     dauerhaft leer, ohne dass irgendetwas rot wird.
  2. **ist er da → NICHT nachladen.** Ein Alt-Worker ignoriert das Flag und
     liefert weiterhin alles; ein zweiter Read wäre dann reine Verschwendung —
     und zwar genau der Read, den dieser Cut einsparen soll.

  Beide Richtungen sind still, wenn sie brechen: im ersten Fall eine leere
  Spalte, im zweiten ein doppelter Read. Kein Fehler, keine Log-Zeile.
  """

  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Snapshot

  # Ein Socket-Ersatz, der nur zeigt, ob start_scope_load gerufen wurde.
  # `start_scope_load/2` greift auf Assigns zu — für die Weichen-Prüfung
  # reicht es, den Aufruf am Absturz zu erkennen, statt LiveView zu starten.
  defp weiche(snap) do
    Snapshot.nachlade_glatt(:kein_socket, {:ok, snap})
  catch
    _, _ -> :geladen
  end

  describe "reload_dirty? beim Start loeschen (#1183)" do
    # Der zweite Antrieb desselben Rejoin-Moments: `reload_dirty?` bedeutet
    # "waehrend des laufenden Reads kamen Aenderungen" (#321). Es wurde nur
    # beim Mount und beim Abarbeiten geloescht, nie beim Start — ein `:reload`
    # aus der no_worker-Kette ueberlebte den Start des erfolgreichen Reads und
    # erzwang dahinter einen zweiten Voll-Read samt zweiter Skelett-Phase
    # (Prod-Log: identisches snapshot_words=295913, anon 309).
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
      # Beide Stellen sind noetig: der Start (alte Flags) und der Nachlauf
      # (das gerade abgearbeitete Flag) — sonst laeuft der Nachlauf endlos.
      src = File.read!(Path.join([__DIR__, "../..", "lib/hub_web/live/campaign_live.ex"]))
      assert src =~ ~r/assign\(:reload_dirty\?, false\)\s*\|>\s*Snapshot\.schedule_reload\(\)/
    end
  end

  describe "die Weiche — Fehler (#1183)" do
    test "ein gescheiterter Voll-Read loest KEINEN Skelett-Read aus" do
      # Der Kreis beim Rollover: Voll-Read {:error, :no_worker} → Skelett-Read
      # {:error, :no_worker} → schedule_reload → 150 ms → von vorn (429 Runden
      # in 66 s). Ein Fehler darf hier nichts nachladen; der Ausgang ist
      # `workers_changed`.
      assert Snapshot.nachlade_glatt(:kein_socket, {:error, :no_worker}) == :kein_socket
      assert Snapshot.nachlade_glatt(:kein_socket, {:error, :queue_timeout}) == :kein_socket
    end

    test "der Aufrufer uebergibt das TUPEL, nicht die Map (Quelltext-Waechter)" do
      # Die C4-Klauseln matchten Maps und griffen nie — `result` ist an der
      # einzigen Aufrufstelle das Reader-Ergebnis. Bricht das, greifen die
      # Schutzklauseln still nicht mehr, wie zwischen C4 und #1183.
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
    test "smoothed fehlt → es wird nachgeladen" do
      assert weiche(%{"campaign" => %{}}) == :geladen
    end

    test "smoothed ist da → es wird NICHT nachgeladen" do
      # Der Alt-Worker-Fall. Bricht er, verdoppelt sich der Read genau dort,
      # wo dieser Cut ihn halbieren soll.
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"smoothed" => []}}) == :kein_socket

      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"smoothed" => [%{"id" => "b1"}]}}) ==
               :kein_socket
    end

    test "leere Liste zählt als geliefert" do
      # Eine Kampagne ohne geglättete Blöcke liefert []. Da ist nichts
      # nachzuladen — und genau deshalb lässt der Worker den Key WEG, statt
      # ihn zu leeren: sonst wären die beiden Fälle nicht unterscheidbar.
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"smoothed" => []}}) == :kein_socket
    end

    test "Fehler-Antworten lösen keinen zweiten Read aus" do
      # forbidden/not_found tragen kein smoothed — ohne diese Klauseln liefe
      # der Hub in einen Nachlade-Read für eine Kampagne, die er nicht sehen
      # darf oder die es nicht gibt.
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"forbidden" => true}}) == :kein_socket
      assert Snapshot.nachlade_glatt(:kein_socket, {:ok, %{"not_found" => true}}) == :kein_socket
    end
  end

  describe "der Scope trägt das Flag" do
    test "snapshot_scope setzt glatt=lazy" do
      # Quelltext-Prüfung: ohne das Flag im Scope liefert der Worker weiterhin
      # alles, und der ganze Cut wäre wirkungslos — ohne dass ein Test bricht.
      src = File.read!(Path.join(__DIR__, "../../lib/hub_web/live/campaign_live/snapshot.ex"))

      assert src =~ ~r/"glatt"\s*=>\s*"lazy"/,
             "snapshot_scope/1 muss das Flag senden (#1151) — sonst ist der Cut wirkungslos"
    end
  end
end
