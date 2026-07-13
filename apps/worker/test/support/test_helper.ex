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
  def event(kind, payload, seq, opts \\ [])
      when is_binary(kind) and is_map(payload) and is_integer(seq) do
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
  Issue #571: idempotenter Helper, der einen genannten Prozess (z.B.
  `Worker.TaskSupervisor`) startet, falls er noch nicht läuft. `starter`
  liefert `{:ok, pid}` oder `{:error, {:already_started, _}}`. Nützlich
  in Standalone-Tests, die Module benutzen, deren Worker.Application-
  Supervision-Tree nicht gestartet ist.

      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

  Issue #695: der gestartete Prozess wird **unlinkt**. `start_link` im Setup
  linkt sonst an den Test-Prozess — der Ersatz-Supervisor stirbt mit dem
  Test-Ende, der nächste Test sieht beim `whereis` noch den sterbenden Pid
  (→ `:ok`) und crasht dann mitten im Test mit `:noproc` (rotete den
  master-Deploy, Ordering-Flake je nach ExUnit-Seed). Unlinkt überlebt der
  Ersatz die Test-Grenze wie das Original aus dem Application-Tree.
  """
  @spec ensure_started(atom(), (-> {:ok, pid()} | {:error, term()})) :: :ok
  def ensure_started(name, starter) when is_atom(name) and is_function(starter, 0) do
    case Process.whereis(name) do
      nil ->
        case starter.() do
          {:ok, pid} ->
            Process.unlink(pid)
            :ok

          {:error, {:already_started, _}} ->
            :ok
        end

      _pid ->
        :ok
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

  @doc """
  `clear_all_tables!/0` PLUS `worker_state` (Seq-/Event-Id-Cursor) — für
  Permutations-Reruns INNERHALB eines Tests (nicht nur zwischen Tests). Ohne
  den Cursor-Reset würde die zweite/dritte Permutation auf denselben
  synthetischen `seq`-Werten wie die erste laufen und der Materializer
  behandelt sie als "schon angewendet"/"Gap" statt sie frisch zu materialisieren.
  """
  @spec reset_for_permutation!() :: :ok
  def reset_for_permutation! do
    clear_all_tables!()
    :mnesia.clear_table(S.worker_state())
    :ok
  end

  @doc """
  Issue #698/#766 (I7-Konvergenz): wiederverwendbarer Permutations-Baustein.
  Wendet dasselbe `events`-Set in mehreren Reihenfolgen an (Original, Reverse,
  Rotate+1/+2/+3 — 5 Permutationen, mehr Abdeckung als reines
  Original/Reverse), räumt zwischen JEDER Permutation via
  `reset_for_permutation!/0`, sammelt `read_fn.()` pro Permutation. Der
  Aufrufer assertet dann üblicherweise, dass alle Ergebnisse identisch sind
  (Konvergenz unabhängig von der Apply-Reihenfolge).

  War zuvor in `materializer_chronik_convergence_test.exs` (#698) und
  `materializer_session_folds_convergence_test.exs` (#781) fast identisch
  dupliziert — hierher konsolidiert (#766, da dieser PR den Baustein 17×
  wiederverwendet).
  """
  @spec materialize_permutations([map()], (-> term())) :: [term()]
  def materialize_permutations(events, read_fn) do
    perms = [
      events,
      Enum.reverse(events),
      rotate_events(events, 1),
      rotate_events(events, 2),
      rotate_events(events, 3)
    ]

    for perm <- perms do
      reset_for_permutation!()
      Enum.each(perm, &Worker.Materializer.apply_event/1)
      read_fn.()
    end
  end

  defp rotate_events(list, n), do: Enum.drop(list, n) ++ Enum.take(list, n)

  @doc """
  Baut die volle Event-Sequenz für eine Test-Kampagne mit N Sessions × M
  Utterances — ersetzt das pro Test ad-hoc zusammengebaute Setup (Issue #66).

  Reuse von `event/4` für konsistente Envelope-Shape; Event-Reihenfolge folgt
  dem produktiven Pfad (CampaignCreated → AdminMemberAdded* → SessionScheduled →
  SessionStarted → UtteranceAppended* [→ SessionSummaryGenerated]).

  ## Optionen

    - `:campaign_id` (Default `"test-campaign"`)
    - `:name` (Default `"Test Campaign"`)
    - `:owner_did` (Default `"did-owner"`) / `:owner_name` (Default `"Owner"`)
    - `:members` — Liste zusätzlicher Member-`discord_id`s (je ein `AdminMemberAdded`),
      Default `[]`
    - `:sessions` — Integer N (→ N Sessions à `:utterances_per_session`) ODER Liste
      von Utterance-Counts pro Session (z.B. `[10, 30]`). Default `[3]`.
    - `:utterances_per_session` (Default `3`) — nur wenn `:sessions` ein Integer ist
    - `:speakers` — `discord_id`s, aus denen die Utterances round-robin sprechen
      (Default `[owner_did | members]`)
    - `:include_summaries?` — pro Session ein `SessionSummaryGenerated` (Default `false`)
    - `:base_seq` — Start-Sequence-Number (Default `1`)
    - `:apply` — wenn `true`, Events via `Materializer.apply_batch/1` anwenden
      (startet den Materializer idempotent). Default `false` → nur die Event-Maps zurück.

  ## Rückgabe

      %{
        campaign_id: String.t(),
        owner_did: String.t(),
        members: [String.t()],
        sessions: [%{id: String.t(), number: pos_integer(), utterance_ids: [String.t()]}],
        events: [map()]
      }
  """
  @spec build_campaign(keyword()) :: map()
  def build_campaign(opts \\ []) do
    campaign_id = Keyword.get(opts, :campaign_id, "test-campaign")
    name = Keyword.get(opts, :name, "Test Campaign")
    owner_did = Keyword.get(opts, :owner_did, "did-owner")
    owner_name = Keyword.get(opts, :owner_name, "Owner")
    members = Keyword.get(opts, :members, [])
    include_summaries? = Keyword.get(opts, :include_summaries?, false)
    base_seq = Keyword.get(opts, :base_seq, 1)

    session_sizes =
      case Keyword.get(opts, :sessions, [3]) do
        n when is_integer(n) -> List.duplicate(Keyword.get(opts, :utterances_per_session, 3), n)
        list when is_list(list) -> list
      end

    speakers =
      case Keyword.get(opts, :speakers, [owner_did | members]) do
        [] -> [owner_did]
        list -> list
      end

    sessions_meta =
      session_sizes
      |> Enum.with_index(1)
      |> Enum.map(fn {m, n} ->
        sid = "#{campaign_id}-s#{n}"
        utt_ids = for i <- 1..m//1, do: "#{sid}-u#{i}"
        %{id: sid, number: n, utterance_ids: utt_ids}
      end)

    pairs =
      [
        {"CampaignCreated",
         %{
           "id" => campaign_id,
           "name" => name,
           "owner_discord_id" => owner_did,
           "owner_display_name" => owner_name
         }}
      ] ++
        Enum.map(members, fn did ->
          {"AdminMemberAdded",
           %{"campaign_id" => campaign_id, "discord_id" => did, "display_name" => "Member #{did}"}}
        end) ++
        Enum.flat_map(sessions_meta, fn s ->
          scheduled =
            {"SessionScheduled",
             %{
               "id" => s.id,
               "campaign_id" => campaign_id,
               "number" => s.number,
               "name" => "Session #{s.number}",
               "scheduled_for" => "2026-01-01T20:00:00Z"
             }}

          started = {"SessionStarted", %{"id" => s.id, "campaign_id" => campaign_id}}

          utts =
            s.utterance_ids
            |> Enum.with_index(0)
            |> Enum.map(fn {uid, idx} ->
              speaker = Enum.at(speakers, rem(idx, length(speakers)))

              {"UtteranceAppended",
               %{
                 "id" => uid,
                 "campaign_id" => campaign_id,
                 "session_id" => s.id,
                 "discord_id" => speaker,
                 "text" => "Utterance #{idx + 1} in #{s.id}",
                 "confidence" => 1.0,
                 "status" => "confirmed"
               }}
            end)

          summary =
            if include_summaries? do
              [
                {"SessionSummaryGenerated",
                 %{
                   "session_id" => s.id,
                   "campaign_id" => campaign_id,
                   "content_md" => "Resümee #{s.id}",
                   "source" => "llm",
                   "source_refs" => Enum.take(s.utterance_ids, 2)
                 }}
              ]
            else
              []
            end

          [scheduled, started] ++ utts ++ summary
        end)

    events =
      pairs
      |> Enum.with_index(base_seq)
      |> Enum.map(fn {{kind, payload}, seq} ->
        event(kind, payload, seq, event_id: "#{campaign_id}-ev-#{seq}")
      end)

    if Keyword.get(opts, :apply, false) do
      ensure_materializer!()
      Worker.Materializer.apply_batch(events)
    end

    %{
      campaign_id: campaign_id,
      owner_did: owner_did,
      members: members,
      sessions: sessions_meta,
      events: events
    }
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
      S.session_facts(),
      S.chronik_entries(),
      # Issue #801: chronik_clear_marks (ChronikClearedForSession-Watermark) +
      # pipeline_errors fehlten in dieser Liste. Folge: ein Clear-Mark aus einem
      # Vortest überlebte (die Geschwister-Chronik-Tests clearten die Tabelle
      # selbst, der Markdown-Test nicht) und unterdrückte via generation-
      # Watermark fremde Session-Einträge → ordering-abhängiger Flake (#801,
      # gleiche Klasse wie #66). Beide Tabellen halten reinen abgeleiteten State,
      # den kein Test stale sehen will.
      S.chronik_clear_marks(),
      S.pipeline_errors(),
      # Issue #66: bislang ungeräumte Daten-Tabellen ergänzt — ohne sie
      # leaken audio_consents/speaker_assignments/vorgaben/spend zwischen
      # Tests und machen Reads darauf seed-abhängig flaky. worker_state
      # (seq-Cursor) bleibt bewusst draußen.
      S.audio_consents(),
      S.speaker_assignments(),
      S.campaign_vorgaben(),
      # Issue #724: sonst leakt ein Kampagnen-Kalender / Session-Anker zwischen
      # Tests → seed-abhängig flaky (z.B. ein Fantasy-Kalender aus Test A lässt
      # „15. Januar 1888" in Test B nicht mehr parsen → in_game_day nil).
      S.campaign_calendars(),
      S.session_anchors(),
      # Issue #724 Slice F: Review-Queue-Fakt-Overrides — sonst leakt ein
      # Datum/Dismiss aus Test A in Test B über dieselbe fo_key-Kombination
      # (dieselbe #801/#66-Flaky-Klasse: geteilte Overlay-Tabelle, kein Test
      # räumt sie einzeln).
      S.session_fact_overrides(),
      S.llm_spend(),
      S.probelauf_runs(),
      S.probelauf_sweeps(),
      S.applied_event_ids(),
      S.events_global(),
      # Issue #766: I7-Bucket-C-Sidecar — sonst leakt ein Fold-Winner aus
      # Test A in Test B (dieselbe #801/#66-Flaky-Klasse: geteilte Sidecar-
      # Tabelle, kein Test räumt sie einzeln). Reiner Metadaten-State,
      # anders als worker_state (Seq-Cursor) kein Grund draußen zu bleiben.
      S.fold_meta()
    ]
  end
end
