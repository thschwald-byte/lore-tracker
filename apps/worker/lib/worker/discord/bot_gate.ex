defmodule Worker.Discord.BotGate do
  @moduledoc """
  Issue #1076: hält die Discord-Gateway-Verbindung am Leben — statt sie einmal
  beim Boot zu versuchen und bei Misserfolg für die gesamte Prozess-Laufzeit
  aufzugeben.

  ## Der Defekt, den dieses Modul behebt

  `Worker.Application.discord_bot_child/0` nahm `Nostrum.Bot` nur dann in den
  Supervisor auf, wenn `BotToken.usable?/0` beim Boot `true` lieferte — und
  diese Prüfung ist ein HTTPS-Call, der bei Netzfehlern fail-closed ist. Real
  passiert am 2026-08-18: der Worker startete Sekunden vor dem DNS
  (`%Mint.TransportError{reason: :nxdomain}`, vier Fehlversuche des
  HubClients, erste Verbindung erst vier Sekunden später). Der HubClient
  verträgt das, weil er reconnected. Die Discord-Vorprüfung kannte keinen
  zweiten Anlauf: kein Bot-Child, kein Gateway, und der Zustand hielt bis zum
  nächsten Neustart. Sichtbar war er nur im Log — im UI stand der Token
  weiterhin als gesetzt, und `/admin/errors` blieb leer, weil der Fehler vor
  dem Prozessstart der `VoiceSession` liegt.

  ## Was hier anders läuft

  1. **Netzfehler ≠ falscher Token** (`BotToken.check/0`). Ein `:rejected`
     wird nicht wiederholt — derselbe Token wird nie gültig. Ein
     `{:network_error, _}` wird mit Backoff wiederholt, unbegrenzt, wie der
     HubClient-Reconnect.
  2. **Der Bot ist nachträglich startbar.** Damit erledigt sich nebenbei die
     dokumentierte Nebenwirkung „Token-Änderung in /settings wirkt erst nach
     Worker-Neustart": im Leerlauf pollt dieses Modul den Token **lokal**
     (Settings/ENV, kein HTTP) und prüft erst gegen Discord, wenn sich
     tatsächlich etwas geändert hat. Ein abgelehnter Token erzeugt so keinen
     API-Verkehr, bis jemand ihn austauscht.
  3. **Der Zustand ist ablesbar.** `status/0` liest aus `worker_state` und
     ruft nie diesen GenServer — der Snapshot-Pfad darf nicht hinter einem
     laufenden 5-Sekunden-HTTP-Call warten (Muster `pending_publish_count`,
     #475).

  ## Warum `Nostrum.Bot` jetzt unter einem DynamicSupervisor hängt

  Der ursprüngliche Grund für die Vorprüfung war, dass `Nostrum.Bot` ein
  **statischer Top-Level-Child** war: ein Start-Fehler propagierte nach oben
  und riss den gesamten Worker-Boot mit (#985, empirisch gefunden). Unter
  `Worker.Discord.GatewaySupervisor` liefert ein Fehlstart `{:error, reason}`
  an den Aufrufer, statt jemanden mitzureißen — derselbe Mechanismus, der
  schon die `VoiceSession`-Starts abfängt.

  Der Bot läuft dort mit `restart: :temporary`, **nicht** `:permanent`: sonst
  gäbe es zwei konkurrierende Wiederbelebungs-Mechanismen (der Supervisor und
  dieses Modul), die sich gegenseitig die Backoff-Rechnung verderben. Stirbt
  der Bot, sieht dieses Modul den `:DOWN` und beginnt wieder von vorn.

  ## Ehrliche Grenzen

  - `status/0` meldet `"connected"` erst, wenn der Consumer ein `:READY`
    gesehen hat. Ein gestarteter Bot-Prozess ist noch keine Verbindung —
    genau diese Verwechslung hätte den Vorfall verschleiert.
  - Ein Widerruf des Tokens auf Discord-Seite fällt erst auf, wenn der Bot
    deswegen stirbt. Es gibt keinen periodischen Gültigkeits-Ping gegen ein
    laufendes Gateway (unnötiger API-Verkehr für einen seltenen Fall).
  - Der Zustand liegt in `worker_state` und überlebt damit einen harten
    Absturz als Altwert. `init/1` überschreibt ihn sofort — ein stale
    `"connected"` kann also nur zwischen Crash und Neustart stehen.
  """

  use GenServer

  require Logger

  alias Worker.Discord.BotToken

  @state_key :discord_gateway_state

  # Backoff für Netzfehler: schnell anfangen (der DNS-Fall ist nach Sekunden
  # geheilt), dann auf 5 Minuten deckeln (ein länger down-es Discord soll den
  # Log nicht fluten). Letzter Wert gilt für alle weiteren Versuche.
  @backoff_ms [5_000, 10_000, 20_000, 40_000, 80_000, 160_000, 300_000]

  # Leerlauf-Takt für „hat sich der Token geändert" — reiner Settings-/ENV-
  # Lesevorgang, kein HTTP.
  # Issue #1062: aus den Settings, Default unverändert.
  defp idle_poll_ms, do: Worker.Settings.get(:discord_bot_idle_poll_ms)

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Meldet, dass das Gateway wirklich steht — aufgerufen aus der `:READY`-Klausel
  des Consumers. Best-effort: läuft dieses Modul nicht (Tests, Setup-Zweig),
  ist der Aufruf ein No-op statt eines Crashs im Consumer.
  """
  @spec gateway_ready() :: :ok
  def gateway_ready do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :gateway_ready)
    end
  end

  @doc """
  Gateway-Zustand für Snapshot + Anzeige. Liest `worker_state`, ruft **nie**
  den GenServer — der Snapshot-Pfad darf nicht blockieren.

  Schlüssel sind Strings (JSON-Roundtrip zum Hub). Der Token-Wert taucht nie
  auf, auch nicht als Hash.
  """
  @spec status() :: map()
  def status do
    case Worker.Repo.get_state(@state_key) do
      %{} = s -> s
      _ -> %{"state" => "unknown", "detail" => nil, "attempts" => 0, "since" => nil}
    end
  end

  # ─── Entscheidungslogik (pur, ohne Netz/Prozesse testbar) ─────────

  @doc """
  Was aus einem Prüf-Ergebnis folgt. Pur — das ist der Teil, den ein Test
  ohne echtes Discord festnageln kann.
  """
  @spec decide(BotToken.check_result(), non_neg_integer()) ::
          :start | {:idle, :no_token | :rejected} | {:retry, pos_integer(), term()}
  def decide(:ok, _attempts), do: :start
  def decide(:no_token, _attempts), do: {:idle, :no_token}
  def decide(:rejected, _attempts), do: {:idle, :rejected}
  def decide({:network_error, reason}, attempts), do: {:retry, backoff_ms(attempts), reason}

  @doc "Backoff-Stufe für den n-ten Fehlversuch (0-basiert), gedeckelt."
  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(attempts) when is_integer(attempts) and attempts >= 0 do
    Enum.at(@backoff_ms, attempts, List.last(@backoff_ms))
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_) do
    # Sofort den Altwert eines früheren Laufs überschreiben — sonst behauptet
    # der Snapshot nach einem harten Absturz weiter "connected".
    put_status("checking", nil, 0)

    # #1005-Lehre: JEDES Feld, das eine Klausel später schreibt, gehört hier
    # hinein — ein `%{state | fehlendes_feld}` wirft KeyError, der GenServer
    # stirbt, und `restart:` dreht daraus eine Endlosschleife.
    state = %{attempts: 0, bot_pid: nil, bot_ref: nil, rejected_hash: nil, timer: nil}
    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, run_check(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, run_check(state)}

  # Leerlauf-Takt: rein lokal prüfen, ob überhaupt ein anderer Token dasteht.
  def handle_info(:poll_token, state) do
    case token_hash() do
      nil ->
        put_status("no_token", nil, 0)
        {:noreply, schedule(%{state | rejected_hash: nil}, :poll_token, idle_poll_ms())}

      hash when hash == state.rejected_hash ->
        # Unverändert abgelehnter Token — kein API-Call, nur weiter warten.
        {:noreply, schedule(state, :poll_token, idle_poll_ms())}

      _changed ->
        Logger.info("Discord.BotGate: Token hat sich geändert — prüfe erneut.")
        {:noreply, run_check(%{state | attempts: 0, rejected_hash: nil})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{bot_ref: ref} = state) do
    Logger.warning("Discord.BotGate: Bot-Prozess beendet (#{inspect(reason)}) — starte neu.")
    put_status("stopped", inspect(reason), 0)

    state = %{state | bot_pid: nil, bot_ref: nil, attempts: 0}
    {:noreply, schedule(state, :check, backoff_ms(0))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:gateway_ready, state) do
    Logger.info("Discord.BotGate: Gateway verbunden.")
    put_status("connected", nil, 0)
    {:noreply, %{state | attempts: 0}}
  end

  # ─── intern ───────────────────────────────────────────────────────

  defp run_check(state) do
    state = cancel_timer(state)

    case decide(BotToken.check(), state.attempts) do
      :start ->
        start_bot(state)

      {:idle, :no_token} ->
        put_status("no_token", nil, 0)
        %{state | rejected_hash: nil} |> schedule(:poll_token, idle_poll_ms())

      {:idle, :rejected} ->
        Logger.error(
          "Discord.BotGate: Discord lehnt den Bot-Token ab (401/403). Kein weiterer Versuch, " <>
            "bis in /settings bzw. DISCORD_BOT_TOKEN ein anderer Token steht."
        )

        put_status("rejected", nil, 0)

        %{state | rejected_hash: token_hash()}
        |> schedule(:poll_token, idle_poll_ms())

      {:retry, delay, reason} ->
        attempts = state.attempts + 1

        Logger.warning(
          "Discord.BotGate: Token-Prüfung nicht möglich (#{inspect(reason)}), Versuch " <>
            "##{attempts}, nächster in #{div(delay, 1000)}s. Discord-Aufnahme ist bis dahin nicht verfügbar."
        )

        put_status("retrying", inspect(reason), attempts)

        %{state | attempts: attempts} |> schedule(:check, delay)
    end
  end

  defp start_bot(state) do
    bot_options = %{
      consumer: Worker.Discord.Consumer,
      intents: [:guilds, :guild_voice_states],
      wrapped_token: fn -> BotToken.get() end
    }

    spec = Supervisor.child_spec({Nostrum.Bot, bot_options}, restart: :temporary)

    case DynamicSupervisor.start_child(Worker.Discord.GatewaySupervisor, spec) do
      {:ok, pid} ->
        Logger.info("Discord.BotGate: Bot gestartet — warte auf READY.")
        put_status("starting", nil, 0)
        %{state | bot_pid: pid, bot_ref: Process.monitor(pid), attempts: 0}

      {:error, reason} ->
        attempts = state.attempts + 1
        delay = backoff_ms(attempts)

        Logger.error(
          "Discord.BotGate: Bot-Start fehlgeschlagen (#{inspect(reason)}), Versuch ##{attempts}, " <>
            "nächster in #{div(delay, 1000)}s."
        )

        put_status("start_failed", inspect(reason), attempts)

        %{state | attempts: attempts} |> schedule(:check, delay)
    end
  end

  # Nur der Hash, nie der Token selbst — dieses Modul schreibt seinen Zustand
  # in worker_state, und das reist per Snapshot zum Hub.
  defp token_hash do
    case BotToken.get() do
      nil -> nil
      token -> :erlang.phash2(token)
    end
  end

  defp schedule(state, msg, delay) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), msg, delay)}
  end

  defp cancel_timer(%{timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: %{state | timer: nil}

  defp put_status(name, detail, attempts) do
    Worker.Repo.put_state(@state_key, %{
      "state" => name,
      "detail" => detail,
      "attempts" => attempts,
      "since" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
