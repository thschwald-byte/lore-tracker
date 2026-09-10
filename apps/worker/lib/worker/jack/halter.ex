defmodule Worker.Jack.Halter do
  @moduledoc """
  Hält den Stand eines Jack-Laufs zwischen den Werkzeugaufrufen.

  Die Laufzeit (`Worker.Agent.Lauf`) kennt Werkzeuge nur als Funktionen von
  Argumenten zu einem Ergebnis. Der Stand liegt deshalb in diesem Prozess,
  und jedes Werkzeug ruft ihn (`aufrufen/3`); die Module unter `Worker.Jack`
  bleiben rein.

  Beim Start und nach jedem Aufruf

    * bekommt ein Beobachter (Option `:beobachter`, ein Prozess) den Stand als
      `{:jack_stand, abbild}` (`Worker.Jack.Abbild.von/1`), für die lokale
      Laufsicht (#1202);
    * schreibt der Halter, wenn `:ablage` gesetzt ist, das Abbild in dieses
      Verzeichnis (`Worker.Jack.Abbild.schreiben/2`).

  Wirft ein Werkzeug oder liefert es keinen Stand zurück, bleibt der Stand,
  wie er war, und das Ergebnis ist ein Fehler mit der Meldung. Ohne diesen
  Schutz stürbe der Halter, und jeder weitere Aufruf des Laufs liefe ins
  Leere.
  """

  alias Worker.Jack.{Abbild, Stand}

  @doc "Startet den Halter mit einem Stand. Optionen: `:beobachter`, `:ablage`."
  @spec start_link(Stand.t(), keyword()) :: Agent.on_start()
  def start_link(%Stand{} = s, opts \\ []) do
    Agent.start_link(fn ->
      z = %{stand: s, beobachter: opts[:beobachter], ablage: opts[:ablage]}
      nachher(z)
      z
    end)
  end

  @doc "Der aktuelle Stand."
  @spec stand(pid()) :: Stand.t()
  def stand(halter), do: Agent.get(halter, & &1.stand)

  @doc """
  Führt `fun` (`fn stand, argumente -> {stand, ergebnis} end`) auf dem Stand
  aus, übernimmt den neuen Stand und liefert das Ergebnis.
  """
  @spec aufrufen(pid(), (Stand.t(), map() -> {Stand.t(), term()}), map()) :: term()
  def aufrufen(halter, fun, argumente) do
    Agent.get_and_update(
      halter,
      fn z ->
        {s, ergebnis} = sicher(fun, z.stand, argumente)
        z = %{z | stand: s}
        nachher(z)
        {ergebnis, z}
      end,
      :infinity
    )
  end

  defp sicher(fun, s, argumente) do
    case fun.(s, argumente) do
      {%Stand{} = neu, ergebnis} -> {neu, ergebnis}
      anderes -> {s, {:error, "Werkzeug lieferte keinen Stand: #{inspect(anderes, limit: 20)}"}}
    end
  rescue
    e -> {s, {:error, Exception.message(e)}}
  end

  defp nachher(%{stand: s, beobachter: beobachter, ablage: ablage}) do
    if beobachter, do: send(beobachter, {:jack_stand, Abbild.von(s)})
    if ablage, do: Abbild.schreiben(ablage, s)
    :ok
  end
end
