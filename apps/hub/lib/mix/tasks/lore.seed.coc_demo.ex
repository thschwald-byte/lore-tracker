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

  alias Mix.Tasks.Lore.Seed.SourceRefs

  @shortdoc "Seed the Corbett-House CoC-Investigation demo campaign"

  @hub_base "http://127.0.0.1:4000"
  @campaign_id "coc-demo"
  @campaign_name "Corbett House — Boston 1925"
  @session_id "coc-demo-session-1"
  @session_name "Das Verschwinden der Mercariats"
  @assets_subpath "apps/worker/priv/probelauf-eval"
  @dummy_owner "100000000000000004"
  @dummy_owner_name "Probelauf-Eval"

  # Speaker-IDs aus session-4-utterances.jsonl → Display-Name + Character-Name.
  # SL ist Spielleiter, die anderen vier sind Spieler-Characters.
  @speakers [
    {"coc-eval-sl", "Spielleiter", :gm, nil, "coc-seed-invite-sl"},
    {"coc-eval-laurent", "Laurent-Spieler", :player, "Henri Laurent", "coc-seed-invite-laurent"},
    {"coc-eval-flaw", "Flaw-Spielerin", :player, "Agnes Flaw", "coc-seed-invite-flaw"},
    {"coc-eval-oreilly", "O'Reilly-Spieler", :player, "Pater O'Reilly",
     "coc-seed-invite-oreilly"},
    {"coc-eval-crawford", "Crawford-Spieler", :player, "Andrew Crawford",
     "coc-seed-invite-crawford"}
  ]

  # Session-Anker: feste Startzeit + 15s pro Utt (~3.5h Session @ 844 utts).
  @session_start ~U[2026-05-25 18:09:00Z]
  @utt_step_seconds 15

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

    Mix.shell().info("Loaded #{length(assets.utterances)} utterances + 3 Goldstandard-Files")

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
      "kind" => Shared.Events.campaign_created(),
      "id" => @campaign_id,
      "name" => @campaign_name,
      "icon_url" => nil,
      "theme_blurb" =>
        "CoC-Investigation 1925, Boston. Demo-Seed der Corbett-House-Story (Issue #286) — identisches Asset wie die Real-Size-Eval-Session des Probelauf-Sweeps.",
      "owner_discord_id" => owner_did,
      "owner_display_name" => owner_display
    })

    session_start_iso = DateTime.to_iso8601(@session_start)

    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.session_scheduled(),
      "id" => @session_id,
      "campaign_id" => @campaign_id,
      "number" => 1,
      "name" => @session_name,
      "scheduled_for" => session_start_iso
    })

    # Speaker als User + Member anlegen, damit die Utts korrekten Spieler-Pillen
    # bekommen. SL wird zusätzlich zum :spielleiter promotet.
    member_event_count = seed_members(hub_base, owner_did)

    # Issue #350: stabile Utterance-ID einmal definieren — dieselbe Formel für
    # das UtteranceAppended-Event UND die source_refs-Berechnung unten, damit
    # die beiden Stellen nicht driften.
    utt_id = fn i -> "u-#{@session_id}-#{i}" end

    indexed_utts = Enum.with_index(assets.utterances)

    utt_count =
      Enum.reduce(indexed_utts, 0, fn {utt, i}, acc ->
        ts = DateTime.add(@session_start, i * @utt_step_seconds, :second)

        post_or_raise!(hub_base, %{
          "kind" => Shared.Events.utterance_appended(),
          "id" => utt_id.(i),
          "session_id" => @session_id,
          "discord_id" => utt["discord_id"] || "coc-demo-system",
          "timestamp" => DateTime.to_iso8601(ts),
          "text" => utt["text"],
          # Issue #376: einheitliches Map-Format (vorher Float 1.0).
          "confidence" => %{"mean_p" => 1.0, "min_p" => 1.0},
          "status" => "confirmed"
        })

        acc + 1
      end)

    # Issue #350: source_refs deterministisch via lexical-overlap, analog zu den
    # statischen Seeds (mix lore.seed.backfill_refs). 1 Session → alle Utts sind
    # Kandidaten; Epos-Refs = Summary-Refs (eine Session).
    ref_utts =
      Enum.map(indexed_utts, fn {utt, i} -> %{"id" => utt_id.(i), "text" => utt["text"]} end)

    summary_refs = SourceRefs.compute_refs(String.trim(assets.summary_md), ref_utts)

    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.session_summary_generated(),
      "session_id" => @session_id,
      "campaign_id" => @campaign_id,
      "content_md" => String.trim(assets.summary_md),
      "source" => "goldstandard",
      "source_refs" => summary_refs
    })

    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.epos_entry_edited(),
      "entry_id" => @campaign_id,
      "campaign_id" => @campaign_id,
      "new_md" => String.trim(assets.epos_md),
      "edited_by" => "goldstandard",
      "source" => "goldstandard",
      "source_refs" => summary_refs
    })

    chronik_count =
      Enum.reduce(assets.chronik, 0, fn entry, acc ->
        post_or_raise!(hub_base, %{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => "chronik-coc-#{@session_id}-#{:erlang.phash2(entry)}",
          "campaign_id" => @campaign_id,
          "session_id" => @session_id,
          "in_game_date" => entry["in_game_date"],
          "label" => entry["label"],
          "summary" => entry["summary"],
          "source_refs" => SourceRefs.compute_refs(entry["summary"], ref_utts)
        })

        acc + 1
      end)

    # CampaignCreated + SessionScheduled + member-events + utts + Summary + Epos + Chronik-Einträge
    2 + member_event_count + utt_count + 2 + chronik_count
  end

  # ─── Speakers als Members anlegen ─────────────────────────────────

  defp seed_members(hub_base, owner_did) do
    Enum.reduce(@speakers, 0, fn {did, display_name, role, character_name, invite_token}, acc ->
      post_or_raise!(hub_base, %{
        "kind" => Shared.Events.user_upserted(),
        "discord_id" => did,
        "display_name" => display_name,
        "avatar_url" => nil
      })

      post_or_raise!(hub_base, %{
        "kind" => Shared.Events.invite_created(),
        "token" => invite_token,
        "campaign_id" => @campaign_id,
        "created_by_discord_id" => owner_did,
        "expires_at" => "2099-12-31T23:59:59Z"
      })

      post_or_raise!(hub_base, %{
        "kind" => Shared.Events.invite_redeemed(),
        "token" => invite_token,
        "discord_id" => did,
        "display_name" => display_name
      })

      events = 3

      events =
        if character_name do
          post_or_raise!(hub_base, %{
            "kind" => Shared.Events.campaign_alias_set(),
            "campaign_id" => @campaign_id,
            "discord_id" => did,
            "character_name" => character_name
          })

          events + 1
        else
          events
        end

      events =
        if role == :gm do
          post_or_raise!(hub_base, %{
            "kind" => Shared.Events.member_role_promoted(),
            "campaign_id" => @campaign_id,
            "discord_id" => did,
            "new_role" => "spielleiter",
            "promoted_by" => owner_did
          })

          events + 1
        else
          events
        end

      acc + events
    end)
  end

  # ─── Caller bootstrap (--as-admin) ────────────────────────────────

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
      "set_by" => "cli:lore.seed.coc_demo --as-admin"
    })

    :ok
  end

  defp send_reset(hub_base) do
    post_or_raise!(hub_base, %{
      "kind" => Shared.Events.campaign_deleted(),
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
