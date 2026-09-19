defmodule Worker.Jack.Zeit.Stand do
  @moduledoc """
  #1247 (Z2): der Stand eines Zeit-Jack-Laufs — was er gelesen, gesetzt und
  offen gelassen hat. Pur; gehalten wird er von
  `Worker.Jack.Resuemee.Halter`.

  ## Die drei Läufe

      :gedaechtnis   den Ablauf verstehen. Setzt nichts.
      :einsortieren  die neuen Utterances einordnen.
      :pruefen       die ganze Linie lesen und prüfen.

  Maintainer (19.09.2026): „ein neue einsortieren lauf und ein alles prüfen
  lauf" — zwei Läufe mit **verschiedenen Aufträgen**, keine Iteration bis zur
  Sättigung. Ein wiederholter Durchgang sähe zweimal dasselbe; der Prüf-Lauf
  hat einen anderen Gegenstand (die entstandene Linie) als der Einsortier-Lauf
  (der Mitschnitt).

  ## Gelesen wird gezählt, nicht bestätigt

  `fertig()` verlangt, dass jede Utterance **zugeordnet** ist: Sie steht in
  der Reihe — und das tut sie durch die Erzählreihenfolge, solange niemand
  sie anfasst — oder sie ist **draußen**. Offen ist nur, was Jack angefasst
  und nicht zu Ende gebracht hat.

  Damit das prüfbar ist, merkt der Stand sich, welche Zeilen er **ausgegeben**
  hat. Das ist keine Bestätigung je Utterance (3.679 in S3 einzeln zu
  quittieren wäre ein Lauf, der nichts anderes mehr tut), sondern die
  Buchführung darüber, was Jack überhaupt gesehen hat.

  **Diese Buchführung ist hier tragend, nicht Diagnostik** — anders als bei
  der Extraktion, und der Unterschied ist der Grund (Review, 19.09.2026):
  Dort heißt „kein Fakt“ nur *nichts gefunden*, eine Aussage über Jacks
  Ausbeute. Hier heißt „nicht angefasst“ *die Grundordnung stimmt für diese
  Zeile* — eine Aussage über die Welt, die er stillschweigend trifft, ohne
  sie getroffen zu haben. Ohne die Schranke hieße `fertig` bloß „Jack hat
  aufgehört“: Er könnte nach 10 von 3.679 Zeilen abschließen, und die
  übrigen 3.669 gälten als richtig eingeordnet. Das ist die schlechteste
  Sorte Fehler, weil sie wie ein Ergebnis aussieht.

  Das Vorbild steht im Repo: `Worker.Jack.Abschluss.nie_gelesen/1` verlangt
  von der Extraktion, dass sie jeden Block **ansieht** — nicht, dass jeder
  einen Fakt liefert.

  **Ehrliche Grenze:** „gelesen“ heißt *ausgegeben bekommen*, nicht
  *angesehen*. Ein Modell, das die Zeilen anfordert und überfliegt, erfüllt
  die Schranke. Sie ist die untere Grenze, keine Zusicherung, dass jede Zeile
  geprüft wurde — dieselbe Grenze, die die Extraktion seit J4 hat (#1236
  führt sie dort als offene Frage).

  ## Die GUIDs

  Eine Rückfrage beim Setzen (`Worker.Jack.Zeit.Setzen`) gibt eine Kennung
  aus, die **genau einmal** gilt und verfällt, wenn der nächste Aufruf sie
  nicht nennt — `Worker.Jack.Tor`-Muster. Ihr Schicksal wird gemerkt, damit
  „erfunden" von „abgelaufen" unterscheidbar bleibt: Das erste ist ein
  Modellfehler, das zweite normaler Ablauf, und eine Antwort, die beides
  gleich behandelt, schickt Jack in die Wiederholung.
  """

  alias Worker.Jack.Zeit.Mitschnitt
  alias Worker.Timeline.Calendar

  defstruct lauf: :gedaechtnis,
            session_id: nil,
            campaign_id: nil,
            kalender: nil,
            mitschnitt: [],
            gelesen: MapSet.new(),
            einordnung: %{},
            anker: %{},
            offene: %{},
            ausgegeben: %{},
            notizen: %{},
            konflikte: [],
            zaehler: 0

  @type t :: %__MODULE__{}

  @doc "Ein frischer Stand für einen Lauf."
  @spec neu(atom(), [Mitschnitt.zeile()], keyword()) :: t()
  def neu(lauf, mitschnitt, opts \\ []) do
    %__MODULE__{
      lauf: lauf,
      mitschnitt: mitschnitt,
      session_id: opts[:session_id],
      campaign_id: opts[:campaign_id],
      kalender: opts[:kalender] || Calendar.default(),
      anker: Map.new(opts[:anker] || [], &{&1[:anker_id] || &1["anker_id"], &1}),
      notizen: opts[:notizen] || %{}
    }
  end

  @doc """
  Merkt die Zeilen, die Jack sich hat zeigen lassen. Liefert den Stand
  zurück — die Buchführung ist Teil des Lesens, nicht ein zweiter Schritt,
  den jemand vergessen kann.
  """
  @spec gelesen(t(), [Mitschnitt.zeile()]) :: t()
  def gelesen(%__MODULE__{} = s, zeilen) do
    %{s | gelesen: Enum.reduce(zeilen, s.gelesen, &MapSet.put(&2, &1.utterance_id))}
  end

  @doc """
  Ordnet Zeilen ein: `:tisch`, `:ingame` oder `:unklar`.

  **Jede Zeile braucht eine Einordnung, bevor der Einsortier-Lauf
  abschliessen darf** (Maintainer, 19.09.2026). Der Grund ist die Linie
  selbst: Was auf ihr liegt, soll Spielwelt sein. Eine Zeile Tischgespräch,
  die niemand herausgenommen hat, wird interpoliert und bekommt eine
  Spielzeit, die es nicht gibt — und sie sieht hinterher aus wie jede andere.

  Die Einordnung ist **kein eigener Arbeitsschritt**: `loesen` setzt
  `:tisch` (und nimmt die Zeile aus der Kette), `zweifel` setzt `:unklar`,
  `ingame` setzt `:ingame`. Ein zweites Werkzeug nur zum Etikettieren wäre
  derselbe Aufruf zweimal.
  """
  @spec einordnen(t(), [Mitschnitt.zeile()], :tisch | :ingame | :unklar) :: t()
  def einordnen(%__MODULE__{} = s, zeilen, art) when art in [:tisch, :ingame, :unklar] do
    %{s | einordnung: Enum.reduce(zeilen, s.einordnung, &Map.put(&2, &1.utterance_id, art))}
  end

  @doc "Die Zeilen ohne Einordnung — alle, samt Anzahl."
  @spec ohne_einordnung(t()) :: %{anzahl: non_neg_integer(), zeilen: [Mitschnitt.zeile()]}
  def ohne_einordnung(%__MODULE__{} = s) do
    fehlend = Enum.reject(s.mitschnitt, &Map.has_key?(s.einordnung, &1.utterance_id))
    %{anzahl: length(fehlend), zeilen: fehlend}
  end

  @doc """
  Die als `:tisch` eingeordneten Zeilen, die noch auf der Linie liegen.

  Sie sind der zweite Teil der Abschlussbedingung: Tischgespräch gehört aus
  der Kette heraus, nicht bloss etikettiert.
  """
  @spec tisch_in_der_kette(t()) :: [Mitschnitt.zeile()]
  def tisch_in_der_kette(%__MODULE__{} = s) do
    geloest =
      for a <- Map.values(s.anker),
          to_string(feld(a, :art)) == "geloest",
          u <- List.wrap(feld(a, :utterance_ids)),
          into: MapSet.new(),
          do: u

    Enum.filter(s.mitschnitt, fn z ->
      Map.get(s.einordnung, z.utterance_id) == :tisch and
        not MapSet.member?(geloest, z.utterance_id)
    end)
  end

  @doc """
  Schreibt eine Notiz unter einen Abschnitt. Derselbe Schlüssel ersetzt.

  **Ohne dieses Werkzeug wäre der ganze Gedächtnis-Lauf wirkungslos**
  (#1247, zweiter echter Lauf): Der Auftrag verlangt Notizen zu ABLAUF,
  ZEITEN und OFFEN, der Stand trug das Feld — aber nichts schrieb hinein.
  Das Modell las alle 418 Fakten, formulierte den Ablauf, und stellte dann
  fest: „Now I need to write notes (memory)" — es gab kein Werkzeug dafür.
  Der nächste Lauf hätte ein leeres Gedächtnis bekommen.
  """
  @spec notieren(t(), String.t(), String.t(), String.t()) :: t()
  def notieren(%__MODULE__{} = s, abschnitt, schluessel, text) do
    eintrag = %{abschnitt: abschnitt, schluessel: schluessel, text: text}
    %{s | notizen: Map.put(s.notizen, schluessel, eintrag)}
  end

  @doc "Die Notizen eines Abschnitts, in Eintragsreihenfolge."
  @spec notizen(t(), String.t() | nil) :: [map()]
  def notizen(%__MODULE__{notizen: n}, abschnitt \\ nil) do
    n
    |> Map.values()
    |> Enum.filter(&(is_nil(abschnitt) or &1.abschnitt == abschnitt))
    |> Enum.sort_by(& &1.schluessel)
  end

  @doc "Trägt einen Anker ein (oder ersetzt ihn unter derselben Adresse)."
  @spec setzen(t(), map()) :: t()
  def setzen(%__MODULE__{} = s, anker) do
    %{s | anker: Map.put(s.anker, anker.anker_id, anker), zaehler: s.zaehler + 1}
  end

  @doc """
  Die Anker, die an mindestens einer dieser Utterances hängen — mit `art:`
  eingeschränkt auf dieselbe Art.

  **Überlappung, nicht Mengengleichheit — und die Art entscheidet mit.** Beide
  reinen Formen sind unbrauchbar (Review, 19.09.2026): Mengengleichheit fängt
  den Doppeleintrag nicht, gegen den die Rückfrage gebaut ist (derselbe Anker
  in leicht anderer Formulierung hat meist auch eine leicht andere Menge);
  reine Überlappung fragt in dicht annotierter Gegend bei fast jedem neuen
  Anker zurück, und Jack verbringt Runden mit Bestätigen — die #1211-Klasse.

  Die Art trennt die beiden Fälle sauber:

      Spanne + Zeitpunkt an derselben Utterance   → KEIN Konflikt.
        „also ist jetzt so grob eine Stunde vergangen, dann wird es jetzt so
        kurz nach zwölf sein" (S3, Block 1106) — die beiden ergänzen sich,
        und dass an einer Utterance mehrere Anker hängen dürfen, ist die
        Regel, nicht die Ausnahme.

      zwei Zeitpunkte an überlappenden Stellen    → Rückfrage.
        Sie widersprechen sich potenziell, und genau das soll Jack sehen.
  """
  @spec an(t(), [String.t()], keyword()) :: [map()]
  def an(%__MODULE__{anker: anker}, utterance_ids, opts \\ []) do
    menge = MapSet.new(utterance_ids)
    nur_art = opts[:art] && to_string(opts[:art])

    anker
    |> Map.values()
    |> Enum.filter(fn a ->
      art = a |> feld(:art) |> to_string()

      art != "geloest" and
        (is_nil(nur_art) or art == nur_art) and
        a |> feld(:utterance_ids) |> List.wrap() |> Enum.any?(&MapSet.member?(menge, &1))
    end)
  end

  @doc "Gibt eine Kennung aus; sie gilt für den nächsten Aufruf."
  @spec ausgeben(t(), String.t(), map()) :: t()
  def ausgeben(%__MODULE__{} = s, guid, offen) do
    %{s | offene: Map.put(s.offene, guid, offen), ausgegeben: Map.put(s.ausgegeben, guid, :offen)}
  end

  @doc "Löst eine Kennung ein. Eine unbekannte bleibt unbekannt."
  @spec verbrauchen(t(), String.t()) :: t()
  def verbrauchen(%__MODULE__{} = s, guid) do
    ausgegeben =
      if Map.get(s.ausgegeben, guid) == :offen,
        do: Map.put(s.ausgegeben, guid, :eingeloest),
        else: s.ausgegeben

    %{s | offene: Map.delete(s.offene, guid), ausgegeben: ausgegeben}
  end

  @doc """
  Was mit einer Kennung ist: `:offen`, `:eingeloest` oder `nil` (nie
  ausgegeben — also erfunden). Der Unterschied gehört in die Antwort.
  """
  @spec schicksal(t(), String.t()) :: :offen | :eingeloest | nil
  def schicksal(%__MODULE__{ausgegeben: a}, guid), do: Map.get(a, guid)

  @doc "Verfallen lassen, was beim letzten Aufruf offen war und nicht genannt wurde."
  @spec verfallen(t(), String.t() | nil) :: t()
  def verfallen(%__MODULE__{} = s, genannt) do
    %{s | offene: Map.take(s.offene, List.wrap(genannt))}
  end

  @doc "Trägt einen Konflikt ein — ein Befund für die Kuration, keine Korrektur."
  @spec konflikt(t(), map()) :: t()
  def konflikt(%__MODULE__{} = s, eintrag), do: %{s | konflikte: s.konflikte ++ [eintrag]}

  @doc """
  Die Zeilen, die Jack noch nicht gesehen hat — **alle**, samt Anzahl.

  Gedeckelt wird erst bei der Ausgabe, und dort in **Bereichen** statt in
  Einzelnummern (`Worker.Jack.Zeit.Abschluss.bereiche/1`): Wer tausend Zeilen
  offen hat, dem sagen „die nächsten zwölf" nichts über die Lücken.
  """
  @spec offen(t()) :: %{anzahl: non_neg_integer(), zeilen: [Mitschnitt.zeile()]}
  def offen(%__MODULE__{} = s) do
    fehlend = Enum.reject(s.mitschnitt, &MapSet.member?(s.gelesen, &1.utterance_id))
    %{anzahl: length(fehlend), zeilen: fehlend}
  end

  @doc "Die Zählwerte des Laufs — dieselben, die `fertig` prüft."
  @spec zahlen(t()) :: map()
  def zahlen(%__MODULE__{} = s) do
    aktiv = s.anker |> Map.values() |> Enum.reject(&(to_string(feld(&1, :art)) == "geloest"))

    %{
      lauf: s.lauf,
      utterances: length(s.mitschnitt),
      gelesen: MapSet.size(s.gelesen),
      offen: length(s.mitschnitt) - MapSet.size(s.gelesen),
      anker: length(aktiv),
      zeitpunkte: zaehle(aktiv, "zeitpunkt"),
      spannen: zaehle(aktiv, "spanne"),
      fristen: zaehle(aktiv, "frist"),
      verschiebungen: zaehle(aktiv, "ordnung"),
      geloest: map_size(s.anker) - length(aktiv),
      eingeordnet: map_size(s.einordnung),
      ohne_einordnung: length(s.mitschnitt) - map_size(s.einordnung),
      konflikte: length(s.konflikte)
    }
  end

  @doc """
  Das Abbild für die Laufsicht. `"jack" => "zeit"` ist die Marke, an der die
  Seite den Lauf erkennt — wie `"epos"` seit #1210. Ohne eigenes Abbild fiele
  sie auf das des Resümee-Jack zurück und zeigte Wörter und Gliederung, die
  es hier nicht gibt (die Klasse, die beim Chronik-Jack einen Absturz in der
  Durchsicht erzeugte).
  """
  @spec abbild(t()) :: map()
  def abbild(%__MODULE__{} = s) do
    z = zahlen(s)

    %{
      "jack" => "zeit",
      "lauf" => to_string(s.lauf),
      "utterances" => z.utterances,
      "gelesen" => z.gelesen,
      "offen" => z.offen,
      "anker" => z.anker,
      "zeitpunkte" => z.zeitpunkte,
      "spannen" => z.spannen,
      "fristen" => z.fristen,
      "verschiebungen" => z.verschiebungen,
      "geloest" => z.geloest,
      "eingeordnet" => z.eingeordnet,
      "konflikte" => z.konflikte,
      "notizen" => s.notizen
    }
  end

  defp zaehle(anker, art), do: Enum.count(anker, &(to_string(feld(&1, :art)) == art))

  defp feld(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k))
end
