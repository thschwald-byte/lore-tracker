defmodule Worker.Jack.Chronik.Datierung do
  @moduledoc """
  Aus der Reihenfolge ein Datum machen — soweit ein Anker es trägt
  (J7, #1211).

  **Die Arbeitsteilung.** Jack sagt, was wovor geschah
  (`Worker.Jack.Chronik.Ordnung`). Ein Datum entsteht daraus nur an den
  Stellen, an denen etwas Festes steht: ein im Spiel genannter Zeitpunkt
  (`zeit_bezug` der Art `absolut`) oder der In-Game-Anker der Sitzung, den
  der Spielleiter gesetzt hat. Von dort aus bekommt die Nachbarschaft ihren
  Tag — nicht durch Rechnen mit Abständen, die niemand genannt hat, sondern
  weil sie in der Reihenfolge daneben steht.

  **Was hier NICHT passiert: raten.** Der alte Pfad gab jedem Fakt ohne
  Zeitangabe den Tag des Session-Ankers; das Ergebnis waren 543 von 544
  Einträgen auf demselben Tag (#1092) — ein Zeitstrahl, der keiner war.
  Bleibt ein Eintrag ohne Anker in Reichweite, bleibt er **ohne Tag**. Er
  steht dann in der Reihenfolge, und die Anzeige zeigt kein Datum. Das ist
  die Kernentscheidung dieses Umbaus: lieber keine Angabe als eine
  gerechnete, die niemand nachprüfen kann.

  ## Wie weit ein Anker reicht

  Ein Anker datiert **seine eigene Stelle in der Reihenfolge**. Was davor
  oder danach steht, bekommt keinen eigenen Tag — wohl aber eine Schranke:
  Ein Eintrag zwischen zwei datierten Einträgen liegt zwischen deren Tagen.
  Diese Schranke wird **nicht** in einen Tag umgerechnet; sie würde eine
  Genauigkeit vortäuschen, die es nicht gibt. Sie begrenzt nur die
  Präzision: Ein Eintrag zwischen dem 3. und dem 5. Wintermond ist „um den
  4."; einer zwischen 1888 und 1889 ist „1888/89".

  **Die Präzision des Ankers ist die Untergrenze** (#1092): Ein Eintrag kann
  nie genauer sein als das, woran er hängt. Aus dem Anker „2081" darf kein
  taggenaues Datum werden.

  ## Ehrliche Grenzen

  Die Spanne einer Phase (Beginn und Ende) wird hier **nicht** gerechnet.
  Dafür bräuchte es Tage an ihren einzelnen Fakten, und genau die gibt es
  nicht — das ist der Grund für diesen ganzen Umbau. Eine Phase bekommt den
  Tag ihrer Stelle in der Reihenfolge, sofern einer zu haben ist.

  Ein `absolut`-Ausdruck, den der Kalender nicht versteht, gilt als nicht
  vorhanden; der Ausdruck bleibt aber am Eintrag stehen (`in_game_date`), wie
  ihn Jack abgeschrieben hat. Verloren geht nichts, es wird nur nichts
  gerechnet.
  """

  alias Worker.Timeline.{Calendar, Resolver}

  @typedoc "Was ein Eintrag an Zeitangaben bekommt."
  @type datum :: %{
          in_game_day: integer() | nil,
          in_game_date: String.t() | nil,
          precision: String.t() | nil
        }

  @doc """
  Datiert die Einträge in ihrer Reihenfolge. `reihenfolge` sind die IDs in
  der Ordnung, `anker` der Session-Anker (`%{in_game_day:, precision:}` oder
  `nil`).

  Liefert eine Map `id => datum`. Einträge ohne erreichbaren Anker fehlen
  darin — sie bekommen keinen Tag, und das ist Absicht.
  """
  @spec datieren([map()], [String.t()], Calendar.t(), map() | nil) :: %{String.t() => datum()}
  def datieren(eintraege, reihenfolge, %Calendar{} = cal, anker) do
    nach_id = Map.new(eintraege, &{&1.id, &1})
    geordnet = for id <- reihenfolge, e = nach_id[id], do: e

    feste = feste_punkte(geordnet, cal, anker)

    geordnet
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {e, i}, acc ->
      case Map.get(feste, e.id) do
        nil -> zwischen(acc, e, i, geordnet, feste, cal)
        datum -> Map.put(acc, e.id, datum)
      end
    end)
  end

  # Die Einträge, deren Tag feststeht: ein im Spiel genannter Zeitpunkt, oder
  # — wenn keiner dasteht — der Anker der Sitzung für den ERSTEN Eintrag.
  #
  # Warum nur für den ersten: Der Session-Anker sagt „diese Sitzung spielt an
  # jenem Tag". Ihn auf jeden Eintrag zu legen, war der alte Fehler. Auf den
  # ersten gelegt, ist er ein Startpunkt, von dem aus die Reihenfolge zählt.
  defp feste_punkte(geordnet, cal, anker) do
    aus_absolut =
      for e <- geordnet,
          # Der erste absolute Bezug des Eintrags datiert ihn; ein zweiter
          # wäre ein Widerspruch, den die Datierung nicht entscheidet.
          %{"art" => "absolut", "zeit" => z} <- Enum.take(absolute(e), 1),
          {:ok, ymd} <- [Calendar.parse(cal, z)],
          into: %{} do
        {e.id,
         %{
           in_game_day: Calendar.to_day(cal, ymd),
           in_game_date: z,
           precision: prec(Resolver.infer_precision(cal, z))
         }}
      end

    case {aus_absolut, geordnet, anker} do
      {leer, [erster | _], %{in_game_day: tag}} when leer == %{} and is_integer(tag) ->
        %{
          erster.id => %{
            in_game_day: tag,
            in_game_date: Calendar.format(cal, tag, prec_atom(anker)),
            precision: prec(prec_atom(anker))
          }
        }

      _ ->
        aus_absolut
    end
  end

  # Ein Eintrag ohne eigenen Anker: Liegt er ZWISCHEN zwei datierten, bekommt
  # er deren Spanne als gröbere Angabe — keinen gerechneten Tag. Liegt er am
  # Rand, bleibt er ohne Datum.
  defp zwischen(acc, e, i, geordnet, feste, cal) do
    # Schrittweite ausdrücklich 1: Ein Eintrag am Rand erzeugt sonst eine
    # ABSTEIGENDE Range (`0..-1`, `n..n-1`), die Elixir als Schritt -1 liest
    # und bei jedem Aufruf laut bemängelt — bei hunderten Einträgen flutet
    # das das Log. Mit `//1` ist sie schlicht leer, und genau das ist gemeint.
    vor = letzter_fester(geordnet, feste, 0..(i - 1)//1)
    nach = erster_fester(geordnet, feste, (i + 1)..(length(geordnet) - 1)//1)

    case {vor, nach} do
      {%{in_game_day: a}, %{in_game_day: b}} when is_integer(a) and is_integer(b) and a <= b ->
        Map.put(acc, e.id, spanne(cal, a, b))

      _ ->
        acc
    end
  end

  defp absolute(e),
    do:
      e.zeit_bezug
      |> Worker.Jack.Chronik.Ordnung.bezuege()
      |> Enum.filter(&(&1["art"] == "absolut"))

  defp letzter_fester(geordnet, feste, bereich) do
    bereich
    |> Enum.reverse()
    |> Enum.find_value(fn i -> geordnet |> Enum.at(i) |> then(&Map.get(feste, &1.id)) end)
  end

  defp erster_fester(geordnet, feste, bereich),
    do:
      Enum.find_value(bereich, fn i -> geordnet |> Enum.at(i) |> then(&Map.get(feste, &1.id)) end)

  # Die Spanne zwischen zwei festen Punkten. Der Tag ist die Mitte — aber die
  # PRÄZISION sagt, wie weit sie trägt: Bei zwei Tagen Abstand ist sie
  # taggenau, bei Monaten nicht mehr. So entsteht keine Genauigkeit, die es
  # nicht gibt.
  defp spanne(_cal, a, b) do
    mitte = div(a + b, 2)
    weite = b - a

    %{
      in_game_day: mitte,
      in_game_date: nil,
      precision: precision_fuer(weite)
    }
  end

  # Bis zu zwei Tage Abstand ist die Mitte eindeutig oder trifft einen der
  # beiden Ränder — da trägt „taggenau". Darüber gibt es mehrere Kandidaten,
  # und die Angabe wäre eine Behauptung: dann lieber der Monat. Ab etwa einem
  # Vierteljahr ist auch der nicht mehr zu halten.
  defp precision_fuer(weite) when weite <= 2, do: "day"
  defp precision_fuer(weite) when weite <= 90, do: "month"
  defp precision_fuer(_), do: "year"

  # `Resolver.infer_precision/2` liefert immer ein Atom — eine Fallback-Klausel
  # dafür wäre toter Code, und Dialyzer sagt das auch (pattern_match_cov).
  defp prec(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp prec_atom(%{precision: p}) when is_atom(p) and not is_nil(p), do: p
  defp prec_atom(%{precision: p}) when is_binary(p), do: String.to_existing_atom(p)
  defp prec_atom(_), do: :day
end
