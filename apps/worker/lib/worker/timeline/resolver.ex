defmodule Worker.Timeline.Resolver do
  @moduledoc """
  Issue #724 (Zeitstrahl, Slice A): löst EINEN Fakt zu `{in_game_day, precision,
  display, anchor_status}` auf. Pur — Kalender + Session-Anker + bereits
  aufgelöste Event-Ziele werden reingereicht.

  Anker-Typen (`fact["time_anchor"]`):
  - `"absolute"` — `time_absolute` wird via `Calendar.parse` geparst.
  - `"session"` — relativ zum In-Game-Datum der Session (`session_anchor_day`) +
    Offset.
  - `"event:<id>"` — relativ zu einem anderen Fakt (dessen Tag aus
    `resolved_days` kommt; die Zuordnung Ausdruck→ID macht `Worker.Timeline.Graph`).
  - `nil`/`"unknown"`/sonst — ein Präsens-Fakt ohne explizites Datum sitzt am
    Session-Datum; alles andere ist `unknown` (kein erfundenes Datum — das ist
    das Sicherheitsventil, #686).

  **Konservativ:** was sich nicht sauber auflösen lässt (Parse-Fehler,
  unauflösbares Offset, fehlendes Event-Ziel, fehlender Anker), wird `unknown`
  (`in_game_day: nil`) — es fließt dann nicht in den Zeitstrahl, sondern in die
  Review-Queue, statt falsch datiert zu werden.
  """

  alias Worker.Timeline.Calendar

  # Präzision fein → grob. Der Index dient dem „coarser"-Vergleich.
  @precision_rank %{day: 0, month: 1, season: 2, year: 3, decade: 4, unknown: 5}

  @type resolved :: %{
          in_game_day: integer() | nil,
          precision: Calendar.precision(),
          display: String.t(),
          anchor_status: :resolved | :unknown
        }

  @doc """
  Löst einen Fakt auf. `resolved_days` ist eine Map `fact_id => in_game_day` der
  bereits aufgelösten (Event-Referenz-)Ziele.
  """
  @spec resolve_one(
          map(),
          Calendar.t(),
          integer() | nil,
          %{optional(String.t()) => integer()},
          Calendar.precision() | nil
        ) :: resolved()
  def resolve_one(
        fact,
        %Calendar{} = cal,
        session_anchor_day,
        resolved_days \\ %{},
        anchor_precision \\ nil
      )
      when is_map(fact) do
    anchor = fact["time_anchor"]
    offset = parse_offset(fact["time_offset"])
    stated = to_precision(fact["precision"])
    # Issue #724 (Slice E): Fällt kein strukturiertes `time_absolute` an, dient
    # das (schon von #676/#729 gefüllte) `in_game_date` als impliziter absoluter
    # Datums-String. So funktioniert der Zeitstrahl mit der HEUTIGEN Extraktion;
    # sobald Slice D `time_anchor`/`time_offset` liefert, haben die Vorrang.
    absolute = blank_to_nil(fact["time_absolute"]) || blank_to_nil(fact["in_game_date"])

    cond do
      offset == :bad ->
        unknown()

      anchor == "absolute" or (is_nil(anchor) and absolute) ->
        resolve_absolute(cal, absolute, stated, offset)

      is_binary(anchor) and String.starts_with?(anchor, "event:") ->
        resolve_event(cal, anchor, offset, stated, resolved_days)

      anchor == "session" ->
        resolve_from_anchor(cal, session_anchor_day, offset, stated, anchor_precision)

      is_integer(session_anchor_day) and (fact["narration_time"] == "present" or offset != nil) ->
        # Kein expliziter Anker, aber relativ zur Session interpretierbar:
        # Präsens-Fakt → sitzt am Session-Datum; Fakt mit Offset („vor 10
        # Jahren", „in 100 Jahren") → relativ zur Session-Gegenwart.
        resolve_from_anchor(cal, session_anchor_day, offset, stated, anchor_precision)

      true ->
        unknown()
    end
  end

  # ─── Anker-Auflösungen ───────────────────────────────────────────────

  defp resolve_absolute(_cal, nil, _stated, _offset), do: unknown()

  defp resolve_absolute(cal, str, stated, offset) do
    case Calendar.parse(cal, str) do
      {:ok, ymd} ->
        # Ohne explizit angegebene Präzision aus dem Roh-String ableiten (bare
        # Jahr → :year statt fälschlich :day), damit „1888" nicht als „1. Januar
        # 1888" gerendert wird.
        base = if stated == :unknown, do: infer_precision(cal, str), else: stated

        ymd
        |> maybe_shift(cal, offset)
        |> resolved_from_ymd(cal, effective_precision(base, offset))

      :error ->
        unknown()
    end
  end

  @doc """
  Issue #1092: leitet die Genauigkeit eines Datums-Strings ab — „2081" ist ein
  Jahr, „2081-03" ein Monat, „24.12.2011" ein Tag.

  Public seit #1092, weil der Session-Anker-Fold (`Materializer.Apply1`)
  dieselbe Ableitung braucht: ohne die mitgeführte Präzision erbt jeder Fakt am
  Anker eine Taggenauigkeit, die niemand angegeben hat.

  **Seit #1068 kommt die Antwort aus `Worker.Timeline.Parser`.** Das frühere
  Dreizeiler-Muster kannte nur „blanke Zahl" und „Zahl-Zahl" und stufte alles
  andere als `:day` ein — auch „Herbst 2040" und „die frühen 2000er", die der
  Parser inzwischen auflöst. Damit wäre die #1092-Korrektur durch die Hintertür
  wieder ausgehebelt gewesen: der Anker hätte ein saisongenaues Datum als
  taggenau gespeichert.

  Der Kalender ist nötig, weil die Präzision aus der **Länge** des geparsten
  Intervalls folgt und Monatslängen kalenderabhängig sind. Erkennt der Parser
  nichts, bleibt es beim alten Verhalten (`:day`) — ein Datums-String, den
  niemand versteht, wird nicht durch Raten besser.
  """
  @spec infer_precision(Calendar.t(), String.t()) :: Calendar.precision()
  def infer_precision(%Calendar{} = cal, str) when is_binary(str) do
    case Worker.Timeline.Parser.parse(cal, str) do
      {:ok, %{typ: :date, praezision: p}} when p != :unknown -> p
      _ -> :day
    end
  end

  def infer_precision(_cal, _str), do: :day

  defp resolve_from_anchor(cal, anchor_day, offset, stated, anchor_precision \\ nil)

  defp resolve_from_anchor(_cal, nil, _offset, _stated, _anchor_precision), do: unknown()

  defp resolve_from_anchor(cal, anchor_day, offset, stated, anchor_precision)
       when is_integer(anchor_day) do
    # Issue #1092: ein Fakt kann nie genauer sein als der Anker, an dem er
    # hängt. `Calendar.parse/2` macht aus einem GM-„2081" still den 1. Januar
    # 2081 — ohne diese Grenze erschiene jeder Präsens-Fakt der Session
    # taggenau auf einem Tag, den niemand genannt hat.
    #
    # `:unknown` ist hier KEINE Grenze: Anker vor der Migration tragen keine
    # Präzision, und weil `:unknown` den gröbsten Rang hat, würde ein
    # `coarser/2` darauf jeden Fakt auf „unbestimmt" ziehen — aus fehlender
    # Information würde so eine Aussage.
    precision =
      case to_precision(anchor_precision) do
        :unknown -> effective_precision(stated, offset)
        anchor_p -> coarser(effective_precision(stated, offset), anchor_p)
      end

    cal
    |> Calendar.from_day(anchor_day)
    |> maybe_shift(cal, offset)
    |> resolved_from_ymd(cal, precision)
  end

  defp resolve_event(cal, "event:" <> ref, offset, stated, resolved_days) do
    case Map.get(resolved_days, ref) do
      # Kein Anker-Präzisions-Erbe: die Genauigkeit stammt hier vom Ziel-Fakt,
      # nicht vom Session-Anker.
      day when is_integer(day) -> resolve_from_anchor(cal, day, offset, stated)
      _ -> unknown()
    end
  end

  # ─── Offset ──────────────────────────────────────────────────────────

  # nil → kein Offset; {value, unit} → geparst; :bad → vorhanden aber
  # unauflösbar (konservativ → unknown).
  defp parse_offset(nil), do: nil
  defp parse_offset(%{"value" => v, "unit" => u}), do: build_offset(v, u)
  defp parse_offset(_), do: :bad

  defp build_offset(v, u) when is_integer(v) do
    case unit_atom(u) do
      nil -> :bad
      unit -> {v, unit}
    end
  end

  defp build_offset(v, u) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> build_offset(n, u)
      _ -> :bad
    end
  end

  defp build_offset(_, _), do: :bad

  defp unit_atom(u) when is_binary(u) do
    case String.downcase(u) do
      x when x in ["day", "days", "tag", "tage"] -> :day
      x when x in ["week", "weeks", "woche", "wochen"] -> :week
      x when x in ["month", "months", "monat", "monate"] -> :month
      x when x in ["year", "years", "jahr", "jahre"] -> :year
      _ -> nil
    end
  end

  defp unit_atom(_), do: nil

  defp maybe_shift(ymd, _cal, nil), do: ymd
  defp maybe_shift(ymd, cal, {value, unit}), do: Calendar.shift(cal, ymd, value, unit)

  # ─── Präzision ───────────────────────────────────────────────────────

  @doc false
  @spec to_precision(term()) :: Calendar.precision()
  def to_precision(p) when is_binary(p) do
    case p do
      "day" -> :day
      "month" -> :month
      "season" -> :season
      "year" -> :year
      "decade" -> :decade
      _ -> :unknown
    end
  end

  def to_precision(p) when p in [:day, :month, :season, :year, :decade, :unknown], do: p
  def to_precision(_), do: :unknown

  @doc """
  Issue #1092: Rang einer Präzision, fein → grob (`:day` = 0 … `:unknown` = 5).
  Public, weil der Epos-Kapitel-Kopf (`Pipeline.Render.chapter_header/3`) die
  gröbste Präzision seiner Einträge braucht — er spannt über alle und darf
  nicht genauer aussehen als sein ungenauester Bestandteil.
  """
  @spec precision_rank(Calendar.precision()) :: non_neg_integer()
  def precision_rank(p), do: Map.get(@precision_rank, p, 5)

  # Effektive Präzision = die gröbere aus (angegebener Präzision, vom Offset
  # implizierter Präzision). Nicht-angegeben (`:unknown`) fällt auf die
  # Auflösungs-Granularität `:day` zurück, damit ein aufgelöster Tag nicht
  # fälschlich „unbestimmt" angezeigt wird.
  @doc false
  def effective_precision(stated, offset) do
    base = if stated == :unknown, do: :day, else: stated
    coarser(base, offset_precision(offset))
  end

  defp offset_precision(nil), do: :day
  defp offset_precision({_v, :day}), do: :day
  defp offset_precision({_v, :week}), do: :day
  defp offset_precision({_v, :month}), do: :month
  defp offset_precision({_v, :year}), do: :year

  defp coarser(a, b), do: if(@precision_rank[a] >= @precision_rank[b], do: a, else: b)

  # ─── Ergebnis-Konstruktoren ──────────────────────────────────────────

  defp resolved_from_ymd(ymd, cal, precision) do
    day = Calendar.to_day(cal, ymd)

    %{
      in_game_day: day,
      precision: precision,
      display: Calendar.format(cal, day, precision),
      anchor_status: :resolved
    }
  end

  defp unknown,
    do: %{in_game_day: nil, precision: :unknown, display: "unbestimmt", anchor_status: :unknown}

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil
end
