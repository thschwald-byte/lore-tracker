defmodule Mix.Tasks.Lore.Seed.Romeo do
  @moduledoc """
  Seeds the "Romeo & Julia" demo campaign into a running local hub.

      # In one shell, start the hub:
      cd apps/hub && mix phx.server

      # In another shell, start the worker (needed for materializer):
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Then seed:
      mix lore.seed.romeo                      # seed into http://127.0.0.1:4000
      mix lore.seed.romeo --hub http://127.0.0.1:4001
      mix lore.seed.romeo --reset              # wipe the romeo campaign first, then re-seed

  The task reads every `*.jsonl` file in `apps/hub/priv/seeds/romeo/` in
  lexicographic order and POSTs each event to the hub's dev-only
  `/dev/event` endpoint. The materializer (running in the worker BEAM)
  picks the events up via PubSub and writes them into the worker_*
  Mnesia tables.

  Refuses to run in `MIX_ENV=prod` and only ever touches the campaign
  with id `romeo-julia-demo` (fixed string, easy to spot and delete).

  See issue #58 for scope, #78 for the follow-up that adds
  `--as-admin <id>`.
  """

  use Mix.Task

  @shortdoc "Seed the Romeo & Julia demo campaign into a running local hub"

  @hub_base "http://127.0.0.1:4000"
  @campaign_id "romeo-julia-demo"
  @seeds_subpath "priv/seeds/romeo"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise(
        "lore.seed.romeo refuses to run in MIX_ENV=prod — Romeo demo data must never reach production."
      )
    end

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    {opts, _positional, _} =
      OptionParser.parse(args,
        switches: [reset: :boolean, hub: :string],
        aliases: [r: :reset, h: :hub]
      )

    hub_base = opts[:hub] || @hub_base
    reset? = opts[:reset] || false

    Mix.shell().info("Target hub: #{hub_base}")
    Mix.shell().info("Campaign:   #{@campaign_id}")

    if reset? do
      Mix.shell().info("Reset:      yes (sending CampaignDeleted first)")
      send_reset(hub_base)
    end

    files = seed_files()

    if files == [] do
      Mix.raise("no seed files found under #{seeds_dir()}")
    end

    Mix.shell().info("Applying #{length(files)} seed file(s):")

    {events, _} =
      Enum.reduce(files, {0, 0}, fn path, {total, _} ->
        count = apply_file(hub_base, path)
        Mix.shell().info("  #{Path.basename(path)} — #{count} events")
        {total + count, count}
      end)

    Mix.shell().info("Done — #{events} events appended.")
  end

  # ─── seed application ─────────────────────────────────────────────

  defp seed_files do
    seeds_dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp seeds_dir do
    # The task lives in apps/hub/lib/mix/tasks/, the seeds in
    # apps/hub/priv/seeds/romeo/. Use Application.app_dir if compiled
    # into an archive, but for repo-local mix invocation File.cwd! +
    # the known sub-path is the simpler path.
    cwd = File.cwd!()

    cond do
      File.dir?(Path.join(cwd, "apps/hub/#{@seeds_subpath}")) ->
        Path.join(cwd, "apps/hub/#{@seeds_subpath}")

      File.dir?(Path.join(cwd, @seeds_subpath)) ->
        Path.join(cwd, @seeds_subpath)

      true ->
        Mix.raise(
          "could not locate seed directory. Expected apps/hub/#{@seeds_subpath} or #{@seeds_subpath} relative to #{cwd}."
        )
    end
  end

  defp apply_file(hub_base, path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.reject(&String.starts_with?(&1, "#"))
    |> Stream.map(&decode_line!(&1, path))
    |> Enum.reduce(0, fn payload, n ->
      case post_event(hub_base, payload) do
        {:ok, _seq} ->
          n + 1

        {:error, reason} ->
          Mix.raise(
            "POST /dev/event failed for event #{inspect(payload["kind"])} in #{Path.basename(path)}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp decode_line!(line, path) do
    case Jason.decode(line) do
      {:ok, %{"kind" => _} = payload} ->
        payload

      {:ok, other} ->
        Mix.raise("malformed seed line in #{path} (missing \"kind\"): #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("invalid JSON in #{path}: #{Exception.message(reason)}\nLine: #{line}")
    end
  end

  defp send_reset(hub_base) do
    payload = %{
      "kind" => "CampaignDeleted",
      "campaign_id" => @campaign_id,
      "deleted_by" => "cli:lore.seed.romeo"
    }

    case post_event(hub_base, payload) do
      {:ok, _seq} -> :ok
      {:error, reason} -> Mix.raise("CampaignDeleted POST failed: #{inspect(reason)}")
    end
  end

  # ─── HTTP plumbing (mirrors lore.fake_session) ────────────────────

  defp post_event(hub_base, payload) do
    body = Jason.encode!(%{"payload" => payload})
    url = String.to_charlist("#{hub_base}/dev/event")
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
end
