defmodule Worker.Agent.Wiederholung do
  @moduledoc """
  Erkennt, wenn ein Agent sich im Kreis dreht, führt die Wiederholung nicht
  mehr aus und bricht den Lauf ab, wenn er nicht aufhört.

  Anlass war Folgedurchgang 2 der Reihe C im Spike #1174 (10.09.2026): ab dem
  110. Aufruf wiederholte Jack einen Block aus neun wörtlich gleichen Aufrufen
  rund dreißigmal — zweimal `suche()`, einmal `aussage()` für immer dieselben
  drei Aussagen, 118 „verify“ gegen 5 Einträge. Er benutzte `aussage()` als
  Abfrage und behielt nicht, was er schon geprüft hatte.

  Toms Vorgaben (10.09.2026, an dave und an eve):

    * „wir merken uns jeden toolaufruf mit seinen parametern in einem lauf“ —
      jeder erneute Aufruf mit exakt demselben Inhalt ist eine Wiederholung,
      egal was dazwischen lag. So fallen auch Schleifen über mehrere
      Werkzeuge auf (Werkzeug 1 → 2 → 3 → von vorn): jeder ihrer Aufrufe
      kehrt wieder.
    * „nachdem 3ten (quasi beim 4ten) kommt die warnung und da wird das
      werkzeug auch nicht ausgeführt“ — der vierte gleiche Aufruf läuft
      nicht, seine Antwort ist die Warnung: den Punkt liegen lassen, beim
      nächsten weitermachen, beim sechsten Mal Abbruch.
    * „kommt er das 6te mal lauf abbrechen“ — der sechste gleiche Aufruf
      beendet den Lauf mit `{:abbruch, {:wiederholung, name}}`.
    * Die Ausnahmen, die Tom eve bestätigt hat, trägt jedes Werkzeug selbst
      (`Worker.Agent.Werkzeug`, Option `wiederholung:`): `:frei` wird nie
      gezählt (`weiter`, `notizen_lesen`, `cast`, `straenge`, `fertig`);
      `:bis_aenderung` zählt nur, solange sich der Bestand nicht geändert hat
      (`aussagen`, `aenderungen`, `ablehnungen` — ihre Antwort hängt am
      Bestand). Eine Bestandsänderung meldet der Lauf über
      `bestand_geaendert/1`, nach jedem erfolgreichen Aufruf eines Werkzeugs
      mit `aendert_bestand: true`.

  „Derselbe Inhalt“ heißt: gleicher Werkzeugname und gleiche Argumente, wie
  das Modell sie geschickt hat (kaputte Argumente über ihren Rohtext).
  Gezählt wird über den ganzen Lauf; die Kompaktierung setzt nicht zurück.

  **Ehrliche Grenze:** auch ein erneuter Aufruf, der wegen einer veränderten
  Lage berechtigt ist, zählt mit, wenn das Werkzeug `:zaehlt` trägt — ab dem
  vierten Mal läuft er nicht mehr, beim sechsten endet der Lauf.

  Rein funktional; der Zustand reist im Lauf mit.
  """

  defstruct warnung: 4, abbruch: 6, gesehen: %{}

  @type art :: :zaehlt | :bis_aenderung
  @type t :: %__MODULE__{
          warnung: pos_integer(),
          abbruch: pos_integer(),
          gesehen: %{{art(), term()} => pos_integer()}
        }
  @type status :: nil | {:warnung, pos_integer()} | {:abbruch, pos_integer()}

  @doc """
  Neuer Zustand. `warnung` und `abbruch` sind die Nummer des gleichen Aufrufs,
  ab der er nicht mehr ausgeführt bzw. der Lauf abgebrochen wird (Default 4
  und 6).
  """
  @spec neu(keyword()) :: {:ok, t()} | {:error, String.t()}
  def neu(opts) when is_list(opts) do
    warnung = Keyword.get(opts, :warnung, 4)
    abbruch = Keyword.get(opts, :abbruch, 6)

    if is_integer(warnung) and is_integer(abbruch) and warnung >= 2 and abbruch > warnung do
      {:ok, %__MODULE__{warnung: warnung, abbruch: abbruch}}
    else
      {:error,
       "warnung ≥ 2 und abbruch > warnung erwartet (Nummer des gleichen Aufrufs), " <>
         "erhalten #{inspect(opts)}"}
    end
  end

  @doc """
  Nimmt einen Aufruf auf; `schluessel` ist `{name, argumente}`, `art` sagt,
  ob eine Bestandsänderung seine Zählung zurücksetzt. Liefert den neuen
  Zustand und, ab der jeweiligen Schwelle, `{:warnung, n}` oder
  `{:abbruch, n}` — `n` ist die Nummer dieses gleichen Aufrufs.
  """
  @spec beobachten(t() | nil, term(), art()) :: {t() | nil, status()}
  def beobachten(w, schluessel, art \\ :zaehlt)
  def beobachten(nil, _schluessel, _art), do: {nil, nil}

  def beobachten(%__MODULE__{} = w, schluessel, art) when art in [:zaehlt, :bis_aenderung] do
    anzahl = Map.get(w.gesehen, {art, schluessel}, 0) + 1
    w = %{w | gesehen: Map.put(w.gesehen, {art, schluessel}, anzahl)}

    status =
      cond do
        anzahl >= w.abbruch -> {:abbruch, anzahl}
        anzahl >= w.warnung -> {:warnung, anzahl}
        true -> nil
      end

    {w, status}
  end

  @doc "Der Bestand hat sich geändert: die Zählung der `:bis_aenderung`-Aufrufe beginnt neu."
  @spec bestand_geaendert(t() | nil) :: t() | nil
  def bestand_geaendert(nil), do: nil

  def bestand_geaendert(%__MODULE__{} = w),
    do: %{w | gesehen: Map.reject(w.gesehen, fn {{art, _}, _} -> art == :bis_aenderung end)}

  @doc "Die Antwort an Stelle des Werkzeugs, wenn gewarnt wird — der Aufruf läuft nicht."
  @spec warnung(String.t(), pos_integer(), pos_integer()) :: String.t()
  def warnung(name, anzahl, abbruch) do
    "WARNUNG — Wiederholung, nicht ausgeführt: Diesen Aufruf (#{name} mit genau diesen " <>
      "Angaben) machst du in diesem Lauf jetzt zum #{anzahl}. Mal. Er wird nicht mehr " <>
      "ausgeführt; die Antwort wäre dieselbe wie zuvor. Lass diesen Punkt liegen und " <>
      "mach mit dem nächsten weiter. Kommt derselbe Aufruf ein #{abbruch}. Mal, wird der " <>
      "Lauf abgebrochen."
  end

  @doc "Die Antwort an Stelle des Werkzeugs, wenn der Lauf abgebrochen wird."
  @spec abbruch(String.t(), pos_integer()) :: String.t()
  def abbruch(name, anzahl) do
    "Nicht ausgeführt: Diesen Aufruf (#{name} mit genau diesen Angaben) hast du in " <>
      "diesem Lauf zum #{anzahl}. Mal gemacht. Der Lauf wird abgebrochen."
  end
end
