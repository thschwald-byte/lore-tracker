defmodule Mix.Tasks.Lore.Seed.VoxMachina do
  @moduledoc """
  Seeds a Vox Machina demo campaign (Critical Role Campaign 1, Kraghammer arc)
  into a running local hub.

      # In one shell, start the hub:
      cd apps/hub && mix phx.server

      # In another shell, start the worker (needed for materializer):
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Then seed:
      mix lore.seed.vox_machina                             # default
      mix lore.seed.vox_machina --hub http://127.0.0.1:4001 # PR-Test-Hub
      mix lore.seed.vox_machina --reset                     # erst CampaignDeleted, dann re-seed
      mix lore.seed.vox_machina --mode protocol-only        # ohne LLM-Output-Events
      mix lore.seed.vox_machina --as-admin <discord-id> --display-name ".carnivor"

  ## Inhalt

  Drei Sessions aus dem Kraghammer-Bogen (frei nach Critical Role Kampagne 1):

  | Session | Titel                        |
  |---------|------------------------------|
  | Ep 1    | Arrival at Kraghammer        |
  | Ep 2    | Into the Mines               |
  | Ep 3    | The Corruption Below         |

  Campaign-ID: `vox-machina-demo`
  Spieler: 7 Dummy-User (Travis/Laura/Marisha/Taliesin/Liam/Ashley/Sam)
  DM-Zeilen: `--as-admin`-Discord-ID (default: Dummy 100000000000000011)

  ## Modes

  - `--mode full` (default) — alle Events inkl. Resümees / Epos / Chronik
  - `--mode protocol-only` — überspringt `SessionSummaryGenerated`, `EposEntryEdited`,
    `ChronikEntryChanged`. Für LLM-Pipeline-Tests.

  ## Safety

  Refuses to run in `MIX_ENV=prod`. Berührt nur Campaign `vox-machina-demo`.
  Für Prod: `scripts/seed_vox_machina_prod.exs` via RPC-Bridge nutzen.
  """

  use Mix.Task

  @shortdoc "Seed the Vox Machina demo campaign into a running local hub"

  @hub_base "http://127.0.0.1:4000"
  @seeds_subpath "priv/seeds/vox-machina"
  @campaign_id "vox-machina-demo"

  @llm_output_kinds ~w(SessionSummaryGenerated EposEntryEdited ChronikEntryChanged)

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise(
        "lore.seed.vox_machina refuses to run in MIX_ENV=prod — use scripts/seed_vox_machina_prod.exs via RPC-Bridge instead."
      )
    end

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    {opts, _positional, _} =
      OptionParser.parse(args,
        switches: [
          reset: :boolean,
          hub: :string,
          as_admin: :string,
          display_name: :string,
          mode: :string
        ],
        aliases: [r: :reset, h: :hub]
      )

    hub_base = opts[:hub] || @hub_base
    reset? = opts[:reset] || false
    as_admin = opts[:as_admin]
    display_name = opts[:display_name] || "Admin"

    mode =
      case opts[:mode] || "full" do
        "full" -> :full
        "protocol-only" -> :protocol_only
        other -> Mix.raise("invalid --mode #{inspect(other)} — expected \"full\" or \"protocol-only\"")
      end

    Mix.shell().info("Target hub: #{hub_base}")
    Mix.shell().info("Campaign:   #{@campaign_id}")
    Mix.shell().info("Mode:       #{mode}")

    if as_admin do
      Mix.shell().info("As admin:   #{as_admin} (\"#{display_name}\")")
    end

    if reset? do
      Mix.shell().info("Reset:      yes (sending CampaignDeleted first)")
      send_reset(hub_base)
    end

    if as_admin do
      send_caller_bootstrap(hub_base, as_admin, display_name)
    end

    files = seed_files()

    if files == [] do
      Mix.raise("no seed files found under #{seeds_dir()}")
    end

    Mix.shell().info("Applying #{length(files)} seed file(s):")

    {total, skipped} =
      Enum.reduce(files, {0, 0}, fn path, {total, skipped} ->
        {applied, file_skipped} =
          apply_file(hub_base, path, as_admin, display_name, mode)

        Mix.shell().info("  #{Path.basename(path)} — #{applied} events (skipped #{file_skipped})")
        {total + applied, skipped + file_skipped}
      end)

    if mode == :protocol_only do
      Mix.shell().info("Done — #{total} events appended, #{skipped} LLM-output events skipped.")
    else
      Mix.shell().info("Done — #{total} events appended.")
    end
  end

  # ─── caller bootstrap (--as-admin) ────────────────────────────────

  defp send_caller_bootstrap(hub_base, discord_id, display_name) do
    post_or_raise!(hub_base, %{
      "kind" => "UserUpserted",
      "discord_id" => discord_id,
      "display_name" => display_name,
      "avatar_url" => nil
    })

    post_or_raise!(hub_base, %{
      "kind" => "UserRoleSet",
      "discord_id" => discord_id,
      "role" => "admin",
      "set_by" => "cli:lore.seed.vox_machina --as-admin"
    })

    :ok
  end

  # ─── seed application ─────────────────────────────────────────────

  defp seed_files do
    seeds_dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp seeds_dir do
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

  defp apply_file(hub_base, path, as_admin, display_name, mode) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.reject(&String.starts_with?(&1, "#"))
    |> Stream.map(&decode_line!(&1, path))
    |> Enum.reduce({0, 0}, fn payload, {applied, skipped} ->
      cond do
        skip_for_mode?(payload, mode) ->
          {applied, skipped + 1}

        true ->
          transformed = transform_for_caller(payload, as_admin, display_name)

          case post_event(hub_base, transformed) do
            {:ok, _seq} ->
              {applied + 1, skipped}

            {:error, reason} ->
              Mix.raise(
                "POST /dev/event failed for event #{inspect(payload["kind"])} in #{Path.basename(path)}: #{inspect(reason)}"
              )
          end
      end
    end)
  end

  @doc false
  def skip_for_mode?(%{"kind" => kind}, :protocol_only), do: kind in @llm_output_kinds
  def skip_for_mode?(_, _), do: false

  @doc false
  def transform_for_caller(payload, nil, _display_name), do: payload

  def transform_for_caller(
        %{"kind" => "CampaignCreated", "id" => @campaign_id} = payload,
        discord_id,
        display_name
      )
      when is_binary(discord_id) do
    payload
    |> Map.put("owner_discord_id", discord_id)
    |> Map.put("owner_display_name", display_name)
  end

  def transform_for_caller(payload, _discord_id, _display_name), do: payload

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
    post_or_raise!(hub_base, %{
      "kind" => "CampaignDeleted",
      "campaign_id" => @campaign_id,
      "deleted_by" => "cli:lore.seed.vox_machina"
    })
  end

  defp post_or_raise!(hub_base, payload) do
    case post_event(hub_base, payload) do
      {:ok, _seq} -> :ok
      {:error, reason} -> Mix.raise("#{payload["kind"]} POST failed: #{inspect(reason)}")
    end
  end

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
