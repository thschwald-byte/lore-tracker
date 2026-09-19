defmodule Worker.Timeline.Linie do
  @moduledoc """
  #1247 (Z1): die Zeitlinie einer Kampagne — **pur**, ohne Mnesia und ohne
  Modell. Sie rechnet aus Ankern und erzeugt nie einen.

  ## Was hier hineingeht

    * **Stellen** — die Utterances in ihrer **Grundordnung**: Sitzungsnummer,
      dann Position im Mitschnitt. Die steht ohnehin da und kostet nichts;
      was niemand anfasst, bleibt in Erzählreihenfolge.
    * **Anker** — was ein Zeit-Jack oder ein Mensch gesetzt hat, je an einer
      MENGE von Utterances (eine Äußerung, mehrere, eine ganze Szene):

          zeitpunkt   ein genannter Zeitpunkt („am 15. November")
          spanne      eine genannte Dauer („zwei Stunden marschiert")
          ordnung     eine Verschiebung gegen die Erzählreihenfolge
                      (ein Rückblick liegt in der Vergangenheit)
          geloest     gehört nicht auf die Linie (Tischgespräch, Regelfrage)

  ## Die Einheit ist die MINUTE, nicht der Tag

  Das ist eine Entscheidung dieses Moduls, und sie folgt aus den Spannen.
  Der bestehende Zeitstrahl rechnet auf einem **Tageszähler**
  (`Worker.Timeline.Calendar`); auf ihm ist „zwei Stunden marschiert" nicht
  darstellbar und damit wirkungslos — 0,083 Tage verschwinden im Rundungsrest.
  Spannen sind aber genau der Mechanismus, mit dem am Spieltisch Zeit vergeht,
  ohne dass jemand eine Uhr nennt: fünf Märsche zu je fünf Stunden sind ein
  Tageswechsel, und dieser Wechsel entsteht nur, wenn man unterhalb des Tages
  rechnen kann.

  Die Linie führt deshalb je Stelle einen **Versatz in Minuten**. Das Datum
  ist eine Ableitung daraus (`div(minuten, 1440)` ergibt den Tag, den
  `Calendar` versteht) — nicht umgekehrt. Nach aussen bleibt der Tageszähler
  damit unverändert.

  **Ehrlich:** Minuten sind gewählt, nicht gemessen. Sekunden wären
  Scheingenauigkeit (niemand am Tisch sagt „siebzehn Sekunden später"),
  Stunden zu grob für „eine halbe Stunde später". Kippt das, ist es eine
  Konstante an einer Stelle.

  ## Was die Linie NICHT tut

  Sie **baut kein Konstrukt** aus mehreren Ankern. `anker_fuer/2` liefert eine
  **Liste** — keinen Mittelwert, keine Spanne, keinen „frühesten". Ein Fakt
  stützt sich auf mehrere Äußerungen, die verschiedene Anker tragen können;
  wer daraus einen Wert braucht, rechnet ihn selbst und sichtbar. Ein
  Mittelwert wäre eine Zeit, die niemand gesagt hat.

  Sie **interpoliert zur Laufzeit** und schreibt nichts fort. Deshalb zieht
  sich die Strecke von allein gerade, wenn jemand einen Anker korrigiert.
  """

  @minuten_pro_tag 1440

  @typedoc "Eine Utterance in der Grundordnung."
  @type stelle :: %{utterance_id: String.t(), session_nr: integer(), pos: integer()}

  @typedoc """
  Ein Anker, wie er aus `worker_zeit_anker` kommt. `utterance_ids` ist die
  Menge, an der er hängt; `minuten` die aufgelöste Dauer einer Spanne bzw.
  `nil`; `ziel`/`richtung` die Verschiebung einer `ordnung`.
  """
  @type anker :: %{optional(atom()) => term()}

  @typedoc "Was an einer Stelle gilt — belegt oder gerechnet."
  @type eintrag :: %{
          utterance_id: String.t(),
          minute: integer() | nil,
          herkunft: :belegt | :interpoliert | :ohne,
          anker_id: String.t() | nil,
          zweifel: String.t() | nil,
          abgesegnet?: boolean()
        }

  @doc """
  Die Adresse eines Ankers: content-adressiert über die **sortierten**
  Utterance-IDs, die **Art** und den **Wert**. Dieselbe Aussage an derselben
  Stelle ergibt dieselbe ID, egal welcher Worker sie schreibt — zwei Worker
  konvergieren damit ohne Abgleich.

  **Art und Wert gehören in die Adresse, nicht nur die Utterances.** Der erste
  Entwurf hashte allein über die Utterance-Menge, und daran wäre ein häufiger
  Fall gestorben: Eine Äußerung nennt eine Dauer und den daraus folgenden
  Zeitpunkt in einem Satz — „also ist jetzt so grob eine Stunde vergangen,
  dann wird es jetzt so kurz nach zwölf sein". Das sind **zwei** Anker an
  **einer** Utterance (eine Spanne und ein Zeitpunkt); mit der alten Regel
  hätten sie dieselbe Adresse, und der zweite hätte den ersten über LWW
  **stumm** überschrieben. Genau das ist die natürliche Sprechweise für
  vergehende Spielzeit, also kein Randfall (Befund aus der handgelesenen
  Referenzliste, seattleV5 S3 Block 1106).
  """
  @spec anker_id([String.t()], atom() | String.t(), String.t()) :: String.t()
  def anker_id(utterance_ids, art, wert) when is_list(utterance_ids) do
    roh =
      Enum.join(Enum.sort(utterance_ids), ",") <>
        "|" <> to_string(art) <> "|" <> normalisiert(wert)

    "z_" <> (:crypto.hash(:sha256, roh) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  # Wie `Parsing.normalize_claim/1`: Gross-/Kleinschreibung und Leerraum
  # sollen keine zweite Adresse für dieselbe Aussage erzeugen.
  defp normalisiert(wert) do
    wert
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Baut die Linie aus Grundordnung und Ankern.

  Liefert `%{reihe: [eintrag], nach_utterance: %{id => eintrag},
  anker_an: %{id => [anker()]}, geloest: MapSet, befunde: [befund]}`.

  **`nach_utterance` und `anker_an` sind zweierlei**, und sie zu vermengen war
  der erste Entwurf: Eine Äußerung hat genau **eine** Position auf der Linie —
  sie kann nicht an zwei Stellen liegen —, aber an ihr können **mehrere
  Anker** hängen. „Also ist jetzt so grob eine Stunde vergangen, dann wird es
  jetzt so kurz nach zwölf sein" ist eine Utterance mit einer Spanne und einem
  Zeitpunkt. Mit einem Eintrag je Utterance wäre die Liste, die die transiente
  Methode liefern soll, gar nicht darstellbar gewesen.
  """
  @spec bauen([stelle()], [anker()]) :: map()
  def bauen(stellen, anker) when is_list(stellen) and is_list(anker) do
    geloest = geloeste(anker)
    aktiv = Enum.reject(stellen, &MapSet.member?(geloest, &1.utterance_id))

    reihe =
      aktiv
      |> grundordnung()
      |> verschieben(anker)

    eintraege = minuten_verteilen(reihe, anker)

    %{
      reihe: eintraege,
      nach_utterance: Map.new(eintraege, &{&1.utterance_id, &1}),
      anker_an: anker_an(anker, geloest),
      geloest: geloest,
      befunde: pruefen(eintraege, reihe, anker)
    }
  end

  # Alle Anker je Utterance — mehrere sind der Normalfall, nicht die Ausnahme.
  # Ein gelöster Anker erscheint hier nicht: er liegt nicht auf der Linie.
  defp anker_an(anker, geloest) do
    for a <- anker,
        art(a) != :geloest,
        u <- Map.get(a, :utterance_ids, []),
        not MapSet.member?(geloest, u),
        reduce: %{} do
      acc -> Map.update(acc, u, [a], &(&1 ++ [a]))
    end
  end

  @doc """
  **Die transiente Methode.** Liefert zu einer Utterance-Menge die Zeitanker —
  als LISTE, in der Reihenfolge der Linie.

  Die Liste ist verschieden lang von der Zahl der Utterances, in beide
  Richtungen: Eine Äußerung kann **mehrere** Anker tragen (eine Dauer und den
  daraus folgenden Zeitpunkt in einem Satz), und sie kann **keinen** tragen —
  dann steht sie interpoliert oder ganz ohne Zeit da.

  Jeder Eintrag trägt seine Herkunft: `:belegt` (an dieser Stelle gesagt),
  `:interpoliert` (gerechnet zwischen zwei Ankern) oder `:ohne` (kein Anker in
  Reichweite). Ohne die Herkunft wäre eine falsche Einordnung nicht
  auffindbar.

  **Es wird nichts gebaut** — kein Mittelwert, keine Spanne, kein
  „frühester". Wer daraus einen Wert braucht, rechnet ihn selbst und sichtbar.
  Eine leere Liste heißt „keine Zeit erreichbar"; das ist eine Aussage und
  kein Fehler.
  """
  @spec anker_fuer(map(), [String.t()]) :: [map()]
  def anker_fuer(%{nach_utterance: nach} = linie, utterance_ids)
      when is_list(utterance_ids) do
    an = Map.get(linie, :anker_an, %{})

    utterance_ids
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case {Map.get(nach, id), Map.get(an, id, [])} do
        # Gelöst oder unbekannt: kein Eintrag. Ein leerer Platzhalter wäre
        # eine Aussage über eine Zeit, die es nicht gibt.
        {nil, _} ->
          []

        # Keine eigenen Anker: die Stelle selbst, mit ihrer gerechneten Zeit.
        {stelle, []} ->
          [stelle]

        # Mehrere Anker an einer Äußerung: jeder einzeln, mit der Zeit der
        # Stelle und seinem eigenen Ausdruck.
        {stelle, anker} ->
          Enum.map(anker, fn a ->
            stelle
            |> Map.put(:anker_id, Map.get(a, :anker_id))
            |> Map.put(:art, art(a))
            |> Map.put(:wert, Map.get(a, :wert))
            |> Map.put(:welt, Map.get(a, :welt))
            |> Map.put(:zweifel, Map.get(a, :zweifel) || stelle.zweifel)
          end)
      end
    end)
    |> Enum.sort_by(&{&1.minute || 0, &1.utterance_id, to_string(&1[:art] || "")})
  end

  def anker_fuer(_, _), do: []

  @doc """
  Der Tag eines Eintrags für `Worker.Timeline.Calendar` — die Minute durch
  1440. `nil` bleibt `nil`; eine Stelle ohne erreichbaren Anker bekommt kein
  Datum.
  """
  @spec tag(eintrag()) :: integer() | nil
  def tag(%{minute: m}) when is_integer(m), do: Integer.floor_div(m, @minuten_pro_tag)
  def tag(_), do: nil

  @doc "Minuten je Tag — die Brücke zum Tageszähler des Kalenders."
  @spec minuten_pro_tag() :: pos_integer()
  def minuten_pro_tag, do: @minuten_pro_tag

  # ─── Grundordnung ───────────────────────────────────────────────────

  # Sitzungsnummer, dann Position. Eine Sitzung ohne Nummer ans Ende (wie
  # `campaign_utterance_tail/2` es hält) — eine Entscheidung, keine
  # Nebenwirkung von Elixirs Term-Ordnung.
  defp grundordnung(stellen),
    do: Enum.sort_by(stellen, &{&1.session_nr || 999_999, &1.pos, &1.utterance_id})

  # ─── Verschiebungen ─────────────────────────────────────────────────

  # Eine `ordnung` hebt ihre Utterances aus der Erzählreihenfolge und setzt
  # sie vor oder hinter eine Zielstelle. Ohne auflösbares Ziel bleibt sie
  # liegen — das ist der Befund „Verschiebung ohne Ziel", nicht ein Raten.
  defp verschieben(reihe, anker) do
    Enum.reduce(ordnungen(anker), reihe, fn a, acc ->
      menge = MapSet.new(Map.get(a, :utterance_ids, []))
      ziel = Map.get(a, :ziel)

      if ziel && Enum.any?(acc, &(&1.utterance_id == ziel)) and not MapSet.member?(menge, ziel) do
        {bewegt, rest} = Enum.split_with(acc, &MapSet.member?(menge, &1.utterance_id))
        einsetzen(rest, bewegt, ziel, Map.get(a, :richtung, :vor))
      else
        acc
      end
    end)
  end

  defp einsetzen(rest, [], _ziel, _richtung), do: rest

  defp einsetzen(rest, bewegt, ziel, richtung) do
    {vorne, hinten} = Enum.split_while(rest, &(&1.utterance_id != ziel))

    case {richtung, hinten} do
      {:vor, _} -> vorne ++ bewegt ++ hinten
      {_, [z | r]} -> vorne ++ [z] ++ bewegt ++ r
      {_, []} -> vorne ++ bewegt
    end
  end

  defp ordnungen(anker), do: Enum.filter(anker, &(art(&1) == :ordnung))

  defp geloeste(anker) do
    anker
    |> Enum.filter(&(art(&1) == :geloest))
    |> Enum.flat_map(&Map.get(&1, :utterance_ids, []))
    |> MapSet.new()
  end

  defp art(a) do
    case Map.get(a, :art) do
      x when is_atom(x) -> x
      x when is_binary(x) -> safe_atom(x)
      _ -> :unbekannt
    end
  end

  # Kein String.to_atom auf Fremddaten (Atom-Tabelle ist endlich und wird nie
  # aufgeräumt) — nur die vier bekannten Formen.
  defp safe_atom("zeitpunkt"), do: :zeitpunkt
  defp safe_atom("spanne"), do: :spanne
  defp safe_atom("ordnung"), do: :ordnung
  defp safe_atom("geloest"), do: :geloest
  defp safe_atom(_), do: :unbekannt

  # ─── Minuten verteilen ──────────────────────────────────────────────

  # Feste Punkte sind die Zeitpunkt-Anker. Dazwischen wird interpoliert; die
  # Spannen dazwischen geben den Abstand vor, soweit sie hineinpassen.
  defp minuten_verteilen(reihe, anker) do
    feste = feste_punkte(reihe, anker)
    spannen = spannen_je_stelle(reihe, anker)
    zweifel = zweifel_je_stelle(anker)
    abgesegnet = abgesegnete(anker)

    reihe
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      {minute, herkunft} = minute_an(i, reihe, feste, spannen)

      %{
        utterance_id: s.utterance_id,
        minute: minute,
        herkunft: herkunft,
        anker_id: Map.get(feste, i, %{})[:anker_id],
        zweifel: Map.get(zweifel, s.utterance_id),
        abgesegnet?: MapSet.member?(abgesegnet, s.utterance_id)
      }
    end)
  end

  defp minute_an(i, _reihe, feste, _spannen) when is_map_key(feste, i),
    do: {feste[i][:minute], :belegt}

  defp minute_an(i, reihe, feste, spannen) do
    case {letzter_fest(i, feste), naechster_fest(i, reihe, feste)} do
      {nil, nil} -> {nil, :ohne}
      {{vi, vm}, nil} -> {vm + gelaufen(vi, i, spannen), :interpoliert}
      {nil, {_ni, _nm}} -> {nil, :ohne}
      {{vi, vm}, {ni, nm}} -> {zwischen(vi, vm, ni, nm, i, spannen), :interpoliert}
    end
  end

  # Zwischen zwei festen Punkten: erst die genannten Dauern: sie sind belegt,
  # die Position ist es nicht. Passen sie nicht in den Abstand, wird linear
  # verteilt — der Widerspruch ist dann ein BEFUND (s. `pruefen/3`) und wird
  # nicht durch eine stille Stauchung versteckt.
  defp zwischen(vi, vm, ni, nm, i, spannen) do
    summe = gelaufen(vi, ni, spannen)
    abstand = nm - vm

    if summe > 0 and summe <= abstand do
      vm + gelaufen(vi, i, spannen)
    else
      vm + div(abstand * (i - vi), max(ni - vi, 1))
    end
  end

  defp gelaufen(von, bis, spannen) when bis > von,
    do: Enum.sum(for j <- (von + 1)..bis, do: Map.get(spannen, j, 0))

  defp gelaufen(_, _, _), do: 0

  defp letzter_fest(i, feste) do
    feste
    |> Enum.filter(fn {j, _} -> j < i end)
    |> Enum.max_by(fn {j, _} -> j end, fn -> nil end)
    |> case do
      {j, %{minute: m}} -> {j, m}
      _ -> nil
    end
  end

  defp naechster_fest(i, _reihe, feste) do
    feste
    |> Enum.filter(fn {j, _} -> j > i end)
    |> Enum.min_by(fn {j, _} -> j end, fn -> nil end)
    |> case do
      {j, %{minute: m}} -> {j, m}
      _ -> nil
    end
  end

  # Ein Zeitpunkt-Anker gilt an der FRÜHESTEN Stelle seiner Menge: er wird
  # dort gesagt, und alles danach liegt danach.
  #
  # Zwei Zeitpunkte an derselben Stelle sind möglich (an einer Utterance dürfen
  # mehrere Anker hängen). Für die Rechnung muss einer gelten; gewählt wird
  # **zweistufig: erst abgesegnet, dann früher**, und der Widerspruch ist ein
  # Befund (`zeitpunkte_uneinig`) — nicht ein stilles Gewinnen nach
  # Listenreihenfolge, das je nach Zustellreihenfolge anders ausfiele.
  #
  # **Warum die Absegnung HIER entschieden wird und nicht im Fold.** Der Fold
  # schützt eine **Adresse**, und die ist `hash(utterance_ids + art + wert)` —
  # der Wert geht ein. Eine Korrektur ist damit ein **zweites Objekt**, keine
  # Überschreibung: „22:45" (von Hand) und „4:11" (von Jack) an derselben
  # Stelle haben verschiedene Adressen, der Fold sieht sie nie gegeneinander,
  # und beide Zeilen stehen zu Recht nebeneinander. Entschieden wird die
  # **Stelle** erst hier.
  #
  # Ohne diese Stufe verlöre der Mensch, und zwar deterministisch: Der Fall
  # aus dem Ticket ist eine Spracherkennung, die „4:11" verstand, wo „22:45"
  # gesagt war. 4:11 ist früher — nach reiner Minutenwahl gewönne die
  # Verstümmelung gegen die Festlegung. Gefunden im Review (19.09.2026), nicht
  # von einem Test: der Fold-Test fuhr beide Ereignisse auf derselben Adresse
  # und prüfte damit den Fall, in dem die Regel greift, nicht den, in dem sie
  # umgangen wird.
  defp feste_punkte(reihe, anker) do
    index = index_nach_utterance(reihe)

    anker
    |> datierte_punkte(index)
    |> verankern(uhrzeit_punkte(anker, index))
  end

  # Die Punkte, die eine absolute Minute mitbringen — aus einem Datum.
  defp datierte_punkte(anker, index) do
    for a <- anker,
        art(a) == :zeitpunkt,
        minute = Map.get(a, :minute),
        is_integer(minute),
        i = frueheste(a, index),
        not is_nil(i),
        reduce: %{} do
      acc -> eintragen(acc, i, punkt(a, minute, false))
    end
  end

  # Die Uhrzeiten: eine TAGESMINUTE, noch ohne Tag.
  defp uhrzeit_punkte(anker, index) do
    for a <- anker,
        art(a) == :zeitpunkt,
        tm = Map.get(a, :tagesminute),
        is_integer(tm),
        i = frueheste(a, index),
        not is_nil(i),
        into: %{},
        do: {i, {tm, a}}
  end

  # **Eine Uhrzeit bekommt ihren Tag aus ihrer Stelle in der Reihe.** „Drei
  # viertel elf" sagt nicht, welcher Tag; das steht im Verlauf. Genommen wird
  # der Tag des letzten festen Punktes davor ODER AN DERSELBEN STELLE — das
  # zweite ist der Fall „am 15. November, um 22:45": Datum und Uhrzeit sind
  # dann zwei Anker an einer Äußerung, und die Uhrzeit erbt den Tag.
  #
  # **Springt die Tagesminute zurück, ist Mitternacht überschritten.** Von
  # 23:40 auf 00:20 geht es vorwärts, nicht 23 Stunden zurück. Die Regel gilt
  # auf der bereits VERSCHOBENEN Reihe — ein Rückblick, den Jack mit
  # `verschieben` an seinen Platz gesetzt hat, steht dort schon richtig und
  # erzeugt keinen falschen Tageswechsel.
  #
  # **Ehrliche Grenze:** Liegt vor der ersten Uhrzeit kein datierter Punkt,
  # beginnt die Linie auf Tag 0. Sie ist dann relativ — was sie ohne Datum
  # ohnehin ist; die Abstände stimmen, das Kalenderdatum gibt es schlicht
  # nicht.
  defp verankern(datierte, uhrzeiten) do
    uhrzeiten
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(datierte, fn {i, {tm, a}}, acc ->
      eintragen(acc, i, punkt(a, absolute_minute(tm, vorlauf(acc, i)), true))
    end)
  end

  defp punkt(a, minute, genau?),
    do: %{minute: minute, anker_id: Map.get(a, :anker_id), abgesegnet?: abgesegnet?(a), genau?: genau?}

  defp eintragen(acc, i, neu) do
    case acc[i] do
      nil -> Map.put(acc, i, neu)
      alt -> if gewinnt?(neu, alt), do: Map.put(acc, i, neu), else: acc
    end
  end

  defp vorlauf(feste, i) do
    feste
    |> Enum.filter(fn {j, _} -> j <= i end)
    |> Enum.max_by(fn {j, _} -> j end, fn -> nil end)
    |> case do
      {_, %{minute: m}} -> m
      _ -> nil
    end
  end

  defp absolute_minute(tagesminute, nil), do: tagesminute

  defp absolute_minute(tagesminute, vorher) do
    tag = Integer.floor_div(vorher, @minuten_pro_tag)
    kandidat = tag * @minuten_pro_tag + tagesminute

    if kandidat < vorher, do: kandidat + @minuten_pro_tag, else: kandidat
  end

  # Erst die menschliche Festlegung, dann die genauere Angabe, dann der
  # frühere Wert. Zwei abgesegnete untereinander entscheidet wieder die
  # Minute — beide sind gleich viel wert, und der Widerspruch steht ohnehin
  # als Befund da.
  #
  # **Die Genauigkeit steht zwischen beiden, weil Datum und Uhrzeit sich nicht
  # widersprechen, sondern ergänzen.** „Am 15. November" ergibt Mitternacht,
  # „22:45" denselben Tag um 22:45 — ohne diese Stufe gewönne das Datum nach
  # der Minutenregel (Mitternacht ist früher), und die einzige wirklich
  # gesagte Uhrzeit fiele aus der Rechnung.
  defp gewinnt?(%{abgesegnet?: true}, %{abgesegnet?: false}), do: true
  defp gewinnt?(%{abgesegnet?: false}, %{abgesegnet?: true}), do: false
  defp gewinnt?(%{genau?: true}, %{genau?: false}), do: true
  defp gewinnt?(%{genau?: false}, %{genau?: true}), do: false
  defp gewinnt?(%{minute: neu}, %{minute: alt}), do: neu < alt

  # Die Stellen, an denen sich zwei Zeitpunkt-Anker widersprechen.
  defp uneinige_zeitpunkte(reihe, anker) do
    index = index_nach_utterance(reihe)

    anker
    |> Enum.filter(&(art(&1) == :zeitpunkt and zahl_traegt?(&1)))
    |> Enum.group_by(&frueheste(&1, index))
    |> Enum.reject(fn {i, gruppe} -> is_nil(i) or length(gruppe) < 2 end)
    |> Enum.flat_map(fn {_i, gruppe} ->
      minuten = gruppe |> Enum.map(&(Map.get(&1, :minute) || Map.get(&1, :tagesminute))) |> Enum.uniq()

      if length(minuten) > 1 do
        wer = if Enum.any?(gruppe, &abgesegnet?/1), do: "der abgesegnete", else: "der frühere"

        [
          %{
            art: :zeitpunkte_uneinig,
            anker_id: gruppe |> Enum.map(&Map.get(&1, :anker_id)) |> Enum.join(", "),
            text:
              "An derselben Stelle stehen zwei verschiedene Zeitpunkte " <>
                "(#{Enum.join(minuten, " und ")} Minuten). Gerechnet wird mit #{wer}."
          }
        ]
      else
        []
      end
    end)
  end

  # Ein Zeitpunkt trägt eine Zahl, wenn er ein Datum ODER eine Uhrzeit
  # hergegeben hat. Nur auf `:minute` zu prüfen liesse den häufigsten Fall am
  # Spieltisch aus dem Befund fallen: zwei widersprechende Uhrzeiten an einer
  # Stelle wären still.
  defp zahl_traegt?(a),
    do: is_integer(Map.get(a, :minute)) or is_integer(Map.get(a, :tagesminute))

  # Eine Spanne gilt ab der SPÄTESTEN Stelle ihrer Menge: „wir sind zwei
  # Stunden marschiert" wird am Ende des Marsches gesagt, die Zeit ist
  # vergangen, bevor der Satz fällt.
  defp spannen_je_stelle(reihe, anker) do
    index = index_nach_utterance(reihe)

    for a <- anker,
        art(a) == :spanne,
        m = Map.get(a, :minuten),
        is_integer(m) and m > 0,
        i = spaeteste(a, index),
        not is_nil(i),
        reduce: %{} do
      acc -> Map.update(acc, i, m, &(&1 + m))
    end
  end

  defp index_nach_utterance(reihe),
    do: reihe |> Enum.with_index() |> Map.new(fn {s, i} -> {s.utterance_id, i} end)

  defp frueheste(a, index), do: a |> stellen_index(index) |> Enum.min(fn -> nil end)
  defp spaeteste(a, index), do: a |> stellen_index(index) |> Enum.max(fn -> nil end)

  defp stellen_index(a, index),
    do: a |> Map.get(:utterance_ids, []) |> Enum.map(&Map.get(index, &1)) |> Enum.reject(&is_nil/1)

  defp zweifel_je_stelle(anker) do
    for a <- anker,
        z = Map.get(a, :zweifel),
        is_binary(z) and z != "",
        u <- Map.get(a, :utterance_ids, []),
        into: %{},
        do: {u, z}
  end

  defp abgesegnete(anker) do
    for a <- anker,
        abgesegnet?(a),
        u <- Map.get(a, :utterance_ids, []),
        into: MapSet.new(),
        do: u
  end

  defp abgesegnet?(a) do
    case Map.get(a, :abgesegnet_am) do
      s when is_binary(s) -> s != ""
      _ -> false
    end
  end

  # ─── Befunde ────────────────────────────────────────────────────────

  @doc """
  Prüft die gebaute Linie und liefert Befunde — sie ändert nichts. Ein Befund
  ist eine Meldung für die Kurationsliste (#1243), keine Korrektur.
  """
  @spec pruefen([eintrag()], [stelle()], [anker()]) :: [map()]
  def pruefen(eintraege, reihe, anker) do
    ohne_ziel(anker, reihe) ++
      spannen_ueberlauf(eintraege, reihe, anker) ++
      uneinige_zeitpunkte(reihe, anker) ++
      zweifel(anker)
  end

  defp ohne_ziel(anker, reihe) do
    ids = MapSet.new(reihe, & &1.utterance_id)

    for a <- anker,
        art(a) == :ordnung,
        ziel = Map.get(a, :ziel),
        is_nil(ziel) or not MapSet.member?(ids, ziel) do
      %{
        art: :verschiebung_ohne_ziel,
        anker_id: Map.get(a, :anker_id),
        text: "Die Verschiebung nennt kein auflösbares Ziel — sie bleibt wirkungslos."
      }
    end
  end

  # Der Widerspruch, der im Plan Punkt 6 heisst: die genannten Dauern
  # zwischen zwei festen Punkten ergeben mehr Zeit, als zwischen ihnen liegt.
  # Gemeldet, nicht weggerechnet.
  defp spannen_ueberlauf(_eintraege, reihe, anker) do
    feste = feste_punkte(reihe, anker) |> Enum.sort_by(fn {i, _} -> i end)
    spannen = spannen_je_stelle(reihe, anker)

    feste
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{vi, %{minute: vm}}, {ni, %{minute: nm}}] ->
      summe = gelaufen(vi, ni, spannen)
      abstand = nm - vm

      if summe > abstand do
        [
          %{
            art: :spannen_ueberlauf,
            anker_id: nil,
            text:
              "Zwischen zwei Ankern liegen #{abstand} Minuten, die genannten Dauern ergeben " <>
                "#{summe}. Entweder ist eine Dauer falsch gelesen oder ein Anker sitzt falsch."
          }
        ]
      else
        []
      end
    end)
  end

  defp zweifel(anker) do
    for a <- anker,
        z = Map.get(a, :zweifel),
        is_binary(z) and z != "" do
      %{art: :zweifel, anker_id: Map.get(a, :anker_id), text: z}
    end
  end
end
