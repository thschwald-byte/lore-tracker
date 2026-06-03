defmodule HubWeb.CampaignLive.Stil do
  @moduledoc """
  Stil-/Vorgabe-Editor pro Pipeline-Stage der CampaignLive (Issues #313/#320,
  ausgelagert in #434 Cut 4): Ton (flavors) + Vorgabe (Überschrift/Darstellungs-
  form) editieren, mit Live-Prompt-Vorschau vom Worker (`Hub.PromptPreview`).

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias HubWeb.CampaignLive.Publisher
  alias Shared.Events

  # Reiter angeklickt: Drafts laden (Ton aus flavors, Vorgabe aus campaign)
  # + Prompt-Vorschau-Segmente synchron vom Worker holen.
  def stage(socket, stage) do
    flavors = current_flavors(socket)
    campaign = socket.assigns.campaign || %{}
    vorgabe = get_in(campaign, ["vorgaben", stage]) || %{}

    {segments, error} =
      case Hub.PromptPreview.preview(socket.assigns.campaign_id, stage) do
        {:ok, segs} -> {segs, nil}
        {:error, reason} -> {[], reason}
      end

    flavor_drafts = %{
      "base" => Map.get(flavors, "base", ""),
      stage => Map.get(flavors, stage, "")
    }

    vorgabe_drafts = %{
      "name" => str_or_empty(vorgabe["name"]),
      "darstellungsform" => str_or_default(vorgabe["darstellungsform"], "fliesstext")
    }

    {:noreply,
     assign(socket,
       stil_stage: stage,
       preview_segments: segments,
       preview_error: error,
       flavor_drafts: flavor_drafts,
       vorgabe_drafts: vorgabe_drafts
     )}
  end

  def close(socket) do
    {:noreply, assign(socket, stil_stage: nil, preview_segments: [], preview_error: nil)}
  end

  # Issue #320: Live-Vorschau. phx-change beim Tippen — holt den echten Prompt
  # vom Worker mit den AKTUELLEN Entwürfen als `overrides`, damit man byte-genau
  # sieht wie der Prompt sich ändert. phx-debounce throttlet die Roundtrips.
  def preview(socket, params) do
    stage = socket.assigns.stil_stage

    flavor_drafts = %{
      "base" => Map.get(params, "base", socket.assigns.flavor_drafts["base"] || ""),
      stage => Map.get(params, stage, Map.get(socket.assigns.flavor_drafts, stage, ""))
    }

    vorgabe_drafts = %{
      "name" => Map.get(params, "name", socket.assigns.vorgabe_drafts["name"] || ""),
      "darstellungsform" =>
        Map.get(
          params,
          "darstellungsform",
          socket.assigns.vorgabe_drafts["darstellungsform"] || "fliesstext"
        )
    }

    overrides = %{
      "flavors" => flavor_drafts,
      "vorgaben" => %{stage => vorgabe_drafts}
    }

    {segments, error} =
      case Hub.PromptPreview.preview(socket.assigns.campaign_id, stage, overrides) do
        {:ok, segs} -> {segs, nil}
        {:error, reason} -> {socket.assigns.preview_segments, reason}
      end

    {:noreply,
     assign(socket,
       flavor_drafts: flavor_drafts,
       vorgabe_drafts: vorgabe_drafts,
       preview_segments: segments,
       preview_error: error
     )}
  end

  def save(socket, %{"stage" => stage} = params) do
    if socket.assigns.can_edit_meta? do
      current = current_flavors(socket)
      did = socket.assigns.current_user.discord_id

      maybe_flavor_event(socket, "base", current, params["base"], did)
      maybe_flavor_event(socket, stage, current, params[stage], did)

      name = clean_flavor(params["name"])
      form = params["darstellungsform"] || "fliesstext"
      # Nur Default (kein Name + Fließtext) ⇒ Row löschen (name+form nil).
      {vname, vform} =
        if is_nil(name) and form == "fliesstext", do: {nil, nil}, else: {name, form}

      Publisher.publish(socket, %{
        "kind" => Events.campaign_vorgabe_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "stage" => stage,
        "name" => vname,
        "darstellungsform" => vform,
        "set_by" => did
      })
    end

    {:noreply,
     socket
     |> assign(stil_stage: nil, preview_segments: [], preview_error: nil)
     |> put_flash(:info, "Stil gespeichert.")}
  end

  defp maybe_flavor_event(socket, slot, current, raw, did) do
    old = Map.get(current, slot)
    new = clean_flavor(raw)

    if old != new do
      Publisher.publish(socket, %{
        "kind" => Events.campaign_flavor_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "slot" => slot,
        "flavor" => new,
        "edited_by" => did
      })
    end
  end

  defp current_flavors(socket) do
    case (socket.assigns.campaign || %{})["flavors"] do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp clean_flavor(nil), do: nil

  defp clean_flavor(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      text -> String.slice(text, 0, 2000)
    end
  end

  defp str_or_empty(s) when is_binary(s), do: s
  defp str_or_empty(_), do: ""
  defp str_or_default(s, _d) when is_binary(s) and s != "", do: s
  defp str_or_default(_s, d), do: d
end
