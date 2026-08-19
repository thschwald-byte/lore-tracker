defmodule Worker.Timeline.Parser do
  @moduledoc """
  Issue #1068 (Etappe E2 des Plans an #1069): parst einen **Zeitausdruck** zu
  einem typisierten Intervall. Pur — kein Mnesia, kein LLM.

  ## Warum ein Intervall statt eines Datums

  Am Spieltisch werden Zeitangaben fast nie exakt gesagt. Bis hierher wurde
  jede in `Calendar.parse/2` durch vier exakte Muster gepresst; was nicht
  passte, fiel auf `:error`, und ein blankes Jahr wurde still zum 1. Januar.
  Aus „in den frühen 2000ern" wurde so ein taggenaues Datum **ohne jeden
  Unschärfe-Vermerk** — die Aussage wurde beim Speichern schärfer als sie war.

  Alle unscharfen Formen sind dasselbe: ein Intervall.

      24. Dezember 2011   von 2011-12-24  bis 2011-12-24    (Länge 1 = exakt)
      2011                von 2011-01-01  bis 2011-12-31
      Herbst 2040         von 2040-09-01  bis 2040-11-30
      von 2001 bis 2009   von 2001-01-01  bis 2009-12-31
      ab 2000             von 2000-01-01  bis offen
      vor 2080            von offen       bis 2079-12-31

  Die Präzision ergibt sich damit aus der Länge und muss nicht separat geraten
  werden.

  ## Warum zuerst der Typ

  Das Feld unterscheidet seit TIMEX3 (TimeML) vier Typen, und **drei davon
  gehören nicht auf einen Zeitstrahl**:

      :date       Kalenderdatum, Tag oder gröber      → Zeitstrahl
      :time       feiner als ein Tag                  → Tageszähler kann es nicht
      :duration   eine Länge (sechs Jahre lang)       → ist kein Punkt
      :set        wiederkehrend (jeden Freitag)       → ist kein Punkt

  Ohne diese Unterscheidung bleibt jede Parser-Erweiterung ein Ratespiel: „50
  Jahre" und „2050" sehen als String ähnlich harmlos aus. Eine Dauer wie
  „Trolle werden 50 Jahre alt" darf niemals als Jahr 50 auf dem Zeitstrahl
  landen — dass das bisher nicht passierte, lag daran, dass das Modell dort
  zufällig kein Datum setzte, nicht an einer Schranke.

  **Die Reihenfolge der Erkennung ist deshalb Teil des Vertrags**: Dauer,
  Uhrzeit und vage Ausdrücke werden VOR den Datums-Mustern geprüft. Sonst
  frisst `^(-?\\d+)$` die „50" aus „50 Jahre alt".

  ## Eine Dauer ist keine Position, aber ein Hinweis

  `:duration` fällt aus dem Zeitstrahl — eine Länge hat keinen Ort. Sie ist
  deshalb aber nicht wertlos: „ihr seid **für die Woche** mein Team" sagt
  etwas darüber, über welche Spanne sich die Handlung erstreckt, und genau
  solche Ausdrücke sind der Rohstoff für den Zeitrahmen aus #1069.

  Erkannte Dauern tragen deshalb ihre gemessene Länge als
  `laenge: {menge, einheit}` mit. Wer den Zeitrahmen einer Session ableitet,
  muss den Ausdruck damit nicht ein zweites Mal parsen — und die Information
  geht nicht verloren, nur weil sie für die Chronik unbrauchbar ist.

  ## Was NICHT aufgelöst wird

  `damals`, `früher`, `vor langer Zeit` ergeben `:vage` mit offenem Intervall —
  sie sind eine Aussage über Unbestimmtheit, kein Datum. `am selben Tag`,
  `danach`, `tags darauf` sind ankerrelativ und gehören nicht hierher, sondern
  an `time_offset` gegen den Session-Anker (#1069).
  """

  alias Worker.Timeline.Calendar

  @typedoc "TIMEX3-Typ plus `:vage` für erkannt-aber-unauflösbar."
  @type typ :: :date | :time | :duration | :set | :vage

  @typedoc """
  `von`/`bis` sind inklusive Grenzen als Tageszähler; `nil` heisst **offen**
  („ab 2000" hat kein Ende). `praezision` folgt aus der Länge.

  `laenge` trägt bei `:duration` die gemessene Spanne als `{menge, einheit}` —
  s. „Eine Dauer ist keine Position, aber ein Hinweis" im Moduldoc.
  """
  @type intervall :: %{
          typ: typ(),
          von: integer() | nil,
          bis: integer() | nil,
          praezision: Calendar.precision(),
          roh: String.t(),
          laenge: {pos_integer(), atom()} | nil
        }

  # ─── D1: Jahrzehnt-Drittel (Konvention, keine Wahrheit) ──────────────
  #
  # „Frühe 2000er" könnte bis 2003 oder bis 2004 gehen — beides ist vertretbar.
  # Entscheidend ist nur, dass es EINE Festlegung gibt, die überall gilt und
  # nicht pro Fundstelle neu diskutiert wird (Plan an #1069, Entscheidung D1).
  @drittel %{
    "früh" => {0, 3},
    "anfang" => {0, 3},
    "mitte" => {4, 6},
    "spät" => {7, 9},
    "ende" => {7, 9}
  }

  # Saison → Monatsspanne. Bewusst auf der Nordhalbkugel und am gregorianischen
  # Zwölfmonatsjahr orientiert; bei einem Fantasy-Kalender mit anderer
  # Monatszahl wird anteilig geviertelt (s. saison_monate/2).
  @saisons %{
    "winter" => 0,
    "frühling" => 1,
    "frühjahr" => 1,
    "sommer" => 2,
    "herbst" => 3
  }

  # Wortstämme, die eine DAUER markieren. Geprüft VOR allen Datums-Mustern.
  #
  # ZWEI Formen, weil echte Rede beide kennt (gemessen an den Ausdrücken aus
  # `seattle-bereinigt-1`, 2026-08-19):
  #
  #   mit Schlusswort:  „sechs Jahre lang", „50 Jahre alt", „zehn Jahre später"
  #   mit Vorwort:      „in den letzten 60 Jahren", „seit mehreren tausend
  #                     Jahren", „über 50 Jahre hinweg", „die nächsten 3 Tage"
  #
  # Die zweite Form ist die gefährlichere: ohne sie würde die Präfix-Toleranz
  # weiter unten aus „in den letzten 60 Jahren" ein „60 Jahren" machen und die
  # 60 als JAHRESZAHL lesen — 2000 Jahre daneben.
  # Reihenfolge ist bedeutsam: LÄNGERE Formen zuerst. Bei einer Alternation
  # gewinnt die erste passende — stünde `ein` vor `einen`, bliebe bei „einen
  # Monat" ein „en" übrig und die Menge fiele weg.
  @mengenwort "\\d+|einem|einen|einer|eines|eine|ein|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|zwanzig|dreissig|fünfzig|hundert|tausend|mehreren|etlichen|einigen|wenigen"
  @zeiteinheit "sekunden?|minuten?|stunden?|tage?n?|wochen?|monate?n?|jahre?n?"

  @dauer_muster ~r/\b(#{@mengenwort})\s+(#{@zeiteinheit})\b.{0,12}\b(lang|alt|dauer|später|zuvor|hindurch|her|hinweg)\b/iu

  # Vorwort-Form: ein Mengen-/Dauerkontext VOR der Zahl.
  # Die MENGE ist Pflicht, und das ist die Trennlinie zum blossen Ankerbezug:
  #
  #   „in den letzten 60 Jahren"        Menge 60  → DAUER
  #   „im Verlauf der kommenden Woche"  keine     → ankerrelativ (#1069)
  #
  # Beide ergeben kein Datum, aber sie sind verschiedene Dinge: die erste ist
  # eine Zeitspanne, die zweite zeigt auf einen Bezugspunkt, den erst der
  # Session-Anker liefert.
  # `seit`/`vor` stehen hier gefahrlos neben den Datums-Mustern, weil die
  # ZEITEINHEIT Pflicht ist: „seit 2019" trägt keine und bleibt ein Datum,
  # „seit mehreren tausend Jahren" trägt eine und ist eine Dauer.
  # Mehrere Mengenwörter hintereinander sind erlaubt („mehreren tausend").
  @dauer_vorwort ~r/\b(letzten?|nächsten?|kommenden?|vergangenen?|über|rund|etwa|gut|knapp|seit|vor|für\s+die|für\s+den|für\s+das)\s+(?:(?:#{@mengenwort})\s+)+(#{@zeiteinheit})\b/iu

  # „für die Woche", „für einen Monat" — eine Dauer, bei der ein ARTIKEL die
  # Stelle der Menge einnimmt. Gefunden an einem echten Fakt: Romeo wirbt die
  # Spieler an mit „ihr seid für die Woche mein Team". Das ist die Laufzeit
  # einer Abmachung, keine Datierung — es sagt, wie LANGE sie gilt, nicht wann
  # sie geschlossen wurde. Ohne diese Form landete der Ausdruck als
  # unverstandener Roh-String in der Chronik.
  @dauer_artikel ~r/\bfür\s+(?:eine?n?|die|den|das)\s+(?:#{@zeiteinheit})\b/iu

  # Uhrzeit-Marker: alles feiner als ein Tag.
  @zeit_muster ~r/(\b\d{1,2}[:.]\d{2}\s*uhr\b|\bum\s+\d{1,2}\s*uhr\b|\b(morgens?|vormittags?|mittags?|nachmittags?|abends?|nachts?|dämmerung|morgengrauen)\b|\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag)(morgen|mittag|nachmittag|abend|nacht)?\b)/iu

  # Wiederkehrend.
  @set_muster ~r/\b(jeden|jede|jedes|alle\s+\d+|täglich|wöchentlich|monatlich|jährlich|immer\s+(montags|dienstags|freitags))\b/iu

  # Unbestimmt-vergangen/zukünftig ohne jeden Ankerwert.
  @vage_muster ~r/\b(damals|früher|einst|vor\s+langer\s+zeit|irgendwann|seinerzeit|dereinst|später\s+einmal|anfang\s*\[)/iu

  # ANKERRELATIV: bezieht sich auf einen Bezugspunkt, den dieser Parser nicht
  # kennt („gestern", „vor etwas mehr als einem Jahr", „kommende Woche"). Das
  # gehört an `time_offset` gegen den Session-Anker — die Auflösung ist Sache
  # von #1069, nicht dieses Moduls. Hier zählt nur: es ist KEINE absolute
  # Position, also darf kein Datum daraus werden.
  # Die „vor X"-Form verlangt eine ZEITEINHEIT — sonst verschlingt sie „vor
  # 2080", das eine offene Datumsspanne ist und kein Ankerbezug. Auch das hat
  # ein Bestandstest gefangen, nicht ich.
  @ankerrelativ_muster ~r/\b(gestern|heute|morgen|vorgestern|übermorgen|vor\s+(?:etwa|etwas|rund|knapp|gut)?\s*(?:einem|einer|zwei|drei|\d+)\s+(?:#{@zeiteinheit})|kommenden?|nächsten?|letzten?|vergangenen?)\b/iu

  @doc """
  Parst einen Zeitausdruck. `{:ok, intervall}` oder `:error`, wenn der String
  keinerlei erkennbare Zeitangabe enthält.

  **`:error` heisst „nichts erkannt", nicht „ungültig".** Ein erkannter, aber
  nicht auf den Kalender abbildbarer Ausdruck (Dauer, Uhrzeit, vage) kommt als
  eigener Typ mit offenem Intervall zurück — der Aufrufer entscheidet, was er
  damit macht. Alles auf `:error` abzubilden würde die Information vernichten,
  DASS dort eine Zeitangabe stand.
  """
  @spec parse(Calendar.t(), String.t()) :: {:ok, intervall()} | :error
  def parse(%Calendar{} = cal, roh) when is_binary(roh) do
    s = roh |> String.trim() |> String.downcase()

    cond do
      s == "" -> :error
      # Reihenfolge ist Vertrag: Nicht-Datums-Typen zuerst, sonst frisst das
      # blanke-Jahr-Muster die Zahl aus „50 Jahre alt".
      Regex.match?(@set_muster, s) -> {:ok, offen(:set, roh)}
      Regex.match?(@dauer_muster, s) -> {:ok, offen(:duration, roh, spanne_von(s))}
      Regex.match?(@dauer_vorwort, s) -> {:ok, offen(:duration, roh, spanne_von(s))}
      Regex.match?(@dauer_artikel, s) -> {:ok, offen(:duration, roh, spanne_von(s))}
      Regex.match?(@ankerrelativ_muster, s) -> {:ok, offen(:vage, roh)}
      Regex.match?(@vage_muster, s) -> {:ok, offen(:vage, roh)}
      true -> parse_datum(cal, s, roh)
    end
  end

  def parse(_, _), do: :error

  # ─── Datums-Formen ───────────────────────────────────────────────────

  defp parse_datum(cal, s, roh) do
    # Uhrzeit wird NICHT sofort verworfen: „am 24. Dezember 2011 abends" trägt
    # beides. Erst versuchen wir den Datumsteil; nur wenn KEINER greift, ist es
    # eine reine Uhrzeit.
    #
    # Issue #1068 (nach dem Messlauf): probiert werden MEHRERE Lesarten
    # desselben Strings — der ganze Ausdruck, dann seine Teile. Echte Rede
    # liefert selten die kanonische Form. Gemessen an `seattle-bereinigt-1`:
    # von 16 extrahierten Zeitausdrücken war KEINER ein blosses „ab 2000",
    # sondern „ab dem Jahr 2000", „in den frühen 2000ern",
    # „Ende 2011, am 24. Dezember 2011".
    s
    |> lesarten()
    |> Enum.find_value(&formen(cal, &1))
    |> case do
      nil ->
        if Regex.match?(@zeit_muster, s), do: {:ok, offen(:time, roh)}, else: :error

      ergebnis ->
        # `laenge` gehört laut Typ zu JEDEM Intervall — bei einem Datum ist sie
        # `nil`. Ein Feld, das mal da ist und mal nicht, zwingt jeden Leser zu
        # `Map.get` statt Pattern-Match.
        {:ok, ergebnis |> Map.put(:roh, roh) |> Map.put_new(:laenge, nil)}
    end
  end

  defp formen(cal, s) do
    spanne(cal, s) || bereich(cal, s) || jahrzehnt(cal, s) || saison(cal, s) ||
      drittel_jahr(cal, s) || exakt(cal, s) || monat_jahr(cal, s) || jahr(cal, s)
  end

  # Lesarten eines Ausdrucks, von der wörtlichsten zur freiesten. Die
  # Reihenfolge ist bedeutsam: die erste, die greift, gewinnt.
  #
  #   1. der Ausdruck selbst
  #   2. ohne führende Füllwörter („in den frühen 2000ern" → „frühen 2000ern")
  #   3. seine durch Komma getrennten Teile, jeweils entfüllt — der SPEZIFISCHSTE
  #      zuerst. „Ende 2011, am 24. Dezember 2011" soll den Tag ergeben, nicht
  #      das Jahresdrittel; wer beides sagt, meint das Genauere.
  defp lesarten(s) do
    teile =
      s
      |> String.split(~r/[,;]/u)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      # Längere Teile zuerst: „am 24. Dezember 2011" schlägt „Ende 2011".
      |> Enum.sort_by(&(-String.length(&1)))

    ([s, entfuellt(s)] ++ Enum.flat_map(teile, &[&1, entfuellt(&1)]))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  # Führende Präpositionen und Artikel abschneiden, die keine Bedeutung tragen.
  #
  # `ab|seit|nach|vor|bis` bleiben STEHEN — sie sind die Aussage („vor 2080"
  # heisst etwas anderes als „2080"). Entfernt wird nur, was zwischen ihnen und
  # der Zahl steht („ab dem Jahr 2000" → „ab 2000").
  defp entfuellt(s) do
    s
    |> String.replace(~r/^(?:im|in|am|an|zu|zum|zur)\s+(?:dem|der|den|das)?\s*/u, "")
    |> String.replace(~r/\b(dem|der|den|des|das|die)\s+jahre?\s+/u, "")
    # „im Jahr 2070" → nach dem Präpositions-Strip bleibt „Jahr 2070" stehen.
    |> String.replace(~r/^jahre?\s+(?=-?\d)/u, "")
    |> String.replace(
      ~r/^(ab|seit|nach|vor|bis)\s+(?:dem|der|den|das|etwa|rund|circa|ca\.?)\s+/u,
      "\\1 "
    )
    |> String.trim()
  end

  # „ab 2000", „seit 2000", „nach 2019" → von … bis offen
  # „vor 2080", „bis 2080"              → von offen … bis
  defp spanne(cal, s) do
    cond do
      m = Regex.run(~r/^(?:ab|seit|nach)\s+(-?\d{1,5})$/u, s) ->
        j = int(m, 1)
        %{typ: :date, von: jahresbeginn(cal, j), bis: nil, praezision: :year}

      m = Regex.run(~r/^(?:vor|bis)\s+(-?\d{1,5})$/u, s) ->
        j = int(m, 1)
        %{typ: :date, von: nil, bis: jahresende(cal, j - 1), praezision: :year}

      true ->
        nil
    end
  end

  # „von 2001 bis 2009", „2001–2009", „2055 bis 2065"
  #
  # Der schlichte Bindestrich ist mehrdeutig: „2011-03" ist Monat/Jahr, kein
  # Bereich von 3 bis 2011. Deshalb gilt er nur als Bereichstrenner, wenn beide
  # Zahlen **gleich viele Stellen** haben. „bis" und der Gedankenstrich sind
  # eindeutig und brauchen die Bedingung nicht.
  defp bereich(cal, s) do
    m =
      Regex.run(~r/^(?:von\s+)?(-?\d{1,5})\s*(bis|[–—-])\s*(-?\d{1,5})$/u, s)

    with [_, a_s, trenner, b_s] <- m,
         true <- trenner != "-" or String.length(a_s) == String.length(b_s) do
      {a, b} = {String.to_integer(a_s), String.to_integer(b_s)}
      {a, b} = if a <= b, do: {a, b}, else: {b, a}
      %{typ: :date, von: jahresbeginn(cal, a), bis: jahresende(cal, b), praezision: :year}
    else
      _ -> nil
    end
  end

  # „die frühen 2000er", „Mitte der 2060er", „2010er"
  defp jahrzehnt(cal, s) do
    # `er[ns]?$` fängt die Flexion: „2000er", aber auch „2000ern" (Dativ, wie in
    # „in den frühen 2000ern" — die Form, die im echten Transkript stand).
    # `\w*` nach dem Drittel-Wort fängt „frühen"/„späten" statt nur „früh".
    # Das `\w*` für die Adjektiv-Flexion („frühen") gehört IN die Drittel-Gruppe,
    # nicht dahinter: freistehend frisst es gierig die Jahreszahl an. „2010er"
    # wurde damit zu Jahrzehnt 0 (`\w*` nahm „201", übrig blieb „0er") — 2000
    # Jahre daneben, und der Bestandstest hat es gefangen.
    m =
      Regex.run(
        ~r/^(?:die\s+|der\s+|den\s+)?(?:(früh|anfang|mitte|spät|ende)\w*\s+)?(?:der\s+)?(-?\d{1,4})er[ns]?$/u,
        s
      )

    if m do
      teil = Enum.at(m, 1)
      basis = int(m, 2)

      case Map.get(@drittel, teil || "") do
        {a, b} ->
          %{
            typ: :date,
            von: jahresbeginn(cal, basis + a),
            bis: jahresende(cal, basis + b),
            praezision: :year
          }

        nil ->
          %{
            typ: :date,
            von: jahresbeginn(cal, basis),
            bis: jahresende(cal, basis + 9),
            praezision: :decade
          }
      end
    end
  end

  # „Herbst 2040", „im Sommer 2040"
  defp saison(cal, s) do
    m = Regex.run(~r/^(?:im\s+)?(winter|frühling|frühjahr|sommer|herbst)\s+(-?\d{1,5})$/u, s)

    if m do
      idx = Map.fetch!(@saisons, Enum.at(m, 1))
      j = int(m, 2)
      {von_m, bis_m} = saison_monate(cal, idx)

      %{
        typ: :date,
        von: Calendar.to_day(cal, {j, von_m, 1}),
        bis: Calendar.to_day(cal, {j, bis_m, Calendar.days_in_month(cal, bis_m)}),
        praezision: :season
      }
    end
  end

  # „Anfang 2012", „Mitte 2012", „Ende 2012" — Jahres-Drittel, nicht Jahrzehnt.
  defp drittel_jahr(cal, s) do
    m = Regex.run(~r/^(anfang|mitte|ende|früh|spät)\s+(-?\d{1,5})$/u, s)

    if m do
      j = int(m, 2)
      n = Calendar.months_per_year(cal)
      {von_m, bis_m} = jahres_drittel(Enum.at(m, 1), n)

      %{
        typ: :date,
        von: Calendar.to_day(cal, {j, von_m, 1}),
        bis: Calendar.to_day(cal, {j, bis_m, Calendar.days_in_month(cal, bis_m)}),
        praezision: :month
      }
    end
  end

  # Die vier exakten Formen des Alt-Parsers — unverändert im Verhalten,
  # nur als Länge-1-Intervall statt als Punkt.
  defp exakt(cal, s) do
    ymd =
      cond do
        m = Regex.run(~r/^(-?\d+)-(\d{1,2})-(\d{1,2})$/, s) ->
          {int(m, 1), int(m, 2), int(m, 3)}

        m = Regex.run(~r/^(\d{1,2})\.\s*(\d{1,2})\.\s*(-?\d+)$/, s) ->
          {int(m, 3), int(m, 2), int(m, 1)}

        m = Regex.run(~r/^(\d{1,2})\.\s*([\p{L}]+)\s+(-?\d+)$/u, s) ->
          case monat_index(cal, Enum.at(m, 2)) do
            nil -> nil
            mo -> {int(m, 3), mo, int(m, 1)}
          end

        true ->
          nil
      end

    with {j, mo, t} <- ymd,
         true <- gueltig?(cal, mo, t) do
      tag = Calendar.to_day(cal, {j, mo, t})
      %{typ: :date, von: tag, bis: tag, praezision: :day}
    else
      _ -> nil
    end
  end

  # „2011-03", „März 2011"
  defp monat_jahr(cal, s) do
    m =
      Regex.run(~r/^(-?\d+)[-.\/](\d{1,2})$/, s) ||
        (Regex.run(~r/^([\p{L}]+)\s+(-?\d+)$/u, s) &&
           (fn [_, name, j] = mm ->
              case monat_index(cal, name) do
                nil -> nil
                mo -> [Enum.at(mm, 0), to_string(j), to_string(mo)]
              end
            end).(Regex.run(~r/^([\p{L}]+)\s+(-?\d+)$/u, s)))

    if m do
      {j, mo} = {int(m, 1), int(m, 2)}

      if mo >= 1 and mo <= Calendar.months_per_year(cal) do
        %{
          typ: :date,
          von: Calendar.to_day(cal, {j, mo, 1}),
          bis: Calendar.to_day(cal, {j, mo, Calendar.days_in_month(cal, mo)}),
          praezision: :month
        }
      end
    end
  end

  # Blankes Jahr → GANZES Jahr. Das ist die Kernkorrektur gegenüber
  # `Calendar.parse/2`, das hier still den 1. Januar zurückgab.
  defp jahr(cal, s) do
    if m = Regex.run(~r/^(-?\d{1,5})$/, s) do
      j = int(m, 1)
      %{typ: :date, von: jahresbeginn(cal, j), bis: jahresende(cal, j), praezision: :year}
    end
  end

  # ─── Helfer ──────────────────────────────────────────────────────────

  defp offen(typ, roh, laenge \\ nil),
    do: %{typ: typ, von: nil, bis: nil, praezision: :unknown, roh: roh, laenge: laenge}

  defp int(m, i), do: m |> Enum.at(i) |> String.to_integer()

  # Zahlwörter, wie sie am Tisch fallen. Der bestimmte Artikel zählt als EINS
  # („für die Woche" = eine Woche) — das ist die Lesart, die der Satz meint.
  @zahlwoerter %{
    "ein" => 1,
    "eine" => 1,
    "einen" => 1,
    "einem" => 1,
    "einer" => 1,
    "die" => 1,
    "der" => 1,
    "das" => 1,
    "den" => 1,
    "zwei" => 2,
    "drei" => 3,
    "vier" => 4,
    "fünf" => 5,
    "sechs" => 6,
    "sieben" => 7,
    "acht" => 8,
    "neun" => 9,
    "zehn" => 10,
    "zwanzig" => 20,
    "dreissig" => 30,
    "fünfzig" => 50,
    "hundert" => 100,
    "tausend" => 1000
  }

  @einheiten %{
    "sekunde" => :second,
    "minute" => :minute,
    "stunde" => :hour,
    "tag" => :day,
    "woche" => :week,
    "monat" => :month,
    "jahr" => :year
  }

  # Die Spanne einer erkannten Dauer: `{menge, einheit}` oder `nil`, wenn sich
  # keine eindeutige Menge findet („seit mehreren tausend Jahren" — das ist
  # keine Zahl, sondern eine Geste).
  defp spanne_von(s) do
    with [_, menge_roh, einheit_roh] <-
           Regex.run(~r/\b(#{@mengenwort}|die|der|das|den)\s+(#{@zeiteinheit})\b/iu, s),
         {:ok, menge} <- zu_menge(menge_roh),
         {:ok, einheit} <- zu_einheit(einheit_roh) do
      {menge, einheit}
    else
      _ -> nil
    end
  end

  defp zu_menge(roh) do
    d = String.downcase(roh)

    cond do
      Regex.match?(~r/^\d+$/, d) -> {:ok, String.to_integer(d)}
      Map.has_key?(@zahlwoerter, d) -> {:ok, Map.fetch!(@zahlwoerter, d)}
      true -> :keine
    end
  end

  # Über den PRÄFIX statt über einen Stamm-Strip: „Woche"/„Wochen" beginnen
  # beide mit „woch", und ein Strip von `(en|n|e)$` machte aus „Woche" ein
  # „woch", das in keiner Tabelle steht — die Länge fiel dann still weg.
  defp zu_einheit(roh) do
    d = String.downcase(roh)

    @einheiten
    |> Enum.find(fn {form, _} -> String.starts_with?(d, String.slice(form, 0..-2//1)) end)
    |> case do
      {_, einheit} -> {:ok, einheit}
      nil -> :keine
    end
  end

  defp jahresbeginn(cal, j), do: Calendar.to_day(cal, {j, 1, 1})

  defp jahresende(cal, j) do
    n = Calendar.months_per_year(cal)
    Calendar.to_day(cal, {j, n, Calendar.days_in_month(cal, n)})
  end

  defp gueltig?(cal, mo, t) do
    mo >= 1 and mo <= Calendar.months_per_year(cal) and t >= 1 and
      t <= Calendar.days_in_month(cal, mo)
  end

  defp monat_index(%Calendar{months: months}, name) do
    down = String.downcase(name)

    months
    |> Enum.find_index(fn %{name: n} -> String.downcase(n) == down end)
    |> case do
      nil -> nil
      i -> i + 1
    end
  end

  # Saison-Viertel des Jahres. Bei zwölf Monaten ergibt das die vertraute
  # Zuordnung (Winter = Dez–Feb wird zu Jan–Mär vereinfacht, weil ein
  # jahresübergreifendes Intervall hier nichts brächte: die Saison bezieht sich
  # immer auf das GENANNTE Jahr).
  defp saison_monate(cal, idx) do
    n = Calendar.months_per_year(cal)
    breite = max(div(n, 4), 1)
    von = min(idx * breite + 1, n)
    bis = min(von + breite - 1, n)
    {von, bis}
  end

  defp jahres_drittel(wort, n) do
    d = max(div(n, 3), 1)

    case wort do
      w when w in ["anfang", "früh"] -> {1, min(d, n)}
      "mitte" -> {min(d + 1, n), min(2 * d, n)}
      _ -> {min(2 * d + 1, n), n}
    end
  end
end
