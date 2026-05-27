defmodule Mix.Tasks.Lore.Seed.CocDemo do
  @moduledoc """
  Seeds the Corbett-House CoC-Investigation demo campaign into a running local hub.

  Same Asset-Files wie die Real-Size-Eval-Session des Probelauf-Sweeps
  (Issue #286) — eine kanonische Quelle, hier als reguläre Test-Stage-Kampagne
  in einen Hub geladen statt als probelauf-eval-Goldstandard.

  Backbone der Story stammt aus einer echten CoC-Session (Session 1 + 2 der
  prod-Kampagne, anonymisiert): die Investigatoren Henri Laurent, Agnes Flaw,
  Pater O'Reilly und Andrew Crawford untersuchen das Corbett House in Boston
  1925 — die Familie Mercariat ist dort vor zwei Jahren ums Leben gekommen.

      # In one shell, start the hub:
      cd apps/hub && mix phx.server

      # In another shell, start the worker (needed for materializer):
      cd apps/worker && LORE_MNESIA_DIR=… elixir --sname worker --no-halt -S mix run

      # Then seed:
      mix lore.seed.coc_demo                              # default: http://127.0.0.1:4000
      mix lore.seed.coc_demo --hub http://127.0.0.1:4001  # PR-Test-Hub
      mix lore.seed.coc_demo --reset                      # erst CampaignDeleted, dann re-seed
      mix lore.seed.coc_demo --as-admin <discord-id>      # Caller als Owner
      mix lore.seed.coc_demo --as-admin <did> --display-name "Tom"

  ## Assets

  Liest aus `apps/worker/priv/probelauf-eval/`:
  - `session-4-utterances.jsonl` — ~800 Whisper-anmutende Utts mit echten
    Speaker-IDs (5 Sprecher: sl, laurent, flaw, oreilly, crawford)
  - `session-4-summary.md` — Resümee als Goldstandard
  - `session-4-epos.md` — Epos-Kapitel als Goldstandard
  - `session-4-chronik.json` — Chronik-Einträge als Goldstandard

  Campaign-ID `coc-demo` (fix). Owner ist per Default ein Dummy
  „Probelauf-Eval" — mit `--as-admin <did>` wird der Caller als Owner gesetzt
  (analog `lore.seed.romeo`).

  ## Safety

  Refuses to run in `MIX_ENV=prod`. Berührt nur `coc-demo`.
  `--reset` löscht die Kampagne und re-seedet — der Caller-User bleibt erhalten.
  """

  use Mix.Task

  @shortdoc "Seed the Corbett-House CoC-Investigation demo campaign"

  @hub_base "http://127.0.0.1:4000"
  @campaign_id "coc-demo"
  @campaign_name "Corbett House — Boston 1925"
  @session_id "coc-demo-session-1"
  @session_name "Das Verschwinden der Mercariats"
  @assets_subpath "apps/worker/priv/probelauf-eval"
  @dummy_owner "100000000000000004"
  @dummy_owner_name "Probelauf-Eval"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise(
        "lore.seed.coc_demo refuses to run in MIX_ENV=prod — demo data must never reach production."
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

    owner_did = as_admin || @dummy_owner
    owner_display = if as_admin, do: display_name, else: @dummy_owner_name

    Mix.shell().info("Target hub: #{hub_base}")
    Mix.shell().info("Campaign:   #{@campaign_id}")
    Mix.shell().info("Session:    #{@session_id}")
    Mix.shell().info("Owner:      #{owner_did} (\"#{owner_display}\")")

    if reset? do
      Mix.shell().info("Reset:      yes (sending CampaignDeleted first)")
      send_reset(hub_base)
    end

    if as_admin do
      send_caller_bootstrap(hub_base, as_admin, display_name)
    end

    assets = load_assets()

    Mix.shell().info(
      "Loaded #{length(assets.utterances)} utterances + 3 Goldstandard-Files"
    )

    total = seed_campaign(hub_base, assets, owner_did, owner_display)
    Mix.shell().info("Done — #{total} events appended.")
  end

  # ─── Asset loading ────────────────────────────────────────────────

  defp load_assets do
    dir = assets_dir()

    utterances =
      Path.join(dir, "session-4-utterances.jsonl")
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)

    summary_md = File.read!(Path.join(dir, "session-4-summary.md"))
    epos_md = File.read!(Path.join(dir, "session-4-epos.md"))
    chronik = Path.join(dir, "session-4-chronik.json") |> File.read!() |> Jason.decode!()

    %{utterances: utterances, summary_md: summary_md, epos_md: epos_md, chronik: chronik}
  end

  defp assets_dir do
    cwd = File.cwd!()

    cond do
      File.dir?(Path.join(cwd, @assets_subpath)) ->
        Path.join(cwd, @assets_subpath)

      File.dir?(Path.join(cwd, "../#{@assets_subpath}")) ->
        Path.join(cwd, "../#{@assets_subpath}")

      true ->
        Mix.raise(
          "could not locate CoC-demo asset directory. Expected #{@assets_subpath} relative to #{cwd}."
        )
    end
  end

  # ─── Event emission ───────────────────────────────────────────────

  defp seed_campaign(hub_base, assets, owner_did, owner_display) do
    post_or_raise!(hub_base, %{
      "kind" => "CampaignCreated",
      "id" => @campaign_id,
      "name" => @campaign_name,
      "icon_url" => nil,
      "theme_blurb" =>
        "CoC-Investigation 1925, Boston. Demo-Seed der Corbett-House-Story (Issue #286) — identisches Asset wie die Real-Size-Eval-Session des Probelauf-Sweeps.",
      "owner_discord_id" => owner_did,
      "owner_display_name" => owner_display
    })

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    post_or_raise!(hub_base, %{
      "kind" => "SessionScheduled",
      "id" => @session_id,
      "campaign_id" => @campaign_id,
      "number" => 1,
      "name" => @session_name,
      "scheduled_for" => now_iso
    })

    utt_count =
      assets.utterances
      |> Enum.with_index()
      |> Enum.reduce(0, fn {utt, i}, acc ->
        post_or_raise!(hub_base, %{
          "kind" => "UtteranceAppended",
          "id" => "u-#{@session_id}-#{i}",
          "session_id" => @session_id,
          "discord_id" => utt["discord_id"] || "coc-demo-system",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "text" => utt["text"],
          "confidence" => 1.0,
          "status" => "confirmed"
        })

        acc + 1
      end)

    post_or_raise!(hub_base, %{
      "kind" => "SessionSummaryGenerated",
      "session_id" => @session_id,
      "campaign_id" => @campaign_id,
      "content_md" => String.trim(assets.summary_md),
      "source" => "goldstandard"
    })

    post_or_raise!(hub_base, %{
      "kind" => "EposEntryEdited",
      "entry_id" => @campaign_id,
      "campaign_id" => @campaign_id,
      "new_md" => String.trim(assets.epos_md),
      "edited_by" => "goldstandard",
      "source" => "goldstandard"
    })

    chronik_count =
      Enum.reduce(assets.chronik, 0, fn entry, acc ->
        post_or_raise!(hub_base, %{
          "kind" => "ChronikEntryChanged",
          "id" => "chronik-coc-#{@session_id}-#{:erlang.phash2(entry)}",
          "campaign_id" => @campaign_id,
          "session_id" => @session_id,
          "in_game_date" => entry["in_game_date"],
          "label" => entry["label"],
          "summary" => entry["summary"]
        })

        acc + 1
      end)

    # CampaignCreated + SessionScheduled + utts + Summary + Epos + Chronik-Einträge
    2 + utt_count + 2 + chronik_count
  end

  # ─── Caller bootstrap (--as-admin) ────────────────────────────────

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
      "set_by" => "cli:lore.seed.coc_demo --as-admin"
    })

    :ok
  end

  defp send_reset(hub_base) do
    post_or_raise!(hub_base, %{
      "kind" => "CampaignDeleted",
      "campaign_id" => @campaign_id,
      "deleted_by" => "cli:lore.seed.coc_demo"
    })
  end

  # ─── HTTP plumbing (mirrors lore.seed.romeo) ──────────────────────

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
