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
  der HÄUFIGSTE genannte Zeitpunkt, ein Datum dagegen die Ausnahme.

  ## Die Wortform ist der Normalfall, nicht der Sonderfall

  Der erste Wurf las **nur** die ziffernförmige Uhrzeit und überließ „drei
  viertel elf" bewusst Jack. Das war an den echten Daten gemessen genau
  verkehrt herum (dave, 19.09.2026, gezählt über die handgelesene
  Referenzliste S1+S3):

      ziffernförmig      2      davon 2 FALLEN
      Wortform           3      davon 3 echte Spielwelt-Anker
      Datum              8
      weder noch        92      Dauern und relative Angaben

  **Alle drei echten Uhrzeit-Anker der Referenzsitzung sind Wortform**
  („Drei viertel elf", „kurz nach zwölf", „Es ist kurz vor zwei"), und
  **beide ziffernförmigen sind Fallen**: „um 20:10 Uhr" ist in Wahrheit die
  Jahreszahl 2010, die die Spracherkennung als Uhrzeit geschrieben hat, und
  „schon 10 Uhr" ist Tischzeit. Das Modul löste also genau die Fälle auf, die
  es nicht durfte, und genau die nicht, auf die es ankommt.

  Gelesen werden deshalb beide Formen. Die Wortformen sind eine geschlossene
  Liste über zwölf Zahlwörtern (`halb`, `viertel`, `drei viertel`, `viertel
  vor/nach`, `kurz vor/nach`, `gegen`, `um`) — kein offenes Feld.

  ## Der Halbtag gehört der KETTE, nicht dem einzelnen Anker

  Eine Wortform ist zwölfdeutig: „drei viertel elf" ist 10:45 oder 22:45.
  Diese Entscheidung auf Jack zu verlagern war der zweite Fehler des ersten
  Wurfs — er kann sie beim Setzen eines einzelnen Ankers **gar nicht
  treffen**: In Block 506 steht der Satz allein; dass Nacht ist, folgt aus
  einem anderen Block und aus der Kette (22:45 → 00:05 → 01:50 ist nur als
  Nacht monoton).

  Deshalb liefert dieses Modul für eine Wortform eine **Halbtagsminute**
  (`:halbtag_minute`, 0–719) statt einer Tagesminute, und
  `Worker.Timeline.Linie` löst sie **relativ zur vorhergehenden** auf: Sie
  nimmt die nächste Minute vorwärts, die auf `halbtag_minute` endet. Damit
  ist der Fehler, den die Verlagerung erzeugt hätte, **strukturell
  ausgeschlossen** statt bloss unwahrscheinlich — die Kette 22:45 → 00:05 →
  01:50 und die Kette 10:45 → 12:05 → 13:50 haben dieselben Abstände, und die
  Linie braucht die Abstände. Läge die Wahl bei Jack und er schriebe 10:45,
  entstünde beim Rücksprung auf 00:05 ein Tageswechsel, und die Sitzung
  spannte fünfzehn Stunden statt drei — jede Einzelprüfung grün, das Ergebnis
  um einen halben Tag falsch.

  Weiss Jack den Halbtag doch (weil es dasteht), sagt er ihn im Feld
  `halbtag`; dann wird daraus sofort eine feste Tagesminute. Der absolute
  Tagesbezug der ganzen Kette kommt ohnehin erst von einem Datums-Anker; ohne
  einen ist die Linie relativ, und das ist sie ohne Uhrzeiten auch.

  ## Was dieses Modul NICHT erkennen kann

  „um 20:10 Uhr" ist eine formal einwandfreie Uhrzeit und in Wahrheit eine
  Jahreszahl. Kein Muster trennt das — nur der Zusammenhang, in dem der Satz
  steht. Der Schutz dagegen steht in der Werkzeugbeschreibung, wo Jack ihn
  bei jedem Aufruf liest, nicht hier.
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

  # Die zwölf Zahlwörter der Uhr. „ein"/„eins" beide, weil beides gesagt wird
  # („kurz vor eins", „viertel nach ein").
  @zahlwort %{
    "ein" => 1, "eins" => 1, "zwei" => 2, "drei" => 3, "vier" => 4,
    "fünf" => 5, "fuenf" => 5, "sechs" => 6, "sieben" => 7, "acht" => 8,
    "neun" => 9, "zehn" => 10, "elf" => 11, "zwölf" => 12, "zwoelf" => 12
  }


  # Die geschlossene Liste der Wortformen. Die Reihenfolge ist tragend:
  # „drei viertel elf" muss VOR „viertel elf" stehen, sonst liest das kürzere
  # Muster „viertel elf" (10:15) aus „drei viertel elf" (10:45) — ein stiller
  # Fehler von einer halben Stunde.
  @wortformen [
    {~r/\bdrei\s*viertel\s+(?<z>\p{L}+)/iu, 45, :vor_naechster},
    {~r/\bviertel\s+vor\s+(?<z>\p{L}+)/iu, 45, :vor_naechster},
    {~r/\bviertel\s+nach\s+(?<z>\p{L}+)/iu, 15, :diese},
    {~r/\bviertel\s+(?<z>\p{L}+)/iu, 15, :vor_naechster},
    {~r/\bhalb\s+(?<z>\p{L}+)/iu, 30, :vor_naechster},
    {~r/\bkurz\s+vor\s+(?<z>\p{L}+)/iu, -10, :diese},
    {~r/\bkurz\s+nach\s+(?<z>\p{L}+)/iu, 5, :diese},
    {~r/\b(?:gegen|um)\s+(?<z>\p{L}+)\s+uhr\b/iu, 0, :diese},
    {~r/\b(?<z>\p{L}+)\s+uhr\b/iu, 0, :diese}
  ]

  @doc """
  Setzt `:minute` (Zeitpunkt) bzw. `:minuten` (Spanne), soweit der Parser den
  Ausdruck hergibt. Alles andere bleibt unverändert.
  """
  @spec aufloesen(map(), term()) :: map()
  def aufloesen(%{art: art} = a, cal) when art in [:zeitpunkt, "zeitpunkt"] do
    wert = to_string(Map.get(a, :wert, ""))
    a = mit_uhrzeit(a, wert)

    case Parser.parse(cal, wert) do
      {:ok, %{typ: :date, von: von}} when is_integer(von) ->
        Map.put(a, :minute, von * Linie.minuten_pro_tag())

      _ when is_map_key(a, :tagesminute) or is_map_key(a, :halbtag_minute) ->
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
  Die Tagesminute einer ziffernförmigen Uhrzeit (0–1439), sonst `nil`.

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
  Die Halbtagsminute einer in Worten gesagten Uhrzeit (0–719), sonst `nil`.

  „Drei viertel elf" ergibt 645 — das ist 10:45 **oder** 22:45; welches von
  beiden, entscheidet die Kette in `Worker.Timeline.Linie`, nicht dieses
  Modul und nicht das Modell.

  Eine ziffernförmige Uhrzeit hat hier nichts verloren: Sie ist schon
  eindeutig, und sie hier noch einmal zu lesen machte aus einer Aussage eine
  Vermutung.
  """
  @spec halbtag_minute(String.t()) :: non_neg_integer() | nil
  def halbtag_minute(wert) when is_binary(wert) do
    if tagesminute(wert), do: nil, else: wortform(wert)
  end

  def halbtag_minute(_), do: nil

  @doc """
  Macht aus einer Halbtagsminute eine Tagesminute, wenn der Halbtag bekannt
  ist. `"unklar"`, `nil` und alles Unbekannte lassen sie, wie sie ist — die
  Kette löst sie dann auf.
  """
  @spec mit_halbtag(non_neg_integer(), term()) :: non_neg_integer() | nil
  def mit_halbtag(hm, halbtag) when is_integer(hm) do
    case halbtag && String.downcase(to_string(halbtag)) do
      "vormittag" -> hm
      "nachmittag" -> hm + 720
      _ -> nil
    end
  end

  def mit_halbtag(_, _), do: nil

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

  # Eine eindeutige Uhrzeit wird zur Tagesminute; eine Wortform zur
  # Halbtagsminute — es sei denn, Jack hat den Halbtag dazugesagt, dann ist
  # auch sie eindeutig.
  defp mit_uhrzeit(a, wert) do
    cond do
      tm = tagesminute(wert) ->
        Map.put(a, :tagesminute, tm)

      hm = halbtag_minute(wert) ->
        case mit_halbtag(hm, Map.get(a, :halbtag)) do
          nil -> Map.put(a, :halbtag_minute, hm)
          tm -> Map.put(a, :tagesminute, tm)
        end

      true ->
        a
    end
  end

  # Das erste passende Muster gewinnt; die Liste ist nach Länge geordnet, das
  # ist tragend (s. @wortformen).
  defp wortform(wert) do
    Enum.find_value(@wortformen, fn {muster, offset, bezug} ->
      with %{"z" => wort} <- Regex.named_captures(muster, wert),
           stunde when is_integer(stunde) <- @zahlwort[String.downcase(wort)] do
        basis = if bezug == :vor_naechster, do: stunde - 1, else: stunde
        Integer.mod(Integer.mod(basis, 12) * 60 + offset, 720)
      else
        _ -> nil
      end
    end)
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
