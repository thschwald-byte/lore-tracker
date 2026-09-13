defmodule Worker.Jack.Resuemee.Halter do
  @moduledoc """
  Hält den Stand eines Resümee-Laufs zwischen den Werkzeugaufrufen — das
  Muster von `Worker.Jack.Halter`: die Laufzeit kennt Werkzeuge nur als
  Funktionen, der Stand liegt in diesem Prozess, und die Module unter
  `Worker.Jack.Resuemee` bleiben rein.

  Ein eigener Halter statt des Fakten-Jack-Halters, weil jener zwei Teile
  mitbringt, die nur dort Sinn haben: `Worker.Jack.Probieren` (kennt
  `aussage` und prüft `suche` gegen eingereichte Aussagen) und
  `Worker.Jack.Abbild` (schreibt den Bestand in die Dateien des Spikes).

  Beim Start und nach jedem Aufruf bekommt ein Beobachter (Option
  `:beobachter`) den Stand als `{:jack_resuemee_stand, abbild}`
  (`Worker.Jack.Resuemee.Stand.abbild/1`) — eine eigene Nachricht, damit
  eine Laufsicht, die nur den Fakten-Jack kennt, sie überhört statt sie
  falsch zu lesen.

  Wirft ein Werkzeug oder liefert es keinen Stand zurück, bleibt der Stand,
  wie er war, und das Ergebnis ist ein Fehler mit der Meldung.
  """

  alias Worker.Jack.Resuemee.Stand

  @doc "Startet den Halter mit einem Stand. Option: `:beobachter`."
  @spec start_link(Stand.t(), keyword()) :: Agent.on_start()
  def start_link(%Stand{} = s, opts \\ []) do
    Agent.start_link(fn ->
      z = %{stand: s, beobachter: opts[:beobachter]}
      melden(z)
      z
    end)
  end

  @doc "Der aktuelle Stand."
  @spec stand(pid()) :: Stand.t()
  def stand(halter), do: Agent.get(halter, & &1.stand)

  @doc """
  Liest etwas Kleines aus dem Stand, ohne ihn zu ändern: `fun` läuft im
  Halter, zurück kommt nur ihr Ergebnis — nicht der ganze Stand, der samt
  geladener Mitschnitte früherer Sitzungen groß sein kann (#1210). Wirft
  `fun`, ist das Ergebnis `:fehler` und der Halter lebt weiter.
  """
  @spec lesen(pid(), (Stand.t() -> term())) :: term()
  def lesen(halter, fun) do
    Agent.get(
      halter,
      fn z ->
        try do
          fun.(z.stand)
        rescue
          _ -> :fehler
        end
      end,
      :infinity
    )
  end

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
        melden(z)
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

  defp melden(%{beobachter: nil}), do: :ok
  defp melden(%{stand: s, beobachter: b}), do: send(b, {:jack_resuemee_stand, Stand.abbild(s)})
end
