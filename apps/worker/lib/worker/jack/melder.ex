defmodule Worker.Jack.Melder do
  @moduledoc """
  Meldet Jacks Lesefortschritt ans Laufband: jeder Block, den eine Phase zum
  ersten Mal holt, ist eine erledigte Einheit ihrer Stufe (Gedächtnis,
  Extraktion, Verifikation — `Shared.PipelineStufen`). Der Halter schickt
  nach jedem Werkzeugaufruf `{:jack_stand, abbild}`
  (`Worker.Jack.Abbild.von/1`); daraus zählt der Melder die neu gelesenen
  Blöcke.

  **Ein Melder je Phase**, nicht einer für den ganzen Lauf
  (`Worker.Jack.Pipeline` startet und stoppt ihn um jede Phase). Am Stand
  allein lassen sich die Phasen nicht sicher trennen: der Durchgang im Stand
  wird aus dem Bestand abgeleitet (`Worker.Jack.Fortsetzung`, höchstes
  `_iter` plus eins) und bleibt stehen, solange eine Verifikation nichts Neues
  einträgt — zwei Verifikationen ohne Neues sähen gleich aus, und die zweite
  zählte keinen Block mehr. Ein verspäteter Stand der vorigen Phase landet so
  bei deren Melder statt bei der nächsten Stufe.

  Gemeldet wird über den Rückruf `melde` (`:melde_stufe` von
  `Worker.Jack.Pipeline`): zuerst `{:zaehlung, gesamt, durchgang}`, dann je
  Block `{:gelesen, block, durchgang}`. Beides aus dem Melder-Prozess, damit
  die Reihenfolge beim Empfänger hält. Endet die Phase früher, füllt der
  Abschluss der Stufe die Anzeige auf; das ist Sache von `Fortschritt`.

  Der Halter kennt nur einen Beobachter. Der Melder reicht deshalb jeden Stand
  an einen zweiten weiter (`:weiter`), die Laufsicht (`Worker.Jack.Sicht`).
  """

  @doc """
  Startet den Melder für eine Phase: `stufe` (Name aus
  `Shared.PipelineStufen`), `gesamt` Blöcke, `durchgang` (Verifikation) oder
  `nil`. Liefert die Pid — die gehört als `:stand_beobachter` in
  `Worker.Jack.Phase.laufen/3`. Option `:weiter` (Pid, bekommt jeden Stand
  weitergereicht).
  """
  @spec start(
          (String.t(), term() -> term()),
          String.t(),
          non_neg_integer(),
          pos_integer() | nil,
          keyword()
        ) :: pid()
  def start(melde, stufe, gesamt, durchgang, opts \\ []) do
    weiter = opts[:weiter]

    spawn_link(fn ->
      melde.(stufe, {:zaehlung, gesamt, durchgang})
      schleife(%{melde: melde, stufe: stufe, durchgang: durchgang, weiter: weiter}, MapSet.new())
    end)
  end

  @doc """
  Beendet den Melder und wartet, bis er fort ist: was er bis dahin bekommen
  hat, ist dann gezählt und gemeldet — vor dem Abschluss der Stufe.
  """
  @spec stopp(pid()) :: :ok
  def stopp(pid) do
    ref = Process.monitor(pid)
    send(pid, :stopp)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp schleife(m, gesehen) do
    receive do
      {:jack_stand, _} = nachricht ->
        schleife(m, stand(m, gesehen, nachricht))

      :stopp ->
        nachlesen(m, gesehen)

      _anderes ->
        schleife(m, gesehen)
    end
  end

  # Was vor dem Stopp schon im Postfach lag, gehört noch zu dieser Phase.
  defp nachlesen(m, gesehen) do
    receive do
      {:jack_stand, _} = nachricht -> nachlesen(m, stand(m, gesehen, nachricht))
    after
      0 -> :ok
    end
  end

  defp stand(m, gesehen, {:jack_stand, abbild} = nachricht) do
    if m.weiter, do: send(m.weiter, nachricht)

    neu =
      for [von, bis] <- abbild["gelesen"] || [],
          n <- von..bis//1,
          not MapSet.member?(gesehen, n),
          uniq: true,
          do: n

    Enum.each(neu, &m.melde.(m.stufe, {:gelesen, &1, m.durchgang}))
    Enum.into(neu, gesehen)
  end
end
