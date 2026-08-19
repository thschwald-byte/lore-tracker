defmodule Hub.MemoryReporter do
  @moduledoc """
  Issue #1087: periodische Speicher-Zeile im Prod-Log.

  Der Prod-Hub wurde binnen zwölf Tagen fünfzehnmal am Speicherlimit gekillt.
  Die Ursachensuche scheiterte daran, dass Gigalixir nur die **Tatsache** des
  Kills protokolliert, keinen Verlauf: aus den Logs war nicht zu entscheiden,
  ob der Speicher über Stunden stieg (Leck) oder binnen Sekunden sprang
  (Spitze). Diese Zeile macht aus „irgendwann tot" eine Kurve, die sich
  rückwirkend auswerten lässt — die Logs werden ohnehin nach `~/logs/`
  mitgeschrieben.

  Gemessen werden **zwei** Größen, und die Unterscheidung ist der Kern:

  - `:erlang.memory/0` — was der BEAM von sich selbst weiß.
  - die **Cgroup** (`/sys/fs/cgroup/memory.*`) — was der Kernel sieht und
    woran der Container stirbt. Die beiden weichen deutlich voneinander ab
    (live gemessen: BEAM 160 MB, Cgroup 242 MiB bei 381,5 MiB Limit), weil
    Allocator-Verschnitt, VM-Overhead und Seitencache nur in der zweiten Zahl
    stehen. Nur auf die BEAM-Zahl zu schauen, hätte die Ursache verfehlt.

  Dazu die Zahl der offenen LiveViews: der einzige belastbare Zusammenhang aus
  der Log-Auswertung war, dass **kein einziger** Kill in ein Zeitfenster ohne
  Zuschauer fiel (0 von 1494), während 13 in die 272 Fenster mit Zuschauern
  fielen. Ohne diese Spalte bliebe das eine Korrelation über Umwege.

  Reine Messung, kein Eingriff — ein Deckel oder Rückdruck wäre eine Maßnahme
  gegen eine noch unbewiesene Ursache.
  """
  use GenServer

  require Logger

  @default_interval_ms 30_000
  @cgroup_dir "/sys/fs/cgroup"
  # Ab diesem Anteil des Cgroup-Limits wird die Zeile zur Warnung. Kein
  # Eingriff, nur Sichtbarkeit: eine Warnung kurz vor dem Kill macht im
  # Nachhinein den Zusammenhang auffindbar.
  @warn_ratio 0.85
  @top_n 3

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval_ms) ||
        Application.get_env(:hub, :memory_report_interval_ms, @default_interval_ms)

    # Jedes Feld, das eine Klausel später per Map-Update schreibt, MUSS hier
    # stehen — ein fehlender Key wirft KeyError und der GenServer stirbt in
    # einer Restart-Schleife (die Lehre aus #1005).
    state = %{
      interval: interval,
      cgroup_dir: Keyword.get(opts, :cgroup_dir, @cgroup_dir),
      timer: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:report, state) do
    state |> collect() |> log()

    # Das Einsammeln aller Prozessinfos legt einige hundert KB auf den eigenen
    # Heap. Ohne das Aufräumen stünde dieser Prozess in seiner eigenen Top-3 —
    # und verdrängte dort genau die Prozesse, wegen derer die Zeile existiert.
    :erlang.garbage_collect()

    {:noreply, schedule(state)}
  end

  @impl true
  def terminate(_reason, state) do
    cancel(state.timer)
    :ok
  end

  defp schedule(state) do
    cancel(state.timer)
    %{state | timer: Process.send_after(self(), :report, state.interval)}
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  @doc """
  Issue #1087: alle Messwerte einer Runde als Keyword-Liste, in der Reihenfolge
  der Log-Zeile. Public, damit sie ohne laufenden GenServer prüfbar ist.
  """
  @spec collect(map()) :: keyword()
  def collect(%{cgroup_dir: dir}) do
    mem = :erlang.memory()

    beam = [
      total_mb: mb(mem[:total]),
      processes_mb: mb(mem[:processes]),
      binary_mb: mb(mem[:binary]),
      ets_mb: mb(mem[:ets]),
      code_mb: mb(mem[:code]),
      procs: length(:erlang.processes()),
      live_views: live_view_count()
    ]

    beam ++ cgroup_fields(read_cgroup(dir)) ++ [top: top_processes(@top_n)]
  end

  @doc """
  Issue #1087: Cgroup-v2-Werte in Bytes. `%{}`, wenn kein **echtes** Limit
  gesetzt ist.

  Die Unterscheidung ist Absicht: im Container steht in `memory.max` eine Zahl,
  auf der Entwicklermaschine der String `"max"`. Ohne diese Prüfung stünden im
  Dev-Log die Speicherwerte des ganzen Rechners — Zahlen, die aussehen wie eine
  Messung, aber keine sind.
  """
  @spec read_cgroup(String.t()) :: map()
  def read_cgroup(dir) do
    case read_int(Path.join(dir, "memory.max")) do
      nil ->
        %{}

      limit ->
        %{
          limit: limit,
          current: read_int(Path.join(dir, "memory.current")),
          peak: read_int(Path.join(dir, "memory.peak")),
          anon: read_stat_key(Path.join(dir, "memory.stat"), "anon")
        }
    end
  end

  @doc "Issue #1087: Cgroup-Werte als Log-Felder; leer, wenn nicht messbar."
  @spec cgroup_fields(map()) :: keyword()
  def cgroup_fields(cg) when map_size(cg) == 0, do: []

  def cgroup_fields(cg) do
    [
      cg_limit_mb: mb(cg[:limit]),
      cg_used_mb: mb(cg[:current]),
      cg_peak_mb: mb(cg[:peak]),
      cg_anon_mb: mb(cg[:anon]),
      cg_pct: pct(cg[:current], cg[:limit])
    ]
  end

  @doc """
  Issue #1087: Anteil des Limits in Prozent, oder `nil`. `nil` statt 0, weil
  „nicht messbar" und „nichts belegt" verschiedene Aussagen sind.
  """
  @spec pct(integer() | nil, integer() | nil) :: integer() | nil
  def pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0,
    do: round(used * 100 / limit)

  def pct(_, _), do: nil

  @doc """
  Issue #1087: die größten Prozesse mit Namen und Mailbox-Länge.

  Ohne Namen sagt eine Gesamtzahl beim nächsten Kill wieder nichts — die Frage
  wird sein, WER den Speicher hielt. Die Mailbox-Länge steht daneben, weil ein
  Stau dort die zweite plausible Bauform desselben Symptoms ist.
  """
  @spec top_processes(pos_integer()) :: String.t()
  def top_processes(n) do
    :erlang.processes()
    |> Enum.map(&process_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(n)
    |> Enum.map_join(",", fn {kb, name, qlen} -> "#{name}/#{kb}kb/q#{qlen}" end)
  end

  defp process_entry(pid) do
    case Process.info(pid, [:memory, :message_queue_len, :registered_name, :dictionary]) do
      nil ->
        nil

      info ->
        {div(info[:memory], 1024), process_name(pid, info), info[:message_queue_len]}
    end
  end

  defp process_name(pid, info) do
    case info[:registered_name] do
      name when is_atom(name) and not is_nil(name) ->
        name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

      _ ->
        case initial_call(info[:dictionary]) do
          {mod, _f, _a} -> mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
          _ -> inspect(pid)
        end
    end
  end

  @doc """
  Issue #1087: Zahl der offenen LiveView-Prozesse.

  Erkannt am **Prozess-Label**, das Phoenix beim Start eines LiveView-Channels
  setzt (`{Phoenix.LiveView, MeinLive, "lv:phx-…"}`). Naheliegender wäre
  `$initial_call` gewesen — das trägt aber das LiveView-**Modul**
  (`{HubWeb.EinstellungenLive, :mount, 3}`), nicht den Channel, und eine
  Erkennung darüber hätte jede neue Ansicht einzeln kennen müssen.

  Eine Registry gibt es nicht: Phoenix führt keine Liste offener LiveViews,
  und die internen Transport-Strukturen sind kein Vertrag. Das Label ist eine
  bewusst gesetzte Beobachtungshilfe — trotzdem ein Interna, deshalb mountet
  ein Test einen echten LiveView und prüft, dass er hier auftaucht. Ohne den
  Test meldete die Log-Zeile nach einem Phoenix-Update still dauerhaft 0.
  """
  @spec live_view_count() :: non_neg_integer()
  def live_view_count do
    Enum.count(:erlang.processes(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> live_view?(Keyword.get(dict, :"$process_label"))
        _ -> false
      end
    end)
  end

  defp live_view?({Phoenix.LiveView, _module, _id}), do: true
  defp live_view?(_), do: false

  defp initial_call(dict) when is_list(dict), do: Keyword.get(dict, :"$initial_call")
  defp initial_call(_), do: nil

  defp read_int(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_stat_key(path, key) do
    with {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           content |> String.split("\n") |> Enum.find(&String.starts_with?(&1, key <> " ")),
         [_, value] <- String.split(line, " ", parts: 2),
         {n, ""} <- Integer.parse(String.trim(value)) do
      n
    else
      _ -> nil
    end
  end

  defp mb(nil), do: nil
  defp mb(bytes) when is_integer(bytes), do: div(bytes, 1_048_576)

  defp log(fields) do
    line =
      fields
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    if warn?(fields) do
      Logger.warning("[telemetry] event=hub.memory #{line}")
    else
      Logger.info("[telemetry] event=hub.memory #{line}")
    end
  end

  @doc "Issue #1087: ab `@warn_ratio` des Cgroup-Limits wird die Zeile zur Warnung."
  @spec warn?(keyword()) :: boolean()
  def warn?(fields) do
    case Keyword.get(fields, :cg_pct) do
      p when is_integer(p) -> p >= round(@warn_ratio * 100)
      _ -> false
    end
  end
end
