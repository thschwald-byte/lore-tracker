defmodule HubWeb.CampaignLive.FragFenster.Synthetisch do
  @moduledoc """
  Issue #850, erster Schnitt: erfundene Läufe für den Oberflächen-Prototyp.

  **Hier steht nichts Echtes.** Kein Agent, keine Fakten, keine Werkzeuge —
  nur eine geskriptete Spur, damit sich die Oberfläche beurteilen lässt,
  bevor ein Modelllauf dahinterhängt. Wenn der echte Weg kommt, fällt dieses
  Modul ersatzlos weg; alles andere am Fenster bleibt.

  Die drei Läufe sind die Testfragen aus #850 (Kommentar 5, an echten Daten
  erhoben) — bewusst die, die verschieden scheitern können:

  * `:figur` — eine Frage mit Antwort. Der Normalfall.
  * `:verbindung` — zwei Fundstellen ohne Verbindung. Die Antwort muss NEIN
    sagen, obwohl beide Belege echt sind; im Verlauf der Spur ist das
    sichtbar, bevor der Text es sagt.
  * `:leer` — nichts in den Aufzeichnungen. Das ehrliche „steht nicht drin".

  **Die Verzögerungen sind der Gegenstand der Messung**, nicht Beiwerk: Die
  Entscheidung „die Antwort darf dauern, solange man sieht was passiert"
  (Maintainer, 25.09.2026) lässt sich nur beurteilen, wenn sie wirklich
  dauert. `schritte/1` liefert deshalb je Zeile ein `ms`, das der Aufrufer
  abwartet.
  """

  @typedoc "Eine Zeile der Werkzeug-Konsole."
  @type schritt :: %{
          art: :werkzeug | :denken | :fertig,
          text: String.t(),
          treffer: non_neg_integer() | nil,
          ms: pos_integer()
        }

  @doc """
  Welcher Lauf zu einer Frage gehört — grob über Stichworte, damit man im
  Prototyp gezielt die drei Fälle auslösen kann. Alles Unbekannte landet
  bei `:leer`, weil „nichts gefunden" der ehrlichere Standard ist.
  """
  @spec lauf_fuer(String.t()) :: :figur | :verbindung | :leer
  def lauf_fuer(frage) do
    f = String.downcase(frage)

    cond do
      String.contains?(f, ["wer ist", "wer war", "figur"]) -> :figur
      String.contains?(f, ["mag", "karaoke", "rocker"]) -> :verbindung
      true -> :leer
    end
  end

  @doc "Die Konsolen-Zeilen eines Laufs, in Reihenfolge, mit Wartezeit je Zeile."
  @spec schritte(:figur | :verbindung | :leer) :: [schritt()]
  def schritte(:figur),
    do: [
      w("suche_bisher(\"Lucky\")", 49, 900),
      d(
        "49 Treffer ist viel — ich sehe mir die frühesten an, die Rolle steht meist am Anfang.",
        1400
      ),
      w("fakt(f_8a3c…)", nil, 700),
      w("fakt(f_1f0e…)", nil, 600),
      d("Zwei Aussagen reichen: Name und Rolle. Mehr wäre Aufzählung, nicht Antwort.", 1100),
      f("formuliere die Antwort", 1500)
    ]

  def schritte(:verbindung),
    do: [
      w("suche_bisher(\"Rocker\")", 0, 800),
      d(
        "Kein Treffer. „Rocker\" ist eine Beschreibung, kein Name — ich suche die Sache dahinter.",
        1600
      ),
      w("suche_bisher(\"Motorrad\")", 3, 900),
      w("fakt(f_44b1…)", nil, 600),
      w("suche_bisher(\"Karaoke\")", 3, 800),
      w("fakt(f_2c17…)", nil, 600),
      d("Die Karaoke-Aussagen betreffen eine andere Figur. Zwischen beiden steht nichts.", 1700),
      f("formuliere die Antwort", 1200)
    ]

  def schritte(:leer),
    do: [
      w("suche_bisher(…)", 0, 900),
      w("suche_sitzung(…)", 0, 800),
      d(
        "In den geprüften Fakten steht dazu nichts. Erfinden wäre schlimmer als eine Lücke.",
        1500
      ),
      f("formuliere die Antwort", 900)
    ]

  @doc """
  Die Antwort eines Laufs mit **echten** Belegen, wenn die Fakten-Spalte
  geladen ist.

  Der Antworttext bleibt erfunden — aber die Fundstellen darunter sind
  Fakten der Kampagne, und ihr `↗` springt an die echte Stelle im Protokoll.
  Erst damit lässt sich beurteilen, worum es beim beweglichen Fenster geht:
  einen Beleg nachlesen, ohne das Gespräch zu verlieren.

  Ohne geladene Fakten (Lesemodus, leere Kampagne) bleiben die erfundenen
  Belege — dann ist der Sprung tot, aber die Form sichtbar.
  """
  @spec antwort(:figur | :verbindung | :leer, [map()], [map()]) :: %{
          text: String.t(),
          belege: [map()]
        }
  def antwort(art, fakten, sessions \\ [])

  def antwort(art, fakten, sessions) when is_list(fakten) and fakten != [] do
    nummern = Map.new(sessions, fn s -> {s["id"] || s[:id], s["number"] || s[:number]} end)

    # Deterministisch wählen, damit dieselbe Frage dieselben Belege zeigt.
    gewaehlt =
      fakten
      |> Enum.filter(&((&1["quell_utterance_ids"] || []) != []))
      |> Enum.sort_by(&:erlang.phash2({art, &1["id"]}))
      |> Enum.take(if art == :leer, do: 0, else: 2)

    %{text: text_zu(art, gewaehlt), belege: Enum.map(gewaehlt, &beleg_aus(&1, nummern))}
  end

  def antwort(art, _leer, _), do: antwort(art)

  defp beleg_aus(f, nummern) do
    uid = f["quell_utterance_ids"] |> List.first()
    nr = Map.get(nummern, f["session_id"])

    %{
      id: f["id"],
      sitzung: if(nr, do: "S#{nr}", else: "?"),
      block: "",
      text: f["claim"] || "",
      utterance_id: uid
    }
  end

  defp text_zu(:leer, _), do: "Steht nicht in den Aufzeichnungen."

  defp text_zu(:verbindung, _),
    do:
      "Dazu steht nichts in den Aufzeichnungen. Es gibt Aussagen zu beiden " <>
        "Seiten, aber keine, die sie verbindet."

  defp text_zu(_, fakten) do
    "In den Aufzeichnungen steht dazu: " <>
      (fakten |> Enum.map_join(" — ", & &1["claim"]) |> String.slice(0, 400))
  end

  @doc "Die Antwort eines Laufs ohne geladene Fakten: Text und erfundene Belege."
  @spec antwort(:figur | :verbindung | :leer) :: %{text: String.t(), belege: [map()]}
  def antwort(:figur),
    do: %{
      text:
        "Lucky ist eine Straßensamurai der Gruppe. In den Aufzeichnungen trägt sie " <>
          "eine Panzerjacke und übernimmt im Nahkampf die Deckung der anderen.",
      belege: [
        beleg("f_8a3c…", "S1", 507, "Lotta «Lucky» Kupfer, Straßensamurai"),
        beleg("f_1f0e…", "S1", 612, "… soll alle drei vor Nahkampfangriffen beschützen")
      ]
    }

  def antwort(:verbindung),
    do: %{
      text:
        "Dazu steht nichts in den Aufzeichnungen. Es gibt Aussagen über eine Figur " <>
          "aus einer Motorradgang und getrennt davon Aussagen über Karaoke — eine " <>
          "Verbindung zwischen beiden wird nirgends behauptet.",
      belege: [
        beleg("f_44b1…", "S1", 883, "… ist eine Ancient aus der Motorradgang"),
        beleg("f_2c17…", "S2", 1104, "… singt Karaoke im Dante's")
      ]
    }

  def antwort(:leer),
    do: %{
      text: "Steht nicht in den Aufzeichnungen.",
      belege: []
    }

  @doc """
  Ein Befund, wie ihn #1243 später erzeugt — hier von Hand, damit die
  Eintragsform beide Absender trägt. Die Mechanik dahinter ist nicht Teil
  dieses Schnitts.
  """
  @spec befunde() :: [map()]
  def befunde,
    do: [
      %{
        id: "bf-1",
        titel: "Zwei Aussagen widersprechen sich",
        text: "Eine Figur wird einmal als Mensch geführt und einmal ausdrücklich nicht.",
        belege: [
          beleg("f_9d22…", "S1", 412, "… ist ein Mensch"),
          beleg("f_0ab7…", "S1", 1180, "… ist kein Mensch")
        ]
      },
      %{
        id: "bf-2",
        titel: "Unsichere Zeitangabe",
        text:
          "„drei viertel elf\" — im Spiel gesprochen oder am Tisch? Die Antwort " <>
            "verschiebt den Abend um Stunden.",
        belege: [beleg("f_71ce…", "S3", 506, "Drei viertel elf.")]
      }
    ]

  @doc """
  Welcher Befund an einer Fakt-Zeile hängt — oder `nil`.

  **Im Prototyp gestreut, nicht gemeint:** Ein echter Befund entsteht in
  einem Lauf und zeigt auf die Fakten, die er betrifft (#1243). Hier
  entscheidet ein Hash über der Fakt-ID, damit ungefähr jede zehnte Zeile ein
  Zeichen trägt — deterministisch, also beim Neuladen dieselben, und dünn
  genug, dass die Spalte nicht zur Christbaumbeleuchtung wird.

  Der Zweck ist allein die **Interaktion**: Klick am Objekt öffnet das Fenster
  mit genau diesem Befund, statt ihn in einer Liste suchen zu lassen.
  """
  @spec befund_an_fakt(term()) :: String.t() | nil
  def befund_an_fakt(nil), do: nil

  def befund_an_fakt(fakt_id) do
    case :erlang.phash2(fakt_id, 11) do
      0 -> "bf-1"
      5 -> "bf-2"
      _ -> nil
    end
  end

  @doc "Startfragen unter den Befunden — sie zeigen, was das Fenster kann."
  @spec vorschlaege() :: [String.t()]
  def vorschlaege,
    do: ["Wer ist Lucky?", "Mag die Rockerin Karaoke?", "Was weiß die Gruppe über Ares?"]

  defp w(text, treffer, ms), do: %{art: :werkzeug, text: text, treffer: treffer, ms: ms}
  defp d(text, ms), do: %{art: :denken, text: text, treffer: nil, ms: ms}
  defp f(text, ms), do: %{art: :fertig, text: text, treffer: nil, ms: ms}

  defp beleg(id, sitzung, block, text),
    do: %{id: id, sitzung: sitzung, block: block, text: text, utterance_id: nil}
end
