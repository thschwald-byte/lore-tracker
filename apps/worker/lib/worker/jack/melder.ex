defmodule Worker.Jack.Melder do
  @moduledoc """
  Meldet Jacks Lesefortschritt ans Laufband
  (`Worker.Recording.Pipeline.Fortschritt`, Stufe „extract“): jeder Block, den
  Jack in einer Phase zum ersten Mal holt, ist eine erledigte Einheit. Der
  Halter schickt nach jedem Werkzeugaufruf `{:jack_stand, abbild}`
  (`Worker.Jack.Abbild.von/1`); daraus zählt der Melder die neu gelesenen
  Blöcke je Phase und Durchgang.

  Gedächtnis, Extraktion und jede Iteration lesen den ganzen Mitschnitt —
  `gesamt` ist deshalb Blockzahl mal Lesevorgänge. Endet das Iterieren früher
  (gesättigt), füllt der Abschluss der Stufe die Anzeige auf; das ist Sache
  von `Fortschritt`, nicht des Melders.

  Der Halter kennt nur einen Beobachter. Der Melder reicht deshalb jeden Stand
  an einen zweiten weiter (`:weiter`), die Laufsicht (`Worker.Jack.Sicht`).
  """

  alias Worker.Recording.Pipeline.Fortschritt

  @doc """
  Startet den Melder für einen Lauf (`ctx` wie bei `Fortschritt`) mit
  `gesamt` Einheiten und liefert seine Pid — die gehört als
  `:stand_beobachter` in `Worker.Jack.Phase.laufen/3`. Optionen: `:weiter`
  (Pid, bekommt jeden Stand weitergereicht) und `:melden` (Funktion für die
  Meldungen, Default an `Fortschritt`; für Tests).
  """
  @spec start(map(), non_neg_integer(), keyword()) :: pid()
  def start(ctx, gesamt, opts \\ []) do
    melden = Keyword.get(opts, :melden, &an_fortschritt/1)
    weiter = opts[:weiter]
    melden.({:gesamt, ctx, gesamt})
    spawn_link(fn -> schleife(ctx, MapSet.new(), melden, weiter) end)
  end

  @doc "Beendet den Melder."
  @spec stopp(pid()) :: :ok
  def stopp(pid) do
    send(pid, :stopp)
    :ok
  end

  defp schleife(ctx, gesehen, melden, weiter) do
    receive do
      {:jack_stand, %{"gelesen" => g} = abbild} = nachricht ->
        if weiter, do: send(weiter, nachricht)
        lauf = {abbild["phase"], abbild["durchgang"]}

        neu =
          for [von, bis] <- g,
              n <- von..bis//1,
              not MapSet.member?(gesehen, {lauf, n}),
              uniq: true,
              do: {lauf, n}

        Enum.each(neu, &melden.({:fertig, ctx, &1}))
        schleife(ctx, Enum.into(neu, gesehen), melden, weiter)

      :stopp ->
        :ok

      _anderes ->
        schleife(ctx, gesehen, melden, weiter)
    end
  end

  defp an_fortschritt({:gesamt, ctx, n}), do: Fortschritt.gesamt(ctx, "extract", n)
  defp an_fortschritt({:fertig, ctx, id}), do: Fortschritt.fertig(ctx, "extract", id)
end
