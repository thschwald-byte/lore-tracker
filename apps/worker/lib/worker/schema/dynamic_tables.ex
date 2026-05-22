defmodule Worker.Schema.DynamicTables do
  @moduledoc """
  Pro-Campaign Event-Tabellen, dynamisch zur Laufzeit erzeugt (Issue #127,
  Etappe 3a der worker-zentrischen Event-Architektur).

  Heute wachsen Mnesia-Tabellen statisch in `Worker.Schema.Mnesia.bootstrap!/0`.
  Etappe 3 braucht aber pro Campaign eine eigene Event-Tabelle, die erst
  beim ersten Membership-Event (CampaignCreated / InviteRedeemed /
  AdminMemberAdded für den eigenen `admin_discord_id`) angelegt wird —
  und beim Verlassen (MemberRemoved) oder CampaignDeleted wieder gedropt
  wird.

  Tabellen-Namensschema: `:"worker_campaign_events_<slug>"`. `slug` ist die
  UUIDv7 ohne Bindestriche (Mnesia-Atoms vertragen die nicht in allen
  Elixir-Code-Pfaden), klein geschrieben.

  Schema pro Tabelle:
  - `event_id` (Primary Key) — UUIDv7 vom Worker. Zeitlich sortierbar dank
    UUIDv7-Format, ersetzt die Notwendigkeit für einen separaten seq-Counter.
  - `hub_seq` — Hub-zugewiesene `seq` (oder `nil` bei Worker-First-Apply
    Events die der Hub noch nicht gesehen hat)
  - `payload` — wie im Hub-Event
  - `ts` — DateTime des Events

  Pattern folgt `Shared.Mnesia.ensure_table!/2` für Idempotenz.
  """

  require Logger

  @doc """
  Stellt sicher dass die per-Campaign-Event-Tabelle für `campaign_id`
  existiert. Idempotent. Returns das Tabellen-Atom.
  """
  @spec ensure_campaign_store!(String.t()) :: atom()
  def ensure_campaign_store!(campaign_id) when is_binary(campaign_id) do
    table = table_name(campaign_id)

    opts = [
      attributes: [:event_id, :hub_seq, :payload, :ts],
      type: :ordered_set,
      disc_copies: [node()]
    ]

    case :mnesia.create_table(table, opts) do
      {:atomic, :ok} ->
        Logger.info(
          "DynamicTables: created campaign_store table=#{inspect(table)} for campaign=#{campaign_id}"
        )

        :ok

      {:aborted, {:already_exists, ^table}} ->
        :ok
    end

    :ok = :mnesia.wait_for_tables([table], 5_000)
    table
  end

  @doc """
  Dropt die per-Campaign-Event-Tabelle für `campaign_id`. Idempotent —
  no-op wenn die Tabelle nicht existiert (z.B. wenn der Worker nie
  Member der Campaign war).
  """
  @spec drop_campaign_store!(String.t()) :: :ok
  def drop_campaign_store!(campaign_id) when is_binary(campaign_id) do
    table = table_name(campaign_id)

    case :mnesia.delete_table(table) do
      {:atomic, :ok} ->
        Logger.info(
          "DynamicTables: dropped campaign_store table=#{inspect(table)} for campaign=#{campaign_id}"
        )

        :ok

      {:aborted, {:no_exists, ^table}} ->
        :ok
    end
  end

  @doc """
  Existiert die Campaign-Tabelle (= ist der Worker Member der Campaign)?
  Wird vom Materializer benutzt um zu entscheiden ob ein Event in die
  per-Campaign-Tabelle gespiegelt werden soll.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> table_name()
    |> mnesia_table_exists?()
  end

  @doc """
  Schreibt einen Event in die per-Campaign-Tabelle. Erwartet eine offene
  Mnesia-Transaktion (wird aus dem Materializer-Apply-Block aufgerufen).
  Idempotent: wenn der Event mit derselben event_id schon da ist, wird er
  überschrieben — was bei einem Worker-First-Apply gefolgt vom Hub-Broadcast
  genau das gewünschte Verhalten ist (hub_seq wird beim Reapply nachgefüllt).
  """
  @spec write_in_tx(String.t(), String.t(), pos_integer() | nil, map(), DateTime.t()) :: :ok
  def write_in_tx(campaign_id, event_id, hub_seq, payload, ts) do
    table = table_name(campaign_id)
    :ok = :mnesia.write({table, event_id, hub_seq, payload, ts})
    :ok
  end

  @doc "Tabellen-Name für eine campaign_id (für Tests und :mnesia.table_info)."
  @spec table_name(String.t()) :: atom()
  def table_name(campaign_id) when is_binary(campaign_id) do
    slug =
      campaign_id
      |> String.replace("-", "")
      |> String.downcase()

    :"worker_campaign_events_#{slug}"
  end

  @doc """
  Issue #131 (Etappe 3c): Höchstes event_id (= UUIDv7) in der Campaign-
  Tabelle. `nil` wenn die Tabelle nicht existiert oder leer ist. Wird beim
  Connect-Pull-Since als Cursor benutzt.
  """
  @spec last_event_id(String.t()) :: String.t() | nil
  def last_event_id(campaign_id) when is_binary(campaign_id) do
    table = table_name(campaign_id)

    if mnesia_table_exists?(table) do
      case :mnesia.dirty_last(table) do
        :"$end_of_table" -> nil
        event_id when is_binary(event_id) -> event_id
      end
    else
      nil
    end
  end

  @doc """
  Issue #131: Events aus der Campaign-Tabelle ab `after_event_id` (exklusiv,
  UUIDv7-sortiert). Returns Liste von `{event_id, hub_seq, payload, ts}`-Tupeln
  in aufsteigender Reihenfolge.

  `nil` als `after_event_id` returnt alle Events der Campaign (initial
  bootstrap eines neu joinenden Workers).
  """
  @spec events_since(String.t(), String.t() | nil) :: [
          {String.t(), pos_integer() | nil, map(), DateTime.t()}
        ]
  def events_since(campaign_id, after_event_id)
      when is_binary(campaign_id) and (is_binary(after_event_id) or is_nil(after_event_id)) do
    table = table_name(campaign_id)

    if mnesia_table_exists?(table) do
      {:atomic, rows} =
        :mnesia.transaction(fn ->
          # ordered_set + UUIDv7 als Key → :mnesia.next/2 ab `after_event_id`
          # liefert die Schlüssel in lexikografischer Reihenfolge, was bei
          # UUIDv7 chronologisch ist.
          start =
            case after_event_id do
              nil -> :mnesia.first(table)
              id -> :mnesia.next(table, id)
            end

          collect(table, start, [])
        end)

      rows
    else
      []
    end
  end

  defp collect(_table, :"$end_of_table", acc), do: Enum.reverse(acc)

  defp collect(table, key, acc) do
    case :mnesia.read(table, key) do
      [{_, event_id, hub_seq, payload, ts}] ->
        collect(table, :mnesia.next(table, key), [{event_id, hub_seq, payload, ts} | acc])

      [] ->
        collect(table, :mnesia.next(table, key), acc)
    end
  end

  # ─── Internal ─────────────────────────────────────────────────────

  # Mnesia hat keine direkte table_exists?-API. `:mnesia.table_info/2` ist
  # unzuverlässig für existence (returnt 0/`undefined` für nicht-existente
  # Tabellen statt zu exiten). Stattdessen via `system_info(:tables)` —
  # autoritative Liste aller registrierten Tabellen.
  defp mnesia_table_exists?(table) do
    table in :mnesia.system_info(:tables)
  end
end
