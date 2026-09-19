defmodule Worker.Materializer.ZeitAnkerFolds do
  @moduledoc """
  #1247 (Z1): der `ZeitAnkerSet`-Fold — eine Row je **Anker**
  (`worker_zeit_anker`), nicht je Sitzung.

  Ein Zeit-Anker hängt an einer MENGE von Utterances: an einer einzelnen
  Äußerung, an mehreren, oder an einer ganzen Szene. Utterances sind die
  stabilste Schicht des Systems — sie werden nie neu erstellt —, und genau
  deshalb hängt die Zeit seit #1247 dort und nicht mehr am Fakt, der bei
  jeder Extraktion neu entsteht.

  **Der Schlüssel ist content-adressiert** (`anker_id` = `z_<hash>` über die
  sortierten Utterance-IDs, die Art und den Wert — gebildet von
  `Worker.Timeline.Linie.anker_id/3`): dieselbe Aussage an derselben Stelle
  ergibt denselben Anker, egal welcher Worker ihn schreibt. Zwei Worker
  konvergieren damit ohne Abgleich.

  **LWW über `event_id`**, wie bei den Jack-Ständen — und **nie ein
  `:mnesia.delete`**. Eine Rücknahme schreibt eine reguläre Row mit
  `art: "geloest"`; ein Delete würde bei vertauschter Zustellreihenfolge
  zwischen zwei Workern divergieren (#698-Klasse: Delete gegen Wiederkehr).

  **Geschützt ist die ADRESSE, nicht die Stelle.** Das ist der Punkt, an dem
  die Zusage unten leicht stärker gelesen wird, als sie ist: Die `anker_id`
  geht über `utterance_ids` **und Art und Wert**, eine Korrektur ist deshalb
  ein **zweites Objekt** und keine Überschreibung. „22:45" (von Hand) und
  „4:11" (von Jack) an derselben Utterance haben verschiedene Adressen, dieser
  Fold sieht sie nie gegeneinander, und beide Zeilen stehen zu Recht
  nebeneinander — keine überschreibt die andere.

  Welcher von beiden an dieser **Stelle** gilt, entscheidet der Leser:
  `Worker.Timeline.Linie.feste_punkte/2` wählt zweistufig, erst abgesegnet,
  dann früher. Ohne diese zweite Stufe gewänne dort der frühere Wert — und
  damit im Ticket-Fall die ASR-Verstümmelung gegen die menschliche
  Festlegung. (Review-Fund, 19.09.2026.)

  **Die menschliche Absegnung ist hart.** Trägt die bestehende Row ein
  `abgesegnet_am`, gewinnt sie gegen jeden Schreiber **ohne** Absegnung —
  unabhängig von der `event_id`. Ein späterer Jack-Lauf kann eine kuratierte
  Stelle also nicht überschreiben, auch nicht versehentlich über die
  Zeitordnung der Ereignisse. Nur ein Mensch überschreibt einen Menschen; dort
  gilt wieder LWW. Das ist die Durchsetzung am Fold — das Werkzeug lehnt einen
  solchen Anker schon vorher ab und legt Jack die Festlegung vor, aber ein
  Ereignis kann auch aus einem Replay oder von einem älteren Worker kommen,
  und dann gibt es kein Werkzeug mehr, das schützt.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def zeit_anker_set(payload, ts, meta) do
    anker_id = payload["anker_id"]
    cid = payload["campaign_id"]
    sid = payload["session_id"]
    daten = payload["daten"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(anker_id) and is_binary(cid)) ->
        Logger.warning(
          "ZeitAnkerSet: bad anker_id/campaign_id (#{inspect(anker_id)}/#{inspect(cid)}) — dropping"
        )

      not is_map(daten) ->
        Logger.warning("ZeitAnkerSet: keine daten für anker=#{anker_id} — dropping")

      not utterance_ids?(daten) ->
        Logger.warning("ZeitAnkerSet: leere utterance_ids für anker=#{anker_id} — dropping")

      not darf_schreiben?(anker_id, daten, event_id) ->
        :ok

      true ->
        :ok =
          :mnesia.write(
            {S.zeit_anker(), anker_id, cid, sid, Jason.encode!(daten), ts, event_id}
          )
    end
  end

  # Ein Anker ohne Utterances hat keinen Ort — er wäre auf der Linie nicht
  # auffindbar und könnte auch nie wieder getroffen werden (die anker_id ist
  # der Hash genau dieser Menge).
  defp utterance_ids?(%{"utterance_ids" => ids}) when is_list(ids), do: ids != []
  defp utterance_ids?(_), do: false

  # Die Regel ist SYMMETRISCH, und beide Hälften sind nötig:
  #
  #   alt kuratiert, neu nicht  → nie schreiben (eine abgesegnete Stelle
  #                               überschreibt niemand)
  #   neu kuratiert, alt nicht  → IMMER schreiben, ohne die event_id zu fragen
  #   sonst (beide gleich)      → LWW über die event_id
  #
  # Die zweite Hälfte fehlte im ersten Wurf, und der Permutationstest hat es
  # gefunden: Eine menschliche Festlegung scheiterte an einem maschinellen
  # Anker mit höherer event_id. Das heisst in der Praxis, dass ein Jack-Lauf,
  # der nach der Kuration zugestellt wird, sie blockiert — die Kuration wäre
  # dann eine Empfehlung statt einer Entscheidung.
  #
  # Zwei Menschen untereinander bleiben bei LWW: dort ist die spätere
  # Entscheidung die gültige, und beide sind gleich viel wert.
  defp darf_schreiben?(anker_id, neu, event_id) do
    alt = bestehende_daten(anker_id)

    cond do
      abgesegnet?(alt) and not abgesegnet?(neu) -> false
      abgesegnet?(neu) and not abgesegnet?(alt) -> true
      true -> event_id_supersedes?(event_id, bestehende_event_id(anker_id))
    end
  end

  defp abgesegnet?(%{"abgesegnet_am" => am}) when is_binary(am), do: am != ""
  defp abgesegnet?(_), do: false

  defp bestehende_daten(anker_id) do
    case :mnesia.read(S.zeit_anker(), anker_id) do
      [row] when tuple_size(row) >= 5 ->
        case Jason.decode(elem(row, 4) || "") do
          {:ok, %{} = daten} -> daten
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Die `event_id` ist die LETZTE Spalte — so legt `Worker.Schema.JackTabellen`
  # die Tabelle an, und so lesen es die Nachbar-Folds. Hier steht bewusst
  # `tuple_size - 1` statt einer festen Zahl: die Anker-Zeile hat eine Spalte
  # mehr als die Stand-Zeilen (`session_id` für die Cascade), und ein von dort
  # übernommener fester Index las beim ersten Versuch den Zeitstempel statt
  # der event_id. Der Effekt war kein Fehler, sondern das Gegenteil von LWW:
  # `bestehende_event_id` lieferte nie einen Wert, `event_id_supersedes?/2`
  # traf damit immer seine „kein Bestand"-Klausel, und es gewann schlicht der
  # zuletzt zugestellte Schreiber — zwei Worker mit derselben Menge wären
  # auseinandergelaufen. Gefunden hat es der Permutationstest, nicht das Lesen.
  defp bestehende_event_id(anker_id) do
    case :mnesia.read(S.zeit_anker(), anker_id) do
      [row] when tuple_size(row) >= 6 -> elem(row, tuple_size(row) - 1)
      _ -> nil
    end
  end
end
