defmodule Worker.Repo do
  @moduledoc """
  Read/write Mnesia wrappers for the worker's tables. Writes are owned by
  `Worker.Materializer` (event-driven); the snapshot/read helpers are used
  by `Worker.HubClient` to answer `snapshot_request` pushes from the Hub.

  All transactions raise on abort — Mnesia aborts here are programmer
  errors (schema mismatch, missing table), not expected runtime conditions.

  ## Issue #581 + #719: God-Module-Split

  Die Domänen leben in Submodulen, hier per `defdelegate` re-exportiert
  (Call-Sites bleiben `Worker.Repo.x()`):

  - `Worker.Repo.Snapshots` — die `snapshot/1`-Familie (#581)
  - `Worker.Repo.Users` — User-/Rollen-Reads (#581)
  - `Worker.Repo.Rows` — die puren Row-Mapper + Tombstone-Filter, eine Quelle
    pro Tabellen-Shape mit co-lokierten Migrations-Arities (#719)
  - `Worker.Repo.Recording` — Sessions/Utterances/Markers/Speakers (#719)
  - `Worker.Repo.Artifacts` — generierte Pipeline-Artefakte: Resümees/Fakten/
    Faithfulness/Epos/Chronik/Kalender/Probelauf-Runs (#719)

  Der Kern behält: `worker_state`-KV, Campaigns/Members/Invites (inkl. der
  `owner_discord_id`-Anreicherung, die einen Member-Read braucht) und
  `transaction/1` (`@doc false`-public — die Submodule importieren es).
  """

  alias Worker.Repo.Rows
  alias Worker.Schema.Mnesia, as: S

  # ─── worker_state ────────────────────────────────────────────────

  @spec get_state(atom()) :: term() | nil
  def get_state(key) when is_atom(key) do
    transaction(fn -> :mnesia.read(S.worker_state(), key) end)
    |> case do
      [{_, ^key, value}] -> value
      [] -> nil
    end
  end

  @spec put_state(atom(), term()) :: :ok
  def put_state(key, value) when is_atom(key) do
    transaction(fn -> :mnesia.write({S.worker_state(), key, value}) end)
    :ok
  end

  @doc """
  Issue #475: monoton steigender Zähler der `{:ok, :pending}`-Publishes (Hub-Sync
  gescheitert, Event nur lokal). Macht den sonst unbeobachtbaren :pending-Zustand
  sichtbar — abfragbar via `get_state(:pending_publish_count)` + im Warning-Log
  als laufende Summe. Gibt den neuen Stand zurück.
  """
  @spec bump_pending_publish_count(pos_integer()) :: pos_integer()
  def bump_pending_publish_count(by \\ 1) do
    n = (get_state(:pending_publish_count) || 0) + by
    put_state(:pending_publish_count, n)
    n
  end

  @spec put_state_many(map() | keyword()) :: :ok
  def put_state_many(map) do
    table = S.worker_state()

    transaction(fn ->
      Enum.each(map, fn {key, value} ->
        :mnesia.write({table, key, value})
      end)
    end)

    :ok
  end

  # ─── users ──────────────────────────────────────────────────────

  # Returns %{discord_id => %{"display_name" => name, "avatar_url" => url | nil}}.
  # Fallback: if a user-record doesn't exist yet, display_name = discord_id,
  # avatar_url = nil. The UI's `avatar/1` helper computes a Discord-default
  # avatar from the discord_id in that case.
  # Issue #581: public (@doc false) — von Worker.Repo.{Users,Snapshots} via import genutzt.
  @doc false
  def fetch_users(discord_ids) do
    discord_ids
    |> Enum.uniq()
    |> Enum.into(%{}, fn did ->
      case transaction(fn -> :mnesia.read(S.users(), did) end) do
        [{_, _, name, _, avatar, _role, _cap}] ->
          {did, %{"display_name" => name, "avatar_url" => avatar, "deleted" => false}}

        [] ->
          # Issue #57: dangling discord_id (User wurde gelöscht, oder hat
          # sich noch nie eingeloggt). UI rendert das als `<.deleted_user_pill>`
          # via "deleted" == true. display_name bleibt = discord_id für Pfade
          # die das deleted-Flag (noch) nicht checken.
          {did, %{"display_name" => did, "avatar_url" => nil, "deleted" => true}}
      end
    end)
  end

  # ─── campaigns ──────────────────────────────────────────────────

  def get_campaign(id) do
    # Issue #475: die 3-Arity-Tupel-Dekodierung (8/9/10-Tupel) lebt an genau
    # EINER Stelle — campaign_row_to_map/1 (das auch all_campaigns nutzt). Vorher
    # reimplementierte get_campaign dieselbe Dekodierung dreifach; getrennte
    # Implementierungen droht zu driften (genau die Klasse, die mehrere #140-
    # Bugs auslöste). get_campaign ist jetzt campaign_row_to_map + die zusätzliche
    # :vorgaben-Auflösung (die der List-/Snapshot-Pfad nicht braucht).
    #
    # owner_discord_id (kein persistiertes Feld seit #140 → erster Spielleiter)
    # + transcript_source/flavors-Normalisierung erbt get_campaign damit aus
    # campaign_row_to_map; Permission-Gating läuft trotzdem über campaign_role/2.
    case transaction(fn -> :mnesia.read(S.campaigns(), id) end) do
      [row] -> campaign_row_to_map(row) |> Map.put(:vorgaben, vorgaben_for(id))
      [] -> nil
    end
  end

  # Issue #313: Ausgabe-Vorgaben der Campaign als `%{stage => %{name,
  # darstellungsform}}`. Fehlende Stages tauchen nicht auf — der Caller
  # fällt dann auf seine Default-Werte zurück.
  defp vorgaben_for(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_vorgaben(), campaign_id, :campaign_id)
    end)
    |> Enum.into(%{}, fn {_, _key, _cid, stage, name, form} ->
      {stage, %{name: name, darstellungsform: form}}
    end)
  end

  # Issue #140 post-A hotfix: Sort-Comparator-Safety. Wenn die Repair-
  # Migration auf einer noch-nicht-gebooteten Worker-Instanz nicht
  # gelaufen ist (Mehrnode-Setup) oder ein Edge-Case ein Nicht-DateTime
  # ins Feld setzt, soll der Sort nicht den ganzen Dashboard-Snapshot
  # killen. Fallback auf Epoch, damit kaputte Rows hinten landen.
  defp safe_created_at(%DateTime{} = dt), do: dt
  defp safe_created_at(_), do: ~U[1970-01-01 00:00:00.000000Z]

  def list_campaigns_for(discord_id) do
    discord_id
    |> list_campaign_ids_for()
    |> Enum.map(&get_campaign/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(&safe_created_at(&1.created_at), {:desc, DateTime})
  end

  @doc "Liste aller Kampagnen auf dieser Instance (für Admin-UI #35)."
  def all_campaigns do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.campaigns()) end)
    |> Enum.map(&campaign_row_to_map/1)
    |> Enum.reject(&probelauf_campaign?/1)
    |> Enum.sort_by(&safe_created_at(&1.created_at), {:desc, DateTime})
  end

  # Issue #719: die Tupel-Dekodierung (8/9/10-Arity-Shape-Historie) lebt in
  # `Worker.Repo.Rows.campaign/1`; hier bleibt nur die Anreicherung, die einen
  # Member-Read braucht (owner_discord_id = erster Spielleiter, #140).
  defp campaign_row_to_map(row) do
    m = Rows.campaign(row)
    Map.put(m, :owner_discord_id, first_spielleiter(m.id))
  end

  # Probelauf-Campaigns (Issue #74) sollen NICHT in normalen Listen
  # auftauchen — sie sind ephemer und werden nach dem Lauf cascade-deleted.
  # ID-Prefix-Match reicht (Worker.Probelauf seedet mit "probelauf-" + uuid).
  defp probelauf_campaign?(%{id: id}) when is_binary(id),
    do: String.starts_with?(id, "probelauf-")

  defp probelauf_campaign?(_), do: false

  def list_campaign_ids_for(discord_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), discord_id, :discord_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.map(fn row -> elem(row, 2) end)
    |> Enum.uniq()
  end

  # ─── members ────────────────────────────────────────────────────

  def list_members(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_members(), campaign_id, :campaign_id)
    end)
    |> Enum.reject(&member_row_deleted?/1)
    |> Enum.map(&Rows.member/1)
  end

  # Issue #719: Shape-Wissen in `Worker.Repo.Rows`; member_row_deleted?/1
  # bleibt hier als public Weiterleitung (Worker.Repo.Users importiert sie).
  @doc false
  defdelegate member_row_deleted?(row), to: Rows, as: :member_deleted?

  @doc """
  Map of `discord_id → character_name` for the given campaign — only entries
  where an alias is actually set (nil entries excluded). Used by the Hub
  display layer to override the discord-display-name fallback chain.
  """
  def character_names_for(campaign_id) do
    list_members(campaign_id)
    |> Enum.flat_map(fn
      %{discord_id: did, character_name: name} when is_binary(name) and name != "" ->
        [{did, name}]

      _ ->
        []
    end)
    |> Map.new()
  end

  def member?(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [row] -> not member_row_deleted?(row)
      [] -> false
    end
  end

  @doc """
  Per-Campaign-Rolle eines Users in einer Kampagne (Issue #140):
  `:spielleiter | :spieler | nil`. `nil` wenn nicht Member (oder
  Tombstoned). Quelle der Wahrheit: `campaign_members.role`.
  """
  def campaign_role(campaign_id, discord_id) do
    case transaction(fn ->
           :mnesia.read(S.campaign_members(), S.member_key(campaign_id, discord_id))
         end) do
      [row] ->
        if member_row_deleted?(row), do: nil, else: elem(row, 4)

      [] ->
        nil
    end
  end

  @doc """
  Erster Spielleiter einer Kampagne als discord_id (oder nil falls keiner
  gefunden — sollte nur passieren wenn die Auto-Member-Migration aus
  Issue #140 für historische Daten noch nicht gelaufen ist).
  """
  def first_spielleiter(campaign_id) do
    list_members(campaign_id)
    |> Enum.find(&(&1.role == :spielleiter))
    |> case do
      %{discord_id: did} -> did
      nil -> nil
    end
  end

  # ─── invites ────────────────────────────────────────────────────

  def get_invite(token) when is_binary(token) do
    case transaction(fn -> :mnesia.read(S.campaign_invites(), token) end) do
      [{_, ^token, cid, by, created, expires, status, redeemed_by}] ->
        %{
          token: token,
          campaign_id: cid,
          created_by_discord_id: by,
          created_at: created,
          expires_at: expires,
          status: status,
          redeemed_by_discord_id: redeemed_by
        }

      [] ->
        nil
    end
  end

  def list_invites(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.campaign_invites(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, token, cid, by, created, expires, status, redeemed_by} ->
      %{
        token: token,
        campaign_id: cid,
        created_by_discord_id: by,
        created_at: created,
        expires_at: expires,
        status: status,
        redeemed_by_discord_id: redeemed_by
      }
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # Issue #581: public (@doc false) — von Worker.Repo.{Users,Snapshots} via import genutzt.
  @doc false
  def transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> raise "Mnesia transaction aborted: #{inspect(reason)}"
    end
  end

  # ─── Issue #581: Façade-Delegation an die ausgelagerten Submodule ─────────
  # Call-Sites bleiben `Worker.Repo.x()`; die Implementierung lebt im Submodul.

  defdelegate upsert_user(discord_id, display_name), to: Worker.Repo.Users
  defdelegate get_user(discord_id), to: Worker.Repo.Users
  defdelegate audio_consent(discord_id), to: Worker.Repo.Users
  defdelegate list_all_users(), to: Worker.Repo.Users
  defdelegate admin_exists?(), to: Worker.Repo.Users
  defdelegate last_admin?(discord_id), to: Worker.Repo.Users
  defdelegate last_spielleiter_campaigns_for(discord_id), to: Worker.Repo.Users
  defdelegate users_for_campaign(campaign_id), to: Worker.Repo.Users
  defdelegate users_for_dashboard(viewer_discord_id), to: Worker.Repo.Users

  defdelegate snapshot(scope), to: Worker.Repo.Snapshots
  defdelegate monthly_spend_usd(discord_id), to: Worker.Repo.Snapshots
  defdelegate recent_call_count(discord_id, window_seconds), to: Worker.Repo.Snapshots
  defdelegate last_n_pipeline_errors(n \\ 50), to: Worker.Repo.Snapshots
  defdelegate any_active_recording?(), to: Worker.Repo.Snapshots

  # Issue #719: Recording-Domäne (Sessions/Utterances/Markers/Speakers).
  defdelegate list_sessions(campaign_id), to: Worker.Repo.Recording
  defdelegate get_session(session_id), to: Worker.Repo.Recording
  defdelegate active_session_for(campaign_id), to: Worker.Repo.Recording
  defdelegate next_session_number(campaign_id), to: Worker.Repo.Recording
  defdelegate list_utterances(session_id), to: Worker.Repo.Recording
  defdelegate list_utterances(session_id, opts), to: Worker.Repo.Recording
  defdelegate recent_utterance_texts(session_id), to: Worker.Repo.Recording
  defdelegate recent_utterance_texts(session_id, limit), to: Worker.Repo.Recording
  defdelegate live_purge_plan(), to: Worker.Repo.Recording
  defdelegate list_markers(session_id), to: Worker.Repo.Recording
  defdelegate list_speaker_assignments_for_campaign(campaign_id), to: Worker.Repo.Recording
  defdelegate list_speaker_assignments(session_id), to: Worker.Repo.Recording
  defdelegate list_utterances_for_campaign(campaign_id), to: Worker.Repo.Recording
  defdelegate list_utterances_for_campaign(campaign_id, opts), to: Worker.Repo.Recording
  defdelegate list_markers_for_campaign(campaign_id), to: Worker.Repo.Recording

  # Issue #719: generierte Pipeline-Artefakte (Resümee/Fakten/Faithfulness/
  # Epos/Chronik/Kalender/Probelauf).
  defdelegate get_epos_entry(entry_id), to: Worker.Repo.Artifacts
  defdelegate list_epos_history(entry_id), to: Worker.Repo.Artifacts
  defdelegate list_epos_chapters(campaign_id), to: Worker.Repo.Artifacts
  defdelegate get_session_summary(session_id), to: Worker.Repo.Artifacts
  defdelegate get_session_facts(session_id), to: Worker.Repo.Artifacts
  defdelegate list_campaign_facts(campaign_id), to: Worker.Repo.Artifacts
  defdelegate campaign_review_facts(campaign_id), to: Worker.Repo.Artifacts
  defdelegate list_session_summaries(campaign_id), to: Worker.Repo.Artifacts
  defdelegate get_faithfulness_score(session_id), to: Worker.Repo.Artifacts
  defdelegate list_faithfulness_scores(campaign_id), to: Worker.Repo.Artifacts
  defdelegate list_chronik_entries(campaign_id), to: Worker.Repo.Artifacts
  defdelegate get_campaign_calendar(campaign_id), to: Worker.Repo.Artifacts
  defdelegate get_session_anchor_day(session_id), to: Worker.Repo.Artifacts
  defdelegate get_session_anchor(session_id), to: Worker.Repo.Artifacts
  defdelegate derive_chronik_sort_tuple(date), to: Worker.Repo.Artifacts
  defdelegate last_probelauf_run(), to: Worker.Repo.Artifacts
  defdelegate all_probelauf_runs(), to: Worker.Repo.Artifacts
  defdelegate last_probelauf_sweep(), to: Worker.Repo.Artifacts
  defdelegate last_n_probelauf_sweeps(), to: Worker.Repo.Artifacts
  defdelegate last_n_probelauf_sweeps(n), to: Worker.Repo.Artifacts
end
