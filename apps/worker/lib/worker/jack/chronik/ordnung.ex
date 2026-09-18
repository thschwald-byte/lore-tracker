defmodule Worker.Jack.Chronik.Ordnung do
  @moduledoc """
  Die Reihenfolge der Chronik-Einträge (J7, #1211): aus den Bezügen, die Jack
  angibt, eine Ordnung rechnen — und Widersprüche **melden** statt sie
  wegzurechnen.

  **Warum das Modell nicht rechnet.** Ein Sprachmodell kann Tage nicht
  verlässlich addieren; die heutige Chronik belegt, wohin das führt (543 von
  544 Einträgen einer echten Kampagne auf demselben Tag, #1092). Es kann aber
  sagen, was vor, nach oder gleichzeitig mit etwas anderem geschah. Also
  urteilt Jack über die Beziehung, und dieses Modul rechnet daraus die
  Reihenfolge — dieselbe Arbeitsteilung wie seit #724, nur mit Einträgen statt
  Einzelfakten als Knoten.

  **Der Unterschied zum bestehenden Fixpunkt.** `Worker.Timeline.Graph` hat
  seit #724 eine Kahn-artige Auflösung, aber sie ist privat, kennt weder
  „gleichzeitig mit“ noch mehrere Vorgänger — und vor allem: sie löst einen
  Zyklus **still** auf, indem sie alle beteiligten Knoten auf `unknown` setzt.
  Für die Fakten-Chronik war das vertretbar (ein undatierter Fakt fällt aus
  der Anzeige). Hier wäre es die falsche Richtung: Ein Widerspruch in Jacks
  Bezügen ist kein Datenmangel, sondern ein Befund, den er korrigieren kann
  und soll. Deshalb `{:zyklus, ids}` statt eines stillen Rückfalls — die
  Durchsicht legt ihm genau diese Knoten vor.

  ## Die Bezüge

  Ein Eintrag trägt `zeit_bezug`, eine **Liste** von Maps mit `"art"` (seit
  dem Review vom 18.09.2026 — vorher genau eine Map, und „gleichzeitig mit A
  und nach B“ war nicht ausdrückbar; die Liste jetzt ist ein Feld, später
  wäre sie eine Migration über alle Einträge). Die leere Liste heisst
  „isoliert“. `bezuege/1` ist die eine Stelle, die beide Formen liest — eine
  gespeicherte Map aus der Zeit davor wird zur Ein-Element-Liste, ein
  `isoliert`-Element fällt weg. Jedes Element:

    * `"nach"` / `"vor"` mit `"ziel"` (eine Eintrags-ID) — eine Kante.
    * `"gleichzeitig_mit"` mit `"ziel"` — **keine** Kante, sondern eine
      Zusammenlegung: Beide Einträge bilden eine Klasse und stehen an
      derselben Stelle der Reihenfolge.
    * `"absolut"` mit `"zeit"` (der Ausdruck, den Elixir später datiert) oder
      `"isoliert"` — beides ohne Kante.

  „Gleichzeitig“ als Klasse statt als Kantenpaar ist der Punkt, an dem ein
  naiver Nachbau falsch würde: Zwei Kanten in beide Richtungen wären ein
  Zyklus, und die Ordnung meldete einen Widerspruch, wo Jack etwas völlig
  Zulässiges gesagt hat.

  ## Determinismus

  Bei Gleichstand entscheidet die Eintrags-ID, nicht die Eingabereihenfolge.
  Das ist keine Kosmetik: Zwei Worker derselben Kampagne bauen dieselbe
  Chronik, und ohne eine feste Tiebreak-Regel zeigten sie verschiedene
  Reihenfolgen — dieselbe Klasse, die #1092 für die Fakten-Chronik behoben
  hat (dort entschied vorher die Leseordnung einer Mnesia-Tabelle).

  ## Ehrliche Grenzen

  Ein Bezug auf einen **unbekannten** Eintrag ist kein Zyklus, sondern eine
  ins Leere zeigende Kante; sie wird verworfen und in `verwaist` gemeldet.
  Der Eintrag steht dann ohne Bezug in der Reihenfolge — das ist ehrlicher,
  als ihn wegen eines Tippfehlers ans Ende zu schieben.

  Die Ordnung ist eine **Reihenfolge, kein Datum**. Sie sagt nichts darüber,
  wie viel Zeit zwischen zwei Einträgen liegt; das entscheidet erst die
  Datierung an einem Anker.
  """

  @typedoc "Ein Eintrag, wie Jack ihn abgelegt hat — nur die Felder, die hier zählen."
  @type eintrag :: %{required(String.t()) => term()}

  @typedoc """
  Das Ergebnis: die Reihenfolge als Liste von Klassen (jede Klasse eine Liste
  von IDs, die gleichzeitig stattfanden), dazu die verworfenen Bezüge.
  """
  @type ergebnis :: %{reihenfolge: [[String.t()]], verwaist: [String.t()]}

  @doc """
  Rechnet die Reihenfolge. Liefert `{:ok, ergebnis}` oder `{:zyklus, ids}` mit
  den Einträgen, die sich im Kreis aufeinander beziehen.

  Die Reihenfolge ist eine Liste von **Klassen**: `[["a"], ["b", "c"], ["d"]]`
  heißt „erst a, dann b und c gleichzeitig, dann d“.
  """
  @spec ordne([eintrag()]) :: {:ok, ergebnis()} | {:zyklus, [String.t()]}
  def ordne(eintraege) when is_list(eintraege) do
    ids = MapSet.new(eintraege, &id/1)
    klassen = klassen_bilden(eintraege, ids)
    {kanten, verwaist} = kanten_bilden(eintraege, ids, klassen)

    case sortieren(klassen_liste(klassen), kanten) do
      {:ok, stufen} ->
        {:ok, %{reihenfolge: klassen_zu_ids(stufen, klassen), verwaist: Enum.sort(verwaist)}}

      {:zyklus, vertreter} ->
        {:zyklus, zyklus_ids(vertreter, klassen)}
    end
  end

  # ─── Klassen: „gleichzeitig mit" legt zusammen ──────────────────────

  # Union-Find, klein gehalten: eine Map id => Vertreter, iterativ verdichtet.
  # Der Vertreter ist die kleinste ID der Klasse — damit hängt die Ordnung
  # nicht daran, in welcher Reihenfolge die Einträge ankamen.
  defp klassen_bilden(eintraege, ids) do
    paare =
      for e <- eintraege,
          %{"art" => "gleichzeitig_mit", "ziel" => ziel} <- bezuege_von(e),
          MapSet.member?(ids, ziel),
          do: {id(e), ziel}

    Enum.reduce(paare, Map.new(ids, &{&1, &1}), fn {a, b}, acc ->
      va = vertreter(acc, a)
      vb = vertreter(acc, b)
      {klein, gross} = if va <= vb, do: {va, vb}, else: {vb, va}
      Map.new(acc, fn {k, v} -> {k, if(v == gross, do: klein, else: v)} end)
    end)
  end

  defp vertreter(map, id), do: Map.get(map, id, id)

  defp klassen_liste(klassen),
    do: klassen |> Map.values() |> Enum.uniq() |> Enum.sort()

  defp mitglieder(klassen, vertreter),
    do: for({k, v} <- klassen, v == vertreter, do: k) |> Enum.sort()

  # ─── Kanten: „vor" und „nach" ───────────────────────────────────────

  # Eine Kante {von, nach} heißt „von steht vor nach". Kanten innerhalb einer
  # Klasse (Jack sagt „gleichzeitig" UND „danach") fallen weg — sonst wäre die
  # Klasse ihr eigener Vorgänger und jede Gleichzeitigkeit ein Zyklus.
  defp kanten_bilden(eintraege, ids, klassen) do
    {kanten, verwaist} =
      for e <- eintraege,
          %{"art" => art, "ziel" => ziel} <- bezuege_von(e),
          art in ["nach", "vor"],
          reduce: {MapSet.new(), []} do
        {kanten, verwaist} ->
          if MapSet.member?(ids, ziel) do
            a = vertreter(klassen, id(e))
            b = vertreter(klassen, ziel)

            kante = if art == "nach", do: {b, a}, else: {a, b}

            if a == b, do: {kanten, verwaist}, else: {MapSet.put(kanten, kante), verwaist}
          else
            {kanten, [id(e) | verwaist]}
          end
      end

    {kanten, Enum.uniq(verwaist)}
  end

  # ─── Topologischer Sort (Kahn), deterministisch ─────────────────────

  defp sortieren(knoten, kanten) do
    eingang =
      Enum.reduce(kanten, Map.new(knoten, &{&1, 0}), fn {_von, nach}, acc ->
        Map.update(acc, nach, 1, &(&1 + 1))
      end)

    schritt(knoten, kanten, eingang, [])
  end

  defp schritt([], _kanten, _eingang, ausgabe), do: {:ok, Enum.reverse(ausgabe)}

  defp schritt(offen, kanten, eingang, ausgabe) do
    # Sortiert entnehmen: bei Gleichstand entscheidet die ID, nie die
    # Eingabereihenfolge (s. Moduledoc, Determinismus).
    frei = offen |> Enum.filter(&(Map.get(eingang, &1, 0) == 0)) |> Enum.sort()

    case frei do
      [] ->
        # Kein Knoten ohne Vorgänger, aber es sind welche übrig: Kreis. Gemeldet
        # wird nur der KERN — Knoten, die auf einem Kreis liegen —, nicht alles,
        # was dahinter hängt: ein Nachfolger des Kreises ist kein Widerspruch,
        # und Jack soll korrigieren, was falsch ist, nicht, was nur wartet. Mit
        # Bezugslisten (18.09.2026) gibt es mehr Kanten und damit mehr Anhang.
        {:zyklus, offen |> Enum.filter(&im_kreis?(&1, offen, kanten)) |> Enum.sort()}

      _ ->
        rest = offen -- frei

        eingang2 =
          Enum.reduce(kanten, eingang, fn {von, nach}, acc ->
            if von in frei, do: Map.update(acc, nach, 0, &max(&1 - 1, 0)), else: acc
          end)

        schritt(rest, kanten, eingang2, [frei | ausgabe])
    end
  end

  # Liegt `start` auf einem Kreis? Erreichbar von sich selbst, über Kanten
  # zwischen den noch offenen Knoten. Schlichte Maps statt MapSet, weil
  # Dialyzer ein MapSet, das durch eine eigene Rekursion gereicht wird, als
  # Opaque-Verstoss meldet — und ein `no_opaque`-Attribut hier nichts
  # erklärte, was eine Map nicht genauso kann.
  defp im_kreis?(start, offen, kanten) do
    offen = Map.new(offen, &{&1, true})
    nachfolger = fn n -> for {^n, m} <- kanten, Map.has_key?(offen, m), do: m end
    suche(nachfolger.(start), start, nachfolger, %{})
  end

  defp suche([], _ziel, _nachfolger, _gesehen), do: false

  defp suche([n | rest], ziel, nachfolger, gesehen) do
    cond do
      n == ziel -> true
      Map.has_key?(gesehen, n) -> suche(rest, ziel, nachfolger, gesehen)
      true -> suche(nachfolger.(n) ++ rest, ziel, nachfolger, Map.put(gesehen, n, true))
    end
  end

  # Die Ausgabe des Sorts ist eine Liste von Stufen, in denen mehrere Klassen
  # nebeneinander liegen können (beide ohne Vorgänger). Nach außen ist jede
  # Klasse eine eigene Stelle der Reihenfolge — Gleichzeitigkeit hat Jack
  # ausdrücklich gesagt, sie folgt nicht daraus, dass zwei Einträge zufällig
  # keinen Bezug tragen.
  defp klassen_zu_ids(stufen, klassen) do
    for stufe <- stufen, vertreter <- stufe, do: mitglieder(klassen, vertreter)
  end

  defp zyklus_ids(vertreter, klassen),
    do: vertreter |> Enum.flat_map(&mitglieder(klassen, &1)) |> Enum.sort()

  # ─── Zugriff ────────────────────────────────────────────────────────

  defp id(%{"id" => id}) when is_binary(id), do: id

  defp bezuege_von(%{"zeit_bezug" => b}), do: bezuege(b)
  defp bezuege_von(_), do: []

  @doc """
  Die Bezüge eines Eintrags als Liste — die EINE Lesestelle für beide
  Formen: eine Liste bleibt, eine Map (Bestand von vor dem 18.09.2026) wird
  zur Ein-Element-Liste, `isoliert` fällt weg, alles andere (`nil`, Unfug)
  ist leer. Leere Liste heisst: ohne Bezug.
  """
  @spec bezuege(term()) :: [map()]
  def bezuege(liste) when is_list(liste),
    do: Enum.filter(liste, &(is_map(&1) and Map.get(&1, "art") not in [nil, "isoliert"]))

  def bezuege(%{} = einer), do: bezuege([einer])
  def bezuege(_), do: []
end
