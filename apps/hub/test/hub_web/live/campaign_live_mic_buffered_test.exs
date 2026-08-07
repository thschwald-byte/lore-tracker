defmodule HubWeb.CampaignLive.MicBufferedTest do
  @moduledoc """
  Issue #936 / #468 Cut 3: CampaignLive abonniert `mic_state_topic` und bekommt von
  MicLive den `{:mic_chunks_buffered, %{pending, dropped}}`-Broadcast (Client-Outbox-
  Puffer-Indikator). OHNE passende `handle_info`-Klausel crasht CampaignLive daran
  (FunctionClauseError → Re-Mount-Loop = das Flackern + tote Buttons aus
  Störungsanalyse-Befund 2). Dieser Test nagelt die Klausel fest.
  """

  use ExUnit.Case, async: true

  test "handle_info({:mic_chunks_buffered, …}) crasht NICHT + setzt den Puffer-Assign" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:noreply, out} =
             HubWeb.CampaignLive.handle_info(
               {:mic_chunks_buffered, %{pending: 3, dropped: 1}},
               socket
             )

    assert out.assigns.mic_buffered == %{pending: 3, dropped: 1}
  end
end
