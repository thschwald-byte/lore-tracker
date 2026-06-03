defmodule HubWeb.CampaignLive.Utterances do
  @moduledoc """
  Utterance-Bearbeitung der CampaignLive (Issue #3/#36, ausgelagert in #434
  Cut 4): editieren, löschen, manuell hinzufügen + die Edit-Berechtigung.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  `can_edit_utterance?/2` ist public — das colocated Template ruft es.
  """
  import Phoenix.Component, only: [assign: 2]

  alias HubWeb.CampaignLive.Publisher
  alias Shared.Events

  def edit_start(socket, id) do
    current =
      Enum.find_value(socket.assigns.utterances, "", fn u ->
        if u["id"] == id, do: u["text"], else: nil
      end)

    {:noreply, assign(socket, utterance_editing: id, utterance_draft: current || "")}
  end

  def edit_cancel(socket),
    do: {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}

  def edit_save(socket, text) do
    id = socket.assigns.utterance_editing
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if existing && can_edit_utterance?(socket, existing) do
      Publisher.publish(socket, %{
        "kind" => Events.utterance_edited(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "new_text" => text,
        "edited_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, assign(socket, utterance_editing: nil, utterance_draft: "")}
  end

  def delete(socket, id) do
    existing = Enum.find(socket.assigns.utterances, fn u -> u["id"] == id end)

    if existing && can_edit_utterance?(socket, existing) do
      Publisher.publish(socket, %{
        "kind" => Events.utterance_deleted(),
        "id" => id,
        "session_id" => existing["session_id"],
        "campaign_id" => socket.assigns.campaign_id,
        "deleted_by" => socket.assigns.current_user.discord_id
      })
    end

    {:noreply, socket}
  end

  def add_start(socket, sid) do
    {:noreply,
     assign(socket,
       utterance_adding: sid,
       utterance_add_speaker: socket.assigns.current_user.discord_id,
       utterance_add_text: ""
     )}
  end

  def add_cancel(socket),
    do: {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}

  def add_save(socket, speaker, text) do
    sid = socket.assigns.utterance_adding
    cleaned = text |> to_string() |> String.trim()
    member_dids = Enum.map(socket.assigns.members || [], & &1["discord_id"])

    cond do
      not socket.assigns.can_edit_meta? ->
        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}

      sid in [nil, ""] or cleaned == "" or speaker not in member_dids ->
        {:noreply, socket}

      true ->
        Publisher.publish(socket, %{
          "kind" => Events.utterance_appended(),
          "id" => UUIDv7.generate(),
          "session_id" => sid,
          "campaign_id" => socket.assigns.campaign_id,
          "discord_id" => speaker,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "text" => cleaned,
          "confidence" => nil,
          "status" => "manual"
        })

        {:noreply, assign(socket, utterance_adding: nil, utterance_add_text: "")}
    end
  end

  # Spieler darf nur eigene Utterances ändern/löschen, Owner+Admin alle
  # (Issue #36). Akzeptiert socket ODER assigns-Map (Template-Aufrufe).
  def can_edit_utterance?(%{assigns: assigns}, utterance),
    do: can_edit_utterance?(assigns, utterance)

  def can_edit_utterance?(assigns, utterance) when is_map(assigns) do
    assigns.can_edit_meta? or
      utterance["discord_id"] == assigns.current_user.discord_id
  end
end
