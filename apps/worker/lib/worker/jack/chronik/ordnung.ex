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

  ## Die drei Bezüge

  Ein Eintrag trägt `zeit_bezug`, eine Map mit `"art"`:

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
          %{"art" => "gleichzeitig_mit", "ziel" => ziel} <- [bezug(e)],
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
    Enum.reduce(eintraege, {MapSet.new(), []}, fn e, {kanten, verwaist} ->
      case bezug(e) do
        %{"art" => art, "ziel" => ziel} when art in ["nach", "vor"] ->
          if MapSet.member?(ids, ziel) do
            a = vertreter(klassen, id(e))
            b = vertreter(klassen, ziel)

            kante = if art == "nach", do: {b, a}, else: {a, b}

            if a == b, do: {kanten, verwaist}, else: {MapSet.put(kanten, kante), verwaist}
          else
            {kanten, [id(e) | verwaist]}
          end

        _ ->
          {kanten, verwaist}
      end
    end)
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
        # Kein Knoten ohne Vorgänger, aber es sind welche übrig: Kreis.
        {:zyklus, Enum.sort(offen)}

      _ ->
        rest = offen -- frei

        eingang2 =
          Enum.reduce(kanten, eingang, fn {von, nach}, acc ->
            if von in frei, do: Map.update(acc, nach, 0, &max(&1 - 1, 0)), else: acc
          end)

        schritt(rest, kanten, eingang2, [frei | ausgabe])
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

  defp bezug(%{"zeit_bezug" => %{} = b}), do: b
  defp bezug(_), do: %{}
end
