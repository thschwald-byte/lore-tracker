defmodule HubWeb.CampaignLive.StilResuemeeTest do
  @moduledoc """
  J5 (#1209, B4): „Stil setzen“ nach dem Wechsel zum Resümee-Jack — der
  Resümee-Tab zeigt einen Hinweis statt einer Prompt-Vorschau, und die
  Darstellungsform ist entfallen (die Form folgt aus der Überschrift).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.{Components, Editors, Stil}

  # Eigene Kampagnen-ID: der Telemetry-Handler unten hört auf alle Publishes
  # im Hub, auch die paralleler Tests — die ID trennt unsere heraus.
  @cid "camp-laenge-1209"

  defp editor(stage, segments \\ [], drafts \\ %{"name" => ""}) do
    render_component(&Editors.flavor_editor/1,
      campaign: %{"id" => "camp-1", "flavors" => %{}},
      stil_stage: stage,
      segments: segments,
      flavor_drafts: %{"base" => "", stage => ""},
      vorgabe_drafts: drafts,
      is_member?: true
    )
  end

  @doc false
  def publish_gesehen(_event, _messwerte, meta, pid),
    do: send(pid, {:publish, meta.kind, meta.campaign_id})

  # Hört auf `Hub.EventBridge.publish/2` (Telemetry `[:hub, :event_bridge,
  # :publish]`) — das Ereignis kommt, ob ein Worker online ist oder nicht.
  defp publishes_mithoeren do
    id = "stil-laenge-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      [:hub, :event_bridge, :publish],
      &__MODULE__.publish_gesehen/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp save_socket(campaign) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        campaign_id: @cid,
        campaign: Map.merge(%{"id" => @cid, "flavors" => %{}, "vorgaben" => %{}}, campaign),
        can_edit_meta?: true,
        current_user: %{discord_id: "did-me"},
        flash: %{},
        stil_stage: "summary",
        preview_segments: [],
        preview_error: nil
      }
    }
  end

  defp save(campaign, params),
    do: Stil.save(save_socket(campaign), Map.merge(%{"stage" => "summary", "name" => ""}, params))

  describe "Länge des Resümees (#1209)" do
    test "der Resümee-Tab hat das Zahlfeld mit dem Standard als Platzhalter, der Hinweis nennt die Länge" do
      html = editor("summary", [], %{"name" => "", "max_woerter" => ""})

      assert html =~ ~s(id="stil-resuemee-laenge")
      assert html =~ ~s(name="max_woerter")
      assert html =~ ~s(type="number")
      assert html =~ ~s(placeholder="75")
      assert html =~ ~s(min="30")
      assert html =~ ~s(max="1000")
      assert html =~ "Länge des Resümees (Wörter)"
      assert html =~ "„Was bisher geschah“"
      assert html =~ ~r/id="stil-resuemee-hinweis-laenge"[^>]*>\s*75 Wörtern/

      html = editor("summary", [], %{"name" => "", "max_woerter" => "120"})
      assert html =~ ~s(value="120")
      assert html =~ ~r/id="stil-resuemee-hinweis-laenge"[^>]*>\s*120 Wörtern/
    end

    test "Epos und Chronik haben kein Längenfeld" do
      refute editor("epos", [%{"kind" => "locked", "text" => "x"}]) =~ "stil-resuemee-laenge"
      refute editor("chronik") =~ "stil-resuemee-laenge"
    end

    test "der Tab lädt die gespeicherte Länge als Entwurf; ohne sie ist das Feld leer" do
      {:noreply, s} = Stil.stage(save_socket(%{"resuemee_max_woerter" => 120}), "summary")
      assert s.assigns.vorgabe_drafts == %{"name" => "", "max_woerter" => "120"}

      {:noreply, s} = Stil.stage(save_socket(%{}), "summary")
      assert s.assigns.vorgabe_drafts == %{"name" => "", "max_woerter" => ""}
    end

    test "speichern: eine neue Länge wird veröffentlicht, eine unveränderte nicht" do
      publishes_mithoeren()

      {:noreply, s} = save(%{}, %{"max_woerter" => "120"})
      assert s.assigns.stil_stage == nil
      assert s.assigns.flash["info"] == "Stil gespeichert."
      assert_received {:publish, "CampaignResuemeeLaengeSet", @cid}
      assert_received {:publish, "CampaignVorgabeSet", @cid}

      {:noreply, _s} = save(%{"resuemee_max_woerter" => 120}, %{"max_woerter" => "120"})
      assert_received {:publish, "CampaignVorgabeSet", @cid}
      refute_received {:publish, "CampaignResuemeeLaengeSet", @cid}

      # Leer heißt: zurück auf den Standard — eine Änderung, also ein Ereignis.
      {:noreply, _s} = save(%{"resuemee_max_woerter" => 120}, %{"max_woerter" => " "})
      assert_received {:publish, "CampaignResuemeeLaengeSet", @cid}
    end

    test "speichern: eine ungültige Länge speichert nichts, der Editor bleibt offen" do
      publishes_mithoeren()

      for roh <- ["5", "1001", "viel", "7.5"] do
        {:noreply, s} = save(%{}, %{"max_woerter" => roh, "name" => "Rückblick"})

        assert s.assigns.stil_stage == "summary"
        assert s.assigns.flash["error"] =~ "ganze Zahl von 30 bis 1000"
        assert s.assigns.flash["error"] =~ "Nichts gespeichert."
      end

      refute_received {:publish, _, @cid}
    end

    test "ein Formular ohne das Feld (Epos) lässt die Länge unberührt" do
      publishes_mithoeren()

      {:noreply, _s} =
        Stil.save(save_socket(%{"resuemee_max_woerter" => 120}), %{
          "stage" => "epos",
          "name" => ""
        })

      assert_received {:publish, "CampaignVorgabeSet", @cid}
      refute_received {:publish, "CampaignResuemeeLaengeSet", @cid}
    end

    test "„gesetzt“ zählt beim Resümee auch eine eigene Länge" do
      assert Components.vorgabe_set?(%{"resuemee_max_woerter" => 120}, "summary")
      refute Components.vorgabe_set?(%{"resuemee_max_woerter" => 120}, "epos")
      refute Components.vorgabe_set?(%{"resuemee_max_woerter" => nil}, "summary")
    end
  end

  test "der Resümee-Tab erklärt, dass Jack schreibt — kein Prompt, keine Darstellungsform" do
    html = editor("summary")

    assert html =~ ~s(id="stil-resuemee-hinweis")
    assert html =~ "Das Resümee schreibt"
    assert html =~ "bestimmt die Form"
    refute html =~ "Live-Prompt"
    refute html =~ "darstellungsform"
  end

  test "der Epos-Tab behält seine Prompt-Vorschau" do
    html = editor("epos", [%{"kind" => "locked", "text" => "Schreibe ein Kapitel."}])

    assert html =~ "Live-Prompt"
    assert html =~ "Schreibe ein Kapitel."
    refute html =~ "stil-resuemee-hinweis"
    refute html =~ "darstellungsform"
  end

  test "der Resümee-Tab fragt keine Vorschau beim Worker an" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        campaign_id: "camp-1",
        campaign: %{"id" => "camp-1", "flavors" => %{}, "vorgaben" => %{}},
        preview_segments: [],
        preview_error: nil
      }
    }

    # Ohne Worker käme sonst ein Fehler zurück — `nil` heißt: nicht gefragt.
    {:noreply, s} = Stil.stage(socket, "summary")
    assert s.assigns.preview_segments == []
    assert s.assigns.preview_error == nil
    assert s.assigns.vorgabe_drafts == %{"name" => "", "max_woerter" => ""}
    assert "summary" in Stil.ohne_vorschau()
  end

  test "„gesetzt“ heißt: eigene Überschrift — eine alte Darstellungsform zählt nicht" do
    refute Components.vorgabe_set?(
             %{"vorgaben" => %{"summary" => %{"darstellungsform" => "stichpunkte"}}},
             "summary"
           )

    assert Components.vorgabe_set?(
             %{"vorgaben" => %{"summary" => %{"name" => "Run-Report"}}},
             "summary"
           )
  end
end
