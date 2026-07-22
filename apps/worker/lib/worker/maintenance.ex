defmodule Worker.Maintenance do
  @moduledoc """
  Einmalige Wartungs-/Migrations-Operationen, die als benannte Funktion über
  Erlang-Distribution-RPC gegen einen laufenden Worker gefahren werden.

  ## `purge_live/0` (Issue #418)

  Tilgt Alt-`status: :live`-Utterances aus der Mnesia, die vor dem Live-Removal
  (#418, keep-both #394) neben den `confirmed`-Batch-Rows liegen geblieben sind.
  Pro Session wird genau dann ein `LiveUtterancesCleared`-Event publisht (event-
  sourced + replay-durabel), wenn die Session **auch** Batch-Rows hat — Sessions
  mit nur live-Rows (kein Batch-Re-Pass gelaufen) werden zum Schutz vor
  Datenverlust übersprungen + geloggt.

  **Kanonischer Pfad (laufender Daemon):** per RPC, weil der Daemon die Mnesia
  exklusiv hält (Schema-Lock — kein zweiter BEAM auf demselben Dir):

      :rpc.call(:"worker_prod@<host>", Worker.Maintenance, :purge_live, [])

  Für einen gestoppten Worker / Dev-Mnesia geht auch `mix lore.purge_live`.
  """

  require Logger

  alias Worker.{Repo, Intents}

  @doc """
  Publisht `LiveUtterancesCleared` für jede Session mit live+batch-Rows.
  Gibt `%{cleared_sessions, cleared_utterances, orphan_sessions}` zurück.
  """
  @spec purge_live() :: %{
          cleared_sessions: non_neg_integer(),
          cleared_utterances: non_neg_integer(),
          orphan_sessions: non_neg_integer()
        }
  def purge_live do
    %{clearable: clearable, orphan: orphan} = Repo.live_purge_plan()

    for {sid, n} <- orphan do
      Logger.warning(
        "purge_live: session=#{sid} hat #{n} live-Utterance(s) aber KEINE Batch-Rows — " <>
          "übersprungen (kein Datenverlust). Pipeline für die Session neu laufen lassen, dann erneut purgen."
      )
    end

    {sessions, total} =
      Enum.reduce(clearable, {0, 0}, fn {sid, n}, {s_acc, t_acc} ->
        # Issue #589 (Cut 4): Intents.publish/1 ist total ({:ok, seq | :pending}) —
        # Hub-Sync-Fehler werden intern abgefangen (Logger.warning + pending-Counter,
        # #475). Der frühere `err ->`-Zweig war daher tot (Dialyzer pattern_match_cov)
        # und hätte zudem den Reduce-Akku auf `:ok` gekippt statt das Tupel zu führen.
        {:ok, _seq} =
          Intents.publish(%{
            "kind" => Shared.Events.live_utterances_cleared(),
            "session_id" => sid
          })

        {s_acc + 1, t_acc + n}
      end)

    Logger.info(
      "purge_live: #{total} live-Utterance(s) in #{sessions} Session(s) getilgt; " <>
        "#{length(orphan)} orphan-Session(s) übersprungen"
    )

    %{cleared_sessions: sessions, cleared_utterances: total, orphan_sessions: length(orphan)}
  end

  # ─── Campaign-Store-Heilung (Issue #718) ───────────────────────────

  @store_prefix "worker_campaign_events_"

  @doc """
  Issue #718: Soll/Ist-Abgleich der per-Campaign-Event-Stores. Die Schema-Ops
  (`maybe_create/drop_campaign_store`) laufen prinzipbedingt außerhalb der
  Event-Apply-Transaktion — ein Crash dazwischen hinterlässt entweder eine
  Campaign-Row ohne Store (`missing`, Sync-Invariante aus #693 verletzt) oder
  eine `worker_campaign_events_*`-Tabelle ohne Campaign (`orphan`).

  Pure Read (Plan/Apply-Trennung wie `live_purge_plan`):

      %{missing: [campaign_id], orphan: [tabellen_name_string]}

  Probelauf-Stores (`…_probelauf*`) zählen nicht als Orphan — Probelauf-
  Campaigns sind aus `all_campaigns` gefiltert, ihre Stores gehören dem
  Probelauf-Lifecycle (Cascade-Delete am Lauf-Ende).
  """
  @spec campaign_store_plan() :: %{missing: [String.t()], orphan: [String.t()]}
  def campaign_store_plan do
    expected =
      Repo.all_campaigns()
      |> Map.new(fn c ->
        {Atom.to_string(Worker.Schema.DynamicTables.table_name(c.id)), c.id}
      end)

    actual =
      :mnesia.system_info(:tables)
      |> Enum.map(&Atom.to_string/1)
      |> Enum.filter(&String.starts_with?(&1, @store_prefix))
      |> Enum.reject(&String.starts_with?(&1, @store_prefix <> "probelauf"))
      |> MapSet.new()

    missing = for {table, cid} <- expected, table not in actual, do: cid
    orphan = MapSet.difference(actual, MapSet.new(Map.keys(expected)))

    %{missing: Enum.sort(missing), orphan: Enum.sort(orphan)}
  end

  @doc """
  Issue #718: heilt den Plan aus `campaign_store_plan/0`.

  - `missing` → Store anlegen + **Sync-Wasserlinie des Scopes zurücksetzen**
    (ging der Store NACH erfolgtem Sync verloren, stünde die Wasserlinie sonst
    über dem leeren Store — der Pull würde die Historie für immer überspringen)
    + Hub-Subscribe (no-op wenn der HubClient noch nicht läuft; der Join-Pfad
    subscribed + pullt ohnehin alle `all_campaigns`).
  - `orphan` → NUR loggen (Datenverlust-Regel). Drop ausschließlich explizit
    via `drop_orphans: true` (manueller RPC-Aufruf, nie automatisch).

  Läuft beim Worker-Boot (application.ex, best-effort) und ist per RPC
  aufrufbar:

      :rpc.call(:"worker_prod@<host>", Worker.Maintenance, :heal_campaign_stores, [])
  """
  @spec heal_campaign_stores(keyword()) :: %{
          healed: non_neg_integer(),
          orphans: non_neg_integer(),
          dropped: non_neg_integer()
        }
  def heal_campaign_stores(opts \\ []) do
    drop? = Keyword.get(opts, :drop_orphans, false)
    plan = campaign_store_plan()

    for cid <- plan.missing, not campaign_tombstoned?(cid) do
      Worker.Schema.DynamicTables.ensure_campaign_store!(cid)
      :ok = Worker.SyncWatermark.reset(cid)
      :ok = Worker.HubClient.subscribe_campaign(cid)

      Logger.warning(
        "heal_campaign_stores: fehlender Store für campaign=#{cid} nachgelegt " <>
          "(Wasserlinie zurückgesetzt) — Backfill kommt über den Pull-Sync (#693)"
      )
    end

    dropped =
      Enum.count(plan.orphan, fn table ->
        if drop? do
          # Tabellen-Name → campaign_id ist nicht umkehrbar (Slug ohne Binde-
          # striche) — direkt über das existierende Tabellen-Atom droppen.
          case :mnesia.delete_table(String.to_existing_atom(table)) do
            {:atomic, :ok} ->
              Logger.warning(
                "heal_campaign_stores: Orphan-Store #{table} gedroppt (drop_orphans)"
              )

              true

            {:aborted, reason} ->
              Logger.error(
                "heal_campaign_stores: Orphan-Store #{table} nicht dropbar: #{inspect(reason)}"
              )

              false
          end
        else
          Logger.warning(
            "heal_campaign_stores: Orphan-Store #{table} (keine Campaign-Row) — NICHT " <>
              "gedroppt (Datenverlust-Regel); manuell via heal_campaign_stores(drop_orphans: true)"
          )

          false
        end
      end)

    %{healed: length(plan.missing), orphans: length(plan.orphan), dropped: dropped}
  end

  # Issue #894 (L5-Analogon): getombstonte Campaigns nie „heilen" — sonst legte
  # der Boot-Heal einen Store für eine gelöschte Campaign wieder an. Strukturell
  # eigentlich unerreichbar (die Cascade löscht die campaigns-Row in derselben Tx
  # wie den Tombstone-Write, und `missing` enumeriert aus Repo.all_campaigns) —
  # Defensiv-Guard gegen manuell rekonstruierte Rows / Race-Fenster.
  defp campaign_tombstoned?(cid) do
    :mnesia.dirty_read(Worker.Schema.Mnesia.deletion_tombstones(), {:campaign, cid}) != []
  end
end
