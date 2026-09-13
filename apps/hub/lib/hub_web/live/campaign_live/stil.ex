defmodule HubWeb.CampaignLive.Stil do
  @moduledoc """
  Stil-/Vorgabe-Editor pro Pipeline-Stage der CampaignLive (Issues #313/#320,
  ausgelagert in #434 Cut 4): Ton (flavors) + Vorgabe (Überschrift)
  editieren.

  J5 (#1209, B4): das Resümee schreibt der Resümee-Jack. Sein Tab zeigt
  deshalb keinen Prompt, sondern einen Hinweis (`HubWeb.CampaignLive.Editors`):
  die Überschrift bestimmt die Form, die Töne bekommt er vor dem Schreiben.
  Die frühere „Darstellungsform“ ist entfallen — die Form folgt aus der
  Überschrift; der Hub schickt nur noch den Namen.

  J6 (#1210, E4): das Epos-Kapitel schreibt der Epos-Jack. Auch sein Tab zeigt
  einen Hinweis statt der früheren Live-Prompt-Vorschau: die Überschrift
  bestimmt die Form, der Epos-Ton die Erzählhaltung, den Weg übernimmt er aus
  dem Resümee. Damit hat kein Tab mehr eine Vorschau; der Hub fragt den
  Worker nicht mehr danach (`Hub.PromptPreview` ist entfernt). Der Worker
  beantwortet eine Anfrage weiter — für einen zurückgerollten Hub
  (`Worker.HubClient.Rpc.on_preview/2`).

  **Länge des Resümees (#1209):** der Resümee-Tab hat ein Zahlfeld
  `max_woerter` — das Ziel in Wörtern; braucht der Weg der Gruppe mehr, darf
  das Resümee bis zum Doppelten wachsen (`Shared.ResuemeeLaenge.hoechstens/1`,
  Hilfetext und Hinweis im Tab sagen es). Leer heißt Standard
  (`Shared.ResuemeeLaenge`, 150). Gespeichert als eigenes Ereignis
  `CampaignResuemeeLaengeSet`, nicht als Feld von `CampaignVorgabeSet` (s.
  `Shared.Events.campaign_resuemee_laenge_set/0`), und nur, wenn sich der
  Wert geändert hat. Eine ungültige Eingabe (keine ganze Zahl, außerhalb
  von 30 bis 1000) speichert **nichts** — auch Ton und Überschrift nicht —,
  der Editor bleibt offen und sagt, was erlaubt ist: halb gespeichert wäre
  schwerer zu durchschauen als gar nicht. Gelesen wird der Wert aus
  `campaign["resuemee_max_woerter"]` (`nil` = Standard), den der Worker mit
  der Kampagne mitliefert.

  Kontext-Modul mit Delegations-Pattern; läuft im LiveView-Prozess.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias HubWeb.CampaignLive.Publisher
  alias Shared.{Events, ResuemeeLaenge}

  # Reiter angeklickt: Drafts laden (Ton aus flavors, Vorgabe aus campaign).
  def stage(socket, stage) do
    flavors = current_flavors(socket)
    campaign = socket.assigns.campaign || %{}
    vorgabe = get_in(campaign, ["vorgaben", stage]) || %{}

    flavor_drafts = %{
      "base" => Map.get(flavors, "base", ""),
      stage => Map.get(flavors, stage, "")
    }

    vorgabe_drafts =
      mit_laenge(%{"name" => str_or_empty(vorgabe["name"])}, stage, laenge_text(campaign))

    {:noreply,
     assign(socket,
       stil_stage: stage,
       flavor_drafts: flavor_drafts,
       vorgabe_drafts: vorgabe_drafts
     )}
  end

  def close(socket) do
    {:noreply, assign(socket, stil_stage: nil)}
  end

  # phx-change beim Tippen: die Entwürfe mitschreiben (der Resümee-Hinweis
  # nennt die eingegebene Länge live). Bis J6 (#1210) holte derselbe Event
  # die Prompt-Vorschau vom Worker (Issue #320); die gibt es nicht mehr.
  def entwurf(socket, params) do
    stage = socket.assigns.stil_stage

    flavor_drafts = %{
      "base" => Map.get(params, "base", socket.assigns.flavor_drafts["base"] || ""),
      stage => Map.get(params, stage, Map.get(socket.assigns.flavor_drafts, stage, ""))
    }

    vorgabe_drafts =
      mit_laenge(
        %{"name" => Map.get(params, "name", socket.assigns.vorgabe_drafts["name"] || "")},
        stage,
        Map.get(params, "max_woerter", socket.assigns.vorgabe_drafts["max_woerter"] || "")
      )

    {:noreply, assign(socket, flavor_drafts: flavor_drafts, vorgabe_drafts: vorgabe_drafts)}
  end

  def save(socket, %{"stage" => stage} = params) do
    case laenge_aus(stage, params) do
      {:error, text} ->
        {:noreply, put_flash(socket, :error, text)}

      laenge ->
        speichern(socket, stage, params, laenge)

        {:noreply,
         socket
         |> assign(stil_stage: nil)
         |> put_flash(:info, "Stil gespeichert.")}
    end
  end

  defp speichern(socket, stage, params, laenge) do
    if socket.assigns.can_edit_meta? do
      current = current_flavors(socket)
      did = socket.assigns.current_user.discord_id

      # #787: nur Slots anfassen, die das Formular auch enthielt — der
      # chronik-Tab hat keine Ton-Felder; ein `params["base"] == nil` würde
      # sonst einen gesetzten base-Ton still löschen.
      if Map.has_key?(params, "base"),
        do: maybe_flavor_event(socket, "base", current, params["base"], did)

      if Map.has_key?(params, stage),
        do: maybe_flavor_event(socket, stage, current, params[stage], did)

      # Kein Name ⇒ Row löschen (Default-Überschrift greift wieder).
      Publisher.publish(socket, %{
        "kind" => Events.campaign_vorgabe_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "stage" => stage,
        "name" => clean_flavor(params["name"]),
        "set_by" => did
      })

      maybe_laenge_event(socket, laenge, did)
    end
  end

  # Die Länge: nur im Resümee-Tab, und nur, wenn das Formular das Feld
  # enthielt (sonst bliebe ein gesetzter Wert unberührt, wie beim Ton).
  defp laenge_aus("summary", %{"max_woerter" => roh}) do
    case ResuemeeLaenge.pruefen(roh) do
      {:ok, n} ->
        {:ok, n}

      :leer ->
        {:ok, nil}

      {:error, :ungueltig} ->
        {:error,
         "Länge des Resümees: eine ganze Zahl von #{ResuemeeLaenge.untergrenze()} bis " <>
           "#{ResuemeeLaenge.obergrenze()} Wörtern, oder leer für den Standard " <>
           "(#{ResuemeeLaenge.standard()}). Nichts gespeichert."}
    end
  end

  defp laenge_aus(_stage, _params), do: :unberuehrt

  defp maybe_laenge_event(_socket, :unberuehrt, _did), do: :ok

  defp maybe_laenge_event(socket, {:ok, neu}, did) do
    if neu != laenge_gesetzt(socket.assigns.campaign) do
      Publisher.publish(socket, %{
        "kind" => Events.campaign_resuemee_laenge_set(),
        "campaign_id" => socket.assigns.campaign_id,
        "max_woerter" => neu,
        "set_by" => did
      })
    end

    :ok
  end

  defp mit_laenge(drafts, "summary", text), do: Map.put(drafts, "max_woerter", text)
  defp mit_laenge(drafts, _stage, _text), do: drafts

  # Was die Kampagne gespeichert hat — `nil`, wenn nichts (oder ein Wert
  # außerhalb des Bereichs, der dann ohnehin als Standard gilt).
  defp laenge_gesetzt(campaign) do
    case ResuemeeLaenge.pruefen((campaign || %{})["resuemee_max_woerter"]) do
      {:ok, n} -> n
      _ -> nil
    end
  end

  defp laenge_text(campaign) do
    case laenge_gesetzt(campaign) do
      nil -> ""
      n -> Integer.to_string(n)
    end
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
end
