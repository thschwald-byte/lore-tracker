defmodule Mix.Tasks.Lore.Seed.Musketiere do
  @moduledoc """
  Seeds die „Drei-Musketiere"-D&D-Demo-Kampagne in einen laufenden lokalen Hub.

  Quelle gemeinfrei: Alexandre Dumas, „Les trois mousquetaires" (1844). Dumas
  † 1870, global PD seit 1940. Dialoge in den Seed-Files sind eigene deutsch-
  sprachige D&D-Tisch-Kompositionen, lose orientiert an PD-Plot-Beats —
  analog zum bestehenden Romeo-Schlegel-Seed-Pattern (Schlegel-Übersetzung
  1797, ebenfalls PD).

      # In einer Shell, Hub starten:
      cd apps/hub && mix phx.server

      # In einer anderen Shell, Worker starten (Materializer-Apply!):
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Dann seeden:
      mix lore.seed.musketiere                              # gegen http://127.0.0.1:4000
      mix lore.seed.musketiere --hub http://127.0.0.1:4005  # PR-Test-Hub
      mix lore.seed.musketiere --reset                      # erst CampaignDeleted, dann re-seed
      mix lore.seed.musketiere --as-admin <discord-id>      # Caller als Owner+Admin

  ## Über die Kampagne

  Vier Sessions à 25-40k Wörter, nur Protokoll. Plot folgt Dumas:

  - **S1 — D'Artagnans Reise + Triple-Duell**: Meung-Encounter mit Rochefort
    und Milady, Brief gestohlen, Tréville-Audienz, drei Duelle arrangiert,
    Cardinal-Wachen-Kampf, Aufnahme in die Garde.
  - **S2 — Anhänger der Königin**: Constance entführt + gerettet, Anne bittet
    um Anhänger-Rettung, Reise nach London (Porthos/Aramis/Athos fallen
    unterwegs aus), D'Artagnan zu Buckingham, knapp zum Ball.
  - **S3 — Milady + La Rochelle**: D'Artagnan + Milady, das Brandzeichen,
    Athos' Wiedererkennen, Belagerung, Bastion-Saint-Gervais-Frühstück,
    Cardinal-Auftrag an Milady.
  - **S4 — Lys-Finale**: Milady ermordet Buckingham, vergiftet Constance,
    Hetzjagd, Gerichtsverfahren in der Hütte, Hinrichtung am Lys, Lieutenant-
    Patent in Paris.

  4 PCs (Edgin: Bard, Holga: Barbarin, Simon: Sorcerer, Doric: Druidin) —
  pardon, das sind die PCs der **alten** Vorlage. Hier:

  - **D'Artagnan** — Mensch / Rogue (Swashbuckler), neunzehn, Gascogner
  - **Athos** — Mensch / Fighter (Champion), Comte de la Fère a.D.
  - **Porthos** — Mensch / Barbarian (Berserker), eitel, laut
  - **Aramis** — Mensch / Cleric (War Domain), Priester-Aspirant

  Alle NPCs (Tréville, Königin Anne, Cardinal Richelieu, Milady de Winter,
  Rochefort, Constance, Buckingham, Lord de Winter, Henker von Lille etc.)
  werden vom SL gespielt.

  ## Caller-as-Admin (Issue #78)

  Per default ist der Campaign-Owner der Dummy-User „Erzähler". Damit der
  eigene Discord-Account die Kampagne im Dashboard sieht und bearbeiten
  kann:

      mix lore.seed.musketiere --as-admin <discord-id>
      mix lore.seed.musketiere --as-admin <discord-id> --display-name "Tom"

  ## Safety

  Refuses to run in `MIX_ENV=prod`. Berührt nur die Campaign-ID
  `drei-musketiere-demo` — kollidiert nicht mit echten Daten oder anderen
  Demo-Seeds (Romeo: `romeo-julia-*`, Vox-Machina: `vm-*`). `--reset` löscht
  die Kampagne und re-seedet.
  """

  use Mix.Task

  @shortdoc "Seed die Drei-Musketiere-D&D-Demo-Kampagne in einen lokalen Hub"

  @hub_base "http://127.0.0.1:4000"
  @seeds_subpath "priv/seeds/musketiere"
  @campaign_id "drei-musketiere-demo"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise(
        "lore.seed.musketiere refuses to run in MIX_ENV=prod — Demo-Daten dürfen niemals auf Produktion landen."
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
      Mix.raise("no seed files found under #{seeds_dir()}")
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
      "set_by" => "cli:lore.seed.musketiere --as-admin"
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

  def transform_for_caller(
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
      "deleted_by" => "cli:lore.seed.musketiere"
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
