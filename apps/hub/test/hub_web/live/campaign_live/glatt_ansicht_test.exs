defmodule HubWeb.CampaignLive.GlattAnsichtTest do
  @moduledoc """
  Issue #1198: die Hub-Seite der Geglättet-Ansicht — pur und ohne LiveView.

  Festgehalten werden die drei Regeln aus dem Moduledoc von
  `HubWeb.CampaignLive.GlattAnsicht`:

  1. Ein Fehler löst NIE einen Voll-Reload aus (Deploy-Fenster-Schleife).
  2. Höchstens ein Read je LiveView; Wünsche während eines Reads werden
     vorgemerkt.
  3. Die Ansicht geht nur mit, wenn jemand sie gewählt hat.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias HubWeb.CampaignLive.GlattAnsicht

  defp quelle(rel), do: File.read!(Path.join([__DIR__, "../../../..", rel]))

  defp sock(assigns) do
    basis = %{
      __changed__: %{},
      summaries: [],
      epos: nil,
      chronik: [],
      utterances: [],
      glatt_ansicht: [],
      glatt_laedt: :alle,
      glatt_nachlauf: nil,
      glatt_status: :ok
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(basis, assigns), private: %{live_temp: %{}}}
  end

  defp sitzung(sid, nr), do: %{"session_id" => sid, "session_number" => nr, "blocks" => []}

  describe "scope_fuer/2 — die Frage an den Worker" do
    defp assigns(extra),
      do:
        Map.merge(
          %{
            campaign_id: "c1",
            current_user: %{discord_id: "did"},
            glatt_view: %{},
            glatt_windows: %{}
          },
          extra
        )

    test "ohne Wahl und ohne Fenster: keine Wünsche, Vollform" do
      scope = GlattAnsicht.scope_fuer(assigns(%{}), :alle)

      assert scope["kind"] == "campaign_glatt_ansicht"
      assert scope["nur"] == nil
      assert scope["sitzungen"] == %{}
    end

    test "gewählte Ansicht und verschobenes Fenster gehen mit, sonst nil und Tail" do
      scope =
        GlattAnsicht.scope_fuer(
          assigns(%{glatt_view: %{"s1" => "alles"}, glatt_windows: %{"s2" => {10, 20}}}),
          :alle
        )

      assert scope["sitzungen"]["s1"] == %{
               "ansicht" => "alles",
               "fenster" => %{"tail" => GlattAnsicht.tail()}
             }

      assert scope["sitzungen"]["s2"] == %{
               "ansicht" => nil,
               "fenster" => %{"from" => 10, "count" => 20}
             }
    end

    test "eine Teilfrage nennt nur ihre Sessions" do
      scope =
        GlattAnsicht.scope_fuer(
          assigns(%{glatt_view: %{"s1" => "alles", "s2" => "einfach"}}),
          ["s1"]
        )

      assert scope["nur"] == ["s1"]
      assert Map.keys(scope["sitzungen"]) == ["s1"]
    end
  end

  describe "vereinige/2 und einsortieren/3" do
    test "Wünsche zusammenlegen: :alle schluckt alles" do
      assert GlattAnsicht.vereinige(nil, ["a"]) == ["a"]
      assert GlattAnsicht.vereinige(["a"], ["b", "a"]) == ["a", "b"]
      assert GlattAnsicht.vereinige(:alle, ["a"]) == :alle
      assert GlattAnsicht.vereinige(["a"], :alle) == :alle
    end

    test "Vollform ersetzt die ganze Liste" do
      assert GlattAnsicht.einsortieren([sitzung("alt", 1)], [sitzung("neu", 2)], nil) ==
               [sitzung("neu", 2)]
    end

    test "Teilantwort ersetzt genau die angefragten, sortiert nach Sessionnummer" do
      alt = [sitzung("s1", 1), sitzung("s3", 3)]
      neu = [%{sitzung("s2", 2) | "blocks" => [%{"block_id" => "b"}]}]

      assert GlattAnsicht.einsortieren(alt, neu, ["s2"]) |> Enum.map(& &1["session_id"]) ==
               ["s1", "s2", "s3"]
    end

    test "eine angefragte Session, die nicht mehr kommt, fällt heraus" do
      alt = [sitzung("s1", 1), sitzung("weg", 2)]
      assert GlattAnsicht.einsortieren(alt, [], ["weg"]) == [sitzung("s1", 1)]
    end
  end

  describe "apply_ergebnis/2" do
    test "Erfolg: Liste, Status und Marker übernommen, Render-Marke für die Vollform" do
      antwort =
        {:ok,
         {:ok,
          %{
            "glatt_ansicht" => [sitzung("s1", 1)],
            "nur" => nil,
            "luecken_marker" => ["summary:s1"]
          }}}

      s = GlattAnsicht.apply_ergebnis(sock(%{}), antwort)

      assert s.assigns.glatt_ansicht == [sitzung("s1", 1)]
      assert s.assigns.glatt_status == :ok
      assert s.assigns.glatt_laedt == nil
      assert s.assigns.luecken_marker == MapSet.new(["summary:s1"])
      assert_received {:voll_read_rendered, "campaign_glatt_ansicht"}
    end

    test "alter Worker: Hinweis-Status, KEIN Reload" do
      log =
        capture_log(fn ->
          s = GlattAnsicht.apply_ergebnis(sock(%{}), {:ok, {:ok, %{"error" => "unknown_scope"}}})
          assert s.assigns.glatt_status == :worker_veraltet
        end)

      assert log =~ "kennt campaign_glatt_ansicht noch nicht"
      refute_received :reload
    end

    test "Fehler oder Abbruch: der alte Stand bleibt stehen" do
      alt = [sitzung("s1", 1)]

      for ergebnis <- [
            {:ok, {:error, :queue_timeout}},
            {:ok, {:ok, %{"forbidden" => true}}},
            {:exit, :weg}
          ] do
        capture_log(fn ->
          s = GlattAnsicht.apply_ergebnis(sock(%{glatt_ansicht: alt}), ergebnis)
          assert s.assigns.glatt_ansicht == alt
          assert s.assigns.glatt_status == :fehler
        end)
      end

      refute_received :reload
    end
  end

  describe "lade/2" do
    test "läuft schon ein Read, wird der Wunsch vorgemerkt statt einen zweiten zu starten" do
      s =
        sock(%{campaign_id: "c1", current_user: %{discord_id: "d"}, glatt_laedt: :alle})
        |> GlattAnsicht.lade(["s1"])

      assert s.assigns.glatt_nachlauf == ["s1"]
      assert s.assigns.glatt_laedt == :alle
    end

    test "ohne Kampagnen-Kontext passiert nichts (kein KeyError im Render-Pfad)" do
      s = sock(%{glatt_laedt: nil})
      assert GlattAnsicht.lade(s, :alle) == s
    end
  end

  describe "Quelltext-Wächter" do
    test "die Ansicht löst nie einen Voll-Reload aus" do
      src = quelle("lib/hub_web/live/campaign_live/glatt_ansicht.ex")

      refute src =~ "schedule_reload(",
             "ein Fehler der Ansicht startete wieder den Voll-Reload — die Deploy-Fenster-Schleife (#1198)"

      refute src =~ "start_snapshot_load("
    end

    test "die Closure trägt nur die Scope-Map, nicht den Socket" do
      [closure] =
        Regex.run(
          ~r/start_async\(:glatt_ansicht, fn -> (.*?) end\)/s,
          quelle("lib/hub_web/live/campaign_live/glatt_ansicht.ex"),
          capture: :all_but_first
        )

      refute closure =~ "socket", "alles in der Closure kopiert der BEAM in den Task (#1181)"
    end

    test "campaign_live.ex reicht das Ergebnis nur durch" do
      [klausel] =
        Regex.run(
          ~r/def handle_async\(:glatt_ansicht, ergebnis, socket\),\n(.*?)\n/s,
          quelle("lib/hub_web/live/campaign_live.ex"),
          capture: :all_but_first
        )

      assert klausel =~ "GlattAnsicht.apply_ergebnis(socket, ergebnis)"
      refute klausel =~ "schedule_reload"
    end
  end
end
