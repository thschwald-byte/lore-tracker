defmodule Worker.Jack.Pruefung do
  @moduledoc """
  Die Werkzeuge, mit denen Phase 3 sich selbst prüft:

    * die prüfende Rolle `b` liest die Schritte der ordnenden Rolle
      (`aenderungen`), nimmt sie an (`aenderung_annehmen`) oder rollt sie
      zurück (`aenderung_ablehnen`) — ändern kann sie selbst nichts;
    * die nachbessernde Rolle `c` liest, was zurückgerollt wurde
      (`ablehnungen`), und hakt es ab (`ablehnung_erledigt`).

  Portiert aus dem Spike (`werkzeuge.ts`, Stand Lauf 6), Texte wörtlich.
  Reihe C hat Phase 3 nicht erreicht; ihr Vertrag ist ungemessen.

  Die Begründung einer Ablehnung geht automatisch ins Gedächtnis (Abschnitt
  `ABLEHNUNGEN`), wo beide Rollen hinsehen: was die prüfende Rolle vergessen
  kann, ist keine Übergabe.

  **Abweichungen vom Spike:**

    * Pflichtfelder, Typen und erlaubte Werte prüft das Schema: `stufe` und
      `entscheidung` sind Enums (der Spike nahm auch „unschön“ und
      Großschreibung an), `ids` hat mindestens einen Eintrag.
    * `anmerkung` in `aenderung_annehmen` und `alle` in `ablehnungen` sind
      Pflicht; `anmerkung` darf leer sein.
    * `ablehnung_erledigt` mit „nachgebessert“ verlangt einen späteren
      redaktionellen Schritt an denselben Aussagen; eine Annahme durch `b`
      zählt nicht mehr als Nachbesserung.
    * Ein Aufruf, der nichts geändert hat, ist `{:error, …}` (`ok: false`).
  """

  alias Worker.Jack.{Antwort, Ordnung, Stand}

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "aenderungen",
        beschreibung:
          "Die redaktionellen Schritte der ordnenden Rolle in einem Blockbereich — " <>
            "mit Begruendung, Wortlaut vorher und nachher. Denselbe Bereich wie " <>
            "bloecke(von, bis): so liegen die Schritte und die Bloecke, an denen du " <>
            "sie pruefst, nebeneinander.",
        parameter:
          objekt(%{
            "von" => nummer("erste Blocknummer"),
            "bis" => nummer("letzte Blocknummer")
          }),
        wiederholung: :bis_aenderung,
        ausfuehren: &aenderungen/2
      },
      %{
        name: "aenderung_annehmen",
        beschreibung:
          "Haelt fest, dass ein Schritt geprueft ist und haelt. Angenommene " <>
            "Schritte tauchen in aenderungen() nicht mehr auf — in der naechsten " <>
            "Runde siehst du also nur, was seither dazugekommen ist. Nimm an, was " <>
            "du geprueft hast und was standhaelt; das ist die Regel, nicht die " <>
            "Ausnahme.",
        parameter:
          objekt(%{
            "ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "description" => "Kennungen aus aenderungen(), etwa [\"r3\",\"r4\"]"
            },
            "anmerkung" => %{
              "type" => "string",
              "minLength" => 0,
              "description" => "woran du es geprueft hast (darf leer sein)"
            }
          }),
        aendert_bestand: true,
        ausfuehren: &aenderung_annehmen/2
      },
      %{
        name: "aenderung_ablehnen",
        beschreibung:
          "Rollt einen Schritt der ordnenden Rolle vollstaendig zurueck: der Stand " <>
            "vor der Aenderung wird wiederhergestellt. Nur benutzen, wenn der " <>
            "Mitschnitt der Begruendung widerspricht oder der Beleg den Claim nicht " <>
            "traegt — nicht, weil dir eine andere Formulierung besser gefiele.",
        parameter:
          objekt(%{
            "id" => text("die Kennung aus aenderungen(), etwa \"r7\""),
            "stufe" => %{
              "type" => "string",
              "enum" => Ordnung.stufen(),
              "description" =>
                "wie schwer der Mangel wiegt: kritisch (die Aussage wird dadurch falsch) | " <>
                  "schwer (der Beleg traegt den Claim nicht mehr) | mittel (Inhalt ist " <>
                  "verlorengegangen) | leicht (ungenau, aber nicht falsch) | unschoen (nur " <>
                  "die Formulierung). Mit jeder Runde faellt die mildeste Stufe weg."
            },
            "grund" => text("was am Schritt nicht haelt, mit Blocknummer")
          }),
        aendert_bestand: true,
        ausfuehren: &aenderung_ablehnen/2
      },
      %{
        name: "ablehnungen",
        beschreibung:
          "Was die pruefende Rolle zurueckgerollt hat: was die ordnende Rolle " <>
            "vorhatte und warum, was die Pruefung dagegen einzuwenden hatte, und der " <>
            "Stand, wie er jetzt wieder dasteht. Das ist deine Arbeitsliste.",
        parameter:
          objekt(%{
            "alle" => %{
              "type" => "boolean",
              "description" => "auch die schon erledigten (true) oder nur die offenen (false)"
            }
          }),
        wiederholung: :bis_aenderung,
        ausfuehren: &ablehnungen/2
      },
      %{
        name: "ablehnung_erledigt",
        beschreibung:
          "Haelt fest, wie du mit einer Ablehnung umgegangen bist. Erst nachdem du " <>
            "gehandelt hast (nachgebessert oder bewusst dabei belassen).",
        parameter:
          objekt(%{
            "id" => text("die Kennung des zurueckgerollten Schritts, etwa \"r7\""),
            "entscheidung" => %{
              "type" => "string",
              "enum" => ["nachgebessert", "angenommen"],
              "description" => "\"nachgebessert\" oder \"angenommen\""
            },
            "begruendung" => text("was du getan hast und warum")
          }),
        aendert_bestand: true,
        ausfuehren: &ablehnung_erledigt/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}
  defp text(beschreibung), do: %{"type" => "string", "description" => beschreibung}

  defp nummer(beschreibung),
    do: %{"type" => "integer", "minimum" => 0, "description" => beschreibung}

  # ─── aenderungen ──────────────────────────────────────────────────────

  @doc "Die offenen Schritte eines Bereichs (Werkzeug `aenderungen`)."
  @spec aenderungen(Stand.t(), map()) :: ergebnis()
  def aenderungen(%Stand{} = s, %{"von" => von, "bis" => bis}) do
    o = s.ordnung
    offen = Ordnung.offene_schritte(o)

    teil =
      offen
      |> Enum.filter(fn e -> Enum.any?(Ordnung.schritt_refs(e), &(&1 >= von and &1 <= bis)) end)
      |> Enum.map(&schritt_eintrag(s, &1))

    s = %{s | ordnung: %{o | gesehen: MapSet.put(o.gesehen, "p#{von}-#{bis}")}}
    alle = Ordnung.raster(s.max_block)

    offen_alle =
      Enum.reject(alle, fn {v, b} -> MapSet.member?(s.ordnung.gesehen, "p#{v}-#{b}") end)

    naechste =
      case Enum.filter(offen_alle, fn {v, _} -> v > von end) do
        [] -> offen_alle
        dahinter -> dahinter
      end

    gilt = Ordnung.stufen_der_runde(o.runde)

    antwort =
      Antwort.geordnet(
        [
          {"bereich", "#{von}-#{bis}"},
          {"anzahl", length(teil)},
          {"aenderungen", teil},
          {"portion", "#{length(alle) - length(offen_alle)} von #{length(alle)}"},
          {"offen_gesamt", length(offen)},
          {"schon_durch", MapSet.size(Ordnung.erledigte_schritte(o))},
          {"runde", o.runde},
          {"wirksame_stufen", gilt},
          {"stufen_hinweis", stufen_hinweis(gilt)}
        ] ++ naechste(naechste, offen_alle) ++ unbearbeitet(s, von, bis)
      )

    {s, {:ok, antwort}}
  end

  defp schritt_eintrag(s, e) do
    nrn = Ordnung.beruehrt(e)
    haupt = nrn |> Enum.map(&Stand.bestand_von(s, &1)) |> Enum.reject(&is_nil/1) |> List.first()

    vorher =
      Enum.map(e["vorher"] || [], fn v ->
        Antwort.geordnet([
          {"nummer", v["nummer"]},
          {"claim", v["claim"]},
          {"beleg", v["beleg"]},
          {"source_refs", v["source_refs"]}
        ])
      end)

    # Der aktuelle Stand reist nur mit, wenn er vom erwarteten abweicht —
    # sonst wäre er eine Wiederholung von `nachher`.
    jetzt =
      if haupt && e["nachher"] && haupt["claim"] != e["nachher"],
        do:
          Antwort.geordnet([
            {"nummer", haupt["nummer"]},
            {"claim", haupt["claim"]},
            {"beleg", haupt["beleg"]},
            {"source_refs", haupt["source_refs"]}
          ])

    Antwort.geordnet([
      {"id", e["id"]},
      {"was", e["was"]},
      {"runde", e["runde"]},
      {"grund", e["grund"]},
      {"betroffen", nrn},
      {"vorher", vorher},
      {"nachher", e["nachher"]},
      {"jetzt", jetzt},
      {"jetzt_verworfen", if(haupt && !e["nachher"], do: haupt["_verworfen"] == true)}
    ])
  end

  defp stufen_hinweis([]),
    do: "In dieser Runde zaehlt keine Stufe mehr — die Pruefung ist zu Ende."

  defp stufen_hinweis(gilt) do
    "In dieser Runde fuehrt eine Ablehnung nur bei #{Enum.join(gilt, ", ")} zum " <>
      "Zurueckrollen. Mildere Maengel notierst du mit notiz() unter ## OFFEN."
  end

  defp naechste([], _offen_alle), do: [{"hinweis", "Alle Bereiche durchgesehen."}]

  defp naechste([{v, b} | _], offen_alle) do
    [
      {"naechster_bereich", "#{v}-#{b}"},
      {"hinweis",
       "Noch #{length(offen_alle)} Bereiche offen. Der naechste ist aenderungen(#{v}, #{b})."}
    ]
  end

  # Was die ordnende Rolle liegen gelassen hat. Ohne das beurteilte die
  # Prüfung nur Taten und nie Unterlassungen.
  defp unbearbeitet(s, von, bis) do
    liegen =
      s
      |> Ordnung.offene_kandidaten()
      |> Enum.filter(fn k ->
        Enum.any?(k.paar, fn n ->
          ((Stand.bestand_von(s, n) || %{})["source_refs"] || [])
          |> Enum.any?(&(&1 >= von and &1 <= bis))
        end)
      end)

    if liegen == [] do
      []
    else
      [
        {"unbearbeitete_kandidaten", Enum.map(liegen, & &1.paar)},
        {"kandidaten_hinweis",
         "Diese Dubletten-Paare wurden der ordnenden Rolle vorgelegt und weder " <>
           "zusammengefuehrt noch als verschieden erklaert. Du kannst sie nicht " <>
           "selbst aufloesen — aber sie zaehlen als offene Arbeit, und der Lauf " <>
           "ist damit nicht fertig. Nimm sie in deinen Abschlussbericht auf."}
      ]
    end
  end

  # ─── aenderung_annehmen ───────────────────────────────────────────────

  @doc "Schritte als geprüft annehmen (Werkzeug `aenderung_annehmen`)."
  @spec aenderung_annehmen(Stand.t(), map()) :: ergebnis()
  def aenderung_annehmen(%Stand{} = s, %{"ids" => ids, "anmerkung" => anmerkung}) do
    start = %{s: s, ok: [], schon: [], weg: [], durch: Ordnung.erledigte_schritte(s.ordnung)}

    %{s: s, ok: ok, schon: schon, weg: weg} =
      Enum.reduce(ids, start, &annehmen_eins(&1, &2, anmerkung))

    hinweise =
      if(weg != [], do: ["Kennung(en) gibt es nicht: #{Jason.encode!(weg)}"], else: []) ++
        if schon != [], do: ["schon erledigt: #{Jason.encode!(schon)}"], else: []

    antwort =
      Antwort.geordnet([
        {"ok", ok != []},
        {"angenommen", ok},
        {"hinweise", if(hinweise != [], do: hinweise)},
        {"noch_offen", length(Ordnung.offene_schritte(s.ordnung))}
      ])

    {s, {if(ok != [], do: :ok, else: :error), antwort}}
  end

  defp annehmen_eins(id, acc, anmerkung) do
    case Enum.find(acc.s.ordnung.verlauf, &(&1["id"] == id and schritt?(&1))) do
      nil ->
        %{acc | weg: acc.weg ++ [id]}

      e ->
        if MapSet.member?(acc.durch, id) do
          %{acc | schon: acc.schon ++ [id]}
        else
          {s, _} =
            Ordnung.verlauf_schreiben(acc.s, %{
              "was" => "angenommen",
              "ref_id" => id,
              "betraf" => e["was"],
              "nummer" => List.first(Ordnung.beruehrt(e)),
              "grund" => anmerkung
            })

          %{acc | s: s, ok: acc.ok ++ [id], durch: MapSet.put(acc.durch, id)}
        end
    end
  end

  defp schritt?(e), do: e["was"] not in ~w(abgelehnt angenommen erledigt) and e["was"] != nil

  # ─── aenderung_ablehnen ───────────────────────────────────────────────

  @doc "Einen Schritt zurückrollen (Werkzeug `aenderung_ablehnen`)."
  @spec aenderung_ablehnen(Stand.t(), map()) :: ergebnis()
  def aenderung_ablehnen(%Stand{} = s, %{"id" => id, "stufe" => stufe, "grund" => grund}) do
    o = s.ordnung

    with {:ok, e} <- ablehnbar(o, id),
         :ok <- nicht_abgelehnt(o, id),
         :ok <- da(grund, "`grund` fehlt."),
         :ok <- stufe_gilt(o.runde, stufe),
         :ok <- kein_spaeterer(o, e, id),
         {:ok, s, n} <- zurueckrollen(s, e) do
      nrn = Ordnung.beruehrt(e)

      {s, _} =
        Ordnung.verlauf_schreiben(s, %{
          "was" => "abgelehnt",
          "ref_id" => id,
          "betraf" => e["was"],
          "stufe" => stufe,
          "nummer" => List.first(nrn),
          "grund" => grund,
          "wiederhergestellt" => Enum.map(e["vorher"] || [], & &1["nummer"])
        })

      # Die Begründung muss bei der ordnenden Rolle ankommen — ins Gedächtnis,
      # wo beide hinsehen, und automatisch statt als Bitte im Auftragstext.
      zeile =
        "#{e["was"]} an ##{Enum.join(nrn, ", #")} zurueckgerollt " <>
          "(#{stufe}, Runde #{o.runde}): #{grund}"

      bloecke = e |> Ordnung.schritt_refs() |> Enum.uniq() |> Enum.sort() |> Enum.take(6)
      s = ablehnung_notieren(s, "zurueck-#{id}", zeile, bloecke, "+")

      ok(s, [
        {"id", id},
        {"zurueckgerollt", n},
        {"hinweis", "Der Stand vor dieser Aenderung ist wieder da."}
      ])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  defp ablehnbar(o, id) do
    case Enum.find(o.verlauf, &(&1["id"] == id and &1["was"] not in [nil, "abgelehnt"])) do
      nil -> {:fehler, ["Kennung #{id} gibt es nicht. Nimm eine aus aenderungen()."]}
      e -> {:ok, e}
    end
  end

  defp nicht_abgelehnt(o, id) do
    if Enum.any?(o.verlauf, &(&1["was"] == "abgelehnt" and &1["ref_id"] == id)),
      do: {:fehler, ["#{id} ist schon abgelehnt."]},
      else: :ok
  end

  defp stufe_gilt(runde, stufe) do
    gilt = Ordnung.stufen_der_runde(runde)

    if stufe in gilt do
      :ok
    else
      noch = if gilt == [], do: "keine", else: Enum.join(gilt, ", ")

      {:fehler,
       [
         "In Runde #{runde} zaehlt die Stufe „#{stufe}“ nicht mehr — " <>
           "noch wirksam: #{noch}. Der Schritt bleibt stehen. " <>
           "Stuf einen Mangel danach ein, was er anrichtet, nicht danach, was du " <>
           "durchsetzen willst; was diese Runde nicht mehr zaehlt, notierst du mit " <>
           "notiz() unter ## OFFEN."
       ]}
    end
  end

  # Ein späterer Schritt kann auf diesem aufgebaut haben; ihn zuerst
  # zurückzurollen überschriebe den späteren still.
  defp kein_spaeterer(o, e, id) do
    meine = MapSet.new(Ordnung.beruehrt(e))

    spaeter =
      o
      |> Ordnung.schritte()
      |> Enum.filter(fn x ->
        Ordnung.id_nummer(x["id"]) > Ordnung.id_nummer(e["id"]) and
          Enum.any?(Ordnung.beruehrt(x), &MapSet.member?(meine, &1))
      end)

    if spaeter == [],
      do: :ok,
      else:
        {:fehler,
         [
           "Auf #{id} bauen spaetere Schritte auf: " <>
             "#{Jason.encode!(Enum.map(spaeter, & &1["id"]))}. Lehne den spaetesten zuerst ab."
         ]}
  end

  defp zurueckrollen(s, e) do
    vorher = Enum.filter(e["vorher"] || [], &is_integer(&1["nummer"]))
    s = Enum.reduce(vorher, s, &Stand.ersetzen(&2, &1["nummer"], &1))

    if vorher == [],
      do: {:fehler, ["Konnte den vorherigen Stand nicht wiederherstellen."]},
      else: {:ok, s, length(vorher)}
  end

  # ─── ablehnungen ──────────────────────────────────────────────────────

  @doc "Die Arbeitsliste der nachbessernden Rolle (Werkzeug `ablehnungen`)."
  @spec ablehnungen(Stand.t(), map()) :: ergebnis()
  def ablehnungen(%Stand{} = s, %{"alle" => alle?}) do
    alle = Ordnung.ablehnungen_liste(s)
    offen = Enum.reject(alle, & &1["erledigt"])
    zeig = if alle?, do: alle, else: offen
    off = Ordnung.offene_arbeit(s)

    antwort =
      Antwort.geordnet([
        {"offen", length(offen)},
        {"gesamt", length(alle)},
        {"auch_liegengeblieben", off},
        {"liegengeblieben_hinweis", liegengeblieben(off)},
        {"hinweis",
         if(zeig != [],
           do:
             "Zu jeder Ablehnung entscheidest du: nachbessern (dann den Schritt neu " <>
               "und besser machen) oder annehmen (dann bleibt es beim alten Stand). " <>
               "Danach ablehnung_erledigt() — sonst steht der Punkt in der naechsten " <>
               "Runde wieder da.",
           else: "Nichts offen. Du bist fertig."
         )},
        {"ablehnungen", zeig}
      ])

    {s, {:ok, antwort}}
  end

  defp liegengeblieben(%{"bereiche_offen" => [], "kandidaten_offen" => []}), do: nil

  defp liegengeblieben(off) do
    "Die ordnende Rolle hat nicht alles erledigt: " <>
      "#{length(off["bereiche_offen"])} Bereich(e) nie angesehen, " <>
      "#{length(off["kandidaten_offen"])} Kandidatenpaar(e) unentschieden. " <>
      "Das gehoert auch zu deiner Arbeit — erst die Einwaende, dann das."
  end

  # ─── ablehnung_erledigt ───────────────────────────────────────────────

  @doc "Eine Ablehnung abhaken (Werkzeug `ablehnung_erledigt`)."
  @spec ablehnung_erledigt(Stand.t(), map()) :: ergebnis()
  def ablehnung_erledigt(%Stand{} = s, %{"id" => id, "entscheidung" => ent, "begruendung" => b}) do
    o = s.ordnung

    with {:ok, e} <- abgelehnt(o, id),
         :ok <- nicht_abgehakt(o, id),
         :ok <- da(b, "`begruendung` fehlt."),
         :ok <- nachgebessert(o, e, id, ent) do
      {s, _} =
        Ordnung.verlauf_schreiben(s, %{
          "was" => "erledigt",
          "ref_id" => id,
          "entscheidung" => ent,
          "grund" => b
        })

      s = ablehnung_notieren(s, "zurueck-#{id}", "#{ent} (Runde #{o.runde}): #{b}", nil, "~")
      noch = s |> Ordnung.ablehnungen_liste() |> Enum.count(&(!&1["erledigt"]))
      ok(s, [{"id", id}, {"entscheidung", ent}, {"noch_offen", noch}])
    else
      {:fehler, f} -> fehler(s, f)
    end
  end

  defp abgelehnt(o, id) do
    case Enum.find(o.verlauf, &(&1["was"] == "abgelehnt" and &1["ref_id"] == id)) do
      nil -> {:fehler, ["Zu #{id} gibt es keine Ablehnung. Nimm eine aus ablehnungen()."]}
      e -> {:ok, e}
    end
  end

  defp nicht_abgehakt(o, id) do
    if Enum.any?(o.verlauf, &(&1["was"] == "erledigt" and &1["ref_id"] == id)),
      do: {:fehler, ["#{id} ist schon abgehakt."]},
      else: :ok
  end

  # „nachgebessert“ ohne einen neuen Schritt an denselben Aussagen wäre eine
  # Behauptung ohne Tat. Als neuer Schritt zählt nur ein redaktioneller: der
  # Spike zählte auch eine spätere Annahme durch `b` mit, an derselben
  # Aussage — dann galt `c` als „nachgebessert“, ohne etwas getan zu haben.
  defp nachgebessert(_o, _e, _id, "angenommen"), do: :ok

  defp nachgebessert(o, e, id, "nachgebessert") do
    urspr = Enum.find(o.verlauf, %{}, &(&1["id"] == id))
    nrn = MapSet.new(urspr["vorher"] || [], & &1["nummer"])

    danach? =
      Enum.any?(Ordnung.schritte(o), fn x ->
        Ordnung.id_nummer(x["id"]) > Ordnung.id_nummer(e["id"]) &&
          Enum.any?(Ordnung.beruehrt(x), &MapSet.member?(nrn, &1))
      end)

    if danach? do
      :ok
    else
      liste = nrn |> Enum.sort() |> Enum.map_join(", ", &"##{&1}")

      {:fehler,
       [
         "Du hast an #{liste} seit der " <>
           "Ablehnung nichts geaendert. Entweder du besserst wirklich nach, oder du " <>
           "haakst mit entscheidung \"angenommen\" ab."
       ]}
    end
  end

  # ─── Gemeinsames ──────────────────────────────────────────────────────

  # Den Eintrag unter ABLEHNUNGEN setzen oder ersetzen; `bloecke: nil` behält
  # die Blöcke eines bestehenden Eintrags.
  defp ablehnung_notieren(s, schluessel, zeile, bloecke, art) do
    i =
      Enum.find_index(
        s.register,
        &(&1.abschnitt == "ABLEHNUNGEN" and &1.schluessel == schluessel)
      )

    alt = if i, do: Enum.at(s.register, i).bloecke, else: []

    eintrag = %{
      abschnitt: "ABLEHNUNGEN",
      schluessel: schluessel,
      zeile: zeile,
      bloecke: bloecke || alt
    }

    register = if i, do: List.replace_at(s.register, i, eintrag), else: s.register ++ [eintrag]

    %{s | register: register}
    |> Stand.journal("notizen_verlauf.txt", %{
      "art" => art,
      "abschnitt" => "ABLEHNUNGEN",
      "schluessel" => schluessel,
      "zeile" => zeile
    })
  end

  defp da(text, meldung),
    do: if(String.trim(text || "") == "", do: {:fehler, [meldung]}, else: :ok)

  defp ok(s, felder), do: {s, {:ok, Antwort.geordnet([{"ok", true} | felder])}}
  defp fehler(s, f), do: {s, {:error, Antwort.geordnet([{"ok", false}, {"fehler", f}])}}
end
