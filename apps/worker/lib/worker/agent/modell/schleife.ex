defmodule Worker.Agent.Modell.Schleife do
  @moduledoc """
  #1247: erkennt, dass ein Modell sich **innerhalb einer Antwort** wörtlich
  wiederholt — die Degeneration, die keine der bestehenden Sperren sieht.

  Am 25.09.2026 am laufenden Zeit-Jack gemessen: 52.962 Zeichen Denktext in
  einer Runde, darin **dreissigmal** derselbe Absatz, elf Minuten Rechenzeit,
  und `wiederholungen: 0`. Die Wiederholungssperre (`Worker.Agent.Werkzeug`)
  zählt gleiche **Werkzeugaufrufe**; hier entsteht die Wiederholung, bevor ein
  Aufruf da ist. Der Rundendeckel greift auch nicht — die Runde ist EINE.

  **Erkannt wird nur wörtliche Wiederholung**, kein Ähnlichkeitsmaß. Was
  Degeneration erzeugt, ist Zeichen für Zeichen dasselbe, und „exakt" ist
  nichts, worüber man streiten kann. Ein Modell, das dieselbe Überlegung in
  anderen Worten dreht, läuft weiter — das ist die benannte Grenze.

  **Abgebrochen wird wegen Wiederholung, nie wegen Länge.** Ein langer
  Denkstrom ist legitim (der Fable-Referenzlauf hat welche); ein Token-Deckel
  auf die Denkphase träfe ihn mit.

  Die Schwelle ist grosszügig: derselbe Block muss `mindestens/0`-mal
  vorkommen. Eine legitime Wiederholung (eine Liste, ein Zitat) kann eine
  Handvoll Treffer erzeugen — dreissig nie.
  """

  # Geprüft wird nicht bei jedem Delta, sondern wenn seit der letzten Prüfung
  # so viele Zeichen dazugekommen sind. Eine Teilstring-Suche über einen
  # wachsenden Text ist billig, aber nicht kostenlos.
  @intervall 2_000

  # Der Block, dessen Wiederkehr gezählt wird: das Ende des Textes. Kurz
  # genug, dass er in eine Wiederholung ganz hineinpasst, lang genug, dass er
  # nicht zufällig mehrfach vorkommt („Let me check the chain." allein wäre
  # kein Befund).
  @block 300

  # So oft muss der Block vorkommen, der eigene Vorkommen eingerechnet.
  @mindestens 3

  defstruct text: "", naechste: @intervall

  @type t :: %__MODULE__{}

  @doc "Ein leerer Zustand."
  @spec neu() :: t()
  def neu, do: %__MODULE__{}

  @doc false
  @spec intervall() :: pos_integer()
  def intervall, do: @intervall

  @doc false
  @spec block() :: pos_integer()
  def block, do: @block

  @doc "Wie oft derselbe Block vorkommen muss, damit es eine Schleife ist."
  @spec mindestens() :: pos_integer()
  def mindestens, do: @mindestens

  @doc """
  Nimmt das nächste Stück Text auf. Liefert den neuen Zustand und `:weiter`
  oder `{:schleife, block, anzahl}`.

  Aufgerufen für jedes Delta — Denken **und** Text, in einem Zustand: Die
  Degeneration steckt im Denken, der Text danach ist ihr Ergebnis, und zwei
  getrennte Zustände hätten je die halbe Sicht.
  """
  @spec dazu(t(), String.t()) :: {t(), :weiter | {:schleife, String.t(), pos_integer()}}
  def dazu(%__MODULE__{} = z, stueck) when is_binary(stueck) do
    text = z.text <> stueck

    if byte_size(text) < z.naechste do
      {%{z | text: text}, :weiter}
    else
      z = %{z | text: text, naechste: byte_size(text) + @intervall}

      case pruefen(text) do
        :weiter -> {z, :weiter}
        treffer -> {z, treffer}
      end
    end
  end

  @doc """
  Die Prüfung für sich — ohne Zustand, für Tests und für einen einmaligen
  Blick auf einen fertigen Text.
  """
  @spec pruefen(String.t()) :: :weiter | {:schleife, String.t(), pos_integer()}
  def pruefen(text) when is_binary(text) do
    # Der Block ist das ENDE des Textes: Eine Schleife wiederholt gerade
    # jetzt, und was vor hundert Absätzen einmal doppelt stand, ist keine.
    with true <- byte_size(text) >= @block * @mindestens,
         block = binary_part(text, byte_size(text) - @block, @block),
         n = vorkommen(text, block),
         true <- n >= @mindestens do
      {:schleife, block, n}
    else
      _ -> :weiter
    end
  end

  # Zählt, wie oft `block` in `text` vorkommt — ohne Überlappung, weil sich
  # eine Wiederholung nicht mit sich selbst überlappt.
  defp vorkommen(text, block) do
    text |> String.split(block) |> length() |> Kernel.-(1)
  end
end
