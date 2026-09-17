defmodule Worker.Status.Endpunkt do
  @moduledoc """
  Issue #1218: HTTP und JSON über einen **Unix-Domain-Socket**, kein Port.

  Der Maintainer hat beides entschieden: „ich will kein RPC im Loretracker —
  eine ordentliche API", und als Weg dorthin den Socket. Das hat zwei Folgen,
  die diesen Endpunkt von `Worker.Setup.Endpoint` unterscheiden:

  - **Nichts lauscht im Netz**, auch nicht auf 127.0.0.1. Die Zugriffskontrolle
    sind Dateirechte (0600 für den Nutzer, dem der Worker gehört).
  - **Eine Socket-Datei überlebt ihren Prozess.** Nach einem harten Abbruch
    liegt sie noch da, und `bind` scheitert daran. Beim Start wird eine solche
    Leiche deshalb entfernt — aber nur, wenn es wirklich eine Socket-Datei ist.

  **Aus, wenn kein Pfad gesetzt ist.** `LORE_STATUS_SOCKET` setzt ihn; ohne die
  Variable wird er aus `XDG_RUNTIME_DIR` abgeleitet, und fehlt auch die, gibt es
  keinen Endpunkt. `LORE_STATUS_SOCKET=aus` schaltet ihn ausdrücklich ab.
  """

  require Logger

  @doc "Der Socket-Pfad, oder `nil` wenn der Endpunkt aus ist."
  @spec pfad() :: String.t() | nil
  def pfad do
    case System.get_env("LORE_STATUS_SOCKET") do
      nil -> aus_laufzeitverzeichnis()
      "" -> nil
      wert when wert in ["aus", "0", "off"] -> nil
      wert -> wert
    end
  end

  defp aus_laufzeitverzeichnis do
    case System.get_env("XDG_RUNTIME_DIR") do
      nil -> nil
      "" -> nil
      dir -> Path.join([dir, "lore-tracker", "status.sock"])
    end
  end

  @doc """
  Das Kind für den Supervisor, oder `[]` wenn der Endpunkt aus ist.

  Bewusst eine Liste: `Worker.Application` hängt sie an die Kinderliste an, wie
  beim Updater. So gibt es keinen Platzhalter-Prozess für „abgeschaltet".
  """
  @spec kind() :: list()
  def kind do
    case pfad() do
      nil ->
        []

      pfad ->
        case vorbereiten(pfad) do
          :ok ->
            [
              Plug.Cowboy.child_spec(
                scheme: :http,
                plug: Worker.Status.Router,
                options: [ip: {:local, pfad}, port: 0]
              )
            ]

          {:error, grund} ->
            # Best-effort: ein Statusendpunkt ist eine Zugabe. Er darf den
            # Worker nicht am Starten hindern — aber still scheitern darf er
            # auch nicht, sonst sucht jemand später an der Hardware.
            Logger.warning("Status-Endpunkt aus: #{pfad} nicht nutzbar — #{inspect(grund)}")
            []
        end
    end
  end

  @doc false
  # Verzeichnis anlegen, Leiche wegräumen, Rechte setzen. Public für den Test.
  @spec vorbereiten(String.t()) :: :ok | {:error, term()}
  def vorbereiten(pfad) do
    with :ok <- File.mkdir_p(Path.dirname(pfad)),
         :ok <- leiche_weg(pfad) do
      :ok
    end
  end

  # Nur eine Socket-Datei wird entfernt. Läge dort eine gewöhnliche Datei,
  # hätte jemand den Pfad verwechselt — dann ist Scheitern richtig.
  defp leiche_weg(pfad) do
    case File.lstat(pfad) do
      {:ok, %File.Stat{type: :other}} -> File.rm(pfad)
      {:ok, %File.Stat{type: typ}} -> {:error, {:kein_socket, typ}}
      {:error, :enoent} -> :ok
      {:error, grund} -> {:error, grund}
    end
  end

  @doc """
  Die Dateirechte auf 0600 setzen.

  Cowboy legt den Socket beim Binden selbst an, also geht das erst danach. Der
  Aufrufer ist `Worker.Application`, nachdem der Supervisor steht.
  """
  @spec rechte_setzen(String.t() | nil) :: :ok
  def rechte_setzen(nil), do: :ok

  def rechte_setzen(pfad) do
    # Keine Datei heißt: abgeschaltet oder nicht gestartet. Dann ist hier nichts
    # zu tun und auch nichts zu melden — eine Warnung über eine Datei, die es
    # nach Bauart nicht gibt, ist Lärm, und Lärm ist die Vorstufe zum Überlesen.
    if File.exists?(pfad), do: chmod(pfad), else: :ok
  end

  defp chmod(pfad) do
    case File.chmod(pfad, 0o600) do
      :ok ->
        :ok

      {:error, grund} ->
        Logger.warning("Status-Endpunkt: Rechte auf #{pfad} nicht gesetzt — #{inspect(grund)}")
        :ok
    end
  end
end
