defmodule Worker.Jack.Redaktion do
  @moduledoc """
  Die Werkzeuge der ordnenden Rolle in Phase 3 (Rolle `a`, beim Nachbessern
  auch `c`): `aussagen` liest den Bestand eines Bereichs samt
  Dublettenkandidaten; `kandidat_getrennt`, `aussage_berichtigen`,
  `aussage_verwerfen` und `aussage_zusammenfuehren` ändern ihn.

  Portiert aus dem Spike (`werkzeuge.ts`, Stand Lauf 6), Texte wörtlich.
  Reihe C hat Phase 3 nicht erreicht; ihr Vertrag ist ungemessen.

  Jede Änderung geht mit dem vollständigen vorherigen Stand in den Verlauf
  (`Worker.Jack.Ordnung`), damit die prüfende Rolle sie zurückrollen kann.
  Der Beleg wird hier erzwungen, mit derselben Prüfung und denselben
  Meldungen wie bei `aussage` (`Worker.Jack.Beleg.fehler/3`, also mit der
  entschärften Frageprüfung).

  **Abweichungen vom Spike:**

    * Pflichtfelder und Typen prüft das Schema; `nummern` in
      `kandidat_getrennt` hat genau zwei Einträge, `source_refs` mindestens
      einen.
    * `aussage_zusammenfuehren` lehnt Blöcke ab, die es nicht gibt. Der Spike
      ließ sie still weg und prüfte den Beleg gegen den Rest.
    * Ein Aufruf, der nichts geändert hat, ist `{:error, …}` (`ok: false`).
  """

  alias Worker.Jack.{Antwort, Beleg, Ordnung, Stand}

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @beleg_beschreibung "wortgetreu; mehrere Zitate mit „ … “ trennen, eines je Block"

  @doc "Die Werkzeuge dieses Moduls, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "aussagen",
        beschreibung:
          "Die bereits eingetragenen Aussagen eines Blockbereichs — mit Nummer, " <>
            "Wortlaut, Beleg, Fundstellen und der Zahl der Kollisionen (wie oft ein " <>
            "spaeterer Versuch auf dieselbe Sache lief; hohe Zahl heisst: mehrere " <>
            "Durchgaenge haben sie unabhaengig gefunden). Aussagen zu derselben " <>
            "Stelle stehen beieinander — dort finden sich Dubletten und Widersprueche.",
        parameter:
          objekt(%{
            "von" => nummer("erste Blocknummer"),
            "bis" => nummer("letzte Blocknummer")
          }),
        wiederholung: :bis_aenderung,
        ausfuehren: &aussagen/2
      },
      %{
        name: "kandidat_getrennt",
        beschreibung:
          "Haelt fest, dass ein vorgelegtes Dubletten-Paar ZWEI VERSCHIEDENE Sachen " <>
            "beschreibt und darum nicht zusammengefuehrt wird. Damit ist das Paar " <>
            "erledigt. Ein Paar, zu dem weder eine Zusammenfuehrung noch diese " <>
            "Erklaerung vorliegt, gilt als unbearbeitet und kommt in der naechsten " <>
            "Runde wieder.",
        parameter:
          objekt(%{
            "nummern" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 2,
              "maxItems" => 2,
              "description" => "die beiden Nummern, etwa [90, 266]"
            },
            "grund" => text("worin sie sich unterscheiden")
          }),
        aendert_bestand: true,
        ausfuehren: &kandidat_getrennt/2
      },
      %{
        name: "aussage_berichtigen",
        beschreibung:
          "Ueberschreibt eine bestehende Aussage. Fuer den Fall, dass sie richtig " <>
            "gemeint, aber falsch formuliert oder unvollstaendig belegt ist. Der " <>
            "alte Stand bleibt vollstaendig in aussagen_verlauf.jsonl und kann von " <>
            "der pruefenden Rolle zurueckgerollt werden.",
        parameter:
          objekt(%{
            "nummer" => nummer("welche Aussage"),
            "claim" => %{"type" => "string"},
            "beleg" => text(@beleg_beschreibung),
            "source_refs" => refs(),
            "grund" =>
              text("was daran falsch war und woraus im Mitschnitt sich die neue Fassung ergibt")
          }),
        aendert_bestand: true,
        ausfuehren: &aussage_berichtigen/2
      },
      %{
        name: "aussage_verwerfen",
        beschreibung:
          "Markiert eine Aussage als verworfen — sie faellt aus dem Ergebnis, " <>
            "bleibt aber mit deiner Begruendung stehen. Fuer Aussagen, die falsch " <>
            "sind oder nicht ueber die Welt handeln. Loeschen kannst du nichts.",
        parameter:
          objekt(%{
            "nummer" => %{"type" => "integer", "minimum" => 0},
            "grund" => text("warum sie nicht in den Bestand gehoert — pruefbar, nicht pauschal")
          }),
        aendert_bestand: true,
        ausfuehren: &aussage_verwerfen/2
      },
      %{
        name: "aussage_zusammenfuehren",
        beschreibung:
          "Zwei Aussagen ueber dieselbe Sache zu einer. Die behaltene bekommt die " <>
            "neue Fassung, die aufgegebene wird verworfen — in EINEM Schritt. Der " <>
            "neue Claim darf nur enthalten, was in den beiden Ausgangsaussagen stand, " <>
            "und jeder genannte Block muss im Beleg zitiert sein.",
        parameter:
          objekt(%{
            "behalten" => nummer("diese Nummer bleibt"),
            "aufgeben" => nummer("diese faellt weg"),
            "claim" => text("die zusammengefuehrte Fassung"),
            "beleg" => text(@beleg_beschreibung),
            "source_refs" => refs(),
            "grund" =>
              text(
                "warum das dieselbe Sache ist, und was aus der aufgegebenen Fassung " <>
                  "uebernommen wurde"
              )
          }),
        aendert_bestand: true,
        ausfuehren: &aussage_zusammenfuehren/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}
  defp text(beschreibung), do: %{"type" => "string", "description" => beschreibung}

  defp nummer(beschreibung),
    do: %{"type" => "integer", "minimum" => 0, "description" => beschreibung}

  defp refs, do: %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1}

  # ─── aussagen ─────────────────────────────────────────────────────────

  @doc "Den Bestand eines Bereichs lesen, mit Dublettenkandidaten (Werkzeug `aussagen`)."
  @spec aussagen(Stand.t(), map()) :: ergebnis()
  def aussagen(%Stand{} = s, %{"von" => von, "bis" => bis}) do
    raus =
      s.eingetragen
      |> Enum.map(& &1.voll)
      |> Enum.filter(&(&1["_verworfen"] != true and im_bereich?(&1, von, bis)))
      |> Enum.sort_by(&Enum.min(&1["source_refs"] || [], fn -> 0 end))

    bereich = "#{von}-#{bis}"
    {s, kand} = kandidaten(s, raus, bereich)
    s = gesehen(s, bereich)

    alle = Ordnung.raster(s.max_block)

    offen_alle =
      Enum.reject(alle, fn {v, b} -> MapSet.member?(s.ordnung.gesehen, "#{v}-#{b}") end)

    # Der nächste offene Bereich NACH dem gelesenen, nicht der erste
    # überhaupt: wer bei 450 anfängt, soll bei 600 weitergehen.
    offen =
      case Enum.filter(offen_alle, fn {v, _} -> v > von end) do
        [] -> offen_alle
        dahinter -> dahinter
      end

    off = Ordnung.offene_arbeit(s)

    antwort =
      Antwort.geordnet(
        [
          {"bereich", bereich},
          {"anzahl", length(raus)},
          {"aussagen", Enum.map(raus, &zeile(s, &1))},
          {"portion", "#{length(alle) - length(offen_alle)} von #{length(alle)}"}
        ] ++
          kandidaten_felder(kand) ++
          naechster(offen, offen_alle) ++
          [{"offene_arbeit", off}, {"nicht_fertig", nicht_fertig(off)}]
      )

    {s, {:ok, antwort}}
  end

  defp im_bereich?(voll, von, bis),
    do: Enum.any?(voll["source_refs"] || [], &(is_integer(&1) and &1 >= von and &1 <= bis))

  defp zeile(s, v) do
    Antwort.geordnet([
      {"nummer", v["nummer"]},
      {"claim", v["claim"]},
      {"beleg", v["beleg"]},
      {"source_refs", v["source_refs"]},
      {"character", v["character"]},
      {"fact_type", v["fact_type"]},
      {"kollisionen", Map.get(s.kollisionen, v["nummer"], 0)}
    ])
  end

  # Kandidatenpaare nach Wortüberlappung. In Lauf 19a blieben Teilmengen
  # stehen, die im selben Bereich direkt untereinander standen — auffallen
  # allein reicht nicht; wer ausdrücklich gefragt wird, kann nicht übersehen.
  defp kandidaten(s, raus, bereich) do
    paare = for {x, i} <- Enum.with_index(raus), y <- Enum.drop(raus, i + 1), do: {x, y}

    Enum.reduce(paare, {s, []}, fn {x, y}, {s, kand} ->
      case kandidat(s, x, y) do
        nil -> {s, kand}
        k -> {anbieten(s, k, bereich), kand ++ [k]}
      end
    end)
  end

  defp kandidat(s, x, y) do
    wx = Beleg.woerter(x["claim"] || "")
    wy = Beleg.woerter(y["claim"] || "")
    gemeinsam = Enum.any?(x["source_refs"] || [], &(&1 in (y["source_refs"] || [])))
    paar = [x["nummer"], y["nummer"]]

    with false <- MapSet.size(wx) == 0 or MapSet.size(wy) == 0,
         g = MapSet.size(MapSet.intersection(wx, wy)),
         deckung = g / min(MapSet.size(wx), MapSet.size(wy)),
         ueberlapp = g / (MapSet.size(wx) + MapSet.size(wy) - g),
         true <- deckung >= 0.7 or (gemeinsam and ueberlapp >= 0.4),
         false <- MapSet.member?(s.ordnung.getrennt, Ordnung.paar_key(x["nummer"], y["nummer"])) do
      %{paar: paar, deckung: Float.round(deckung, 2), gemeinsamer_block: gemeinsam}
    else
      _ -> nil
    end
  end

  defp anbieten(s, %{paar: [a, b] = paar}, bereich) do
    key = Ordnung.paar_key(a, b)

    if Enum.any?(s.ordnung.kandidaten, &(&1.key == key)) do
      s
    else
      o = s.ordnung

      %{
        s
        | ordnung: %{o | kandidaten: o.kandidaten ++ [%{key: key, paar: paar, bereich: bereich}]}
      }
      |> Stand.journal("kandidaten.jsonl", %{"paar" => paar, "bereich" => bereich})
    end
  end

  # Die Abdeckung überdauert die Sitzung: die nachbessernde Rolle macht dort
  # weiter, wo die ordnende aufgehört hat.
  defp gesehen(s, bereich) do
    o = s.ordnung

    if MapSet.member?(o.gesehen, bereich) do
      s
    else
      %{s | ordnung: %{o | gesehen: MapSet.put(o.gesehen, bereich)}}
      |> Stand.journal("bereiche.jsonl", %{
        "bereich" => bereich,
        "rolle" => o.rolle,
        "runde" => o.runde
      })
    end
  end

  defp kandidaten_felder([]), do: []

  defp kandidaten_felder(kand) do
    [
      {"dubletten_kandidaten",
       Enum.map(kand, fn k ->
         Antwort.geordnet([
           {"paar", k.paar},
           {"deckung", k.deckung},
           {"gemeinsamer_block", k.gemeinsamer_block}
         ])
       end)},
      {"kandidaten_hinweis",
       "#{length(kand)} Paar(e) mit auffaelliger Wortueberlappung. Entscheide zu " <>
         "JEDEM: dieselbe Sache (dann zusammenfuehren) oder zwei verschiedene " <>
         "Sachen (dann beide stehen lassen). Die Liste ist eine Vorauswahl nach " <>
         "Wortgleichheit, kein Urteil."}
    ]
  end

  defp naechster([], _offen_alle), do: [{"hinweis", "Alle Bereiche durchgesehen."}]

  defp naechster([{v, b} | _], offen_alle) do
    [
      {"naechster_bereich", "#{v}-#{b}"},
      {"hinweis",
       "Noch #{length(offen_alle)} Bereiche offen. Der naechste ist " <>
         "aussagen(#{v}, #{b}) — die Bereiche ueberlappen " <>
         "sich um 50 Bloecke, damit nichts an einer Grenze durchfaellt."}
    ]
  end

  defp nicht_fertig(%{"bereiche_offen" => [], "kandidaten_offen" => []}), do: nil

  defp nicht_fertig(off) do
    "Noch offen: #{length(off["bereiche_offen"])} Bereich(e), " <>
      "#{length(off["kandidaten_offen"])} Kandidatenpaar(e). Du bist erst fertig, " <>
      "wenn beides null ist — ein Paar entscheidest du mit " <>
      "aussage_zusammenfuehren() oder kandidat_getrennt()."
  end

  # ─── kandidat_getrennt ────────────────────────────────────────────────

  @doc "Ein Paar als verschieden erklären (Werkzeug `kandidat_getrennt`)."
  @spec kandidat_getrennt(Stand.t(), map()) :: ergebnis()
  def kandidat_getrennt(%Stand{} = s, %{"nummern" => [a, b] = nr, "grund" => grund}) do
    key = Ordnung.paar_key(a, b)

    with :ok <- grund_da(grund, "`grund` fehlt."),
         :ok <- alle_da(s, nr),
         :ok <- nicht_getrennt(s, key, nr) do
      o = s.ordnung

      s =
        %{
          s
          | ordnung: %{
              o
              | getrennt: MapSet.put(o.getrennt, key),
                getrennt_neu: o.getrennt_neu + 1
            }
        }
        |> Stand.journal("kandidaten.jsonl", %{
          "getrennt" => nr,
          "grund" => grund,
          "runde" => o.runde,
          "rolle" => o.rolle
        })

      ok(s, [
        {"getrennt", nr},
        {"offene_kandidaten", length(Ordnung.offene_kandidaten(s))}
      ])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  defp alle_da(s, nummern) do
    case Enum.reject(nummern, &Stand.bestand_von(s, &1)) do
      [] -> :ok
      fehlt -> {:fehler, ["Gibt es nicht: #{Jason.encode!(fehlt)}"]}
    end
  end

  defp nicht_getrennt(s, key, [a, b]) do
    if MapSet.member?(s.ordnung.getrennt, key),
      do: {:fehler, ["#{a}/#{b} ist schon getrennt."]},
      else: :ok
  end

  # ─── aussage_berichtigen ──────────────────────────────────────────────

  @doc "Eine Aussage neu fassen (Werkzeug `aussage_berichtigen`)."
  @spec aussage_berichtigen(Stand.t(), map()) :: ergebnis()
  def aussage_berichtigen(%Stand{} = s, %{"nummer" => n, "source_refs" => refs} = p) do
    with {:ok, alt} <- vorhanden(s, n),
         :ok <- grund_da(p["grund"], "`grund` fehlt."),
         :ok <- bloecke_da(s, refs),
         :ok <- beleg(s, p["beleg"], refs) do
      neu =
        Map.merge(alt, %{
          "claim" => p["claim"],
          "beleg" => p["beleg"],
          "source_refs" => refs,
          "_belegt" => true,
          "_pos" => Beleg.pos_von(refs),
          "_iter" => s.durchgang,
          "_berichtigt" => (alt["_berichtigt"] || 0) + 1
        })

      {s, id} =
        s
        |> Stand.ersetzen(n, neu)
        |> Ordnung.verlauf_schreiben(%{
          "was" => "berichtigt",
          "nummer" => n,
          "grund" => p["grund"],
          "vorher" => [alt],
          "nachher" => p["claim"]
        })

      ok(s, [{"nummer", n}, {"id", id}])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  # ─── aussage_verwerfen ────────────────────────────────────────────────

  @doc "Eine Aussage verwerfen, mit Begründung (Werkzeug `aussage_verwerfen`)."
  @spec aussage_verwerfen(Stand.t(), map()) :: ergebnis()
  def aussage_verwerfen(%Stand{} = s, %{"nummer" => n, "grund" => grund}) do
    with {:ok, alt} <- vorhanden(s, n),
         :ok <- grund_da(grund, "`grund` fehlt."),
         :ok <- nicht_verworfen(alt, n) do
      neu = Map.merge(alt, %{"_verworfen" => true, "_grund" => grund, "_iter" => s.durchgang})

      {s, id} =
        s
        |> Stand.ersetzen(n, neu)
        |> Ordnung.verlauf_schreiben(%{
          "was" => "verworfen",
          "nummer" => n,
          "grund" => grund,
          "claim" => alt["claim"],
          "vorher" => [alt]
        })

      ok(s, [{"nummer", n}, {"id", id}])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  # ─── aussage_zusammenfuehren ──────────────────────────────────────────

  @doc "Zwei Aussagen zu einer zusammenführen (Werkzeug `aussage_zusammenfuehren`)."
  @spec aussage_zusammenfuehren(Stand.t(), map()) :: ergebnis()
  def aussage_zusammenfuehren(%Stand{} = s, %{"behalten" => ka, "aufgeben" => kb} = p) do
    refs = Enum.uniq(p["source_refs"])

    with {:ok, a} <- vorhanden(s, ka),
         {:ok, b} <- vorhanden(s, kb),
         :ok <- verschieden(ka, kb),
         :ok <- nicht_verworfen(a, ka),
         :ok <- nicht_verworfen(b, kb),
         :ok <-
           grund_da(
             p["grund"],
             "`grund` fehlt. Die pruefende Rolle liest ihn — ohne Begruendung " <>
               "ist die Zusammenfuehrung nicht nachvollziehbar."
           ),
         :ok <- bloecke_da(s, refs),
         :ok <- beleg(s, p["beleg"], refs) do
      neu =
        Map.merge(a, %{
          "claim" => p["claim"],
          "beleg" => p["beleg"],
          "source_refs" => refs,
          "_belegt" => true,
          "_pos" => Beleg.pos_von(refs),
          "_iter" => s.durchgang,
          "_zusammengefuehrt" => (a["_zusammengefuehrt"] || []) ++ [kb]
        })

      weg =
        Map.merge(b, %{
          "_verworfen" => true,
          "_grund" => "zusammengefuehrt in Nr. #{ka}",
          "_iter" => s.durchgang
        })

      {s, id} =
        s
        |> Stand.ersetzen(ka, neu)
        |> Stand.ersetzen(kb, weg)
        |> Ordnung.verlauf_schreiben(%{
          "was" => "zusammengefuehrt",
          "behalten" => ka,
          "aufgegeben" => kb,
          "grund" => p["grund"],
          "vorher" => [a, b],
          "nachher" => p["claim"]
        })

      ok(s, [{"nummer", ka}, {"verworfen", kb}, {"id", id}])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  defp verschieden(n, n), do: {:fehler, ["behalten und aufgeben sind dieselbe Nummer."]}
  defp verschieden(_, _), do: :ok

  # ─── Gemeinsame Prüfungen ─────────────────────────────────────────────

  defp vorhanden(s, n) do
    case Stand.bestand_von(s, n) do
      nil -> {:fehler, ["Aussage Nr. #{n} gibt es nicht."]}
      alt -> {:ok, alt}
    end
  end

  defp grund_da(grund, text) do
    if String.trim(grund || "") == "", do: {:fehler, [text]}, else: :ok
  end

  defp nicht_verworfen(%{"_verworfen" => true}, n),
    do: {:fehler, ["Nr. #{n} ist schon verworfen."]}

  defp nicht_verworfen(_alt, _n), do: :ok

  defp bloecke_da(s, refs) do
    case Enum.reject(refs, &Map.has_key?(s.bloecke, &1)) do
      [] -> :ok
      weg -> {:fehler, ["source_refs nennt Bloecke, die es nicht gibt: #{Jason.encode!(weg)}"]}
    end
  end

  defp beleg(s, beleg, refs) do
    case Beleg.fehler(beleg, refs, s.bloecke) do
      nil -> :ok
      f -> {:fehler, f}
    end
  end

  defp ok(s, felder), do: {s, {:ok, Antwort.geordnet([{"ok", true} | felder])}}

  defp fehler(s, f), do: {s, {:error, Antwort.geordnet([{"ok", false}, {"fehler", f}])}}
end
