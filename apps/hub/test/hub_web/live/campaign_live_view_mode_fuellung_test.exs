defmodule HubWeb.CampaignLiveViewModeFuellungTest do
  @moduledoc """
  Issue #1200: der Lesen|Bearbeiten-Umschalter antwortet sofort.

  An seattleV4 gemessen brachte der Wechsel nach Bearbeiten eine einzige
  Antwort von 2,7 MB (Kurations-Panels, Protokoll, Fakten) — der Knopf sprang
  erst um, wenn der Browser alles eingebaut hatte. Seitdem: der Browser
  schaltet selbst um (`data-view-mode` + CSS), die erste Server-Antwort trägt
  nur das Gerüst, die schweren Teile folgen Stück für Stück.

  Festgehalten wird hier beides — das Verhalten und die Verdrahtung. Die
  Verdrahtung braucht Quelltext-Wächter, weil ihr Fehlen **keinen** Fehler
  erzeugt: ohne das Attribut am Wurzel-`div` oder ohne den Klick-Handler im
  Hook wartet der Knopf wieder still auf den Server.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.ViewMode

  defp sock(assigns \\ %{}) do
    basis = %{
      __changed__: %{},
      view_mode: :lesen,
      active_cols: ViewMode.columns_for_mode(:lesen),
      bearbeiten_teile: MapSet.new(),
      bearbeiten_lauf: 0,
      # kein Nachladen der Fakten — das bräuchte einen echten LiveView-Prozess
      facts_loaded?: true
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(basis, assigns), private: %{live_temp: %{}}}
  end

  defp umschalten(socket, modus) do
    {:noreply, s} = ViewMode.set_view_mode(socket, modus, nil)
    s
  end

  # Alle angestoßenen Stufen der Reihe nach abarbeiten, wie die LiveView es tut.
  defp alle_stufen(socket) do
    receive do
      {:bearbeiten_fuellen, lauf, teile} ->
        socket |> ViewMode.fuellen(lauf, teile) |> alle_stufen()
    after
      0 -> socket
    end
  end

  describe "ViewMode (pur)" do
    test "nach Bearbeiten: erst das Gerüst, die Füllung ist angestoßen" do
      s = umschalten(sock(), "bearbeiten")

      assert s.assigns.view_mode == :bearbeiten
      assert s.assigns.bearbeiten_teile == MapSet.new()
      lauf = s.assigns.bearbeiten_lauf
      assert_received {:bearbeiten_fuellen, ^lauf, teile}
      assert teile == ViewMode.teile()
    end

    test "jede Stufe gibt genau einen Teil frei und stößt die nächste an" do
      s = umschalten(sock(), "bearbeiten")
      lauf = s.assigns.bearbeiten_lauf
      assert_received {:bearbeiten_fuellen, ^lauf, [erster | rest]}

      s = ViewMode.fuellen(s, lauf, [erster | rest])

      assert s.assigns.bearbeiten_teile == MapSet.new([erster])
      assert_received {:bearbeiten_fuellen, ^lauf, ^rest}
    end

    test "am Ende sind alle Teile da, und es kommt keine weitere Stufe" do
      s = sock() |> umschalten("bearbeiten") |> alle_stufen()

      assert s.assigns.bearbeiten_teile == MapSet.new(ViewMode.teile())
      refute_received {:bearbeiten_fuellen, _, _}
    end

    test "zurück nach Lesen leert sofort und entwertet die laufende Füllung" do
      s = umschalten(sock(), "bearbeiten")
      alter_lauf = s.assigns.bearbeiten_lauf
      assert_received {:bearbeiten_fuellen, ^alter_lauf, teile}

      s = umschalten(s, "lesen")
      assert s.assigns.bearbeiten_teile == MapSet.new()
      refute_received {:bearbeiten_fuellen, _, _}

      # Die Nachricht aus dem alten Lauf kommt trotzdem an — sie darf nichts füllen.
      assert ViewMode.fuellen(s, alter_lauf, teile) == s
    end

    test "hin, zurück, hin: nur der jüngste Lauf füllt" do
      s = umschalten(sock(), "bearbeiten")
      assert_received {:bearbeiten_fuellen, erster_lauf, teile}
      s = s |> umschalten("lesen") |> umschalten("bearbeiten")
      assert_received {:bearbeiten_fuellen, zweiter_lauf, ^teile}

      assert erster_lauf != zweiter_lauf
      assert ViewMode.fuellen(s, erster_lauf, teile) == s
    end

    test "derselbe Modus noch einmal baut nichts neu auf" do
      # Sonst leerte ein Doppelklick die gefüllten Spalten und schickte die
      # 2,7 MB ein zweites Mal.
      s = sock() |> umschalten("bearbeiten") |> alle_stufen()
      nochmal = umschalten(s, "bearbeiten")

      assert nochmal.assigns.bearbeiten_teile == s.assigns.bearbeiten_teile
      refute_received {:bearbeiten_fuellen, _, _}
    end

    test "bereit?/2 verträgt einen Socket ohne Assigns" do
      refute ViewMode.bereit?(nil, "protokoll")
      refute ViewMode.bereit?(MapSet.new(), "protokoll")
      assert ViewMode.bereit?(MapSet.new(["protokoll"]), "protokoll")
    end
  end

  describe "in der LiveView" do
    defp mount_lv(conn) do
      snap =
        Fixtures.snapshot(
          campaign_id: "c-vm-1200",
          name: "Umschalt Kampagne",
          sessions: [%{"id" => "s-1", "number" => 1, "name" => "Eins"}],
          members: [Fixtures.member("did-a", "spieler")],
          utterances: [
            %{
              "id" => "u-1200",
              "session_id" => "s-1",
              "speaker_discord_id" => "did-a",
              "text" => "Eine Zeile aus dem Protokoll",
              "timestamp" => "2026-09-10T08:00:00Z"
            }
          ]
        )

      stub_reader!(snap)
      user = Fixtures.user(discord_id: "did-a", display_name: "A", campaign_role: :spieler)
      {:ok, lv, _html} = conn |> log_in(user) |> live("/campaigns/c-vm-1200")
      render_async(lv)
      lv
    end

    # Jede Stufe ist eine eigene Nachricht an die LiveView; ein synchroner
    # Aufruf lässt jeweils die davor eingereihten abarbeiten.
    defp fuellung_abwarten(lv) do
      for _ <- 1..(length(ViewMode.teile()) + 1), do: :sys.get_state(lv.pid)
      render(lv)
    end

    test "die erste Antwort trägt nur das Gerüst, danach wird gefüllt", %{conn: conn} do
      lv = mount_lv(conn)

      sofort = render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
      assert sofort =~ "protokoll-scroll", "das Gerüst der Protokoll-Spalte fehlt"
      assert sofort =~ "Wird geladen"
      refute sofort =~ "Eine Zeile aus dem Protokoll", "die erste Antwort trägt schon den Inhalt"

      gefuellt = fuellung_abwarten(lv)
      assert gefuellt =~ "Eine Zeile aus dem Protokoll"
      refute gefuellt =~ "Wird geladen"
    end

    test "der Server bestätigt den Modus am Wurzel-div", %{conn: conn} do
      lv = mount_lv(conn)
      assert render(lv) =~ ~s(data-view-mode="lesen")

      assert render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"}) =~
               ~s(data-view-mode="bearbeiten")
    end

    test "zurück nach Lesen: Protokoll ist wieder weg", %{conn: conn} do
      lv = mount_lv(conn)
      render_click(lv, "view_mode_toggle", %{"mode" => "bearbeiten"})
      fuellung_abwarten(lv)

      refute render_click(lv, "view_mode_toggle", %{"mode" => "lesen"}) =~ "protokoll-scroll"
    end
  end

  describe "Quelltext-Wächter" do
    defp quelle(rel), do: File.read!(Path.join([__DIR__, "../../..", rel]))
    defp heex, do: quelle("lib/hub_web/live/campaign_live.html.heex")

    test "das Wurzel-div trägt den Modus fürs CSS" do
      assert heex() =~ "data-view-mode={@view_mode}"
    end

    test "die Knöpfe sind markiert und färben sich nicht über den Server" do
      [gruppe] =
        Regex.run(~r/aria-label="Ansichtsmodus">(.*?)<\/div>/s, heex(), capture: :all_but_first)

      assert gruppe =~ ~s(data-mode-knopf="lesen")
      assert gruppe =~ ~s(data-mode-knopf="bearbeiten")

      # Nur aria-pressed darf am Server-Modus hängen — eine Farbe daran
      # sprünge erst mit der Antwort um.
      assert length(Regex.scan(~r/@view_mode/, gruppe)) == 2
    end

    test "der Hook setzt den Modus beim Klick selbst" do
      js = quelle("assets/js/hooks/view_mode_persist.js")
      assert js =~ "root.dataset.viewMode = knopf.dataset.modeKnopf"

      # Kein sticky JS.set_attribute — das überstimmte den Server auch nach
      # einem Reconnect mit anderem Modus.
      refute heex() =~ ~s(JS.set_attribute({"data-view-mode")
    end

    test "das CSS blendet Bearbeiten-Teile im Lesemodus aus und färbt den Knopf" do
      css = quelle("assets/css/app.css")
      assert css =~ ~s(#campaign-live-root[data-view-mode="lesen"] .nur-bearbeiten)
      assert css =~ ~s([data-mode-knopf="bearbeiten"])
    end

    test "Chronik- und Resümee-Liste hängen nicht am Modus" do
      # Hinge ein Eintrag am Modus, zeichnete jeder Wechsel die ganze Liste
      # neu und schickte sie mit der ersten Antwort.
      for kopf <- ["<%= for entry <- @chronik do %>", "<%= for s <- @summaries do %>"] do
        [_, rest] = String.split(heex(), kopf, parts: 2)
        [liste | _] = String.split(rest, "</.column>", parts: 2)
        refute liste =~ "@view_mode", "#{kopf} hängt wieder am Modus"
      end
    end

    test "campaign_live.ex nimmt die Füllstufen an" do
      # Die CampaignLive hat keinen handle_info-Auffangzweig (#1149): ohne die
      # Klausel stürzt sie beim ersten Wechsel nach Bearbeiten ab.
      assert quelle("lib/hub_web/live/campaign_live.ex") =~
               "handle_info({:bearbeiten_fuellen, lauf, teile}, socket)"
    end
  end
end
