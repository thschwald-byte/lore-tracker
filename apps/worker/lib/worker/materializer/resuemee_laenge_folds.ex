defmodule Worker.Materializer.ResuemeeLaengeFolds do
  @moduledoc """
  J5 (#1209): der CampaignResuemeeLaengeSet-Fold — Schwester-Modul von
  `Worker.Materializer.Apply2` (dessen God-Module-Budget), dort nur eine
  Dünn-Dispatch-Klausel (Muster `Worker.Materializer.DiscordConfigFolds`).

  1 Row/Kampagne (`worker_campaign_resuemee_laengen`), LWW über die
  fold_meta-Sidecar (`:campaign_resuemee_laenge_set`), Voll-Snapshot-Payload:
  das Event trägt genau ein Feld, `max_woerter`, und ersetzt die Row ganz.

  **Getrennt von CampaignVorgabeSet**, obwohl die Länge zur Vorgabe der
  Resümee-Spalte gehört: dessen Fold ersetzt die Vorgabe-Row aus einem
  Payload, und ein Producer, der nur den Namen kennt, würde eine Länge in
  derselben Row still löschen — und umgekehrt (s.
  `Shared.Events.campaign_resuemee_laenge_set/0`). Eigene Tabelle, eigener
  Fold-Slot: Name und Länge überschreiben einander nie.

  **Nie ein `:mnesia.delete`:** auch das Zurücksetzen auf den Standard
  (`max_woerter: nil`) schreibt eine reguläre Row — sonst divergierte ein
  vertauschtes Setzen→Zurücksetzen-Paar zwischen Workern (#698-Klasse).

  **Ein ungültiger Wert gilt als Standard und steht laut im Log** — die Row
  bekommt `nil`. Der Hub lehnt ungültige Eingaben schon im Formular ab
  (`HubWeb.CampaignLive.Stil`); hier landet ein ungültiger Wert nur aus
  anderen Quellen (ein älterer Hub, ein Skript, ein Replay). Ihn zu
  ignorieren wäre die Alternative: dann bliebe der vorige Wert stehen, und
  niemand sähe, warum der eben gesetzte nicht greift.
  """

  require Logger

  alias Shared.ResuemeeLaenge
  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @fold :campaign_resuemee_laenge_set

  @doc false
  def campaign_resuemee_laenge_set(payload, ts, meta) do
    id = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not is_binary(id) ->
        Logger.warning("CampaignResuemeeLaengeSet: bad campaign_id (#{inspect(id)}) — dropping")

      not fold_supersedes?(S.campaign_resuemee_laengen(), id, @fold, event_id) ->
        :ok

      true ->
        n = max_woerter(id, payload["max_woerter"])
        :ok = :mnesia.write({S.campaign_resuemee_laengen(), id, n, ts})
        record_fold_winner!(S.campaign_resuemee_laengen(), id, @fold, event_id)
    end
  end

  defp max_woerter(id, wert) do
    case ResuemeeLaenge.pruefen(wert) do
      {:ok, n} ->
        n

      :leer ->
        nil

      {:error, :ungueltig} ->
        Logger.warning(
          "CampaignResuemeeLaengeSet: ungültige Länge #{inspect(wert)} für Kampagne #{id} — " <>
            "es gilt der Standard (#{ResuemeeLaenge.standard()} Wörter; erlaubt " <>
            "#{ResuemeeLaenge.untergrenze()} bis #{ResuemeeLaenge.obergrenze()})"
        )

        nil
    end
  end
end
