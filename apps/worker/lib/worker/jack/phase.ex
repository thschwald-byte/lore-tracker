defmodule Worker.Jack.Phase do
  @moduledoc """
  Eine Phase eines Jack-Laufs: ein Halter mit dem Stand, Jacks Werkzeuge und
  eine Sitzung der Laufzeit mit pis Systemprompt. Gemeinsam für den Messlauf
  (`Worker.Jack.Messlauf`, mit Ablage und Protokoll je Phase) und den Betrieb
  (`Worker.Jack.Pipeline`, ohne Dateien) — damit beide dieselbe Sitzung
  fahren und eine Messung für den Betrieb etwas bedeutet.
  """

  alias Worker.Jack.{Halter, Stand, Systemprompt, Werkzeuge, Zusammenfassung}

  # Endet eine Antwort ohne Werkzeugaufruf, bevor Jack `fertig` aufgerufen hat,
  # schickt ihn die Laufzeit zurück an die Arbeit (Tom, 11.09.2026; im Betrieb
  # und in den Messläufen). Anlass: auf der Teststage schrieb qwen3.8:27b-text
  # einen `aussage`-Aufruf als rohes Markup in den Text, die Phase endete ohne
  # Abschluss, und die ganze Sitzung (14 Minuten) war verloren. Höchstens
  # dreimal in Folge; danach endet die Phase wie zuvor.
  @nachhaken_hoechstens 3
  @nachhaken_text "Deine letzte Antwort enthielt keinen Werkzeugaufruf. " <>
                    "Setz die Arbeit fort; wenn du durch bist, ruf fertig() auf."

  # Kompaktierung wie in Reihe C (pi): ab `fenster − reserve` Token wird
  # zusammengefasst, danach bleiben die jüngsten `behalten` Token stehen. Das
  # Fenster ist einstellbar (`:kontext_fenster`; im Betrieb `ctx_jack`),
  # Reserve und Behalten nicht — sie sind Teil dessen, was gemessen wurde.
  @fenster 98_304
  @reserve 4096
  @behalten 8000

  @doc """
  Fährt eine Phase. Optionen: `:modell` (Pflicht, `{modul, opts}`),
  `:kontext_fenster` (Token, Default 98 304 wie in den Messläufen; mindestens
  `mindestfenster/0`), `:denken_zurueck` (Default `false`), `:beispiele`,
  `:max_runden` (5000), `:max_ms` (6 Stunden), `:ablage` (Verzeichnis für das
  Abbild nach jedem Aufruf; ohne sie keine Dateien), `:protokoll` (Pfad; ohne
  ihn keins), `:beobachter` (bekommt Protokoll und Stand, etwa die
  Laufsicht), `:stand_beobachter` (bekommt nur den Stand, statt
  `:beobachter`; etwa `Worker.Jack.Melder`), `:bei_stopp` (Default
  `nachhaken/1`). Liefert das Ergebnis der Laufzeit und den Stand danach.

  Das Kontextfenster setzt nur Jacks eigene Kompaktierung, nicht das Fenster
  des Servers (siehe `Worker.Agent.Modell.Ollama`).
  """
  @spec laufen(Stand.t(), String.t(), keyword()) :: {{:ok | :error, map()}, Stand.t()}
  def laufen(%Stand{} = s, auftrag, opts) do
    stand_beobachter = Keyword.get(opts, :stand_beobachter, opts[:beobachter])
    {:ok, halter} = Halter.start_link(s, beobachter: stand_beobachter, ablage: opts[:ablage])

    ergebnis =
      Worker.Agent.laufen(
        modell: Keyword.fetch!(opts, :modell),
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        anheften: false,
        denken_zurueck: Keyword.get(opts, :denken_zurueck, false),
        werkzeuge: Werkzeuge.fuer(halter, beispiele: opts[:beispiele]),
        kontext: [
          fenster: Keyword.get(opts, :kontext_fenster, @fenster),
          reserve: @reserve,
          behalten: @behalten,
          zusammenfassen: Zusammenfassung.fuer(halter)
        ],
        max_runden: Keyword.get(opts, :max_runden, 5000),
        max_ms: Keyword.get(opts, :max_ms, 6 * 3_600_000),
        beobachter: opts[:beobachter],
        protokoll: opts[:protokoll],
        bei_stopp: Keyword.get(opts, :bei_stopp, &nachhaken/1)
      )

    stand = Halter.stand(halter)
    Agent.stop(halter)
    {ergebnis, stand}
  end

  @doc """
  Das kleinste Kontextfenster, mit dem eine Phase überhaupt startet: Reserve
  (4096) und Behalten (8000) müssen darunter Platz haben
  (`Worker.Agent.Lauf` lehnt sonst mit `ArgumentError` ab). Eine harte Grenze,
  keine Empfehlung — bei so kleinem Fenster fasst Jack fast nach jedem Aufruf
  zusammen.
  """
  @spec mindestfenster() :: pos_integer()
  def mindestfenster, do: @reserve + @behalten + 1

  @doc """
  Was die Laufzeit tut, wenn eine Antwort ohne Werkzeugaufruf endet: bis zur
  dritten Antwort in Folge zurück an die Arbeit mit einem Hinweis auf
  `fertig()`, danach Schluss (`:fertig`, die Phase gilt dann als nicht
  abgeschlossen).
  """
  @spec nachhaken(map()) :: :fertig | {:weiter, String.t()}
  def nachhaken(%{ohne_aufruf_in_folge: n}) when n <= @nachhaken_hoechstens,
    do: {:weiter, @nachhaken_text}

  def nachhaken(_info), do: :fertig

  @doc "Ob eine Phase mit `fertig` abschloss."
  @spec abgeschlossen?(term()) :: boolean()
  def abgeschlossen?({:ok, %{ende: :halt}}), do: true
  def abgeschlossen?(_ergebnis), do: false

  @doc "Wie eine Phase endete — `:halt`, ein Deckel oder der Grund eines Abbruchs."
  @spec ende(term()) :: term()
  def ende({_, %{ende: ende}}), do: ende
  def ende(anderes), do: anderes
end
