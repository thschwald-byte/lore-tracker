defmodule Worker.Intents do
  @moduledoc """
  Worker-Side Event-Publisher mit Worker-First-Apply (Issue #123, Etappe 2).

  Jeder Aufruf:
  1. Generiert `event_id` (UUIDv7) wenn keiner im Payload ist
  2. Appliest den Event **lokal sofort** via `Worker.Materializer.apply_local/1`
     — Owner-Worker sieht den Output unabhängig vom Hub
  3. Sendet den Event zum Hub via `Worker.HubClient.publish/1` (best-effort)

  Returns:
  - `{:ok, seq}` wenn Hub-Sync erfolgreich
  - `{:ok, :pending}` wenn Hub-Sync gescheitert (Event ist lokal sichtbar,
    aber andere Worker sehen ihn erst nach Etappe-3-Sync)

  Aufrufer matchen nicht hart auf `{:ok, _seq}` — Etappe 1 hat den Crash-Schutz
  schon eingebaut, alle Stage-Publishes laufen über `Pipeline.publish_event/1`
  oder ähnliche Wrapper.
  """

  require Logger

  # Issue #430: gibt IMMER {:ok, …} zurück — Hub-Sync-Fehler werden zu
  # {:ok, :pending} (local-apply ist schon passiert, Issue #215), local-apply
  # selbst ist `:ok =`-asserted. Kein {:error}-Pfad (war toter Branch bei Callern).
  @spec publish(map()) :: {:ok, pos_integer() | :pending}
  def publish(payload) when is_map(payload) do
    event_id = Map.get(payload, "event_id") || UUIDv7.generate()

    local_event = %{
      "event_id" => event_id,
      "payload" => payload,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "author_worker_id" => Worker.Repo.get_state(:worker_id)
    }

    :ok = Worker.Materializer.apply_local(local_event)

    case Worker.HubClient.publish(event_id, payload) do
      {:ok, seq} ->
        {:ok, seq}

      {:error, reason} ->
        # Issue #475: :pending zählbar machen (sonst unbeobachtbar). Laufende
        # Summe in worker_state + im Log, damit ein länger down-er Hub sichtbar wird.
        pending_total = Worker.Repo.bump_pending_publish_count()

        Logger.warning(
          "Intents.publish: Hub-Sync failed (kind=#{payload["kind"]} event_id=#{event_id}, " <>
            "pending_total=#{pending_total}): " <> inspect(reason)
        )

        {:ok, :pending}
    end
  end

  # Issue #702: Chunk-Größe pro publish_intent_batch-Frame (Hub-Gate: 100)
  # + Pause zwischen Chunks, damit Hub-PubSub/LV-Diffing zwischen den Frames
  # drainen kann (600er-Backlog ≈ 24 Frames über ~1,2 s statt 600 Frames).
  #
  # #717-Klarstellung: `Worker.Intents` ist KEIN GenServer — publish_batch/1
  # (und damit der Chunk-Sleep unten) läuft im CALLER-Prozess (typisch der
  # Transcribe-Task nach Session-Ende). Der Sleep ist bewusstes Pacing eines
  # Hintergrund-Tasks und blockiert keinen zentralen Prozess; die Codebase-
  # Review 2026-07-07 hatte das fälschlich als GenServer-Blocking geflaggt.
  @batch_chunk_size 25
  @chunk_pause_ms 50

  @doc """
  Gebatchter Publish für Event-Schwälle (Issue #702) — primär den Whisper-
  Transkriptions-Backlog nach Session-Ende, der als Einzel-Publishes den Hub
  in den OOM getrieben hat (ein Broadcast + ein LV-Diff pro Event).

  Semantik:
  1. **Local-first**: JEDES Payload wird einzeln + sofort via
     `Materializer.apply_local/1` in den lokalen Event-Store geschrieben
     (eigene event_id, unverändertes Store-Format — Sync/Wasserlinien/#693
     unberührt). Datensicherheit hängt nie am Hub.
  2. Hub-Sync in #{@batch_chunk_size}er-Chunks als `publish_intent_batch`-
     Frames. Alter Hub (kein caps-Announce) → einmalig geloggter Fallback
     auf Einzel-Publishes. Chunk-Fehler werden geloggt + gezählt, die
     restlichen Chunks laufen weiter (#693-Pull heilt Peers ohnehin).

  Returns `{:ok, %{synced: s, pending: p}}` — `pending` zählt Events, die
  den Hub nicht (oder als rejected) erreicht haben; nie ein Error für
  Hub-Gründe (Muster `publish/1`).
  """
  @spec publish_batch([map()]) :: {:ok, %{synced: non_neg_integer(), pending: non_neg_integer()}}
  def publish_batch([]), do: {:ok, %{synced: 0, pending: 0}}

  def publish_batch(payloads) when is_list(payloads) do
    worker_id = Worker.Repo.get_state(:worker_id)

    local =
      Enum.map(payloads, fn payload ->
        event_id = Map.get(payload, "event_id") || UUIDv7.generate()

        :ok =
          Worker.Materializer.apply_local(%{
            "event_id" => event_id,
            "payload" => payload,
            "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "author_worker_id" => worker_id
          })

        %{event_id: event_id, payload: payload}
      end)

    sync_chunks(chunk_events(local), %{synced: 0, pending: 0})
  end

  # Pur + einzeln testbar: Chunking in Publish-Frames.
  @doc false
  @spec chunk_events([map()], pos_integer()) :: [[map()]]
  def chunk_events(events, size \\ @batch_chunk_size), do: Enum.chunk_every(events, size)

  defp sync_chunks([], acc), do: {:ok, acc}

  defp sync_chunks([chunk | rest], acc) do
    case Worker.HubClient.publish_batch(chunk) do
      {:ok, reply} ->
        rejected = Map.get(reply, "rejected", 0)

        if rejected > 0 do
          # Trust-Boundary-Drop am Hub (#473) — kein "pending sync", sondern
          # ein lauter Verwurf; der Hub hat die Gründe bereits geloggt.
          Logger.warning(
            "Intents.publish_batch: Hub hat #{rejected}/#{length(chunk)} Events verworfen " <>
              "(erster kind=#{first_kind(chunk)}) — siehe Hub-Log (Trust-Boundary #473)."
          )
        end

        acc = %{
          acc
          | synced: acc.synced + length(chunk) - rejected,
            pending: acc.pending + rejected
        }

        unless rest == [], do: Process.sleep(@chunk_pause_ms)
        sync_chunks(rest, acc)

      {:error, :batch_unsupported} ->
        # Alter Hub ohne publish_intent_batch-Cap: EINMAL loggen, dann alle
        # restlichen Events einzeln pushen. NICHT publish/1 — apply_local ist
        # für alle Events schon passiert.
        remaining = Enum.concat([chunk | rest])

        Logger.info(
          "Intents.publish_batch: Hub kennt publish_intent_batch nicht (alter Hub) — " <>
            "Fallback auf #{length(remaining)} Einzel-Publishes"
        )

        Enum.reduce(remaining, {:ok, acc}, fn %{event_id: id, payload: payload}, {:ok, a} ->
          case Worker.HubClient.publish(id, payload) do
            {:ok, _seq} ->
              {:ok, %{a | synced: a.synced + 1}}

            {:error, reason} ->
              pending_total = Worker.Repo.bump_pending_publish_count()

              Logger.warning(
                "Intents.publish_batch: Einzel-Fallback-Sync failed (kind=#{payload["kind"]} " <>
                  "event_id=#{id}, pending_total=#{pending_total}): " <> inspect(reason)
              )

              {:ok, %{a | pending: a.pending + 1}}
          end
        end)

      {:error, reason} ->
        # Transienter Fehler (Timeout, Disconnect): Chunk als pending zählen,
        # aber mit den restlichen Chunks WEITERMACHEN — ein Timeout auf Chunk 3
        # darf 4..n nicht droppen.
        pending_total = Worker.Repo.bump_pending_publish_count(length(chunk))

        Logger.warning(
          "Intents.publish_batch: Hub-Sync für Chunk (#{length(chunk)} Events, " <>
            "erster kind=#{first_kind(chunk)}) failed (pending_total=#{pending_total}): " <>
            inspect(reason)
        )

        acc = %{acc | pending: acc.pending + length(chunk)}
        unless rest == [], do: Process.sleep(@chunk_pause_ms)
        sync_chunks(rest, acc)
    end
  end

  defp first_kind([%{payload: payload} | _]), do: payload["kind"]
  defp first_kind(_), do: nil
end
