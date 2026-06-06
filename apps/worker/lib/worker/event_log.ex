defmodule Worker.EventLog do
  @moduledoc """
  Issue #97 (Cut 1): Retention/Pruning für den worker-lokalen EventLog.

  Die Event-Stores (`worker_events_global` + pro-Campaign `worker_campaign_events_<slug>`)
  wachsen append-only und werden auch von `CampaignDeleted` nicht geleert. Sie
  dienen ausschließlich (a) dem Worker-zu-Worker-Gossip-Pull (#131/#141) und
  (b) der Disaster-Recovery. Die materialisierte Lese-State (campaigns/sessions/
  utterances/… als disc_copies) wird beim Boot NICHT aus dem Log rekonstruiert —
  sie ist persistent. Alte Event-Rows zu prunen lässt die Lese-State daher
  unangetastet.

  `prune_before/2` löscht Event-Rows mit `ts < cutoff` aus dem globalen Store
  und allen per-Campaign-Stores (oder einem). Der Pull-Cursor (`last_event_id`
  via `:mnesia.dirty_last`) zeigt auf das JÜNGSTE Event und bleibt damit
  unberührt — Prunen alter Events bricht den Gossip-Connect-Cursor nicht.

  **Single-Worker-Scope (#97 Cut 1):** Bei Multi-Worker-Setups (#131-Gossip)
  würde ein anderer Worker mit älterem Cursor die geprunten Events nicht mehr
  geliefert bekommen (Lücke), und ein Pull von einem Worker der sie noch hat
  drückte sie wieder ein. Korrekte Multi-Worker-Konvergenz braucht einen
  signierten Prune-Event — bewusst Folge-Issue. Prune ist destruktiv für die
  Disaster-Recovery der geprunten Events: vorher ein Backup ziehen.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  @campaign_store_prefix "worker_campaign_events_"

  @type prune_result :: %{
          global: non_neg_integer(),
          campaigns: %{atom() => non_neg_integer()},
          total: non_neg_integer(),
          dry_run: boolean()
        }

  @doc """
  Löscht alle Event-Rows mit `ts < cutoff` (DateTime).

  Opts:
  - `:dry_run` (bool, default false) — nur zählen, nichts löschen.
  - `:campaign_id` (String) — nur den Store dieser Campaign prunen (+ NICHT global).
    Ohne diese Option: globaler Store + ALLE per-Campaign-Stores.

  Returns `%{global:, campaigns: %{table => n}, total:, dry_run:}`.
  """
  @spec prune_before(DateTime.t(), keyword()) :: prune_result()
  def prune_before(%DateTime{} = cutoff, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    tables =
      case Keyword.get(opts, :campaign_id) do
        nil -> [S.events_global() | campaign_store_tables()]
        cid when is_binary(cid) -> [Worker.Schema.DynamicTables.table_name(cid)]
      end

    {global, campaigns} =
      Enum.reduce(tables, {0, %{}}, fn table, {g, c} ->
        n = prune_table(table, cutoff, dry_run)

        if table == S.events_global() do
          {n, c}
        else
          {g, Map.put(c, table, n)}
        end
      end)

    total = global + (campaigns |> Map.values() |> Enum.sum())

    Logger.warning(
      "Worker.EventLog: prune_before(#{DateTime.to_iso8601(cutoff)}) " <>
        "#{if dry_run, do: "[DRY-RUN] ", else: ""}global=#{global} " <>
        "campaigns=#{map_size(campaigns)} total=#{total}"
    )

    %{global: global, campaigns: campaigns, total: total, dry_run: dry_run}
  end

  # Alle existierenden per-Campaign-Event-Store-Tabellen-Atome.
  @spec campaign_store_tables() :: [atom()]
  defp campaign_store_tables do
    :mnesia.system_info(:tables)
    |> Enum.filter(fn t -> String.starts_with?(Atom.to_string(t), @campaign_store_prefix) end)
  end

  # Löscht (oder zählt) Rows mit ts < cutoff. Store-Schema:
  # {table, event_id, hub_seq, payload, ts}. Sammeln-dann-löschen in EINER
  # Transaktion (kein Delete während foldl über dieselbe Tabelle).
  defp prune_table(table, cutoff, dry_run) do
    if table in :mnesia.system_info(:tables) do
      {:atomic, count} =
        :mnesia.transaction(fn ->
          to_delete =
            :mnesia.foldl(
              fn {_t, event_id, _hub_seq, _payload, ts}, acc ->
                if before?(ts, cutoff), do: [event_id | acc], else: acc
              end,
              [],
              table
            )

          unless dry_run do
            Enum.each(to_delete, fn event_id -> :mnesia.delete({table, event_id}) end)
          end

          length(to_delete)
        end)

      count
    else
      0
    end
  end

  defp before?(%DateTime{} = ts, cutoff), do: DateTime.compare(ts, cutoff) == :lt
  # Defensiv: nicht-DateTime ts (Altdaten) nie prunen.
  defp before?(_, _), do: false
end
