defmodule Worker.Jack.Lesen do
  @moduledoc """
  Die lesenden Werkzeuge: `bloecke`, `block`, `suche`, `weiter`, `cast` und
  `straenge`. Pur wie `Worker.Jack.Aussage`: Stand und Argumente hinein, neuer
  Stand und Ergebnis heraus.

  Beschreibungen und Antworttexte sind die des Spikes (`werkzeuge.ts`, Stand
  Lauf 6), einschließlich seiner Umschrift ohne Umlaute — sie sind Teil des
  gemessenen Verhaltens.

  Was gelesen wird, führt der Stand (`gelesen`, beim Sammeln zusätzlich
  `sammelnd`); daran prüft `fertig`, ob der Mitschnitt lückenlos angesehen
  wurde.

  **Beppo-Modus** (`Stand.beppo`): der Mitschnitt kommt in Portionen über
  `weiter`, seine Größe wird nirgends genannt. `bloecke` ist dann nicht in der
  Werkzeugliste (das entscheidet die Einbindung), und `block` nennt bei einer
  unbekannten Nummer keine Gesamtzahl.

  **Abweichungen vom Spike:**

    * `bloecke` mit `von > bis` oder einem Bereich ganz hinter dem Mitschnitt
      ist ein Fehler. Im Spike kam eine leere Antwort, und der Bereich zählte
      trotzdem als gelesen, weil die Lückenprüfung ihn umdrehte:
      `bloecke(1801, 0)` hätte den ganzen Mitschnitt als gelesen verbucht, ohne
      einen Block zu zeigen. Als gelesen gilt jetzt nur, was geliefert wurde,
      auf den Mitschnitt beschnitten.
    * Eine unbekannte Blocknummer, ein zu kurzer Suchbegriff und `weiter` nach
      dem Ende sind `{:error, …}` statt einer gewöhnlichen Antwort; der
      Wortlaut bleibt. Der dritte `weiter`-Aufruf nach dem Ende bricht den Lauf
      ab (`{:abbruch, …}`, Toms Regel).
    * In `suche` sind `ab` und `bis` die einzigen optionalen Felder: als
      Pflicht müsste Jack im Beppo-Modus die Größe des Mitschnitts kennen oder
      raten.
  """

  alias Worker.Jack.{Antwort, Beleg, Stand}

  @treffer_max 40
  @weiter_abbruch 3

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc """
  Die Werkzeuge dieses Moduls für einen Stand, zur Einbindung als
  `Worker.Agent.Werkzeug`: Name, Beschreibung, Parameter, gegebenenfalls
  `optional` und `wiederholung`, dazu `ausfuehren` (`fn stand, argumente ->
  {stand, ergebnis} end`). Fehlende Markierungen haben die Defaults von
  `Worker.Agent.Werkzeug.neu/1`. Welche Werkzeuge eine Phase bekommt,
  entscheidet die Einbindung.
  """
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "bloecke",
        beschreibung:
          "Liest einen Bereich des Mitschnitts. Spalten: Blocknummer, Sprecher, Text. " <>
            "von und bis sind Blocknummern, der Bereich ist einschliesslich. " <>
            "Der Mitschnitt hat die Bloecke 0 bis #{s.max_block}. " <>
            "Wie gross du den Bereich waehlst, entscheidest du.",
        parameter:
          objekt(%{
            "von" => nummer("erste Blocknummer"),
            "bis" => nummer("letzte Blocknummer")
          }),
        ausfuehren: &bloecke/2
      },
      %{
        name: "block",
        beschreibung: "Liefert einen einzelnen Block mit Nummer, Sprecher und Text.",
        parameter: objekt(%{"nummer" => %{"type" => "integer", "minimum" => 0}}),
        ausfuehren: &block/2
      },
      %{
        name: "suche",
        beschreibung:
          "Sucht einen Ausdruck im ganzen Mitschnitt und liefert die Fundstellen als " <>
            "Blocknummer, Sprecher und Textzeile. Gross-/Kleinschreibung ist egal. " <>
            "Damit findest du frueher Gesagtes, ohne alles erneut zu lesen: Namen, " <>
            "Gegenstaende, Orte, Rueckbezuege. Hoechstens 40 Fundstellen je Aufruf — " <>
            "kommen mehr, wird die Zahl genannt und du kannst genauer suchen.",
        parameter:
          objekt(%{
            "begriff" => %{
              "type" => "string",
              "description" => "Wortfolge, die im Blocktext vorkommt"
            },
            "ab" => nummer("erst ab dieser Blocknummer suchen"),
            "bis" => nummer("nur bis zu dieser Blocknummer suchen")
          }),
        optional: ["ab", "bis"],
        ausfuehren: &suche/2
      },
      %{
        name: "weiter",
        beschreibung:
          "Gibt dir den naechsten Abschnitt des Mitschnitts — Blocknummer, Sprecher, " <>
            "Text. Arbeite ihn ab, dann ruf weiter() wieder. So oft, bis es dir sagt, " <>
            "dass nichts mehr kommt. Du musst nichts ausrechnen und keinen Bereich " <>
            "waehlen; das Werkzeug merkt sich, wo du stehst.",
        parameter: objekt(%{}),
        wiederholung: :frei,
        ausfuehren: &weiter/2
      },
      %{
        name: "cast",
        beschreibung:
          "Die Liste der bekannten handelnden Personen. Sie ist die einzige zulaessige " <>
            "Quelle fuer das Feld cast_match. Passt keine, bleibt cast_match leer (\"\").",
        parameter: objekt(%{}),
        wiederholung: :frei,
        ausfuehren: &cast/2
      },
      %{
        name: "straenge",
        beschreibung:
          "Die Liste der bereits bekannten Themen, als Quelle fuer das Feld threads. " <>
            "Passt keines, waehle eine eigene kurze Bezeichnung.",
        parameter: objekt(%{}),
        wiederholung: :frei,
        ausfuehren: &straenge/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}

  defp nummer(beschreibung),
    do: %{"type" => "integer", "minimum" => 0, "description" => beschreibung}

  # ─── bloecke ──────────────────────────────────────────────────────────

  @doc "Einen Bereich lesen (Werkzeug `bloecke`)."
  @spec bloecke(Stand.t(), map()) :: ergebnis()
  def bloecke(%Stand{} = s, %{"von" => von, "bis" => bis}) do
    cond do
      von > bis ->
        {s,
         {:error,
          "von (#{von}) ist groesser als bis (#{bis}). Der Bereich ist einschliesslich: " <>
            "bloecke(von, bis) mit von <= bis."}}

      von > s.max_block ->
        {s,
         {:error,
          "Der Bereich #{von}-#{bis} liegt hinter dem Mitschnitt. " <>
            "Der Mitschnitt hat die Bloecke 0 bis #{s.max_block}."}}

      true ->
        b = min(bis, s.max_block)
        {gelesen(s, von, b), {:ok, zeilen(s, von, b)}}
    end
  end

  # ─── block ────────────────────────────────────────────────────────────

  @doc "Einen einzelnen Block lesen (Werkzeug `block`)."
  @spec block(Stand.t(), map()) :: ergebnis()
  def block(%Stand{} = s, %{"nummer" => n}) do
    case Stand.block(s, n) do
      nil ->
        rest =
          if s.beppo,
            do: "Nimm nur Blocknummern, die dir weiter() gezeigt hat.",
            else: "Gültig sind 0 bis #{s.max_block}."

        {s, {:error, "Block #{n} gibt es nicht. " <> rest}}

      blk ->
        {s, {:ok, zeile(n, blk)}}
    end
  end

  # ─── suche ────────────────────────────────────────────────────────────

  @doc "Im ganzen Mitschnitt suchen (Werkzeug `suche`)."
  @spec suche(Stand.t(), map()) :: ergebnis()
  def suche(%Stand{} = s, %{"begriff" => begriff} = p) do
    nadel = Beleg.norm(begriff)

    if String.length(nadel) < 3 do
      {s, {:error, "Der Begriff ist zu kurz — nimm mindestens drei Zeichen."}}
    else
      funde = funde(s, nadel, Map.get(p, "ab") || 0, Map.get(p, "bis") || s.max_block)
      {s, {:ok, Enum.join([kopf(begriff, length(funde)) | Enum.take(funde, @treffer_max)], "\n")}}
    end
  end

  defp funde(s, nadel, von, zu) do
    von..zu//1
    |> Enum.map(&{&1, Stand.block(s, &1)})
    |> Enum.filter(fn {_, blk} -> blk && String.contains?(Beleg.norm(blk.text || ""), nadel) end)
    |> Enum.map(fn {i, blk} -> zeile(i, blk) end)
  end

  defp kopf(begriff, 0), do: "Keine Fundstelle fuer #{Jason.encode!(begriff)}."

  defp kopf(_begriff, n) when n > @treffer_max,
    do: "#{n} Fundstelle(n), die ersten #{@treffer_max}:"

  defp kopf(_begriff, n), do: "#{n} Fundstelle(n):"

  # ─── weiter ───────────────────────────────────────────────────────────

  @doc """
  Die nächste Portion (Werkzeug `weiter`, Beppo-Modus). Nach dem Ende warnt
  es; beim dritten Aufruf nach dem Ende bricht es den Lauf ab.
  """
  @spec weiter(Stand.t(), map()) :: ergebnis()
  def weiter(%Stand{} = s, _args) do
    if s.beppo_pos > s.max_block, do: nach_dem_ende(s), else: portion(s)
  end

  defp portion(s) do
    von = s.beppo_pos
    bis = min(von + s.portion - 1, s.max_block)
    letzter = bis >= s.max_block

    s =
      %{gelesen(s, von, bis) | beppo_pos: bis + 1}
      |> Stand.journal("beppo.jsonl", %{"von" => von, "bis" => bis, "letzter" => letzter})

    schluss =
      if letzter,
        do:
          "— Das war der letzte Abschnitt. Wenn du ihn abgearbeitet hast, " <>
            "schliess mit fertig() ab.",
        else: "— Wenn du diesen Abschnitt abgearbeitet hast, ruf weiter()."

    {s, {:ok, zeilen(s, von, bis) <> "\n\n" <> schluss}}
  end

  defp nach_dem_ende(s) do
    n = s.weiter_leer + 1
    abbruch = n >= @weiter_abbruch

    s =
      %{s | weiter_leer: n}
      |> Stand.journal("wiederholungen.jsonl", %{
        "phase" => s.phase,
        "werkzeug" => "weiter",
        "n" => n,
        "aufruf" => "weiter() nach dem Ende"
      })

    hinweis =
      if abbruch do
        "Das war dein #{n}. Aufruf von weiter(), obwohl nichts mehr kommt. " <>
          "Der Lauf wird jetzt abgebrochen."
      else
        "Der Mitschnitt ist durch — es kommt nichts mehr. " <>
          "Sieh dein Ergebnis noch einmal an und schliess dann mit fertig() ab. " <>
          "Beim #{@weiter_abbruch}. Aufruf von weiter() nach dem Ende wird der Lauf abgebrochen" <>
          if(n == @weiter_abbruch - 1, do: " — das wäre der nächste.", else: ".")
      end

    antwort = Antwort.geordnet([{"nichts_mehr", true}, {"hinweis", hinweis}])
    {s, {if(abbruch, do: :abbruch, else: :error), antwort}}
  end

  # ─── cast, straenge ───────────────────────────────────────────────────

  @doc "Die bekannten Personen (Werkzeug `cast`)."
  @spec cast(Stand.t(), map()) :: ergebnis()
  def cast(%Stand{} = s, _args), do: {s, {:ok, Enum.join(s.cast, "\n")}}

  @doc "Die bekannten Themen (Werkzeug `straenge`)."
  @spec straenge(Stand.t(), map()) :: ergebnis()
  def straenge(%Stand{} = s, _args), do: {s, {:ok, Enum.join(s.straenge, "\n")}}

  # ─── Gemeinsames ──────────────────────────────────────────────────────

  defp gelesen(s, von, bis) do
    s = %{s | gelesen: s.gelesen ++ [{von, bis}]}
    if s.lfd > 0, do: %{s | sammelnd: s.sammelnd ++ [{von, bis}]}, else: s
  end

  defp zeilen(s, von, bis) do
    von..bis//1
    |> Enum.flat_map(fn i ->
      case Stand.block(s, i) do
        nil -> []
        blk -> [zeile(i, blk)]
      end
    end)
    |> Enum.join("\n")
  end

  defp zeile(i, blk), do: "#{i}\t#{Map.get(blk, :sprecher) || ""}\t#{blk.text}"
end
