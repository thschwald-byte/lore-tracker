defmodule Mix.Tasks.Lore.Seed.Romeo do
  @moduledoc """
  Seeds the "Romeo & Julia" demo campaign into a running local hub.

      # In one shell, start the hub:
      cd apps/hub && mix phx.server

      # In another shell, start the worker (needed for materializer):
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Then seed:
      mix lore.seed.romeo                              # default: dummy "Erzähler" als Owner
      mix lore.seed.romeo --hub http://127.0.0.1:4001  # PR-Test-Hub
      mix lore.seed.romeo --reset                      # erst CampaignDeleted, dann re-seed

  ## Caller-as-Admin (Issue #78)

  Per default ist der campaign-Owner der Dummy-User „Erzähler"
  (Discord-ID 100000000000000001). Damit der eigene Discord-Account
  die Kampagne im Dashboard sieht und bearbeiten kann, muss er als
  Owner eingetragen werden:

      mix lore.seed.romeo --as-admin <discord-id>
      mix lore.seed.romeo --as-admin <discord-id> --display-name "Tom"
      mix lore.seed.romeo --as-admin <discord-id> --mode protocol-only

  Was `--as-admin` macht:
  - User-Upsert + Rolle `:admin` für den Caller (idempotent).
  - Im `CampaignCreated`-Event wird `owner_discord_id` / `owner_display_name`
    auf den Caller umgeschrieben — der Materializer trägt ihn dann
    automatisch als Owner-Member ein.
  - Der Dummy-Erzähler bleibt als User in der DB, ist aber nicht mehr
    Member der Romeo-Kampagne.

  ## Modes

  - `--mode full` (default) — Resümees / Epos / Chronik aus den Seeds
    werden mit appliziert. Klick-fertige Demo.
  - `--mode protocol-only` — überspringt die LLM-Output-Events
    (`SessionSummaryGenerated`, `EposEntryEdited`, `ChronikEntryChanged`).
    Use Case: LLM-Lasttest mit echten Inputs (Pipeline triggert sich
    nach Seed selbst), Probelauf (#74).

  ## Safety

  Refuses to run in `MIX_ENV=prod`. Touches only the campaign with id
  `romeo-julia-demo` (fixed string). `--reset` löscht die Kampagne und
  re-seedet — der Caller-User bleibt erhalten (sonst sperrt man sich
  selber aus).
  """

  use Mix.Task

  @shortdoc "Seed the Romeo & Julia demo campaign into a running local hub"

  @hub_base "http://127.0.0.1:4000"
  @campaign_id "romeo-julia-demo"
  @seeds_subpath "priv/seeds/romeo"

  @llm_output_kinds ~w(SessionSummaryGenerated EposEntryEdited ChronikEntryChanged)

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
        "full" ->
          :full

        "protocol-only" ->
          :protocol_only

        other ->
          Mix.raise(
            "invalid --mode #{inspect(other)} — expected \"full\" or \"protocol-only\""
          )
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
        {applied, file_skipped} = apply_file(hub_base, path, as_admin, display_name, mode)
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
      "set_by" => "cli:lore.seed.romeo --as-admin"
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
  # Public for test reach. Drops LLM-output events in protocol-only mode.
  def skip_for_mode?(%{"kind" => kind}, :protocol_only), do: kind in @llm_output_kinds
  def skip_for_mode?(_, _), do: false

  @doc false
  # Public for test reach. When --as-admin is set, replace the
  # CampaignCreated event's owner fields so the materializer adds the
  # caller as the owner-member. The dummy "Erzähler" still gets
  # UserUpserted/UserRoleSet events later in the seed; that's harmless
  # (he exists as a user, just isn't a member of this campaign).
  def transform_for_caller(payload, nil, _display_name), do: payload

  def transform_for_caller(
        %{"kind" => "CampaignCreated", "id" => @campaign_id} = payload,
        discord_id,
        display_name
      ) do
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
      "deleted_by" => "cli:lore.seed.romeo"
    })
  end

  defp post_or_raise!(hub_base, payload) do
    case post_event(hub_base, payload) do
      {:ok, _seq} -> :ok
      {:error, reason} -> Mix.raise("#{payload["kind"]} POST failed: #{inspect(reason)}")
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
