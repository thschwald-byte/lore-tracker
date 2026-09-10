defmodule Worker.Agent.Wiederholung do
  @moduledoc """
  Erkennt, wenn ein Agent sich im Kreis dreht.

  Anlass war Folgedurchgang 2 der Reihe C im Spike #1174 (10.09.2026): ab dem
  110. Aufruf wiederholte Jack einen Block aus neun wörtlich gleichen Aufrufen
  rund dreißigmal — zweimal `suche()`, einmal `aussage()` für immer dieselben
  drei Aussagen, 118 „verify“ gegen 5 Einträge. Er benutzte `aussage()` als
  Abfrage und behielt nicht, was er schon geprüft hatte.

  Toms Vorgaben (10.09.2026):

    * Die Sperre **merkt sich die Werkzeugaufrufe des Laufs** und schaut auf
      Wiederholungen, nicht auf die Zahl der Aufrufe. Wird irgendein Werkzeug
      im Lauf mit exakt demselben Inhalt noch einmal aufgerufen, ist das eine
      Wiederholung — egal, was dazwischen lag. So fallen auch Schleifen über
      mehrere Werkzeuge auf (Werkzeug 1 → 2 → 3 → von vorn): jeder ihrer
      Aufrufe kehrt wieder.
    * Nach **drei** Wiederholungen, also beim vierten gleichen Aufruf, hängt
      eine Warnung an der Antwort: den Punkt liegen lassen und beim nächsten
      weitermachen. Kein Abbruch — den gibt es nur über den Rundendeckel des
      Laufs.

  „Derselbe Inhalt“ heißt: gleicher Werkzeugname und gleiche Argumente, wie
  das Modell sie geschickt hat (kaputte Argumente über ihren Rohtext).
  Gezählt wird über den ganzen Lauf; auch die Kompaktierung setzt nicht
  zurück. Einzige Ausnahme sind Werkzeuge mit `wiederholbar: true`, bei denen
  der gleiche Aufruf gewollt ist — `weiter()` hat keine Argumente und liefert
  jedes Mal den nächsten Abschnitt.

  **Ehrliche Grenze:** auch ein erneuter Aufruf, der wegen einer veränderten
  Lage berechtigt ist, zählt mit. Die Warnung sagt dann etwas Falsches; sie
  hält aber nichts auf, das Werkzeug läuft und seine Antwort steht davor.

  Rein funktional; der Zustand reist im Lauf mit.
  """

  defstruct schwelle: 3, gesehen: %{}

  @type t :: %__MODULE__{schwelle: pos_integer(), gesehen: %{term() => pos_integer()}}

  @doc "Neuer Zustand; `false` schaltet die Sperre ab (Ergebnis `nil`)."
  @spec neu(pos_integer() | false) :: t() | nil
  def neu(false), do: nil

  def neu(schwelle) when is_integer(schwelle) and schwelle > 0,
    do: %__MODULE__{schwelle: schwelle}

  @doc """
  Nimmt einen Aufruf auf; `schluessel` ist `{name, argumente}`. Liefert den
  neuen Zustand und — wenn gewarnt werden muss — die Nummer der Wiederholung.
  """
  @spec beobachten(t() | nil, term()) :: {t() | nil, pos_integer() | nil}
  def beobachten(nil, _schluessel), do: {nil, nil}

  def beobachten(%__MODULE__{} = w, schluessel) do
    vorher = Map.get(w.gesehen, schluessel, 0)
    w = %{w | gesehen: Map.put(w.gesehen, schluessel, vorher + 1)}
    {w, if(vorher >= w.schwelle, do: vorher, else: nil)}
  end

  @doc "Der Text, der an die Antwort des Werkzeugs angehängt wird."
  @spec warnung(String.t(), pos_integer()) :: String.t()
  def warnung(name, wiederholung) do
    "\n\nWARNUNG — Wiederholung: Diesen Aufruf (#{name} mit genau diesen Angaben) machst " <>
      "du in diesem Lauf jetzt zum #{wiederholung + 1}. Mal; die Antwort bleibt dieselbe. " <>
      "Lass diesen Punkt liegen und mach mit dem nächsten weiter."
  end
end
