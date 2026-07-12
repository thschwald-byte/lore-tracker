defmodule Hub.RateLimit do
  @moduledoc """
  Issue #629: Per-IP Fixed-Window-Rate-Limit für unauthenticated/semi-auth
  HTTP-Routes (`/pair`, `/invite/:token`, `/auth/discord/callback`).

  **Kein `GenServer.call` im Hot-Path.** Ein Angreifer schickt im Zweifel
  tausende req/s — würde der Check über einen Call laufen, würde die
  GenServer-Mailbox fluten, Requests liefen in Timeouts, und der Rate-Limiter
  selbst würde zum DOS-Amplifier für die drei Routes, die er eigentlich
  schützen soll. `check/4` ist deshalb eine direkte, lock-freie ETS-Operation;
  der GenServer ist ausschließlich Tabellen-Owner + periodischer Sweep.

  **Fenster als absoluter Start-Zeitstempel im Key, nicht als skalierter
  Index**: der Bucket-Key ist `{name, ip, window_start_ms}`, wobei
  `window_start_ms = div(now, window_ms) * window_ms` — eine echte
  ms-Zeitangabe, unabhängig davon welches `window_ms` sie erzeugt hat. Das
  macht den Sweep-Cutoff (siehe unten) unabhängig von `window_ms` vergleichbar;
  ein skalierter Index (`div(now, window_ms)`) wäre für unterschiedliche
  `window_ms`-Werte (60s in Prod, 10min in Tests) nicht direkt vergleichbar.
  Der Value ist ein reiner Counter — `:ets.update_counter/4` ist atomar für
  den kompletten Check inkl. Default-Insert bei einem neuen Fenster, keine
  Race zwischen Lookup und Insert, keine Serialisierung über einen Prozess
  nötig.

  **Fail-open bei Tabellen-Verlust**: crasht der Owner-GenServer (z.B. beim
  Deploy-Restart), ist die named ETS-Tabelle kurz weg. `check/4` fängt das
  `ArgumentError` und lässt durch (Verfügbarkeit vor Härtung) — ein toter
  Rate-Limiter darf die drei Routes nicht mitreißen.

  **Sweep** alle 60s räumt Fenster ab, deren Start-Zeitstempel älter als
  `@max_window_ms` (1h) ist. Diese Konstante ist eine Ceiling-Annahme über
  das größte je konfigurierte `window_ms` — aktuell max. 10min (Test-Overlay).
  Wird künftig ein größeres Fenster konfiguriert, muss `@max_window_ms`
  mitwachsen, sonst könnte der Sweep einen noch aktiven Bucket vorzeitig
  räumen (Zähler resettet sich früher als das Fenster eigentlich vorsieht —
  kein Sicherheitsrisiko, aber ein Korrektheitsfehler im Throttling). Ohne
  Sweep würde ein IP-Scanner/Botnet über Stunden die Tabelle monoton wachsen
  lassen — die Selbst-DoS-Variante des DOS-Schutzes.

  **Wiederverwendung für Einmal-pro-Fenster-Warnungen**: `check/4` eignet
  sich auch für "log nur beim ersten Vorkommnis pro Fenster"-Zwecke, die
  keine echte Rate-Limit-Semantik brauchen (z.B. der XFF-Längen-Mismatch-
  Frühwarn-Log im Plug) — `check(:my_marker, ip, 1, window_ms)` liefert `:ok`
  nur beim ersten Aufruf im Fenster.
  """

  use GenServer

  require Logger

  @table :hub_rate_limit
  @sweep_interval_ms 60_000
  # Ceiling-Annahme: größtes je konfiguriertes window_ms. Siehe @moduledoc.
  @max_window_ms 3_600_000

  # ─── Public API ──────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Zählt einen Request für `{name, ip}` im aktuellen Fenster (`window_ms`
  breit). `:ok` wenn unter `limit`, sonst `{:error, :rate_limited, count}`
  (`count` ist der aktuelle Zählerstand — der Aufrufer kann daran die
  erste Überschreitung im Fenster erkennen, für Log-Drosselung).

  Fail-open (`:ok`) wenn die Tabelle nicht existiert (Owner-Crash/Restart).
  """
  @spec check(atom(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, pos_integer()}
  def check(name, ip, limit, window_ms)
      when is_atom(name) and is_binary(ip) and is_integer(limit) and limit > 0 and
             is_integer(window_ms) and window_ms > 0 do
    key = {name, ip, window_start_ms(window_ms)}

    try do
      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

      if count > limit do
        {:error, :rate_limited, count}
      else
        :ok
      end
    rescue
      ArgumentError ->
        Logger.error("Hub.RateLimit: ETS-Tabelle #{inspect(@table)} weg — fail-open")
        :ok
    end
  end

  @doc "Löscht alle Buckets (alle Fenster) für `{name, ip}` — nur für Tests."
  @spec reset(atom(), String.t()) :: :ok
  def reset(name, ip) when is_atom(name) and is_binary(ip) do
    :ets.match_delete(@table, {{name, ip, :_}, :_})
    :ok
  rescue
    # Tabelle kurz weg (z.B. Owner-Restart-Fenster in Tests) — reset/2 ist
    # ohnehin nur Test-Cleanup, kein Prod-Pfad.
    ArgumentError -> :ok
  end

  @doc "Absoluter Start-Zeitstempel (ms) des aktuellen `window_ms`-breiten Fensters."
  @spec window_start_ms(pos_integer()) :: integer()
  def window_start_ms(window_ms) when is_integer(window_ms) and window_ms > 0 do
    now = System.system_time(:millisecond)
    div(now, window_ms) * window_ms
  end

  @doc false
  def table, do: @table

  @doc """
  Test-Sync-Point: blockiert bis alle zuvor an diesen Prozess gesendeten
  Nachrichten (z.B. ein manuell geschicktes `:sweep`) verarbeitet wurden.
  Funktioniert weil Erlang FIFO-Ordering pro Sender→Empfänger garantiert —
  ein `send(pid, :sweep)` gefolgt von `sync()` aus demselben Prozess sieht
  garantiert den Post-Sweep-State. Kein `:sys`-Trick (Sys-Messages können
  reguläre Mailbox-Messages überholen — das wäre selbst ein Flake).
  """
  def sync, do: GenServer.call(__MODULE__, :sync)

  # ─── GenServer callbacks ─────────────────────────────────────────

  @impl true
  def init(_) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table, timer_ref: schedule_sweep()}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, %{state | timer_ref: schedule_sweep()}}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  # Restart-/Shutdown-Hygiene: laufenden Timer cancellen, damit kein
  # veraltetes :sweep an eine nachfolgende Prozess-Inkarnation zugestellt
  # wird (analog Worker.PipelineErrorLog.Pruner).
  @impl true
  def terminate(_reason, %{timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp sweep do
    cutoff = System.system_time(:millisecond) - @max_window_ms

    :ets.select_delete(@table, [
      {{{:"$1", :"$2", :"$3"}, :_}, [{:<, :"$3", cutoff}], [true]}
    ])
  end
end
