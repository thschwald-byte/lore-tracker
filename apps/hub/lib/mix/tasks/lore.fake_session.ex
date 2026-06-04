defmodule Mix.Tasks.Lore.FakeSession do
  @moduledoc """
  Streams stub utterance events at the running hub for a campaign's active
  session, pretending to be a Discord-bot+Whisper pipeline (which lands
  in M8). Useful for testing the live Protokoll column without real audio.

      # In one shell:
      mix phx.server

      # In another, hit a campaign you've already started a recording for:
      mix lore.fake_session <CAMPAIGN_ID> [--rate=2 --duration=60 --speakers=alice,bob,carol]

  Talks to the hub via HTTP at `POST /dev/event` (dev-only route).
  """

  use Mix.Task

  @shortdoc "Stream fake utterance events at a running hub"

  @hub_base "http://127.0.0.1:4000"
  @sample_sentences [
    "You find a sealed iron chest.",
    "Is it locked? I examine it.",
    "Yes, it's locked, and it looks like there might be a trap.",
    "I cast Detect Magic.",
    "The chest pulses with faint abjuration magic.",
    "I'll try to disarm it. *rolls* …17.",
    "You hear a soft click as the mechanism releases.",
    "Inside: a tarnished amulet and three small vials.",
    "Grizlow steps back, eyeing the vials suspiciously.",
    "What did you just say, DM? Pizza is here."
  ]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [rate: :integer, duration: :integer, speakers: :string],
        aliases: [r: :rate, d: :duration, s: :speakers]
      )

    case positional do
      [campaign_id] ->
        run_loop(campaign_id, opts)

      _ ->
        Mix.raise(
          "usage: mix lore.fake_session <CAMPAIGN_ID> [--rate=N --duration=N --speakers=a,b]"
        )
    end
  end

  defp run_loop(campaign_id, opts) do
    rate = opts[:rate] || 2
    duration = opts[:duration] || 30

    speakers =
      (opts[:speakers] || "alice,bob,carol")
      |> String.split(",", trim: true)

    total = rate * duration
    interval_ms = div(1_000, max(rate, 1))

    # Discover the active session via /dev/session_for endpoint? We don't
    # have that. Instead, just send utterances tagged with a session_id
    # the user has to look up. Simpler: accept the campaign's currently-
    # recording session_id from /dev/active_session, fall back to error.
    case fetch_active_session(campaign_id) do
      {:ok, session_id} ->
        Mix.shell().info(
          "Streaming #{total} utterances over #{duration}s at #{rate}/s into session #{session_id}"
        )

        Enum.reduce(1..total, [], fn i, acc ->
          speaker = Enum.at(speakers, rem(i - 1, length(speakers)))
          text = Enum.at(@sample_sentences, rem(i - 1, length(@sample_sentences)))

          payload = %{
            "kind" => Shared.Events.utterance_appended(),
            "id" => uuidv7(),
            "session_id" => session_id,
            "discord_id" => speaker,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "text" => text,
            # Issue #376: einheitliches Map-Format (vorher Float 0.9).
            "confidence" => %{"mean_p" => 0.9, "min_p" => 0.9},
            "status" => "confirmed"
          }

          case post_event(payload) do
            {:ok, seq} -> [seq | acc]
            {:error, reason} -> Mix.raise("post_event failed: #{inspect(reason)}")
          end

          Process.sleep(interval_ms)
        end)

        Mix.shell().info("done")

      {:error, reason} ->
        Mix.raise("could not find active session for campaign #{campaign_id}: #{inspect(reason)}")
    end
  end

  # ─── HTTP plumbing ────────────────────────────────────────────────

  defp post_event(payload) do
    body = Jason.encode!(%{"payload" => payload})
    url = ~c"#{@hub_base}/dev/event"
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"seq" => seq}} -> {:ok, seq}
          other -> {:error, {:bad_response, other}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_active_session(campaign_id) do
    # Stub: the dev intent endpoint is fire-and-forget; for now require the
    # user to have started a session via the UI before running this task,
    # and look up the session id via /dev/active_session/<campaign_id>.
    url = ~c"#{@hub_base}/dev/active_session/#{campaign_id}"

    case :httpc.request(:get, {url, []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"session_id" => sid}} when is_binary(sid) -> {:ok, sid}
          {:ok, %{"error" => err}} -> {:error, err}
          other -> {:error, {:bad_response, other}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uuidv7 do
    # Pseudo-UUID — sufficient for stub utterances; M8's real Whisper
    # pipeline will use the proper Worker.Intents UUIDv7 generator.
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
