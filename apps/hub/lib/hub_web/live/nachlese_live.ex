defmodule HubWeb.NachleseLive do
  @moduledoc """
  Issue #907 (Epic #900 S4): die Nachlese-Seite — die schlanke Spieler-Sicht
  auf die Wahrheitsbasis (#687: nachlesen ohne SL-Arbeit). Drei Blöcke:
  „Was war letztes Mal?" (Recap der letzten Session, #715-Flagging via
  `render_recap_with_flags`), „Wo stehen wir?" (offene Bögen, aktiv zuerst,
  Leitfrage + deterministischer Stand; Abgeschlossene zugeklappt) und
  „Wer ist wer?" (Who's-who, PCs markiert). Dazu ein zugeklapptes
  📚-Themen-Register (Context-Codex).

  Schlanker async-Mount über den schmalen `campaign_nachlese`-Scope
  (member-gated am Worker; forbidden → Flash + Redirect, Muster
  CampaignLive). Bewusst OHNE Live-Refresh in v1 (Seite lädt beim Aufruf —
  benannte Grenze; PubSub-Reload ist ein Folge-Schnitt).
  """

  use HubWeb, :live_view

  import HubWeb.CampaignLive.Components, only: [render_md_safe: 1]

  alias Hub.Reader

  @impl true
  def mount(%{"id" => campaign_id}, %{"current_user" => user}, socket) do
    socket =
      socket
      |> assign(
        current_user: user,
        campaign_id: campaign_id,
        active_nav: :campaign,
        waiting?: true,
        campaign: nil,
        recap: nil,
        boegen_offen: [],
        boegen_geschlossen: [],
        themen: [],
        who: [],
        geschlossen_open: false,
        themen_open: false
      )

    socket =
      if connected?(socket) do
        scope = %{
          "kind" => "campaign_nachlese",
          "id" => campaign_id,
          "viewer_discord_id" => user.discord_id
        }

        start_async(socket, :load, fn -> Reader.read(scope) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:load, {:ok, {:ok, %{"forbidden" => true}}}, socket) do
    {:noreply,
     socket |> put_flash(:error, "Kein Zugriff auf diese Kampagne.") |> push_navigate(to: ~p"/")}
  end

  def handle_async(:load, {:ok, {:ok, %{"not_found" => true}}}, socket) do
    {:noreply,
     socket |> put_flash(:error, "Kampagne nicht gefunden.") |> push_navigate(to: ~p"/")}
  end

  def handle_async(:load, {:ok, {:ok, snap}}, socket) do
    {:noreply,
     assign(socket,
       waiting?: false,
       campaign: snap["campaign"],
       recap: snap["recap"],
       boegen_offen: snap["boegen_offen"] || [],
       boegen_geschlossen: snap["boegen_geschlossen"] || [],
       themen: snap["themen"] || [],
       who: snap["who"] || []
     )}
  end

  # Kein Worker online → im Warte-Zustand bleiben (Hinweis rendert die Seite).
  def handle_async(:load, {:ok, {:error, _reason}}, socket),
    do: {:noreply, socket}

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, "Nachlese-Load fehlgeschlagen — Seite neu laden.")}

  @impl true
  def handle_event("toggle_geschlossen", _params, socket),
    do: {:noreply, update(socket, :geschlossen_open, &(not &1))}

  def handle_event("toggle_themen", _params, socket),
    do: {:noreply, update(socket, :themen_open, &(not &1))}
end
