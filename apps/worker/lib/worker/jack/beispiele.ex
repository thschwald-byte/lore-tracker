defmodule Worker.Jack.Beispiele do
  @moduledoc """
  Der Beispielsatz für den Regelfilter-Lauf (Tom, 11.09.2026): Stellen aus
  Mitschnitten mit ihrer Einordnung — Regel, gemischt, Handlung —, die Jack
  über die Werkzeuge `beispiele` und `beispiel` nachschlägt, statt einer
  Wortliste zu folgen („Teufelszeug“, Tom). Pur: Text hinein, Struktur und
  Antworten heraus.

  **Festlegung von eve (11.09.), wörtlich gleich in pi (`werkzeuge.ts`):**

    * Die Datei ist UTF-8. Kopfzeile
      `### Beispiel <n> · <Regel|gemischt|Handlung|entfallen>[ · <Stichwort>]`
      (Trenner Leerzeichen, U+00B7, Leerzeichen). Ein Abschnitt reicht von
      seiner Kopfzeile bis vor die nächste, am Ende ohne Leerraum.
    * Alles vor der ersten Kopfzeile sind die `regeln`, ohne Leerraum am Ende
      und ohne eine abschließende Zeile `---`.
    * Eine doppelte Nummer oder eine unlesbare Kopfzeile ist ein Fehler beim
      Laden — der Lauf startet nicht, statt still ohne Werkzeug zu laufen.
    * Die Nummern sind dauerhaft: gestrichene bleiben als
      `### Beispiel <n> · entfallen` stehen. Sie erscheinen in der Übersicht,
      treffen bei der Suche nie und fehlen in `alle`.
    * Antworten sind kompaktes JSON mit fester Schlüsselreihenfolge
      (`Jason.OrderedObject`); ein Fehler ist ein normales Ergebnis mit
      `fehler`, kein Werkzeugfehler.
    * Suche: im ganzen Abschnitt samt Kopfzeile, beide Seiten kleingeschrieben,
      die Anfrage an Leerraum in Wörter geteilt; ein Treffer enthält jedes Wort
      als Teilzeichenkette.
    * Nur in Phase 2 und den Folgedurchgängen; beide Werkzeuge sind von der
      Wiederholungssperre ausgenommen — das erneute Lesen nach einer
      Kompaktierung ist gewollt.

  `sha256` (über die Bytes der Datei, wie gelesen) und `pfad` stehen in
  `messlauf.json`, damit ein Ergebnis immer auf genau diesen Satz zurückgeht.
  """

  @enforce_keys [:regeln, :eintraege, :sha256]
  defstruct @enforce_keys ++ [pfad: nil]

  @type eintrag :: %{
          nummer: pos_integer(),
          klasse: String.t(),
          stichwort: String.t() | nil,
          text: String.t()
        }
  @type t :: %__MODULE__{
          regeln: String.t(),
          eintraege: [eintrag()],
          sha256: String.t(),
          pfad: Path.t() | nil
        }

  @kopf ~r/^### Beispiel (\d+) · (Regel|gemischt|Handlung|entfallen)(?: · (.+))?$/u
  # Kandidat für eine Kopfzeile ist nur, was mit „### Beispiel “ samt
  # Leerzeichen beginnt (wie in pi); „### Beispiele sind …“ gehört zum Text.
  @kopf_anfang "### Beispiel "

  @beschreibung_beispiele "Beispiele dafür, was eine Aussage ist und was Regelgerede: jeweils " <>
                            "ein Stück Mitschnitt, die Entscheidung und die Begründung. Ohne " <>
                            "Angabe: die Grundregel und die Übersicht aller Beispiele (Nummer, " <>
                            "Klasse, Stichwort). Mit suche: die Beispiele, in denen die Wörter " <>
                            "vorkommen. Mit alle: true: die Grundregel und alle Beispiele " <>
                            "vollständig."
  @beschreibung_suche "Ein oder mehrere Wörter. Treffer sind die Beispiele, in denen jedes " <>
                        "Wort vorkommt, auch als Teil eines Wortes; Groß- und Kleinschreibung " <>
                        "zählt nicht."
  @beschreibung_alle "true: alle Beispiele vollständig am Stück."
  @beschreibung_beispiel "Ein Beispiel vollständig: Mitschnitt, Entscheidung, Begründung."
  @beschreibung_nummer "Die Nummer aus der Übersicht."

  # ─── Lesen ────────────────────────────────────────────────────────────

  @doc "Liest die Datei; Fehler, wenn sie fehlt oder keinen gültigen Satz enthält."
  @spec laden(Path.t()) :: {:ok, t()} | {:error, term()}
  def laden(pfad) do
    case File.read(pfad) do
      {:ok, text} -> lesen(text, pfad)
      {:error, grund} -> {:error, {:beispiele_datei, pfad, grund}}
    end
  end

  @doc "Zerlegt den Text der Datei."
  @spec lesen(String.t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def lesen(text, pfad \\ nil) when is_binary(text) do
    zeilen = String.split(text, "\n")

    with :ok <- kopfzeilen_pruefen(zeilen) do
      {vor, bloecke} = zerlegen(zeilen)
      eintraege = Enum.map(bloecke, &eintrag/1)
      nummern = Enum.map(eintraege, & &1.nummer)

      cond do
        eintraege == [] ->
          {:error, :keine_beispiele}

        (doppelt = nummern -- Enum.uniq(nummern)) != [] ->
          {:error, {:doppelte_nummer, Enum.uniq(doppelt)}}

        true ->
          {:ok,
           %__MODULE__{
             regeln: regeln(vor),
             eintraege: eintraege,
             sha256: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
             pfad: pfad
           }}
      end
    end
  end

  @doc "Das Beispiel mit der Nummer, oder `nil`."
  @spec eintrag(t(), integer()) :: eintrag() | nil
  def eintrag(%__MODULE__{eintraege: e}, nummer), do: Enum.find(e, &(&1.nummer == nummer))

  @doc "Ist das Beispiel gestrichen?"
  @spec entfallen?(eintrag()) :: boolean()
  def entfallen?(%{klasse: klasse}), do: klasse == "entfallen"

  @doc "Die höchste Nummer in der Datei; entfallene zählen mit."
  @spec max(t()) :: pos_integer()
  def max(%__MODULE__{eintraege: e}), do: e |> Enum.map(& &1.nummer) |> Enum.max()

  defp kopfzeilen_pruefen(zeilen) do
    case Enum.find(
           zeilen,
           &(String.starts_with?(&1, @kopf_anfang) and not Regex.match?(@kopf, &1))
         ) do
      nil -> :ok
      zeile -> {:error, {:unlesbare_kopfzeile, zeile}}
    end
  end

  # Alles vor der ersten Kopfzeile, danach je Kopfzeile ein Abschnitt.
  defp zerlegen(zeilen) do
    {vor, rest} = Enum.split_while(zeilen, &(not Regex.match?(@kopf, &1)))

    bloecke =
      Enum.chunk_while(
        rest,
        [],
        fn z, acc ->
          if Regex.match?(@kopf, z) and acc != [],
            do: {:cont, Enum.reverse(acc), [z]},
            else: {:cont, [z | acc]}
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    {vor, bloecke}
  end

  defp regeln(vor) do
    zeilen = vor |> Enum.join("\n") |> String.trim_trailing() |> String.split("\n")

    if List.last(zeilen) == "---",
      do: zeilen |> Enum.drop(-1) |> Enum.join("\n") |> String.trim_trailing(),
      else: Enum.join(zeilen, "\n")
  end

  defp eintrag([kopf | _] = zeilen) do
    {nummer, klasse, stichwort} =
      case Regex.run(@kopf, kopf) do
        [_, n, k] -> {n, k, nil}
        [_, n, k, s] -> {n, k, s}
      end

    %{
      nummer: String.to_integer(nummer),
      klasse: klasse,
      stichwort: stichwort,
      text: zeilen |> Enum.join("\n") |> String.trim_trailing()
    }
  end

  # ─── Werkzeuge ────────────────────────────────────────────────────────

  @doc "Die Definitionen von `beispiele` und `beispiel` (Form wie in `Worker.Jack.Werkzeuge`)."
  @spec werkzeuge(t()) :: [map()]
  def werkzeuge(%__MODULE__{} = b) do
    [
      %{
        name: "beispiele",
        beschreibung: @beschreibung_beispiele,
        parameter: %{
          "type" => "object",
          "properties" => %{
            "suche" => %{"type" => "string", "description" => @beschreibung_suche},
            "alle" => %{"type" => "boolean", "description" => @beschreibung_alle}
          }
        },
        optional: ["suche", "alle"],
        wiederholung: :frei,
        ausfuehren: fn s, args -> {s, beispiele(b, args)} end
      },
      %{
        name: "beispiel",
        beschreibung: @beschreibung_beispiel,
        parameter: %{
          "type" => "object",
          "properties" => %{
            "nummer" => %{"type" => "integer", "description" => @beschreibung_nummer}
          }
        },
        wiederholung: :frei,
        ausfuehren: fn s, %{"nummer" => n} -> {s, beispiel(b, n)} end
      }
    ]
  end

  @doc "Werkzeug `beispiele`: Übersicht, Suche oder alle."
  @spec beispiele(t(), map()) :: {:ok, Jason.OrderedObject.t()}
  def beispiele(%__MODULE__{} = b, args) do
    suche = args["suche"]
    alle = args["alle"] == true

    cond do
      is_binary(suche) and alle -> fehler("Entweder suche oder alle, nicht beides.")
      is_binary(suche) and String.trim(suche) == "" -> fehler("suche ist leer.")
      is_binary(suche) -> suchen(b, suche)
      alle -> vollstaendig(b)
      true -> uebersicht(b)
    end
  end

  @doc "Werkzeug `beispiel`: genau eines, der ganze Abschnitt samt Kopfzeile."
  @spec beispiel(t(), integer()) :: {:ok, Jason.OrderedObject.t()}
  def beispiel(%__MODULE__{} = b, n) do
    case eintrag(b, n) do
      nil ->
        fehler("Beispiel #{n} gibt es nicht, vorhanden sind 1–#{max(b)}.")

      e ->
        if entfallen?(e),
          do: fehler("Beispiel #{n} ist entfallen."),
          else: {:ok, o([{"nummer", e.nummer}, {"text", e.text}])}
    end
  end

  defp uebersicht(b) do
    {:ok,
     o([
       {"regeln", b.regeln},
       {"beispiele", Enum.map(b.eintraege, &kurz/1)},
       {"hinweis", "beispiel(n) zeigt ein Beispiel vollständig, beispiele(alle: true) alle."}
     ])}
  end

  defp suchen(b, suche) do
    woerter = suche |> String.downcase() |> String.split()

    treffer =
      for e <- b.eintraege,
          not entfallen?(e),
          text = String.downcase(e.text),
          Enum.all?(woerter, &String.contains?(text, &1)),
          do: kurz(e)

    hinweis =
      if treffer == [],
        do: "Kein Beispiel enthält „#{suche}“. beispiele() zeigt die Übersicht.",
        else: "beispiel(n) zeigt ein Beispiel vollständig."

    {:ok, o([{"suche", suche}, {"treffer", treffer}, {"hinweis", hinweis}])}
  end

  defp vollstaendig(b) do
    {:ok,
     o([
       {"regeln", b.regeln},
       {"beispiele",
        for(e <- b.eintraege, not entfallen?(e), do: o([{"nummer", e.nummer}, {"text", e.text}]))}
     ])}
  end

  defp kurz(e),
    do: o([{"nummer", e.nummer}, {"klasse", e.klasse}, {"stichwort", e.stichwort || ""}])

  defp fehler(text), do: {:ok, o([{"fehler", text}])}

  defp o(paare), do: Jason.OrderedObject.new(paare)
end
