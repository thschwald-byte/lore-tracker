defmodule Mix.Tasks.Lore.PrTest.Neustart do
  @moduledoc """
  Startet die BEAMs einer laufenden Teststage mit frisch übersetztem Code neu,
  **ohne das Datenverzeichnis anzufassen** (Issue #850).

  Der Unterschied zu `mix lore.pr_test_down` + neuem Spawn ist genau dieser
  Punkt: In der Worker-Mnesia einer Stage stecken regelmässig Daten, die nicht
  reproduzierbar sind — eine per Event-Replay eingespielte Kampagne, Stunden
  Pipeline-Rechenzeit. Ein Abbau wirft sie weg.

  **Die Umgebung kommt aus `/proc`, nicht aus einer Rekonstruktion.** Beim
  Spawn entstehen Werte, die sich nicht folgenlos nachrechnen lassen (ein frisch
  gemintetes JWT, der Mnesia-Pfad, der Port der Jack-Laufsicht). Was der
  laufende Prozess hat, ist die Wahrheit; sie wird gelesen und unverändert
  weitergereicht.

  **Der Startbefehl kommt dagegen NICHT aus `/proc`.** Dort steht `beam.smp`
  mit den entfalteten Erlang-Flags, nicht der Befehl, mit dem gestartet wurde.
  Er wird am Prozessnamen unterschieden: `…-hub` läuft mit `mix phx.server`,
  `…-worker-N` mit `mix run`. Ein Vorläufer dieses Moduls (ein Python-Skript
  ausserhalb des Repos) startete **immer** `mix run` — für den Hub also gar
  nicht.

  **Übersetzt wird vor dem Beenden, nicht danach.** Sonst steht die Stage für
  die Dauer des Compiles; und scheitert er, ist sie beendet und der neue Code
  läuft trotzdem nicht.
  """

  alias Mix.Tasks.Lore.PrTest.Runner

  @kill_frist_ms 30_000

  @doc """
  Startet die BEAMs der Stage `port` neu. `nur` schränkt auf `:hub` oder
  `:worker` ein, `nil` nimmt beide.
  """
  @spec neu_starten(pos_integer(), :hub | :worker | nil) :: :ok
  def neu_starten(port, nur \\ nil) do
    laufzeit = "/tmp/pr-#{port}"

    prozesse =
      laufzeit
      |> Path.join("*.pid")
      |> Path.wildcard()
      |> Enum.map(&lesen/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&passt?(&1, nur))
      |> Enum.sort_by(& &1.art)

    if prozesse == [], do: Mix.raise("Keine laufenden BEAMs in #{laufzeit} gefunden.")

    Enum.each(prozesse, &neu/1)
    :ok
  end

  @doc "Der Arbeits-Worktree der Stage, aus dem Arbeitsverzeichnis eines Prozesses."
  @spec worktree(pos_integer()) :: String.t() | nil
  def worktree(port) do
    "/tmp/pr-#{port}"
    |> Path.join("*.pid")
    |> Path.wildcard()
    |> Enum.map(&lesen/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [p | _] -> Path.expand("../..", p.cwd)
      [] -> nil
    end
  end

  # ─── ein Prozess ──────────────────────────────────────────────────────

  defp neu(p) do
    Mix.shell().info("  #{p.art} (#{p.sname}) beenden …")
    System.cmd("kill", [Integer.to_string(p.pid)], stderr_to_stdout: true)

    if warte_auf_ende(p.pid) do
      Runner.spawn_detached!(befehl(p), p.cwd, p.env, p.log, p.pid_file)
      Mix.shell().info("  #{p.art} neu gestartet — #{p.log}")
    else
      Mix.raise(
        "#{p.art} (pid #{p.pid}) lebt nach #{div(@kill_frist_ms, 1000)} s noch. " <>
          "Abgebrochen, statt einen zweiten daneben zu starten."
      )
    end
  end

  # Zwei BEAMs auf derselben Mnesia wären ein Schaden, kein Ärgernis — deshalb
  # wird gewartet und im Zweifel abgebrochen.
  defp warte_auf_ende(pid, wartete_ms \\ 0)
  defp warte_auf_ende(_pid, wartete) when wartete >= @kill_frist_ms, do: false

  defp warte_auf_ende(pid, wartete) do
    if File.exists?("/proc/#{pid}") do
      Process.sleep(500)
      warte_auf_ende(pid, wartete + 500)
    else
      true
    end
  end

  # Der Hub läuft mit `phx.server`, der Worker mit `run` — in /proc steht das
  # nicht, dort ist beides `beam.smp`.
  defp befehl(%{art: :hub} = p), do: elixir_befehl(p, "phx.server")
  defp befehl(p), do: elixir_befehl(p, "run")

  defp elixir_befehl(p, mix_aufgabe),
    do: "elixir --sname #{p.sname} --cookie #{p.cookie} --no-halt -S mix #{mix_aufgabe}"

  # ─── /proc lesen ──────────────────────────────────────────────────────

  defp lesen(pid_file) do
    with {:ok, roh} <- File.read(pid_file),
         {pid, _} <- Integer.parse(String.trim(roh)),
         true <- File.exists?("/proc/#{pid}"),
         {:ok, argv} <- argv(pid),
         {:ok, sname} <- flag(argv, "-sname"),
         {:ok, cookie} <- flag(argv, "-setcookie"),
         {:ok, env} <- env(pid),
         {:ok, cwd} <- File.read_link("/proc/#{pid}/cwd") do
      %{
        pid: pid,
        pid_file: pid_file,
        sname: sname,
        cookie: cookie,
        env: env,
        cwd: cwd,
        art: art(sname),
        log: String.replace_suffix(pid_file, ".pid", ".log")
      }
    else
      _ -> nil
    end
  end

  defp argv(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, roh} -> {:ok, roh |> String.split(<<0>>) |> Enum.reject(&(&1 == ""))}
      _ -> :error
    end
  end

  defp flag(argv, name) do
    case Enum.find_index(argv, &(&1 == name)) do
      nil -> :error
      i -> Enum.fetch(argv, i + 1)
    end
  end

  # Als Liste von Paaren, wie `Runner.spawn_detached!/5` sie erwartet.
  defp env(pid) do
    case File.read("/proc/#{pid}/environ") do
      {:ok, roh} ->
        paare =
          roh
          |> String.split(<<0>>)
          |> Enum.filter(&String.contains?(&1, "="))
          |> Enum.map(fn kv ->
            [k, v] = String.split(kv, "=", parts: 2)
            {k, v}
          end)

        {:ok, paare}

      _ ->
        :error
    end
  end

  defp art(sname), do: if(String.ends_with?(sname, "-hub"), do: :hub, else: :worker)

  defp passt?(_p, nil), do: true
  defp passt?(p, art), do: p.art == art
end
