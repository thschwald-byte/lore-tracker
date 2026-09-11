defmodule Worker.Jack.Phase do
  @moduledoc """
  Eine Phase eines Jack-Laufs: ein Halter mit dem Stand, Jacks Werkzeuge und
  eine Sitzung der Laufzeit mit pis Systemprompt. Gemeinsam für den Messlauf
  (`Worker.Jack.Messlauf`, mit Ablage und Protokoll je Phase) und den Betrieb
  (`Worker.Jack.Pipeline`, ohne Dateien) — damit beide dieselbe Sitzung
  fahren und eine Messung für den Betrieb etwas bedeutet.
  """

  alias Worker.Jack.{Halter, Stand, Systemprompt, Werkzeuge, Zusammenfassung}

  @doc """
  Fährt eine Phase. Optionen: `:modell` (Pflicht, `{modul, opts}`),
  `:denken_zurueck` (Default `false`), `:beispiele`, `:max_runden` (5000),
  `:max_ms` (6 Stunden), `:ablage` (Verzeichnis für das Abbild nach jedem
  Aufruf; ohne sie keine Dateien), `:protokoll` (Pfad; ohne ihn keins),
  `:beobachter`. Liefert das Ergebnis der Laufzeit und den Stand danach.
  """
  @spec laufen(Stand.t(), String.t(), keyword()) :: {{:ok | :error, map()}, Stand.t()}
  def laufen(%Stand{} = s, auftrag, opts) do
    {:ok, halter} = Halter.start_link(s, beobachter: opts[:beobachter], ablage: opts[:ablage])

    ergebnis =
      Worker.Agent.laufen(
        modell: Keyword.fetch!(opts, :modell),
        system: Systemprompt.pi(),
        nachrichten: [%{role: :user, content: auftrag}],
        anheften: false,
        denken_zurueck: Keyword.get(opts, :denken_zurueck, false),
        werkzeuge: Werkzeuge.fuer(halter, beispiele: opts[:beispiele]),
        kontext: [
          fenster: 98_304,
          reserve: 4096,
          behalten: 8000,
          zusammenfassen: Zusammenfassung.fuer(halter)
        ],
        max_runden: Keyword.get(opts, :max_runden, 5000),
        max_ms: Keyword.get(opts, :max_ms, 6 * 3_600_000),
        beobachter: opts[:beobachter],
        protokoll: opts[:protokoll]
      )

    stand = Halter.stand(halter)
    Agent.stop(halter)
    {ergebnis, stand}
  end

  @doc "Ob eine Phase mit `fertig` abschloss."
  @spec abgeschlossen?(term()) :: boolean()
  def abgeschlossen?({:ok, %{ende: :halt}}), do: true
  def abgeschlossen?(_ergebnis), do: false

  @doc "Wie eine Phase endete — `:halt`, ein Deckel oder der Grund eines Abbruchs."
  @spec ende(term()) :: term()
  def ende({_, %{ende: ende}}), do: ende
  def ende(anderes), do: anderes
end
