defmodule Worker.Jack.Frage.Werkzeuge do
  @moduledoc """
  Die Werkzeuge des Frage-Jack (#850): die **ganze Lesebasis** des
  Resümee-Jack (`Worker.Jack.Resuemee.Werkzeuge.lesend/0` — `fakten`, `fakt`,
  `boegen`, `boegen_kampagne`, `vorige_resuemees`, `vorige_kapitel`,
  `vorige_gedanken`, `bloecke`, `block`, `suche_sitzung`, `suche_bisher`,
  `cast`, `straenge`) plus `antworte` und `keine_antwort`.

  Mehr braucht er nicht, und weniger ginge nicht: Eine Frage kann alles
  betreffen, was in der Kampagne steht. Keine Notizen, kein Entwurf, keine
  Durchsicht — ein Lauf, eine Antwort.

  Gebaut über `Worker.Jack.Resuemee.Werkzeuge.aus/3` wie beim Epos-Jack
  (#1210); jedes Werkzeug ruft den Halter, und `hilfe()` kommt von dort.
  """

  alias Worker.Agent.Werkzeug
  alias Worker.Jack.Frage.Antworten
  alias Worker.Jack.Resuemee.{Halter, Lesen, Stand}
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam

  # Zwei Abschlüsse, keiner optional: `antworte` verlangt Belege,
  # `keine_antwort` verlangt keine. Die Wahl IST die Aussage (#850).
  @eigen ~w(antworte keine_antwort)

  @doc "Die Namen der Werkzeuge, in der Reihenfolge der Werkzeugliste."
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{}), do: Gemeinsam.lesend() ++ @eigen

  @doc "Alle Definitionen für einen Stand, ungefiltert."
  @spec definitionen(Stand.t()) :: [map()]
  def definitionen(%Stand{} = s), do: Lesen.werkzeuge(s) ++ Antworten.werkzeuge(s)

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end
end
