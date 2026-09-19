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

  ## Die GUIDs

  Eine Rückfrage beim Setzen (`Worker.Jack.Zeit.Setzen`) gibt eine Kennung
  aus, die **genau einmal** gilt und verfällt, wenn der nächste Aufruf sie
  nicht nennt — `Worker.Jack.Tor`-Muster. Ihr Schicksal wird gemerkt, damit
  „erfunden" von „abgelaufen" unterscheidbar bleibt: Das erste ist ein
  Modellfehler, das zweite normaler Ablauf, und eine Antwort, die beides
  gleich behandelt, schickt Jack in die Wiederholung.
  """

  alias Worker.Jack.Zeit.Mitschnitt

  defstruct lauf: :gedaechtnis,
            session_id: nil,
            campaign_id: nil,
            mitschnitt: [],
            gelesen: MapSet.new(),
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

  @doc "Trägt einen Anker ein (oder ersetzt ihn unter derselben Adresse)."
  @spec setzen(t(), map()) :: t()
  def setzen(%__MODULE__{} = s, anker) do
    %{s | anker: Map.put(s.anker, anker.anker_id, anker), zaehler: s.zaehler + 1}
  end

  @doc "Die Anker, die an mindestens einer dieser Utterances hängen."
  @spec an(t(), [String.t()]) :: [map()]
  def an(%__MODULE__{anker: anker}, utterance_ids) do
    menge = MapSet.new(utterance_ids)

    anker
    |> Map.values()
    |> Enum.filter(fn a ->
      a |> feld(:art) |> to_string() != "geloest" and
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
  Die Zeilen, die Jack noch nicht gesehen hat. Höchstens `deckel` Stück —
  eine Antwort mit 3.679 Zeilen wäre keine Auskunft, sondern der Mitschnitt
  noch einmal.
  """
  @spec offen(t(), pos_integer()) :: %{anzahl: non_neg_integer(), zeilen: [Mitschnitt.zeile()]}
  def offen(%__MODULE__{} = s, deckel \\ 20) do
    fehlend = Enum.reject(s.mitschnitt, &MapSet.member?(s.gelesen, &1.utterance_id))
    %{anzahl: length(fehlend), zeilen: Enum.take(fehlend, deckel)}
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
      verschiebungen: zaehle(aktiv, "ordnung"),
      geloest: map_size(s.anker) - length(aktiv),
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
      "verschiebungen" => z.verschiebungen,
      "geloest" => z.geloest,
      "konflikte" => z.konflikte,
      "notizen" => s.notizen
    }
  end

  defp zaehle(anker, art), do: Enum.count(anker, &(to_string(feld(&1, :art)) == art))

  defp feld(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k))
end
