defmodule Mix.Tasks.Lore.Seed.Skandal do
  @moduledoc """
  Seeds das „Ein Skandal in Böhmen"-Fidelity-Testset in einen laufenden Hub.

  Quelle gemeinfrei: Arthur Conan Doyle, „A Scandal in Bohemia" (1891; Doyle
  † 1930, global PD). Gespielt als Call-of-Cthulhu / BRP / Gaslight, mythos-frei
  (viktorianisches London 1888). Die Dialoge in den Seed-Files sind eigene
  deutschsprachige Tisch-Kompositionen, die den PD-Plot **abbilden, nicht
  dazudichten** — siehe `apps/hub/priv/seeds/skandal-boehmen/README.md`.

  Anders als Romeo/Musketiere ist dies kein Klick-Demo, sondern ein
  **Treue-Testset** für Stage 2 (Resümee): Regel-Noise-Filterung + Attribution
  der SL-gesprochenen NPCs aus dem Kontext. Gold-Resümee + Fact-Key liegen im
  Seed-Verzeichnis (`reference-summary.md`, `fact-key.json`).

      # Hub + Worker müssen laufen (Worker für Materializer-Apply!):
      cd apps/hub && mix phx.server
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Dann seeden:
      mix lore.seed.skandal                              # gegen http://127.0.0.1:4000
      mix lore.seed.skandal --hub http://localhost:4001  # Teststage-Hub
      mix lore.seed.skandal --reset                      # erst CampaignDeleted, dann re-seed
      mix lore.seed.skandal --as-admin <discord-id>      # Caller als Owner+Admin

  ## Caller-as-Admin (Issue #78)

  Per default ist der Owner der Dummy-„Spielleiter". Damit der eigene
  Discord-Account die Kampagne im Dashboard sieht und bedienen kann:

      mix lore.seed.skandal --as-admin <discord-id> --display-name "Tom"

  ## Safety

  Refuses to run in `MIX_ENV=prod`. Berührt nur die Campaign-ID
  `skandal-boehmen-demo` — kollidiert nicht mit echten Daten oder anderen
  Demo-Seeds (Romeo: `romeo-julia-*`, Musketiere: `drei-musketiere-demo`).
  `--reset` löscht die Kampagne und re-seedet.
  """

  use Mix.Task

  @shortdoc "Seed das Skandal-in-Böhmen-Fidelity-Testset in einen Hub"

  @hub_base "http://127.0.0.1:4000"
  @seeds_subpath "priv/seeds/skandal-boehmen"
  @campaign_id "skandal-boehmen-demo"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise(
        "lore.seed.skandal refuses to run in MIX_ENV=prod — Demo-/Test-Daten dürfen niemals auf Produktion landen."
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
          display_name: :string
        ],
        aliases: [r: :reset, h: :hub]
      )

    hub_base = opts[:hub] || @hub_base
    reset? = opts[:reset] || false
    as_admin = opts[:as_admin]
    display_name = opts[:display_name] || "Admin"

    Mix.shell().info("Target hub: #{hub_base}")
    Mix.shell().info("Campaign:   #{@campaign_id}")

    if as_admin do
      Mix.shell().info("As admin:   #{as_admin} (\"#{display_name}\")")
    end

    if reset? do
      Mix.shell().info("Reset:      yes (sending CampaignDeleted first)")
      send_reset(hub_base, @campaign_id)
    end

    if as_admin do
      send_caller_bootstrap(hub_base, as_admin, display_name)
    end

    files = seed_files()

    if files == [] do
      Mix.raise("no seed files found under #{seeds_dir()} — generator.exs schon gelaufen?")
    end

    Mix.shell().info("Applying #{length(files)} seed file(s):")

    total =
      Enum.reduce(files, 0, fn path, total ->
        applied = apply_file(hub_base, path, @campaign_id, as_admin, display_name)
        Mix.shell().info("  #{Path.basename(path)} — #{applied} events")
        total + applied
      end)

    Mix.shell().info("Done — #{total} events appended.")
  end

  defp send_caller_bootstrap(hub_base, discord_id, display_name) do
    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.user_upserted(),
      "discord_id" => discord_id,
      "display_name" => display_name,
      "avatar_url" => nil
    })

    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.user_role_set(),
      "discord_id" => discord_id,
      "role" => "admin",
      "set_by" => "cli:lore.seed.skandal --as-admin"
    })

    :ok
  end

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

  defp apply_file(hub_base, path, campaign_id, as_admin, display_name) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.reject(&String.starts_with?(&1, "#"))
    |> Stream.map(&decode_line!(&1, path))
    |> Enum.reduce(0, fn payload, applied ->
      transformed = transform_for_caller(payload, campaign_id, as_admin, display_name)

      case post_event(hub_base, transformed) do
        {:ok, _seq} ->
          applied + 1

        {:error, reason} ->
          Mix.raise(
            "POST /dev/event failed for event #{inspect(payload["kind"])} in #{Path.basename(path)}: #{inspect(reason)}"
          )
      end
    end)
  end

  @doc false
  def transform_for_caller(payload, _campaign_id, nil, _display_name), do: payload

  # Issue #571 / #644: Pattern-Match-Head ohne Remote-Call (Iron-Law #8).
  def transform_for_caller(
        # credo:disable-for-next-line LoreTracker.Credo.Check.HardcodedEventKind
        %{"kind" => "CampaignCreated", "id" => campaign_id} = payload,
        campaign_id,
        discord_id,
        display_name
      )
      when is_binary(discord_id) do
    payload
    |> Map.put("owner_discord_id", discord_id)
    |> Map.put("owner_display_name", display_name)
  end

  def transform_for_caller(payload, _campaign_id, _discord_id, _display_name), do: payload

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

  defp send_reset(hub_base, campaign_id) do
    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.campaign_deleted(),
      "campaign_id" => campaign_id,
      "deleted_by" => "cli:lore.seed.skandal"
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
