defmodule HubWeb.CampaignLive.StilResuemeeTest do
  @moduledoc """
  J5 (#1209, B4): „Stil setzen“ nach dem Wechsel zum Resümee-Jack — der
  Resümee-Tab zeigt einen Hinweis statt einer Prompt-Vorschau, und die
  Darstellungsform ist entfallen (die Form folgt aus der Überschrift).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HubWeb.CampaignLive.{Components, Editors, Stil}

  defp editor(stage, segments \\ []) do
    render_component(&Editors.flavor_editor/1,
      campaign: %{"id" => "camp-1", "flavors" => %{}},
      stil_stage: stage,
      segments: segments,
      flavor_drafts: %{"base" => "", stage => ""},
      vorgabe_drafts: %{"name" => ""},
      is_member?: true
    )
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
    assert s.assigns.vorgabe_drafts == %{"name" => ""}
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
