defmodule Worker.Jack.Zeit.Speicher do
  @moduledoc """
  #1247: sichert den Stand des Zeit-Jack **nach jedem Werkzeugaufruf**, nicht
  erst am Ende des Laufs.

  ## Warum

  Maintainer, 24.09.2026: „jeder werkzeugaufruf speichert in db". Der Anlass
  sind zwei Totalverluste an einem Tag:

    * Ein Lauf lief 56 Minuten, geriet in eine Wiederholungsschleife und wurde
      abgebrochen — **null** Glieder in der Datenbank.
    * Ein Lauf lief 62 Minuten, hatte 2168 Zeilen gelesen, 1992 eingeordnet und
      25 Glieder gebaut, und starb an der Wiederholungssperre. Wieder **null**
      Glieder: Veröffentlicht wurde erst nach `Zeit.laufen/2`, und dorthin kam
      der Lauf nie.

  Dieses Repo speichert Entscheidungen ohnehin als Ereignisse. Eine Eintragung
  in die Kette **ist** eine Entscheidung; sie bis zum Laufende im
  Arbeitsspeicher zu halten war die Ausnahme von der Hausregel, und sie hat
  zweimal die Arbeit eines ganzen Vormittags gekostet.

  ## Der Stand ist mehr als die Kette

  Deshalb gehen drei Dinge raus, nicht eines (Maintainer, ebenda):

    * die **Kette** — eine Row je Glied (`Kettenspeicher`),
    * die **Anker** — eine Row je Anker (`ZeitAnkerSet`),
    * der **übrige Stand** — Leseabdeckung, Einordnung, Notizen, Konflikte als
      ein Blob je Sitzung (`JackZeitStandAbgelegt`).

  Eine Kette ohne das, was sie erklärt, wäre schlechter als gar nichts: Sie
  sähe vollständig aus.

  ## Geschrieben wird nur, was sich geändert hat

  Jeder Schritt vergleicht gegen den Bestand in Mnesia und publiziert nur die
  Differenz — meist null bis zwei Ereignisse je Aufruf. Ohne diesen Vergleich
  schöbe jeder Aufruf die `event_id` jeder Zeile vor, und der LWW-Vergleich in
  den Folds verlöre seine Aussage (dieselbe Regel wie bei den Ankern seit Z1).

  Der Stand-Blob ist davon ausgenommen: Er ist eine einzige Row je Sitzung, und
  sein Inhalt ändert sich bei praktisch jedem Aufruf (`gelesen` wächst schon
  beim Lesen). Ihn zu vergleichen kostete mehr, als es spart.

  ## Ein Fehler beim Speichern beendet den Lauf nicht

  Er wird laut geloggt, und der Lauf geht weiter. Die Abwägung ist einseitig:
  Ein nicht gespeicherter Zwischenstand kostet im schlimmsten Fall das, was
  vorher ohnehin verloren war; ein abgebrochener Lauf kostet eine Stunde
  Modellzeit.

  ## Ehrliche Grenze: die Millisekunde

  `event_id` ist eine UUIDv7 und innerhalb derselben Millisekunde nicht
  geordnet (nachgemessen: rund die Hälfte aufeinanderfolgender IDs ist
  kleiner als ihr Vorgänger). Zwei Schreibungen **derselben Zeile** in
  derselben Millisekunde entscheiden deshalb zufällig. Zwischen zwei
  Werkzeugaufrufen liegt die Antwortzeit des Modells — Sekunden, nicht
  Millisekunden —, und jeder Aufruf schreibt eine Zeile höchstens einmal. Der
  Fall ist damit nicht ausgeschlossen, aber weit entfernt; er wäre erreichbar,
  wenn ein Werkzeug je Aufruf mehrfach dieselbe Zeile schriebe.
  """

  require Logger

  alias Worker.Jack.Zeit.{Kettenspeicher, Stand}

  @doc """
  Sichert den Stand. Liefert den Stand unverändert zurück, damit der Aufruf
  in eine Kette passt.

  Ohne `session_id`/`campaign_id` im Stand passiert nichts — so laufen Tests
  und Messläufe ohne Mnesia weiter.
  """
  @spec sichern(Stand.t()) :: Stand.t()
  def sichern(%Stand{session_id: sid, campaign_id: cid} = s)
      when is_binary(sid) and is_binary(cid) do
    sitzung = %{id: sid}
    kampagne = %{id: cid}

    zaehlen(fn -> Kettenspeicher.veroeffentlichen(sitzung, kampagne, s.kette) end, "kette")
    zaehlen(fn -> anker_sichern(s, sitzung, kampagne) end, "anker")
    zaehlen(fn -> stand_sichern(s, sitzung, kampagne) end, "stand")

    s
  end

  def sichern(%Stand{} = s), do: s

  # Ein Fehler beim Sichern darf den Lauf nicht beenden — aber er darf auch
  # nicht still bleiben: Wer ihn nicht sieht, hält einen Lauf für gesichert,
  # der es nicht ist.
  defp zaehlen(fun, was) do
    fun.()
  rescue
    e -> Logger.error("Zeit-Speicher (#{was}): #{Exception.message(e)}")
  catch
    art, grund -> Logger.error("Zeit-Speicher (#{was}): #{inspect({art, grund})}")
  end

  # ─── Anker ──────────────────────────────────────────────────────────

  # Nur Jacks eigene Anker, und nur die, die so noch nicht in der Datenbank
  # stehen. Die menschlich gesetzten reisen als Eingabe mit und gehören nicht
  # zurückgeschrieben (dieselbe Regel wie in `Pipeline.veroeffentlichen/3`).
  defp anker_sichern(%Stand{} = s, sitzung, kampagne) do
    bestand = Map.new(Worker.Repo.Zeit.anker(kampagne.id), &{&1[:anker_id], &1})

    s.anker
    |> Map.values()
    |> Enum.filter(&(to_string(Map.get(&1, :quelle) || "") == "jack"))
    |> Enum.reject(&gleich?(&1, bestand[&1[:anker_id]]))
    |> Enum.each(fn a ->
      {:ok, _} =
        Worker.Intents.publish(Worker.Jack.Zeit.Pipeline.payload(a, sitzung, kampagne))
    end)
  end

  # Verglichen werden die Felder, die der Anker trägt — nicht die gerechneten
  # (`minute` &Co.), die der Leser aus Ausdruck und Kalender neu bildet.
  @felder [
    :utterance_ids,
    :art,
    :wert,
    :welt,
    :halbtag,
    :zweifel,
    :beleg,
    :quelle,
    :ziel,
    :richtung
  ]
  defp gleich?(_neu, nil), do: false

  defp gleich?(neu, alt) do
    Enum.all?(@felder, fn f -> norm(Map.get(neu, f)) == norm(Map.get(alt, f)) end)
  end

  defp norm(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: to_string(v)
  defp norm(nil), do: ""
  defp norm(v), do: v

  # ─── Der übrige Stand ───────────────────────────────────────────────

  # Dieselbe Form wie die abschliessende Ablage in `Pipeline.stand_ablegen/3`,
  # damit ein Zwischenstand und ein Endstand dasselbe bedeuten. Der Mitschnitt
  # geht NICHT mit: Er steht in der Glättung und wäre je Aufruf ein Vielfaches
  # der übrigen Nutzlast.
  defp stand_sichern(%Stand{} = s, sitzung, kampagne) do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.jack_zeit_stand_abgelegt(),
        "session_id" => sitzung.id,
        "campaign_id" => kampagne.id,
        "stand" => %{
          "jack" => "zeit",
          "abbild" => Stand.abbild(s),
          "notizen" => s.notizen,
          "kette_glieder" => Worker.Timeline.Kette.anzahl(s.kette),
          "konflikte" => s.konflikte,
          "laeuft" => true,
          "abgelegt_am" => DateTime.to_iso8601(DateTime.utc_now())
        }
      })
  end
end
