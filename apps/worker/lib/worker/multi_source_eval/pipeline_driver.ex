defmodule Worker.MultiSourceEval.PipelineDriver do
  @moduledoc """
  End-to-End-Driver für Multi-Source-Pipeline-Eval (Issue #377 Plan v5 Section E).

  Worker-only — Hub umgangen. Voraussetzung: laufende Worker-OTP-Children
  (`Phoenix.PubSub`, `Task.Supervisor` `Worker.TaskSupervisor`,
  `Worker.GpuQueue`, `Worker.Materializer`, `Worker.Recording.AudioBuffer`).
  Stage 2-4 (`Worker.Recording.Pipeline`) ist explizit NICHT nötig —
  `UtterancesTranscribed` firet nach Stage 1 unabhängig.

  Schritte:
    1. PubSub-subscribe auf den Materializer-Topic (vor allem anderen — vermeidet Race)
    2. CampaignCreated + AdminMemberAdded(pro Sprecher) + SessionScheduled + SessionStarted
       lokal publishen
    3. AudioBuilder → WebM/Opus pro Sprecher
    4. AudioBuffer.open_session → append pro Sprecher → finalize
    5. Wait auf `{:applied, %{"payload" => %{"kind" => "UtterancesTranscribed", ...}}}`
    6. Return `Worker.Repo.list_utterances(session_id)`
  """

  alias Shared.Events
  alias Worker.{Intents, Materializer, Recording.AudioBuffer, Repo}
  alias Worker.MultiSourceEval.AudioBuilder

  # Issue #571: Modul-Attribut für event-kind-Pattern-Match (Iron-Law #8 — kein
  # Remote-Call im Match-Head).
  @utterances_transcribed_kind Events.utterances_transcribed()

  @default_timeout_ms 5 * 60_000

  @doc """
  Fährt eine Session durch die volle Stage-1-Pipeline und gibt die produzierten
  Utterances zurück.

  Optionen:
    * `:fixtures_root` — Pfad zum `faust/`-Verzeichnis. Default: relativ zum Modul.
    * `:timeout_ms` — Maximal-Wartezeit auf `UtterancesTranscribed`. Default 5 min.
    * `:campaign_id` / `:session_id` — explizite IDs (Default: UUIDv7).
  """
  @spec run(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(session, variant, opts \\ []) when is_map(session) and is_binary(variant) do
    fixtures_root = Keyword.get(opts, :fixtures_root, default_fixtures_root())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    campaign_id = Keyword.get(opts, :campaign_id, "eval-cid-" <> short_uuid())
    session_id = Keyword.get(opts, :session_id, UUIDv7.generate())

    :ok = Phoenix.PubSub.subscribe(Worker.PubSub, Materializer.topic())

    try do
      with {:ok, tracks} <- AudioBuilder.build_for_session(session, variant, fixtures_root),
           :ok <- setup_campaign_and_session(campaign_id, session_id, session),
           :ok <- AudioBuffer.open_session(session_id, campaign_id, :default),
           :ok <- send_chunks(session_id, tracks),
           :ok <- finalize_session(session_id),
           :ok <- await_transcribed(session_id, timeout_ms) do
        {:ok,
         %{
           session_id: session_id,
           campaign_id: campaign_id,
           variant: variant,
           tracks: tracks,
           utterances: Repo.list_utterances(session_id)
         }}
      end
    after
      Phoenix.PubSub.unsubscribe(Worker.PubSub, Materializer.topic())
    end
  end

  @doc "Default `faust/`-Fixtures-Root: relativ zu diesem Modul (apps/worker/test/fixtures/stt/faust)."
  def default_fixtures_root do
    Path.expand("../../../test/fixtures/stt/faust", __DIR__)
  end

  # ─── Internals ──────────────────────────────────────────────────────

  defp setup_campaign_and_session(campaign_id, session_id, session) do
    speakers = Map.fetch!(session, "speakers")
    [{owner_name, owner_did} | _] = Enum.to_list(speakers)

    publish!(%{
      "kind" => Shared.Events.campaign_created(),
      "id" => campaign_id,
      "name" => "eval-" <> Map.fetch!(session, "name"),
      "owner_discord_id" => owner_did,
      "owner_display_name" => owner_name
    })

    Enum.each(speakers, fn {speaker_name, discord_id} ->
      publish!(%{
        "kind" => Shared.Events.admin_member_added(),
        "campaign_id" => campaign_id,
        "discord_id" => discord_id,
        "display_name" => speaker_name
      })
    end)

    publish!(%{
      "kind" => Shared.Events.session_scheduled(),
      "id" => session_id,
      "campaign_id" => campaign_id,
      "number" => 1,
      "name" => Map.fetch!(session, "name"),
      "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    publish!(%{
      "kind" => Shared.Events.session_started(),
      "id" => session_id,
      "campaign_id" => campaign_id
    })

    :ok
  end

  defp publish!(payload) do
    case Intents.publish(payload) do
      {:ok, _seq_or_pending} -> :ok
      err -> raise "Intents.publish failed: #{inspect(err)}"
    end
  end

  defp send_chunks(session_id, tracks) do
    Enum.each(tracks, fn %{discord_id: did, audio_b64: b64} ->
      AudioBuffer.append(session_id, did, b64)
    end)

    :ok
  end

  defp finalize_session(session_id) do
    AudioBuffer.finalize(session_id)
    :ok
  end

  defp await_transcribed(session_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(session_id, deadline)
  end

  defp do_await(session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:applied,
         %{"payload" => %{"kind" => @utterances_transcribed_kind, "session_id" => ^session_id}}} ->
          :ok

        _other ->
          do_await(session_id, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp short_uuid do
    UUIDv7.generate()
    |> binary_part(0, 8)
  end
end
