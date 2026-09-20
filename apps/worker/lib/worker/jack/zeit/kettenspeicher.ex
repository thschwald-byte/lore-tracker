defmodule Worker.Jack.Zeit.Kettenspeicher do
  @moduledoc """
  #1247: schreibt die **Kette** eines Laufs als Ereignisse — eines je Glied
  (`ZeitKettengliedSet`), nicht als Blob im Jack-Stand.

  ## Drei Regeln, und jede hat einen Grund

  **Nur was sich geändert hat.** Ein Ereignis je Lauf und Glied, auch wo
  nichts anders ist, schöbe bei jedem Lauf die `event_id` vor; der
  LWW-Vergleich im Fold verlöre damit seine Aussage, und ein zweiter Worker
  gewönne allein dadurch, dass er zuletzt gelaufen ist. Dieselbe Regel wie
  bei den Ankern (`Worker.Jack.Zeit.Pipeline.veroeffentlichen/3`).

  **Ein verschwundenes Glied bekommt einen Grabstein**, kein Delete. Wer ein
  Glied herausnimmt und die Zeile stehen liesse, bekäme es beim nächsten
  Lesen zurück — und ein `:mnesia.delete` divergierte bei vertauschter
  Zustellung zwischen zwei Workern (#698-Klasse).

  **Der rechte Nachbar reist mit.** Der Platz steht als Bezug auf die Kennung
  des linken Nachbarn (Maintainer, 20.09.2026). Wer ein Glied entfernt oder
  versetzt, ändert damit die Zeile dessen, was danach kommt — sonst zeigt sie
  auf etwas, das dort nicht mehr steht. Das passiert hier von selbst, weil
  `Kette.zu_zeilen/1` die ganze Kette neu ausrechnet und der Vergleich jede
  geänderte Zeile findet; ein Aufrufer muss nichts nachziehen.
  """

  alias Worker.Timeline.Kette

  @doc """
  Veröffentlicht die Kette. Liefert `{geschrieben, grabsteine}` — die Zahlen
  gehen in die Messzeile, weil „nichts geändert" und „nichts geschrieben"
  sonst gleich aussehen.

  `bestand` sind die gespeicherten Zeilen (aus `Worker.Repo.Zeit.ketten_zeilen/2`);
  ohne Angabe werden sie gelesen.
  """
  @spec veroeffentlichen(map(), map(), map(), [map()] | nil) ::
          {non_neg_integer(), non_neg_integer()}
  def veroeffentlichen(session, campaign, kette, bestand \\ nil) do
    alt = (bestand || Worker.Repo.Zeit.ketten_zeilen(campaign.id, session.id)) |> nach_id()
    neu = Kette.zu_zeilen(kette)

    geschrieben =
      neu
      |> Enum.reject(fn z -> Map.get(alt, z["glied_id"]) == vergleichbar(z) end)
      |> Enum.map(&publizieren(&1, session, campaign))
      |> length()

    grabsteine =
      alt
      |> Map.keys()
      |> Kernel.--(Enum.map(neu, & &1["glied_id"]))
      |> Enum.map(&publizieren(grabstein(&1), session, campaign))
      |> length()

    {geschrieben, grabsteine}
  end

  @doc "Das Ereignis einer Zeile — gebaut, nicht publiziert (prüfbar ohne Materializer)."
  @spec payload(map(), map(), map()) :: map()
  def payload(zeile, session, campaign) do
    %{
      "kind" => Shared.Events.zeit_kettenglied_set(),
      "glied_id" => zeile["glied_id"],
      "campaign_id" => campaign.id,
      "session_id" => session.id,
      "daten" => Map.delete(zeile, "glied_id")
    }
  end

  defp publizieren(zeile, session, campaign) do
    {:ok, _} = Worker.Intents.publish(payload(zeile, session, campaign))
    zeile
  end

  defp grabstein(glied_id), do: %{"glied_id" => glied_id, "entfernt" => true}

  # Verglichen wird ohne die Kennung — sie ist der Schlüssel, nicht der
  # Inhalt. Die gelesene Zeile trägt sie als Feld (der Leser setzt sie aus
  # dem Row-Schlüssel), die frisch gerechnete ebenso.
  defp vergleichbar(zeile), do: Map.delete(zeile, "glied_id")

  defp nach_id(zeilen), do: Map.new(zeilen, &{&1["glied_id"], vergleichbar(&1)})
end
