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
    # **Kampagnenweit vergleichen** (#1247, 25.09.2026). Seit die Eingabe die
    # Kette der ganzen Kampagne lädt, enthält `kette` auch Glieder anderer
    # Sitzungen. Verglichen der Speicher nur gegen die eigene Sitzung, wären
    # die alle „neu" — er schriebe sie mit SEINER `session_id` zurück, und sie
    # wanderten in die falsche Sitzung. Umgekehrt bekämen die eigenen, wenn
    # der Lauf nichts an ihnen ändert, Grabsteine.
    roh = bestand || Worker.Repo.Zeit.ketten_zeilen(campaign.id)
    alt = nach_id(roh)
    sitzung_von = Map.new(roh, &{&1["glied_id"], &1["session_id"]})
    neu = Kette.zu_zeilen(kette)

    geschrieben =
      neu
      |> Enum.reject(fn z -> Map.get(alt, z["glied_id"]) == vergleichbar(z) end)
      |> Enum.map(&publizieren(&1, sitzung_fuer(&1, sitzung_von, session), campaign))
      |> length()

    # **Grabsteine nur für die eigene Sitzung.** Ein Glied einer anderen
    # Sitzung, das in dieser Kette fehlt, ist kein gelöschtes Glied — es ist
    # eines, das dieser Lauf nicht geladen hat oder nicht kennt. Es zu
    # begraben, hiesse fremde Arbeit wegzuwerfen; das war vor diesem Cut der
    # Normalfall bei jedem Regenerate.
    grabsteine =
      alt
      |> Map.keys()
      |> Enum.filter(&(Map.get(sitzung_von, &1) == session.id))
      |> Kernel.--(Enum.map(neu, & &1["glied_id"]))
      |> Enum.map(&publizieren(grabstein(&1), session, campaign))
      |> length()

    {geschrieben, grabsteine}
  end

  # Ein bestehendes Glied behält seine Sitzung, ein neues bekommt die des
  # Laufs. Ohne das wanderte ein Glied bei jeder Änderung durch einen Lauf
  # einer anderen Sitzung mit — und `ketten_zeilen(cid, sid)` zählte es
  # plötzlich anders.
  defp sitzung_fuer(zeile, sitzung_von, session) do
    case Map.get(sitzung_von, zeile["glied_id"]) do
      sid when is_binary(sid) -> %{session | id: sid}
      _ -> session
    end
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
  # Verglichen wird ohne Kennung UND ohne Sitzung: beide stehen in
  # Row-Spalten, nicht im Blob. Die gelesene Zeile trägt sie als Felder (der
  # Leser setzt sie aus der Row), die frisch gerechnete kennt nur die Kennung
  # — ohne dieses `Map.delete` sähe jede bestehende Zeile geändert aus, und
  # der Lauf schriebe die ganze Kette bei jedem Werkzeugaufruf neu.
  defp vergleichbar(zeile), do: Map.drop(zeile, ["glied_id", "session_id"])

  defp nach_id(zeilen), do: Map.new(zeilen, &{&1["glied_id"], vergleichbar(&1)})
end
