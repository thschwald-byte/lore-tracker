defmodule Worker.Materializer.ZeitKettenFolds do
  @moduledoc """
  #1247: der `ZeitKettengliedSet`-Fold — **eine Row je Glied** der Kette
  (`worker_zeit_kette`), nicht ein Blob je Lauf.

  ## Warum je Glied

  Die Kette lag bis hierhin als Blob im Stand des Zeit-Jack. Das hat drei
  Nachteile, und der erste ist der schwerste:

    * **Ein Blob ist LWW über die ganze Kette.** Zwei Worker, die
      verschiedene Teile einsortieren, löschen sich gegenseitig aus — die
      #698-Klasse, nur mit mehr Verlust. Je Glied konvergiert es wie bei den
      Ankern nebenan.
    * **Leser.** Die Chronik und das Befundfenster müssen die Kette lesen,
      ohne einen Jack-Stand zu dekodieren.
    * **Kuration.** Wer ein Glied von Hand korrigiert, braucht eine Adresse
      für genau dieses Glied. Ein Blob hat keine.

  ## Der Schlüssel ist die Kennung, nicht der Inhalt

  Anders als bei den Ankern (`z_<hash>` über die Utterance-Menge) ist der
  Schlüssel hier die **Kennung des Gliedes** — eine UUID, vergeben beim
  Anlegen und stabil über jede Änderung (Maintainer, 20.09.2026). Das ist
  nötig, weil ein Glied wächst: Wäre die Adresse content-adressiert, bekäme
  dieselbe Szene nach jeder Erweiterung eine neue, und jeder Bezug auf sie
  zeigte ins Leere.

  **Der Preis ist benannt:** Eine UUID konvergiert nicht. Zwei Worker, die
  dieselbe Szene bilden, schreiben zwei Zeilen. Hinnehmbar, weil ein Glied in
  EINEM Lauf entsteht und dieser Lauf sein Autor ist — dieselbe Abwägung wie
  in `Worker.Timeline.Kette`.

  ## Der Platz steht als Bezug auf die Nachbar-Kennung

  `vorher` ist die Kennung des linken Geschwisters, `eltern` die des Gliedes,
  an dem es hängt (beide `nil` möglich). Daraus baut
  `Worker.Timeline.Kette.aus_zeilen/1` den Baum wieder auf — nachsichtig: ein
  gerissener Bezug hängt das Glied hinten an und wird gemeldet, statt es zu
  verlieren.

  ## Gelöscht wird nie

  Ein entferntes Glied bekommt eine reguläre Row mit `entfernt: true`. Ein
  `:mnesia.delete` divergierte bei vertauschter Zustellung zwischen zwei
  Workern (#698-Klasse: Delete gegen Wiederkehr) — dieselbe Regel wie bei den
  Ankern, den Lücken-Overrides und überall sonst in diesem Repo.

  ## Die Grenze von LWW: eine Millisekunde

  `event_id` ist eine UUIDv7, und die ist **innerhalb derselben Millisekunde
  nicht geordnet** — nachgemessen sind rund die Hälfte aufeinanderfolgender
  IDs lexikografisch kleiner als ihr Vorgänger. Zwei Schreibungen **derselben
  Zeile** in derselben Millisekunde entscheiden deshalb zufällig, nicht nach
  Reihenfolge.

  Für den Betrieb ist das folgenlos: Ein Lauf schreibt jede Zeile höchstens
  einmal, und zwischen zwei Läufen liegen Minuten. Wo zwei Worker gleichzeitig
  schreiben, ist die Reihenfolge ohnehin beliebig — dann ist „einer gewinnt"
  die Zusage, nicht „der spätere". Gilt genauso für die Anker nebenan und für
  jeden anderen LWW-Fold dieses Repos; hier steht es, weil ein Test es
  gefunden hat (20.09.2026, ein Drittel der Läufe rot).

  **LWW über `event_id`.** Eine menschliche Absegnung wie bei den Ankern gibt
  es hier (noch) nicht: Die Kette wird bislang nur von einem Jack-Lauf
  geschrieben. Wenn die Kuration kommt, gehört die Regel an genau diese
  Stelle — eine abgesegnete Zeile überschreibt kein Lauf.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def zeit_kettenglied_set(payload, ts, meta) do
    glied_id = payload["glied_id"]
    cid = payload["campaign_id"]
    sid = payload["session_id"]
    daten = payload["daten"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(glied_id) and glied_id != "" and is_binary(cid)) ->
        Logger.warning(
          "ZeitKettengliedSet: bad glied_id/campaign_id " <>
            "(#{inspect(glied_id)}/#{inspect(cid)}) — dropping"
        )

      not is_map(daten) ->
        Logger.warning("ZeitKettengliedSet: keine daten für glied=#{glied_id} — dropping")

      not inhalt?(daten) ->
        Logger.warning(
          "ZeitKettengliedSet: glied=#{glied_id} trägt weder Äußerungen noch einen " <>
            "Grabstein — dropping"
        )

      not event_id_supersedes?(event_id, bestehende_event_id(glied_id)) ->
        :ok

      true ->
        :mnesia.write({S.zeit_kette(), glied_id, cid, sid, Jason.encode!(daten), ts, event_id})
    end
  end

  # Eine Zeile muss etwas aussagen: entweder trägt sie Äußerungen (ein Glied
  # oder eine gelöste Zeile), oder sie ist ein Grabstein. Eine leere Zeile
  # ohne beides wäre ein Glied ohne Ort — auf der Kette nicht auffindbar und
  # beim Lesen nur ein Befund.
  defp inhalt?(%{"entfernt" => true}), do: true
  defp inhalt?(%{"art" => "draussen"}), do: true
  defp inhalt?(%{"utts" => utts}) when is_list(utts), do: utts != []
  defp inhalt?(_), do: false

  # Die `event_id` ist die LETZTE Spalte — `tuple_size - 1` statt einer festen
  # Zahl, aus demselben Grund wie in `ZeitAnkerFolds`: ein von dort
  # übernommener fester Index las beim ersten Versuch den Zeitstempel, und der
  # LWW-Vergleich traf dann still immer seine „kein Bestand"-Klausel.
  defp bestehende_event_id(glied_id) do
    case :mnesia.read(S.zeit_kette(), glied_id) do
      [row] when tuple_size(row) >= 6 -> elem(row, tuple_size(row) - 1)
      _ -> nil
    end
  end
end
