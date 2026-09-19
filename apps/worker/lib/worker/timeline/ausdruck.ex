defmodule Worker.Timeline.Ausdruck do
  @moduledoc """
  #1247 (Z1/Z2): aus dem gesprochenen Ausdruck eines Ankers wird eine Zahl —
  ein Zeitpunkt seine Minute, eine Spanne ihre Dauer.

  **Pur, und deshalb hier und nicht im Repo.** Die Rechnung stand zuerst in
  `Worker.Repo.Zeit`, weil der Leser sie zuerst brauchte; sie hängt aber an
  nichts als `Worker.Timeline.Parser` und dem Kalender. Der Zeit-Jack braucht
  dieselbe Rechnung **während** seines Laufs — seine `linie()` zeigt sonst
  eine Reihe ohne eine einzige belegte Zeit, und genau das soll sie ja
  prüfbar machen. Zwei Kopien wären zwei Ergebnisse: Jack sähe im Lauf etwas
  anderes als das, was nachher gespeichert gelesen wird.

  **Was der Parser nicht auflöst, bekommt keine Zahl.** Der Anker gilt
  trotzdem — für die Ordnung, und als Beleg dafür, dass an dieser Stelle über
  Zeit gesprochen wurde. Raten wäre hier dieselbe Klasse wie die gerechneten
  Tage aus #1092.

  ## Die Uhrzeit rechnet dieses Modul selbst

  `Worker.Timeline.Parser` kennt eine Uhrzeit nur als `:time` — „feiner als
  ein Tag, Tageszähler kann es nicht" — und liefert dafür **keine** Zahl. Für
  einen Kalender war das richtig; für die Linie, die in Minuten rechnet, ist
  es die Lücke an der entscheidenden Stelle: Am Spieltisch ist die Uhrzeit
  der HÄUFIGSTE genannte Zeitpunkt („drei viertel elf", „kurz nach zwölf"),
  ein Datum dagegen die Ausnahme. Ohne sie bliebe die Linie auf echten Daten
  fast überall leer, und `linie()` zeigte Jack eine Reihe aus Strichen.

  Eine Uhrzeit ist keine absolute Minute, sondern eine **Tagesminute**
  (`:tagesminute`); an welchem Tag sie liegt, entscheidet
  `Worker.Timeline.Linie` aus ihrer Stelle in der Reihe.

  **Gelesen wird nur die ziffernförmige Uhrzeit** (`22:45`, `22 Uhr 45`,
  `22 Uhr`), und zwar im 24-Stunden-Raum. Wortformen („drei viertel elf",
  „halb zehn") bleiben ohne Zahl — nicht aus Bequemlichkeit, sondern weil sie
  **zwölfdeutig** sind: „drei viertel elf" ist 10:45 oder 22:45, und welche
  von beiden gilt, steht nicht im Ausdruck, sondern im Gespräch drumherum.
  Diese Entscheidung gehört zu Jack, der den Kontext hat, nicht zu einem
  Regex, der rät — die Werkzeugbeschreibung sagt ihm deshalb, dass er eine
  gemeinte Uhrzeit in Ziffern nennt. Ein geratenes AM/PM wäre ein Fehler von
  zwölf Stunden, der wie ein Ergebnis aussieht.
  """

  require Logger

  alias Worker.Timeline.{Linie, Parser}

  # `22:45`, `22 Uhr 45`, `22 Uhr`. Der Doppelpunkt ist der einzige erlaubte
  # Trenner ohne das Wort „Uhr": `22.45` wäre von einem Datum nicht zu
  # unterscheiden. Benannte Gruppen, weil die beiden Schreibweisen die Minute
  # an verschiedenen Stellen tragen — mit nummerierten Gruppen hinge die
  # Auswertung an der Zahl der Treffer, und „22 Uhr 45" liefe still in den
  # Zweig für „22:45".
  @uhrzeit ~r/\b(?<h>\d{1,2})(?::(?<m1>\d{2})|\s*uhr(?:\s+(?<m2>\d{1,2}))?)/iu

  @doc """
  Setzt `:minute` (Zeitpunkt) bzw. `:minuten` (Spanne), soweit der Parser den
  Ausdruck hergibt. Alles andere bleibt unverändert.
  """
  @spec aufloesen(map(), term()) :: map()
  def aufloesen(%{art: art} = a, cal) when art in [:zeitpunkt, "zeitpunkt"] do
    wert = to_string(Map.get(a, :wert, ""))
    a = mit_tagesminute(a, wert)

    case Parser.parse(cal, wert) do
      {:ok, %{typ: :date, von: von}} when is_integer(von) ->
        Map.put(a, :minute, von * Linie.minuten_pro_tag())

      _ when is_map_key(a, :tagesminute) ->
        a

      {:ok, %{typ: typ}} ->
        Logger.debug(fn ->
          "Zeit: Anker #{a[:anker_id]} ist als Zeitpunkt gesetzt, gelesen als #{typ} — ohne Datum"
        end)

        a

      _ ->
        a
    end
  end

  def aufloesen(%{art: art} = a, cal) when art in [:spanne, "spanne"] do
    case Parser.parse(cal, to_string(Map.get(a, :wert, ""))) do
      {:ok, %{laenge: {menge, einheit}}} when is_integer(menge) ->
        Map.put(a, :minuten, minuten(menge, einheit))

      _ ->
        a
    end
  end

  def aufloesen(a, _cal), do: a

  @doc """
  Die Tagesminute einer ziffernförmigen Uhrzeit, sonst `nil`.

  Die Stunde muss 0–23 sein und die Minute 0–59; alles andere ist keine
  Uhrzeit, sondern eine Zahl, die zufällig so aussieht. Ein Datum („15.11.")
  wird nicht getroffen — der Punkt als Trenner ist bewusst NICHT erlaubt.
  """
  @spec tagesminute(String.t()) :: non_neg_integer() | nil
  def tagesminute(wert) when is_binary(wert) do
    case Regex.named_captures(@uhrzeit, wert) do
      %{"h" => h, "m1" => m1, "m2" => m2} -> minute_aus(h, erste_minute(m1, m2))
      _ -> nil
    end
  end

  def tagesminute(_), do: nil

  @doc """
  Wie der Parser den Ausdruck gelesen hat — für die Antwort an Jack.

  `:kein_ausdruck` heißt: Der Parser erkennt hier nichts Datierbares. Das ist
  kein Fehler (ein Anker darf einen Ausdruck tragen, den niemand in Minuten
  umrechnet), aber Jack soll es erfahren, statt zu glauben, er habe eine
  Uhrzeit gesetzt.
  """
  @spec gelesen_als(String.t(), term()) :: {:ok, atom()} | :kein_ausdruck
  def gelesen_als(wert, cal) do
    case Parser.parse(cal, to_string(wert)) do
      {:ok, %{typ: typ}} -> {:ok, typ}
      _ -> :kein_ausdruck
    end
  end

  defp mit_tagesminute(a, wert) do
    case tagesminute(wert) do
      nil -> a
      tm -> Map.put(a, :tagesminute, tm)
    end
  end

  defp erste_minute("", ""), do: "0"
  defp erste_minute("", m2), do: m2
  defp erste_minute(m1, _), do: m1

  defp minute_aus(h, m) do
    with {hh, ""} <- Integer.parse(to_string(h)),
         {mm, ""} <- Integer.parse(to_string(m)),
         true <- hh in 0..23 and mm in 0..59 do
      hh * 60 + mm
    else
      _ -> nil
    end
  end

  defp minuten(menge, :second), do: max(div(menge, 60), 0)
  defp minuten(menge, :minute), do: menge
  defp minuten(menge, :hour), do: menge * 60
  defp minuten(menge, :day), do: menge * Linie.minuten_pro_tag()
  defp minuten(menge, :week), do: menge * 7 * Linie.minuten_pro_tag()
  defp minuten(menge, :month), do: menge * 30 * Linie.minuten_pro_tag()
  defp minuten(menge, :year), do: menge * 365 * Linie.minuten_pro_tag()
  defp minuten(_, _), do: 0
end
