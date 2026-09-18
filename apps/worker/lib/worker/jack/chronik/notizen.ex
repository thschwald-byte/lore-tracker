defmodule Worker.Jack.Chronik.Notizen do
  @moduledoc """
  `notiz` und `notizen_lesen` des Chronik-Jack im Überblick (J7, #1211) — mit
  der Mechanik der Resümee-Notizen (`Worker.Jack.Resuemee.Notizen.eintragen/3`:
  derselbe Schlüssel im selben Abschnitt ersetzt, `zeile: null` streicht, eine
  leere Zeile ist kein Eintrag, ein Aufruf ohne Wirkung ist ein Fehler), aber
  mit eigenen Abschnitten (`Worker.Jack.Resuemee.Stand.abschnitte(:chronik)`):

    * **PHASEN** — ein Abschnitt der Handlung, den das Schreiben zu EINEM
      Eintrag macht: ein ganzer Auftrag von der Annahme bis zur Abrechnung,
      nicht zwölf Einzelereignisse. Schlüssel ist, woran Jack ihn
      wiedererkennt (`insel-auftrag`), die Zeile sagt, worum es geht, und
      `fakten` nennt, was dazugehört.
    * **SCHLUESSELSZENEN** — was die Kampagne oder die Welt verändert und
      deshalb einen eigenen Eintrag bekommt: der Tod einer Spielerfigur, ein
      Krieg, eine Seuche, ein Epochenereignis. Gleiche Form wie eine Phase.
    * **NICHT_ZEITLEISTE** — Geschehen, das in keine Zeitleiste gehört
      (Würfelmechanik, Tischgespräch ohne Handlungsfolge, ein Ereignis ohne
      Platz in der Zeit), mit Begründung in der Zeile. Diese Fakten gelten
      als **behandelt**, werden aber nie ein Eintrag. Ohne diesen Abschnitt
      zwang `fertig()` Jack, jedes Geschehen irgendwo unterzubringen — also
      auch das, was nicht hineingehört (Maintainer, 18.09.2026: das Werkzeug
      soll verhindern, dass er Sachen hinschreibt, die nicht in die Timeline
      gehören). Der Trichter zählt sie getrennt (`fakten_ausserhalb`), damit
      „bewusst draussen" von „verschluckt" unterscheidbar bleibt.
    * **OFFEN** — wo die Fakten zum Verstehen nicht reichen; dort schlägt das
      Schreiben nach. Braucht keine Fakten.

  **Der Abschnitt IST die Wichtigkeit.** Eine Notiz unter PHASEN wird zu
  `wichtigkeit: "phase"`, eine unter SCHLUESSELSZENEN zu
  `"schluesselszene"` — deshalb trägt `notiz` kein eigenes Feld dafür. Der
  Auftrag verlangte bis #1211 eine `wichtigkeit`, die das Werkzeug gar nicht
  kannte; das war eine der drei Ursachen, an denen der erste echte Lauf
  gescheitert ist (der Überblick brach nach 638 s mit
  `{:wiederholung, "notiz"}` ab).

  **Ein Geschehen liegt in höchstens einer Gruppe** — dieselbe Regel, die
  `Worker.Jack.Chronik.Entwurf` für die Einträge durchsetzt. Ohne sie
  gruppierte der Überblick denselben Fakt mehrfach, und das Schreiben müsste
  die Doppelung auflösen, ohne zu wissen, welche Gruppe gemeint war. Die
  Ablehnung nennt die Gruppe, in der er schon liegt.

  **Keine FORM, kein Deckel.** Anders als Resümee (#1209) und Epos (#1210)
  leitet der Chronik-Jack keine Form aus einer Überschrift ab, und die Zahl
  der Phasen ist nicht gedeckelt: Wie viele Abschnitte eine Kampagne hat,
  entscheidet die Kampagne. Die Flughöhe steht im Auftrag (aus mehreren
  hundert Fakten sollen etwa zwanzig Einträge werden), nicht als Schranke im
  Werkzeug — ein Deckel hier machte den Lauf unabschließbar, sobald er zu
  eng gegriffen wäre.

  **Nur Bekanntes:** eine Fakt-ID muss es in der Kampagne geben, ein Bogen
  unter den Bögen dieser Sitzung, der Kampagne oder den Strängen; gespeichert
  wird die Schreibweise des Bestands.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Chronik.{Abschluss, Entwurf, Ordnung}
  alias Worker.Jack.Resuemee.{Bisher, Stand}
  alias Worker.Jack.Resuemee.Notizen, as: Mechanik

  @gruppen ~w(PHASEN SCHLUESSELSZENEN)
  @ausserhalb "NICHT_ZEITLEISTE"

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "notiz",
        beschreibung:
          "Deine Notizen zur Chronik. Sie überleben, was dein Kontext vergisst, und sind " <>
            "alles, was das Schreiben von diesem Lauf noch hat. Jeder Eintrag hat einen " <>
            "Abschnitt und einen Schlüssel; derselbe Schlüssel ERSETZT den alten Eintrag, " <>
            "zeile=null streicht ihn. Abschnitte: PHASEN (ein Abschnitt der Handlung, aus " <>
            "dem EIN Chronik-Eintrag wird — ein ganzer Auftrag von der Annahme bis zur " <>
            "Abrechnung, nicht zwölf Ereignisse), SCHLUESSELSZENEN (was die Kampagne oder " <>
            "die Welt verändert und deshalb einen eigenen Eintrag bekommt: Tod einer " <>
            "Spielerfigur, Krieg, Seuche, Epochenereignis), NICHT_ZEITLEISTE (Geschehen, das in " <>
            "keine Zeitleiste gehört — Würfelmechanik, Tischgespräch ohne Handlungsfolge; die " <>
            "Zeile ist die Begründung; diese Fakten gelten als behandelt und werden nie ein " <>
            "Eintrag), OFFEN (wo die Fakten zum Verstehen nicht reichen; braucht keine " <>
            "Fakten). Der Abschnitt ist zugleich die Wichtigkeit des späteren Eintrags. Jedes " <>
            "Geschehen gehört in höchstens eine Gruppe — oder unter NICHT_ZEITLEISTE, nicht " <>
            "beides.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "eintraege" => %{
              "type" => "array",
              "minItems" => 1,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "abschnitt" => %{
                    "type" => "string",
                    "enum" => Stand.abschnitte(:chronik),
                    "description" => "PHASEN, SCHLUESSELSZENEN, NICHT_ZEITLEISTE oder OFFEN"
                  },
                  "schluessel" => %{
                    "type" => "string",
                    "description" =>
                      "woran du den Abschnitt wiedererkennst: \"insel-auftrag\", \"tod-kodex\""
                  },
                  "zeile" => %{
                    "type" => ["string", "null"],
                    "description" => "worum es geht; null streicht den Eintrag"
                  },
                  "fakten" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die IDs der Fakten, die dazugehören (erste Spalte von fakten())"
                  },
                  "boegen" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die Titel der Bögen, zu denen er gehört (aus boegen_kampagne() " <>
                        "oder straenge())"
                  }
                }
              }
            }
          }
        },
        aendert_bestand: true,
        ausfuehren: &notiz/2
      },
      %{
        name: "notizen_lesen",
        beschreibung: lesen_beschreibung(s),
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &notizen_lesen/2
      }
    ]
  end

  # Im Schreiben und in der Durchsicht sind die Notizen nur noch zu lesen;
  # „wo du stehst“ ist dort die Chronik selbst.
  defp lesen_beschreibung(%Stand{lauf: :ueberblick}),
    do:
      "Gibt deine Notizen zurück, dazu wo du stehst: wie viele Fakten du gelesen hast, wie " <>
        "viele Phasen und Schlüsselszenen du hast und wie viele Geschehen noch in keiner " <>
        "Gruppe liegen. Nutze es, wenn du nicht mehr weißt, wo du stehst."

  defp lesen_beschreibung(%Stand{}),
    do:
      "Gibt die Notizen zurück (PHASEN, SCHLUESSELSZENEN, NICHT_ZEITLEISTE, OFFEN) — die " <>
        "Gruppierung aus dem Überblick und was begründet draussen bleibt. Nutze es, wenn " <>
        "du nicht mehr weißt, welche Abschnitte du gesehen hast."

  # ─── notiz ────────────────────────────────────────────────────────────

  @doc "Einträge schreiben, ersetzen oder streichen (Werkzeug `notiz`)."
  @spec notiz(Stand.t(), map()) :: ergebnis()
  def notiz(%Stand{} = s, %{"eintraege" => eintraege}) do
    Mechanik.eintragen(s, eintraege, %{
      pruefen: &pruefen/4,
      fehlt: &fehlt/1,
      weg: &hinweis/1
    })
  end

  defp fehlt(s) do
    if gruppen(s) == [], do: ["PHASEN"], else: []
  end

  defp pruefen(s, a, k, e) do
    zeile = e["zeile"]
    {fakten, fakten_weg} = Mechanik.aufloesen(e["fakten"], &Stand.fakt(s, &1), & &1.id)
    {boegen, boegen_weg} = Mechanik.aufloesen(e["boegen"], &bogen(s, &1), & &1)
    doppelt = doppelt(s, a, k, fakten)

    cond do
      String.trim(zeile) == "" ->
        {:fehler,
         "#{a}/#{k}: die Zeile ist leer. Schreib hin, worum es in diesem Abschnitt geht, " <>
           "oder lass ihn weg (`zeile: null` streicht einen bestehenden)."}

      fakten_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Fakten gibt es nicht: #{Jason.encode!(fakten_weg)}. Die IDs stehen in " <>
           "der ersten Spalte von fakten()."}

      boegen_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Bögen gibt es nicht: #{Jason.encode!(boegen_weg)}. Nimm die Titel aus " <>
           "boegen_kampagne() oder straenge(), wie sie dort stehen."}

      a in @gruppen and fakten == [] ->
        {:fehler,
         "#{a}/#{k}: der Abschnitt nennt keinen Fakt. Eine Phase fasst Geschehen zusammen " <>
           "— nenn ihre IDs in `fakten`."}

      a == @ausserhalb and fakten == [] ->
        {:fehler,
         "#{a}/#{k}: kein Fakt genannt. Nenn in `fakten`, was du aus der Zeitleiste " <>
           "heraushältst, und in der Zeile, warum."}

      doppelt != nil ->
        {fakt, wo} = doppelt

        {:fehler,
         "#{a}/#{k}: der Fakt #{fakt} liegt schon in „#{wo}“. Jedes Geschehen gehört in " <>
           "höchstens eine Gruppe — nimm ihn dort heraus (denselben Schlüssel erneut " <>
           "schreiben ersetzt den Eintrag) oder lass ihn hier weg."}

      true ->
        {:ok, %{abschnitt: a, schluessel: k, zeile: zeile, fakten: fakten, boegen: boegen}}
    end
  end

  # Der erste Fakt, der schon in einer ANDEREN Gruppe liegt — samt ihrem
  # Schlüssel. Der Eintrag unter demselben Schlüssel zählt nicht mit: ihn
  # ersetzt dieser Aufruf gerade.
  defp doppelt(_s, a, _k, _fakten) when a not in @gruppen and a != @ausserhalb, do: nil

  defp doppelt(s, _a, k, fakten) do
    belegt =
      for n <- s.notizen,
          n.abschnitt in @gruppen or n.abschnitt == @ausserhalb,
          n.schluessel != k,
          id <- n.fakten,
          into: %{},
          do: {id, n.schluessel}

    Enum.find_value(fakten, fn id ->
      case belegt[id] do
        nil -> nil
        wo -> {id, wo}
      end
    end)
  end

  @doc """
  Der Titel eines bekannten Bogens, wie er geschrieben steht: unter den Bögen
  dieser Sitzung, denen der Kampagne oder den Strängen — sonst `nil`.
  """
  @spec bogen(Stand.t(), String.t()) :: String.t() | nil
  def bogen(%Stand{} = s, titel) when is_binary(titel) do
    k = Worker.ThreadOverride.normalize(titel)

    (Enum.map(s.boegen, & &1.titel) ++
       Enum.map(Bisher.alle_boegen(s), & &1.titel) ++ s.mitschnitt.straenge)
    |> Enum.find(&(Worker.ThreadOverride.normalize(&1) == k))
  end

  def bogen(_s, _titel), do: nil

  @doc """
  Die IDs der Fakten, die in einer Gruppe liegen (PHASEN oder
  SCHLUESSELSZENEN). Öffentlich, weil `Worker.Jack.Chronik.Abschluss` daraus
  die offenen Geschehen rechnet — dieselbe Menge, gegen die `fertig` prüft.
  """
  @spec gruppiert(Stand.t()) :: [String.t()]
  def gruppiert(%Stand{} = s), do: echt(s, @gruppen)

  @doc "Die ECHTEN IDs der Fakten unter NICHT_ZEITLEISTE — begründet draussen."
  @spec ausgeschlossen(Stand.t()) :: [String.t()]
  def ausgeschlossen(%Stand{} = s), do: echt(s, [@ausserhalb])

  # Die Notizen halten die kurzen IDs (das Gespräch mit dem Modell); der
  # Abgleich mit Einträgen und Trichter läuft auf den echten. Eine kurze ID
  # ohne Fakt (kann nach dem Prüfen in `pruefen/4` nicht vorkommen) fällt weg.
  defp echt(%Stand{notizen: notizen, fakten: fakten}, abschnitte) do
    karte = Map.new(fakten, &{&1.id, &1.fakt_id})

    for n <- notizen,
        n.abschnitt in abschnitte,
        kurz <- n.fakten,
        echt = karte[kurz],
        echt != nil,
        uniq: true,
        do: echt
  end

  @doc "Die Notizen der beiden Gruppen-Abschnitte."
  @spec gruppen(Stand.t()) :: [map()]
  def gruppen(%Stand{notizen: notizen}), do: Enum.filter(notizen, &(&1.abschnitt in @gruppen))

  @doc "Der Hinweis nach einer Änderung (Antwort von `notiz`, unter `weg`)."
  @spec hinweis(Stand.t()) :: String.t()
  def hinweis(%Stand{} = s) do
    offen = Worker.Jack.Chronik.Abschluss.offene_geschehen(s)
    {phasen, szenen} = Enum.split_with(gruppen(s), &(&1.abschnitt == "PHASEN"))

    "#{length(phasen)} Phasen, #{length(szenen)} Schlüsselszenen, " <>
      "#{length(ausgeschlossen(s))} Fakten begründet ausserhalb; " <>
      case offen do
        [] -> "jedes Geschehen liegt in einer Gruppe."
        ids -> "noch #{length(ids)} Geschehen ohne Gruppe."
      end
  end

  # ─── notizen_lesen ────────────────────────────────────────────────────

  @doc "Die Notizen zurückgeben, mit Schlüsseln und dem Stand der Arbeit (Werkzeug `notizen_lesen`)."
  @spec notizen_lesen(Stand.t(), map()) :: ergebnis()
  def notizen_lesen(%Stand{} = s, _args) do
    eintraege =
      Enum.map(s.notizen, fn n ->
        Antwort.geordnet([
          {"abschnitt", n.abschnitt},
          {"schluessel", n.schluessel},
          {"zeile", n.zeile},
          {"fakten", n.fakten},
          {"boegen", n.boegen}
        ])
      end)

    notizen =
      case String.trim(notizen_text(s)) do
        "" -> "(noch keine Notizen)"
        t -> t
      end

    {s,
     {:ok,
      Antwort.geordnet([{"stand", stand_text(s)}, {"eintraege", eintraege}, {"notizen", notizen}])}}
  end

  @doc "Wo die Arbeit steht, wie `notizen_lesen` und die Kompaktierung es zeigen."
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{lauf: :ueberblick} = s) do
    n = length(s.fakten)
    {phasen, szenen} = Enum.split_with(gruppen(s), &(&1.abschnitt == "PHASEN"))
    offen = Worker.Jack.Chronik.Abschluss.offene_geschehen(s)
    geschehen = length(Worker.Jack.Chronik.Abschluss.ereignisse(s))

    Enum.join(
      [
        "Chronik der Kampagne. Bestand: #{length(s.chronik)} Einträge.",
        "Fakten: #{MapSet.size(s.gelesen)} von #{n} gelesen." <>
          noch_ungelesen(Stand.ungelesen(s)),
        "PHASEN: #{length(phasen)}, SCHLUESSELSZENEN: #{length(szenen)}, " <>
          "NICHT_ZEITLEISTE: #{length(ausgeschlossen(s))} Fakten.",
        "Geschehen behandelt (in einer Gruppe oder begründet ausserhalb): " <>
          "#{geschehen - length(offen)} von #{geschehen}."
      ],
      "\n"
    )
  end

  # Im Schreiben und in der Durchsicht steht die Arbeit an der Chronik selbst;
  # die Notizen sind dort nur noch Lesestoff.
  def stand_text(%Stand{} = s) do
    {phasen, szenen} = Enum.split_with(gruppen(s), &(&1.abschnitt == "PHASEN"))

    "Chronik: #{length(s.eintraege)} Einträge (Bestand vorher: #{length(s.chronik)}). " <>
      "Aus dem Überblick: #{length(phasen)} Phasen, #{length(szenen)} Schlüsselszenen."
  end

  defp noch_ungelesen([]), do: ""

  defp noch_ungelesen(bereiche) do
    mehr = if length(bereiche) > 12, do: " …", else: ""
    " Noch nicht gelesen: " <> Enum.join(Enum.take(bereiche, 12), ", ") <> mehr <> "."
  end

  @doc "Die Notizen als Text, je Abschnitt `kopf` + Name (Default `## `)."
  @spec notizen_text(Stand.t(), String.t()) :: String.t()
  def notizen_text(%Stand{notizen: n}, kopf \\ "## "),
    do: Mechanik.text_aus(n, kopf, Stand.abschnitte(:chronik))

  # ─── Abbild ───────────────────────────────────────────────────────────

  @doc """
  Der Stand als JSON-fähige Map für einen Beobachter (über den Halter,
  Option `:abbild`) — `"jack" => "chronik"` und die Zahlen dieses Jacks:
  Lauf, Betriebsart am Bestand, Lesestand, Phasen, Schlüsselszenen, begründet
  ausserhalb, offene Geschehen, die Einträge mit Wichtigkeit und Fakten-Zahl,
  Zyklen und verwaiste Bezüge, die Notizen und das Journal.

  **Ohne dieses Abbild zeigte die Laufsicht einen Chronik-Lauf als Resümee**
  (`jack: "resuemee"`, dazu Wörter, Gliederung, `max_woerter` — Zahlen, die
  hier keine Bedeutung haben): der Halter fällt ohne `:abbild` auf
  `Worker.Jack.Resuemee.Stand.abbild/1` zurück. Am ersten echten Lauf
  gesehen (18.09.2026) — dieselbe Auffangzweig-Klasse wie
  `Stand.abschnitte(:chronik)` und die geteilten Werkzeugbeschreibungen.
  """
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{} = s) do
    {phasen, szenen} = Enum.split_with(gruppen(s), &(&1.abschnitt == "PHASEN"))

    ordnung =
      case Entwurf.ordnen(s.eintraege) do
        {:ok, %{verwaist: v}} -> %{"zyklen" => [], "verwaiste_bezuege" => v}
        {:zyklus, ids} -> %{"zyklen" => ids, "verwaiste_bezuege" => []}
      end

    %{
      "jack" => "chronik",
      "lauf" => to_string(s.lauf),
      "betriebsart" => if(s.chronik == [], do: "aufbau", else: "verfeinerung"),
      "sitzung" => s.sitzung.nummer,
      "fakten" => length(s.fakten),
      "gelesen" => MapSet.size(s.gelesen),
      "ungelesen" => Stand.ungelesen(s),
      "geschehen" => length(Abschluss.ereignisse(s)),
      "phasen" => length(phasen),
      "schluesselszenen" => length(szenen),
      "ausserhalb" => length(Abschluss.ausserhalb(s)),
      "offene_geschehen" => offene_kurz(s),
      "bestand_vorher" => length(s.chronik),
      "eintraege" => Enum.map(s.eintraege, &eintrag_abbild/1),
      "notizen" => Stand.ablage(s)["notizen"],
      "journal" => s |> Stand.journal_liste() |> Enum.frequencies_by(&elem(&1, 0))
    }
    |> Map.merge(ordnung)
    |> Map.merge(durchsicht_abbild(s))
  end

  # Die Durchsicht, wenn eine läuft. **Sie war der Absturz**: Ohne eigenes
  # Abbild rief der Resümee-Fallback `Resuemee.Durchsicht.abbild/2` auf einem
  # Chronik-Stand, dessen `durchsicht` `nil` ist — `{:badmap, nil}` riss den
  # ganzen Lauf mit (18.09.2026, 11:48, nach 31 Minuten Arbeit). Hier wird
  # `nil` als „keine Durchsicht" gelesen, nicht als Map.
  defp durchsicht_abbild(%Stand{durchsicht: nil}), do: %{}

  defp durchsicht_abbild(%Stand{durchsicht: d, eintraege: eintraege}) do
    erledigt = Map.get(d, :erledigt, %{})

    %{
      "durchsicht" => %{
        "durchgang" => Map.get(d, :durchgang, 1),
        "vorgelegt" => length(Map.get(d, :vorgelegt, [])),
        "bestaetigt" => Enum.count(erledigt, fn {_n, art} -> art == :bestaetigt end),
        "ersetzt" => Enum.count(erledigt, fn {_n, art} -> art == :ersetzt end),
        "offen" => length(eintraege) - map_size(erledigt)
      }
    }
  end

  # Die offenen Geschehen mit den kurzen IDs, die auch das Modell sieht — eine
  # echte ID sagt dem Zuschauer nichts.
  defp offene_kurz(%Stand{fakten: fakten} = s) do
    karte = Map.new(fakten, &{&1.fakt_id, &1.id})
    for id <- Abschluss.offene_geschehen(s), do: Map.get(karte, id, id)
  end

  defp eintrag_abbild(e) do
    %{
      "id" => e.id,
      "titel" => e.titel,
      "wichtigkeit" => e.wichtigkeit,
      "fakten" => length(e.fakt_ids),
      "bezuege" => Ordnung.bezuege(e.zeit_bezug),
      "kuratiert" => e.kuratiert?,
      "neu" => e.neu?,
      "woerter" => e.text |> String.split(~r/\s+/, trim: true) |> length()
    }
  end
end
