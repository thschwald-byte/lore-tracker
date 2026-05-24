defmodule Worker.TestHelper do
  @moduledoc """
  Gemeinsame Helper für Worker-Tests (Issue #166 Stufe A).

  Ersetzt die >7 lokal duplizierten `event/2|3`-Helper, das inkonsistente
  Materializer-Lifecycle-Boilerplate und manuelle Mnesia-`clear_table`-
  Schleifen in den Materializer-Tests.

  ## Usage

      defmodule Worker.MyMaterializerTest do
        use ExUnit.Case, async: false
        import Worker.TestHelper

        setup do
          clear_all_tables!()
          mat_pid = ensure_materializer!()
          on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
          :ok
        end

        test "applies event" do
          ev = event("AdminMemberAdded", %{"campaign_id" => "c", ...}, 1)
          ...
        end
      end
  """

  alias Worker.Schema.Mnesia, as: S

  @doc """
  Baut ein Event-Map in der vom Materializer erwarteten Shape.

  - `kind`: Event-Kind als String, z.B. `"AdminMemberAdded"` (wird in `payload["kind"]` gemerged).
  - `payload`: Map mit den Event-spezifischen Feldern.
  - `seq`: Sequence-Number (Integer).
  - `opts`: Keyword-List mit optionalen Overrides:
    - `:ts` — ISO8601-Timestamp-String (default: `DateTime.utc_now() |> to_iso8601`)
    - `:author_worker_id` — String (default: `"test"`)
    - `:event_id` — UUID-String (default: nicht gesetzt; Materializer dedupliziert dann auf `seq`)
  """
  @spec event(String.t(), map(), integer(), keyword()) :: map()
  def event(kind, payload, seq, opts \\ []) when is_binary(kind) and is_map(payload) and is_integer(seq) do
    base = %{
      "seq" => seq,
      "ts" => Keyword.get(opts, :ts, DateTime.to_iso8601(DateTime.utc_now())),
      "author_worker_id" => Keyword.get(opts, :author_worker_id, "test"),
      "payload" => Map.put(payload, "kind", kind)
    }

    case Keyword.get(opts, :event_id) do
      nil -> base
      eid -> Map.put(base, "event_id", eid)
    end
  end

  @doc """
  Startet den Materializer-GenServer idempotent. Returnt den PID falls
  neu gestartet, sonst `nil` (war schon up).

  Benutze in `setup` und kombiniere mit `on_exit/1`:

      mat_pid = ensure_materializer!()
      on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
  """
  @spec ensure_materializer!() :: pid() | nil
  def ensure_materializer! do
    case Worker.Materializer.start_link([]) do
      {:ok, pid} -> pid
      {:error, {:already_started, _pid}} -> nil
    end
  end

  @doc """
  Leert alle Worker-Mnesia-Tabellen (außer `worker_state` — das hält
  Cursor/Token/Settings, die typischerweise pro Test gezielt überschrieben werden).

  Idempotent: nicht-existente oder leere Tabellen werden übersprungen.
  """
  @spec clear_all_tables!() :: :ok
  def clear_all_tables! do
    Enum.each(clearable_tables(), fn table ->
      case :mnesia.clear_table(table) do
        {:atomic, :ok} -> :ok
        # Tabelle existiert nicht (z.B. dynamisch erstellte per-Campaign-Tables)
        {:aborted, {:no_exists, _}} -> :ok
      end
    end)
  end

  defp clearable_tables do
    [
      S.users(),
      S.campaigns(),
      S.campaign_members(),
      S.campaign_invites(),
      S.sessions(),
      S.utterances(),
      S.markers(),
      S.epos_entries(),
      S.epos_history(),
      S.session_summaries(),
      S.session_faithfulness_scores(),
      S.chronik_entries(),
      S.probelauf_runs(),
      S.probelauf_sweeps(),
      S.applied_event_ids(),
      S.events_global()
    ]
  end
end
