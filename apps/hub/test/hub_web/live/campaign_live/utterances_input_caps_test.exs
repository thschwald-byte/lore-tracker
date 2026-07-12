defmodule HubWeb.CampaignLive.UtterancesInputCapsTest do
  @moduledoc """
  Issue #636: Server-Side-Cap-Gates in den Utterance-Save-Handlern.
  Deny-Pfad — bare-Socket-Transform, kein GenServer.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Utterances

  # Ein Byte über dem utterance_text-Cap (8_000).
  @overlong_text String.duplicate("x", 8_001)

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "edit_save/2 — Cap" do
    test "überlanger Text bei berechtigtem User → Flash-Error, Edit-Mode bleibt" do
      s =
        socket(%{
          current_user: %{discord_id: "did-owner"},
          campaign_id: "camp-1",
          flash: %{},
          can_edit_meta?: true,
          utterances: [
            %{
              "id" => "u-1",
              "session_id" => "sess-1",
              "discord_id" => "did-owner",
              "text" => "alt"
            }
          ],
          utterance_editing: "u-1",
          utterance_draft: @overlong_text
        })

      {:noreply, s2} = Utterances.edit_save(s, @overlong_text)

      assert s2.assigns.flash["error"] =~ "Text"
      assert s2.assigns.flash["error"] =~ "8000"
      # Edit-Mode + Draft bleiben — User kann kürzen.
      assert s2.assigns.utterance_editing == "u-1"
      assert s2.assigns.utterance_draft == @overlong_text
    end
  end

  describe "add_save/3 — Cap" do
    test "überlanger Text (GM, gültiger Speaker) → Flash-Error, Add-Mode bleibt" do
      s =
        socket(%{
          current_user: %{discord_id: "did-owner"},
          campaign_id: "camp-1",
          flash: %{},
          can_edit_meta?: true,
          members: [%{"discord_id" => "did-owner"}],
          utterance_adding: "sess-1",
          utterance_add_speaker: "did-owner",
          utterance_add_text: @overlong_text
        })

      {:noreply, s2} = Utterances.add_save(s, "did-owner", @overlong_text)

      assert s2.assigns.flash["error"] =~ "Text"
      assert s2.assigns.flash["error"] =~ "8000"
      assert s2.assigns.utterance_adding == "sess-1"
      assert s2.assigns.utterance_add_text == @overlong_text
    end
  end
end
