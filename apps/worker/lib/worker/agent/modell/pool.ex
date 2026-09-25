defmodule Worker.Agent.Modell.Pool do
  @moduledoc """
  #1247: der HTTP-Pool für die Modell-Aufrufe — ein **eigener** Finch mit
  Idle-Frist, statt Reqs geteiltem Default-Pool.

  ## Der Anlass

  Am 24.09.2026 hielt der Worker nach einem abgebrochenen Jack-Lauf eine offene
  Verbindung nach `11434`, und Ollama hielt dazu einen `llama-server` mit
  12,5 GB Grafikspeicher am Leben — über Stunden, obwohl `ollama ps` leer war.
  Eine andere Session wartete in dieser Zeit auf die Karte. Ein Worker-Neustart
  löste es sofort.

  ## Was belegt ist, und was nicht

  **Belegt:** Reqs Default-Pool hält seine Verbindungen ohne Frist offen
  (`Finch` kennt `pool_max_idle_time`, und der Standard ist `:infinity`), der
  Worker hatte nach dem Lauf eine offene Verbindung, und ein Neustart gab den
  Speicher frei.

  **Nicht belegt:** dass die offene Verbindung die **Ursache** des gehaltenen
  Grafikspeichers war. Plausibel ist es — ein Neustart schliesst sie, und
  danach war der Speicher frei —, aber es ist nicht gemessen; der Zusammenhang
  „offene Verbindung hält den Runner" ist eine Annahme über Ollamas Verhalten,
  keine nachgewiesene Kette. Dieser Pool schliesst die Verbindung nach
  `@idle_ms`; ob damit auch der Speicher fällt, zeigt der nächste Lauf.

  Gebaut wird er trotzdem, weil er unabhängig davon richtig ist: Ein Lauf
  dauert Minuten bis Stunden, danach ruht die Verbindung, und eine ruhende
  Verbindung über Stunden offen zu halten hat keinen Nutzen — der nächste Lauf
  baut sie in Millisekunden neu auf.

  ## Warum ein eigener Pool, nicht ein Aufräumpfad am Lauf-Ende

  Naheliegend wäre „nach dem Lauf die Verbindung schliessen". Das wäre ein
  neuer Pfad, den jeder künftige Ausgang aus dem Lauf kennen müsste — und
  dieses Repo hat mit genau dieser Klasse Erfahrung: Der Abschluss, den jemand
  vergisst, ist der Normalfall (#1011: die Stop-Reihenfolge; #1050: das
  Scharfschalten nach dem Handshake). Eine Frist am Pool braucht niemand zu
  rufen.

  Nebeneffekt, der den Ort mitentscheidet: Die Modell-Aufrufe liegen damit
  nicht mehr im selben Pool wie der Hub-Verkehr. Ein Jack-Lauf blockiert eine
  Verbindung bis zu zehn Minuten (`Ollama`-Zeitgrenze); dass er sie mit den
  Publish-Aufrufen teilte, war nie beabsichtigt.
  """

  # Eine Minute. Lange genug, dass die Aufrufe **innerhalb** eines Laufs
  # dieselbe Verbindung nutzen (zwischen zwei Werkzeugaufrufen liegen Sekunden),
  # kurz genug, dass nach dem Lauf nichts stehen bleibt. Bewusst kein Setting:
  # Die #1062-Liste soll eine Bedeutung behalten, und hier gibt es nichts zu
  # tunen — wer daran dreht, ändert nichts Sichtbares.
  @idle_ms 60_000

  @doc "Der Name, den `Req.post(finch: …)` bekommt."
  @spec name() :: atom()
  def name, do: __MODULE__

  @doc """
  Das Kind für den Supervisor-Baum.

  In der Testumgebung `nil`-frei, aber harmlos: Der Pool startet, und die
  Tests rufen kein Modell.
  """
  @spec kind() :: Supervisor.child_spec() | {module(), keyword()}
  def kind do
    {Finch,
     name: name(),
     pools: %{
       :default => [
         size: 4,
         count: 1,
         pool_max_idle_time: @idle_ms
       ]
     }}
  end

  @doc "Die Idle-Frist in Millisekunden — für Tests und für die Doku."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms
end
