defmodule HubWeb.WorkerRateLimit do
  @moduledoc """
  Issue #630: Per-Worker Token-Bucket für `WorkerChannel.publish_intent(_batch)`.

  Ein kompromittierter oder buggy Worker mit gültigem JWT + Membership konnte
  bislang beliebig viele Events absetzen — jedes löst einen PubSub-Broadcast an
  alle Co-Spieler-LVs + einen Mnesia-Write auf jedem anderen Worker aus. Dieser
  Token-Bucket deckelt die Rate pro Worker.

  **Kein Datenverlust bei Drosselung:** das Event ist beim Erzeuger-Worker
  bereits lokal materialisiert (#123); andere Worker holen es via `pull_since`
  (#131/#693-Tick). Der `publish_intent`-Broadcast ist nur der schnelle Pfad —
  eine rate-limitierte Verwerfung verzögert die Propagierung höchstens bis zum
  nächsten Sync-Tick, sie verliert nichts (dieselbe Recoverable-Klasse wie die
  #473-Trust-Boundary).

  **State pro Socket = pro Worker:** jeder Worker hält genau einen Channel; der
  Bucket lebt in `socket.assigns` (ephemer, kein Hub-Persist — stateless-konform).
  Ein Reconnect setzt den Bucket zurück; das ist kein Verstärker (die Rate über
  die Zeit bleibt gedeckelt, ein Reconnect-Sturm ist ein eigenes Thema).

  **Rein + explizit getaktet:** `check/3` bekommt `now_ms` übergeben (kein
  verstecktes `System.monotonic_time`) → deterministisch testbar ohne Timing-
  Flake. Der Channel füttert die Monotonic-Clock rein.

  **Admin-tunbar** über Application-Config (deploy-zeitlich, stateless-konform):

      config :hub, worker_publish_rate_per_sec: 200, worker_publish_burst: 2000

  Default: 200 Events/s Sustained, Burst 2000 (= 20 volle #702-Batches à
  `@max_batch_size 100`). Generös genug für legitimen Betrieb, deckelt den
  Worst-Case eines Spammers hart.
  """

  @default_rate_per_sec 200
  @default_burst 2000

  @type bucket :: %{tokens: float(), last_ms: integer()}

  @doc "Voller Bucket zum Verbindungsstart."
  @spec new(integer()) :: bucket()
  def new(now_ms) when is_integer(now_ms), do: %{tokens: burst() * 1.0, last_ms: now_ms}

  @doc """
  Prüft + verbucht `cost` Tokens. Refill linear mit `rate_per_sec` seit
  `last_ms`, gedeckelt auf `burst`. `{:ok, bucket}` wenn genug Tokens (abgezogen),
  sonst `{:error, bucket}` (Bucket trotzdem refill-aktualisiert, aber nichts
  abgezogen).
  """
  @spec check(bucket(), pos_integer(), integer()) :: {:ok, bucket()} | {:error, bucket()}
  def check(%{tokens: tokens, last_ms: last_ms}, cost, now_ms)
      when is_integer(cost) and cost >= 1 and is_integer(now_ms) do
    elapsed_ms = max(0, now_ms - last_ms)
    refilled = min(burst() * 1.0, tokens + elapsed_ms * rate_per_sec() / 1000)

    if refilled >= cost do
      {:ok, %{tokens: refilled - cost, last_ms: now_ms}}
    else
      {:error, %{tokens: refilled, last_ms: now_ms}}
    end
  end

  # `Application.get_env/3` liefert den Default NUR wenn der Key fehlt — steht
  # er (via runtime.exs `env!/3`) explizit auf `nil` (Env-Var nicht gesetzt),
  # käme sonst `nil` statt des Defaults durch. `|| default` fängt beide Fälle.
  @spec rate_per_sec() :: pos_integer()
  def rate_per_sec,
    do: Application.get_env(:hub, :worker_publish_rate_per_sec) || @default_rate_per_sec

  @spec burst() :: pos_integer()
  def burst, do: Application.get_env(:hub, :worker_publish_burst) || @default_burst
end
