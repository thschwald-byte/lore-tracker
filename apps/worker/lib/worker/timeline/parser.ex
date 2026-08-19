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
  """
  @type intervall :: %{
          typ: typ(),
          von: integer() | nil,
          bis: integer() | nil,
          praezision: Calendar.precision(),
          roh: String.t()
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
  @dauer_muster ~r/\b(\d+|ein|eine|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|zwanzig|dreissig|fünfzig|hundert)\s+(sekunden?|minuten?|stunden?|tage?n?|wochen?|monate?n?|jahre?n?)\b.{0,12}\b(lang|alt|dauer|später|zuvor|hindurch)\b/iu

  # Uhrzeit-Marker: alles feiner als ein Tag.
  @zeit_muster ~r/(\b\d{1,2}[:.]\d{2}\s*uhr\b|\bum\s+\d{1,2}\s*uhr\b|\b(morgens?|vormittags?|mittags?|nachmittags?|abends?|nachts?|dämmerung|morgengrauen)\b|\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag)(morgen|mittag|nachmittag|abend|nacht)?\b)/iu

  # Wiederkehrend.
  @set_muster ~r/\b(jeden|jede|jedes|alle\s+\d+|täglich|wöchentlich|monatlich|jährlich|immer\s+(montags|dienstags|freitags))\b/iu

  # Unbestimmt-vergangen/zukünftig ohne jeden Ankerwert.
  @vage_muster ~r/\b(damals|früher|einst|vor\s+langer\s+zeit|irgendwann|seinerzeit|dereinst|später\s+einmal)\b/iu

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
      Regex.match?(@dauer_muster, s) -> {:ok, offen(:duration, roh)}
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
    ergebnis =
      spanne(cal, s) || bereich(cal, s) || jahrzehnt(cal, s) || saison(cal, s) ||
        drittel_jahr(cal, s) || exakt(cal, s) || monat_jahr(cal, s) || jahr(cal, s)

    cond do
      ergebnis -> {:ok, Map.put(ergebnis, :roh, roh)}
      Regex.match?(@zeit_muster, s) -> {:ok, offen(:time, roh)}
      true -> :error
    end
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
    m =
      Regex.run(
        ~r/^(?:die\s+|der\s+)?(früh|anfang|mitte|spät|ende)?(?:en?\s+|\s+der\s+|\s+)?(-?\d{1,4})er$/u,
        s
      ) ||
        Regex.run(~r/^(früh|anfang|mitte|spät|ende)\s+der\s+(-?\d{1,4})er$/u, s)

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

  defp offen(typ, roh),
    do: %{typ: typ, von: nil, bis: nil, praezision: :unknown, roh: roh}

  defp int(m, i), do: m |> Enum.at(i) |> String.to_integer()

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
