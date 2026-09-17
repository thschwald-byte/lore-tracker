defmodule Worker.Status.Praesenz do
  @moduledoc """
  Issue #1218, Schnitt 2: der zuletzt gemeldete Stand, wer im Sprachkanal sitzt
  und wer gerade spricht — als Zwischenspeicher für den Statusendpunkt.

  ## Warum ein Zwischenspeicher und keine Abfrage

  Die Präsenz lebt in `Worker.Discord.VoiceSession`. Diesen Prozess darf der
  Endpunkt **nicht** fragen: Er kann während einer gesprochenen Ansage
  blockieren, und `capture_stats/2` liefert aus genau diesem Grund lieber
  nichts als eine erfundene Zahl. `BotGate.status/0` geht denselben Weg und
  liest den abgelegten Zustand statt den Prozess zu rufen (#475).

  Geschrieben wird deshalb im Takt der Präsenz (5-mal je Sekunde, #988), und
  zwar direkt in eine öffentliche ETS-Tabelle — kein `GenServer.call`, keine
  Mnesia-Transaktion im heißen Pfad. Gelesen wird ohne Sperre.

  ## Kennungen verlassen den Worker nicht

  Nach außen geht **nie** die Discord-Kennung, sondern ein gesalzener Hash,
  gekürzt auf acht Zeichen. Das Salz entsteht beim Start neu und lebt nur im
  Arbeitsspeicher: Die Kennung ist damit **innerhalb eines Laufs stabil** —
  genug, damit eine Anzeige eine Person über die Ticks hinweg an derselben
  Stelle zeigt —, aber über einen Neustart hinweg nicht wiedererkennbar und
  nicht zurückrechenbar. Ohne Salz wäre der Hash nur eine andere Schreibweise
  derselben Kennung.

  ## Alter

  Ein Eintrag verfällt nach `frist_ms/0`. Stirbt die Sprachsitzung, hört das
  Melden auf, und die Liste leert sich von selbst. Ohne diese Frist zeigte die
  Anzeige Leute, die längst gegangen sind — eine falsche Aussage, die niemand
  widerruft.
  """

  use GenServer

  @tabelle :worker_status_praesenz
  @salz_schluessel :__salz__
  # Großzügig gegenüber dem Präsenz-Takt (200 ms): ein paar verpasste Ticks
  # sollen die Anzeige nicht leeren, ein totes Segment aber schon.
  @frist_ms 15_000

  @doc "Ab wann ein gemeldeter Stand als veraltet gilt."
  @spec frist_ms() :: pos_integer()
  def frist_ms, do: @frist_ms

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # `:public`, weil die Sprachsitzungen selbst schreiben — der Umweg über
    # diesen Prozess wäre ein `GenServer.call` im 200-ms-Takt, also genau die
    # Kopplung, die dieser Zwischenspeicher vermeiden soll.
    :ets.new(@tabelle, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@tabelle, {@salz_schluessel, :crypto.strong_rand_bytes(16)})
    {:ok, %{}}
  end

  @doc """
  Den Stand einer Sprachsitzung melden. `teilnehmer` ist die Liste aus
  `Worker.Discord.Presence.snapshot/4`.

  No-op, solange es die Tabelle nicht gibt (nicht gepaarter Worker, Tests ohne
  diesen Prozess) — ein Statusdienst darf die Aufnahme nie stören.
  """
  @spec melden(String.t(), [map()], integer()) :: :ok
  def melden(session_id, teilnehmer, jetzt_ms \\ System.monotonic_time(:millisecond)) do
    if :ets.whereis(@tabelle) != :undefined do
      :ets.insert(@tabelle, {{:sitzung, session_id}, teilnehmer, jetzt_ms})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Die Teilnehmer aller lebenden Sprachsitzungen, pseudonymisiert und stabil
  sortiert. Leere Liste heißt „keine Sprecherdaten" — das ist etwas anderes
  als „niemand spricht".
  """
  @spec lesen(integer()) :: [map()]
  def lesen(jetzt_ms \\ System.monotonic_time(:millisecond)) do
    if :ets.whereis(@tabelle) == :undefined do
      []
    else
      @tabelle
      |> :ets.match_object({{:sitzung, :_}, :_, :_})
      |> Enum.filter(fn {_, _, ts} -> jetzt_ms - ts <= @frist_ms end)
      |> Enum.flat_map(fn {_, teilnehmer, _} -> teilnehmer end)
      |> Enum.map(&nach_aussen/1)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["id"])
    end
  rescue
    _ -> []
  end

  @doc """
  Die pseudonyme Kennung zu einer Discord-Kennung: gesalzen, gehasht, auf acht
  Zeichen gekürzt. Ohne laufenden Prozess (kein Salz) gibt es keine Kennung.
  """
  @spec pseudonym(String.t()) :: String.t() | nil
  def pseudonym(discord_id) when is_binary(discord_id) do
    case salz() do
      nil ->
        nil

      salz ->
        :sha256
        |> :crypto.hash(salz <> discord_id)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)
    end
  end

  def pseudonym(_), do: nil

  defp salz do
    case :ets.whereis(@tabelle) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@tabelle, @salz_schluessel) do
          [{_, salz}] -> salz
          _ -> nil
        end
    end
  end

  defp nach_aussen(%{"discord_id" => did} = t) do
    %{
      "id" => pseudonym(did),
      "spricht" => t["speaking"] == true,
      "zustimmung" => t["consent"] == true
    }
  end

  defp nach_aussen(_), do: %{"id" => nil, "spricht" => false, "zustimmung" => false}
end
