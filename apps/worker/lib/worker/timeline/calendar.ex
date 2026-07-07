defmodule Worker.Timeline.Calendar do
  @moduledoc """
  Issue #724 (Zeitstrahl, Slice A): reines Kalender-Primitiv für den
  deterministischen Zeitstrahl. Kein Mnesia, kein LLM, keine Seiteneffekte —
  nur Datums-Arithmetik auf einem ganzzahligen **Tageszähler** (`day`).

  Das Kernprinzip des Features: das LLM liefert Anker + Offset + Präzision, und
  DIESES Modul rechnet daraus deterministisch ein Datum. Temporale Arithmetik
  gehört nicht ins Modell (dort unzuverlässig), sondern hierher (testbar,
  reproduzierbar).

  **Bewusst KEINE Schaltjahre** (v1): jeder Monat hat eine feste Länge, damit ist
  `year_length/1` konstant und `to_day`/`from_day` linear (`y * L + day_of_year`)
  — Round-Trips sind exakt und schnell. Die Daten sind intern konsistent, aber
  NICHT an den realen gregorianischen Kalender (echte Schaltjahre, Wochentage)
  gebunden; das ist für einen RPG-Zeitstrahl irrelevant, weil wir Daten immer nur
  durch denselben Kalender hin- und zurückrechnen. Fantasy-Kalender haben ohnehin
  keine Schaltjahre.

  `day = 0` ist der 1. Tag des 1. Monats im Jahr 0. Negative `day`-Werte liegen
  davor (Flashbacks „vor 10 Jahren" landen bei negativem Offset korrekt in der
  Vergangenheit).

  **Alias-Vorsicht:** Elixir hat ein eigenes `Calendar`-Modul — dieses hier immer
  voll qualifiziert als `Worker.Timeline.Calendar` ansprechen.
  """

  @enforce_keys [:months]
  defstruct months: nil, epoch_label: ""

  @type month :: %{name: String.t(), days: pos_integer()}
  @type t :: %__MODULE__{months: [month()], epoch_label: String.t()}
  @type ymd :: {integer(), pos_integer(), pos_integer()}
  @type precision :: :day | :month | :season | :year | :decade | :unknown

  # Gregorianischer Default: 12 Monate, feste Längen (Februar fix 28 — kein
  # Schaltjahr, siehe @moduledoc). Deutsche Monatsnamen.
  @gregorian_months [
    %{name: "Januar", days: 31},
    %{name: "Februar", days: 28},
    %{name: "März", days: 31},
    %{name: "April", days: 30},
    %{name: "Mai", days: 31},
    %{name: "Juni", days: 30},
    %{name: "Juli", days: 31},
    %{name: "August", days: 31},
    %{name: "September", days: 30},
    %{name: "Oktober", days: 31},
    %{name: "November", days: 30},
    %{name: "Dezember", days: 31}
  ]

  @season_names {"Winter", "Frühling", "Sommer", "Herbst"}

  @doc "Der Default-Kalender (gregorianisch, 12 Monate, ohne Schaltjahre)."
  @spec default() :: t()
  def default, do: %__MODULE__{months: @gregorian_months, epoch_label: ""}

  @doc """
  Baut einen Kalender aus einer JSON-freundlichen Map (String-Keys), wie sie in
  `worker_campaign_calendars.calendar_json` liegt. Fällt bei fehlender/kaputter
  Struktur auf `default/0` zurück (nie crashen — Boundary-Defense).
  """
  @spec from_json(map() | nil) :: t()
  def from_json(%{"months" => months} = m) when is_list(months) and months != [] do
    parsed =
      Enum.map(months, fn
        %{"name" => n, "days" => d} when is_binary(n) and is_integer(d) and d > 0 ->
          %{name: n, days: d}

        _ ->
          nil
      end)

    if Enum.any?(parsed, &is_nil/1) do
      default()
    else
      %__MODULE__{months: parsed, epoch_label: to_string(Map.get(m, "epoch_label", ""))}
    end
  end

  def from_json(_), do: default()

  @doc "Serialisiert einen Kalender in eine JSON-freundliche Map (String-Keys)."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{months: months, epoch_label: label}) do
    %{
      "months" => Enum.map(months, fn %{name: n, days: d} -> %{"name" => n, "days" => d} end),
      "epoch_label" => label
    }
  end

  @doc "Anzahl Monate pro Jahr."
  @spec months_per_year(t()) :: pos_integer()
  def months_per_year(%__MODULE__{months: months}), do: length(months)

  @doc "Tage im Jahr (konstant — keine Schaltjahre)."
  @spec year_length(t()) :: pos_integer()
  def year_length(%__MODULE__{months: months}), do: Enum.sum(Enum.map(months, & &1.days))

  @doc "Tage im (1-basierten) Monat."
  @spec days_in_month(t(), pos_integer()) :: pos_integer()
  def days_in_month(%__MODULE__{months: months}, month) when month >= 1 do
    case Enum.at(months, month - 1) do
      %{days: d} -> d
      _ -> raise ArgumentError, "month #{month} out of range"
    end
  end

  @doc """
  `{year, month, day}` → ganzzahliger Tageszähler. Linear dank fester
  Jahreslänge; funktioniert für negative Jahre (vor der Epoche).
  """
  @spec to_day(t(), ymd()) :: integer()
  def to_day(%__MODULE__{} = cal, {y, m, d}) when m >= 1 and d >= 1 do
    y * year_length(cal) + day_of_year_offset(cal, m, d)
  end

  # Tage vom Jahresanfang bis zu (m, d), 0-basiert: Summe der vollen Vormonate
  # + (d - 1).
  defp day_of_year_offset(%__MODULE__{months: months}, m, d) do
    before = months |> Enum.take(m - 1) |> Enum.map(& &1.days) |> Enum.sum()
    before + (d - 1)
  end

  @doc "Tageszähler → `{year, month, day}` (Inverse von `to_day/2`)."
  @spec from_day(t(), integer()) :: ymd()
  def from_day(%__MODULE__{} = cal, day) when is_integer(day) do
    l = year_length(cal)
    y = Integer.floor_div(day, l)
    walk_months(cal, day - y * l, y, 1)
  end

  defp walk_months(cal, rem_days, y, m) do
    dim = days_in_month(cal, m)

    if rem_days >= dim do
      walk_months(cal, rem_days - dim, y, m + 1)
    else
      {y, m, rem_days + 1}
    end
  end

  @doc """
  Verschiebt ein Datum um ein Offset. `:day`/`:week` rechnen über den
  Tageszähler; `:month`/`:year` sind kalender-bewusst (Monats-/Jahres-Überlauf,
  Tag wird auf die Monatslänge geklemmt, z.B. 31. Jan + 1 Monat → 28. Feb).
  """
  @spec shift(t(), ymd(), integer(), :day | :week | :month | :year) :: ymd()
  def shift(%__MODULE__{} = cal, {_, _, _} = ymd, value, unit) when is_integer(value) do
    case unit do
      :day -> from_day(cal, to_day(cal, ymd) + value)
      :week -> from_day(cal, to_day(cal, ymd) + value * 7)
      :month -> shift_months(cal, ymd, value)
      :year -> shift_months(cal, ymd, value * months_per_year(cal))
    end
  end

  defp shift_months(cal, {y, m, d}, delta_months) do
    mpy = months_per_year(cal)
    total = y * mpy + (m - 1) + delta_months
    y2 = Integer.floor_div(total, mpy)
    m2 = total - y2 * mpy + 1
    d2 = min(d, days_in_month(cal, m2))
    {y2, m2, d2}
  end

  @doc """
  Formatiert einen Tageszähler je nach Präzision als Anzeige-String.

  - `:day` → „15. Januar 1888"
  - `:month` → „Januar 1888"
  - `:season` → „Frühling 1888" (nur bei 12-Monats-Kalendern; sonst wie `:year`)
  - `:year` → „1888"
  - `:decade` → „1880er"
  - `:unknown`/sonst → „unbestimmt"

  `epoch_label` wird, falls gesetzt, an Datums-/Jahresangaben angehängt.
  """
  @spec format(t(), integer() | nil, precision()) :: String.t()
  def format(_cal, nil, _precision), do: "unbestimmt"

  def format(%__MODULE__{} = cal, day, precision) when is_integer(day) do
    {y, m, d} = from_day(cal, day)

    case precision do
      :day -> "#{d}. #{month_name(cal, m)} #{with_epoch(cal, y)}"
      :month -> "#{month_name(cal, m)} #{with_epoch(cal, y)}"
      :season -> season_display(cal, m, y)
      :year -> with_epoch(cal, y)
      :decade -> "#{Integer.floor_div(y, 10) * 10}er"
      _ -> "unbestimmt"
    end
  end

  defp month_name(%__MODULE__{months: months}, m), do: Enum.at(months, m - 1).name

  defp with_epoch(%__MODULE__{epoch_label: ""}, y), do: Integer.to_string(y)
  defp with_epoch(%__MODULE__{epoch_label: label}, y), do: "#{y} #{label}"

  # Jahreszeit nur bei 12-Monats-Kalendern sinnvoll (Nordhalbkugel-Konvention);
  # sonst gibt es keine kanonische Season → reiner Jahr-Fallback.
  defp season_display(%__MODULE__{} = cal, m, y) do
    if months_per_year(cal) == 12 do
      # Dez/Jan/Feb=Winter(0), Mär-Mai=Frühling(1), Jun-Aug=Sommer(2), Sep-Nov=Herbst(3)
      "#{elem(@season_names, div(rem(m, 12), 3))} #{with_epoch(cal, y)}"
    else
      with_epoch(cal, y)
    end
  end

  @doc """
  Parst einen Datums-String (GM-Eingabe oder im Transkript genanntes absolutes
  Datum) zu `{year, month, day}`. Best-effort, deutsche + ISO-Formen:

  - `"1888-04-15"` (ISO)
  - `"15.04.1888"` / `"15.4.1888"`
  - `"15. Januar 1888"` (Monatsname aus dem Kalender)
  - `"1888"` (nur Jahr → 1. Tag des 1. Monats)

  Nicht parsebar → `:error` (der Resolver degradiert das dann zu `unknown`, statt
  ein falsches Datum zu erfinden).
  """
  @spec parse(t(), String.t()) :: {:ok, ymd()} | :error
  def parse(%__MODULE__{} = cal, str) when is_binary(str) do
    s = String.trim(str)

    cond do
      m = Regex.run(~r/^(-?\d+)-(\d{1,2})-(\d{1,2})$/, s) -> from_iso(cal, m)
      m = Regex.run(~r/^(\d{1,2})\.\s*(\d{1,2})\.\s*(-?\d+)$/, s) -> from_dmy(cal, m)
      m = Regex.run(~r/^(\d{1,2})\.\s*([\p{L}]+)\s+(-?\d+)$/u, s) -> from_named(cal, m)
      m = Regex.run(~r/^(-?\d+)$/, s) -> {:ok, {String.to_integer(Enum.at(m, 1)), 1, 1}}
      true -> :error
    end
  end

  defp from_iso(cal, [_, y, mo, d]),
    do: ok_ymd(cal, String.to_integer(y), String.to_integer(mo), String.to_integer(d))

  defp from_dmy(cal, [_, d, mo, y]),
    do: ok_ymd(cal, String.to_integer(y), String.to_integer(mo), String.to_integer(d))

  defp from_named(cal, [_, d, name, y]) do
    case month_index(cal, name) do
      nil -> :error
      mo -> ok_ymd(cal, String.to_integer(y), mo, String.to_integer(d))
    end
  end

  defp month_index(%__MODULE__{months: months}, name) do
    down = String.downcase(name)

    Enum.find_index(months, fn %{name: n} -> String.downcase(n) == down end)
    |> case do
      nil -> nil
      i -> i + 1
    end
  end

  # Validiert Monat/Tag gegen den Kalender; ungültig → :error (kein Silent-Clamp
  # beim Parsen — nur echte Daten durchlassen).
  defp ok_ymd(%__MODULE__{} = cal, y, m, d) do
    if m >= 1 and m <= months_per_year(cal) and d >= 1 and d <= days_in_month(cal, m) do
      {:ok, {y, m, d}}
    else
      :error
    end
  end
end
