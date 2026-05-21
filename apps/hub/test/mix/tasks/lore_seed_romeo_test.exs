defmodule Mix.Tasks.Lore.Seed.RomeoTest do
  @moduledoc """
  Property-tests for the Romeo & Julia seed files.

  We do not exercise the HTTP transport here — that's covered by manual
  PR-test verification on a live hub. What we *can* verify locally is
  that the JSONL payloads themselves are internally consistent: every
  line parses, every required field is present, every cross-reference
  (session_id, campaign_id, discord_id) resolves, and pre-generated
  LLM outputs are populated.

  These properties are what make `mix lore.seed.romeo` deterministic
  and reviewable. If a seed file silently grows a typo or a dangling
  session_id, the failure mode on a real hub is "campaign loads but
  one session is empty" — much harder to diagnose than a CI failure.
  """

  use ExUnit.Case, async: true

  @seeds_dir Path.expand("../../../priv/seeds/romeo", __DIR__)
  @campaign_id "romeo-julia-demo"
  @reserved_id_prefix "10000000000000000"

  setup_all do
    files =
      @seeds_dir
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()

    events =
      Enum.flat_map(files, fn path ->
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          {:ok, payload} = Jason.decode(line)
          {Path.basename(path), payload}
        end)
      end)

    {:ok, files: files, events: events}
  end

  describe "file presence" do
    test "all expected seed files exist", %{files: files} do
      basenames = Enum.map(files, &Path.basename/1)

      assert "01_setup.jsonl" in basenames
      assert "02_act1.jsonl" in basenames
      assert "03_act2.jsonl" in basenames
      assert "04_act3.jsonl" in basenames
      assert "05_act4.jsonl" in basenames
      assert "06_act5.jsonl" in basenames
      assert "07_finale.jsonl" in basenames
    end

    test "files are applied in lexicographic order matching narrative order", %{files: files} do
      basenames = Enum.map(files, &Path.basename/1)
      assert basenames == Enum.sort(basenames)
    end
  end

  describe "event structure" do
    test "every event has a kind field", %{events: events} do
      for {file, payload} <- events do
        assert Map.has_key?(payload, "kind"),
               "#{file}: event missing \"kind\": #{inspect(payload)}"
      end
    end

    test "every kind is one the materializer knows about", %{events: events} do
      known_kinds =
        ~w(
          CampaignCreated CampaignDeleted CampaignAliasSet CampaignFlavorSet
          InviteCreated InviteRedeemed
          UserUpserted UserRoleSet
          SessionScheduled SessionStarted SessionEnded
          UtteranceAppended MarkerAdded
          SessionSummaryGenerated EposEntryEdited ChronikEntryChanged
        )

      for {file, %{"kind" => kind}} <- events do
        assert kind in known_kinds, "#{file}: unknown event kind #{inspect(kind)}"
      end
    end
  end

  describe "campaign consistency" do
    test "every campaign-scoped event references the romeo campaign id", %{events: events} do
      campaign_scoped =
        ~w(CampaignAliasSet CampaignFlavorSet InviteCreated SessionScheduled
           SessionSummaryGenerated EposEntryEdited ChronikEntryChanged
           CampaignDeleted)

      for {file, %{"kind" => kind} = payload} <- events, kind in campaign_scoped do
        cid = payload["campaign_id"]

        assert cid == @campaign_id,
               "#{file}: #{kind} has campaign_id #{inspect(cid)}, expected #{@campaign_id}"
      end
    end

    test "CampaignCreated declares the romeo campaign id", %{events: events} do
      created =
        for {_, %{"kind" => "CampaignCreated"} = p} <- events, do: p

      assert length(created) == 1, "expected exactly one CampaignCreated, got #{length(created)}"
      [%{"id" => id}] = created
      assert id == @campaign_id
    end
  end

  describe "session references" do
    test "every session_id used by events refers to a SessionScheduled event", %{events: events} do
      declared =
        for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events, into: MapSet.new(), do: sid

      session_scoped =
        ~w(SessionStarted SessionEnded UtteranceAppended MarkerAdded SessionSummaryGenerated)

      for {file, %{"kind" => kind} = payload} <- events, kind in session_scoped do
        sid =
          case kind do
            "SessionStarted" -> payload["id"]
            "SessionEnded" -> payload["id"]
            "SessionSummaryGenerated" -> payload["session_id"]
            _ -> payload["session_id"]
          end

        assert sid in declared,
               "#{file}: #{kind} references unknown session #{inspect(sid)}. Declared: #{inspect(MapSet.to_list(declared))}"
      end
    end

    test "exactly 5 sessions are declared (one per Akt)", %{events: events} do
      scheduled = for {_, %{"kind" => "SessionScheduled"} = p} <- events, do: p
      assert length(scheduled) == 5

      numbers = scheduled |> Enum.map(& &1["number"]) |> Enum.sort()
      assert numbers == [1, 2, 3, 4, 5]
    end

    test "every session has both SessionStarted and SessionEnded", %{events: events} do
      scheduled =
        for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events, into: MapSet.new(), do: sid

      started =
        for {_, %{"kind" => "SessionStarted", "id" => sid}} <- events, into: MapSet.new(), do: sid

      ended =
        for {_, %{"kind" => "SessionEnded", "id" => sid}} <- events, into: MapSet.new(), do: sid

      assert MapSet.equal?(scheduled, started), "sessions without SessionStarted: #{inspect(MapSet.difference(scheduled, started))}"
      assert MapSet.equal?(scheduled, ended), "sessions without SessionEnded: #{inspect(MapSet.difference(scheduled, ended))}"
    end
  end

  describe "discord ids" do
    test "every discord_id is in the reserved test range (starts with #{@reserved_id_prefix})", %{events: events} do
      for {file, payload} <- events do
        for {key, value} <- payload, key_holds_discord_id?(key) do
          if is_binary(value) and not String.starts_with?(value, @reserved_id_prefix) do
            flunk(
              "#{file}: payload contains non-reserved discord-id #{inspect(value)}. " <>
                "Use #{@reserved_id_prefix}* range to avoid collisions with real Discord snowflakes."
            )
          end
        end
      end
    end

    test "exactly 7 users are upserted (1 GM + 6 cast)", %{events: events} do
      upserts =
        for {_, %{"kind" => "UserUpserted", "discord_id" => did}} <- events,
            uniq: true,
            do: did

      assert length(upserts) == 7,
             "expected 7 UserUpserted events, got #{length(upserts)}: #{inspect(upserts)}"
    end

    test "GM gets :admin role", %{events: events} do
      role_sets = for {_, %{"kind" => "UserRoleSet"} = p} <- events, do: p

      admin_sets = Enum.filter(role_sets, &(&1["role"] == "admin"))
      assert length(admin_sets) >= 1, "no admin role assignment found"
    end
  end

  describe "pre-generated LLM outputs" do
    test "every session has a SessionSummaryGenerated", %{events: events} do
      scheduled =
        for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events, into: MapSet.new(), do: sid

      summarized =
        for {_, %{"kind" => "SessionSummaryGenerated", "session_id" => sid}} <- events,
            into: MapSet.new(),
            do: sid

      assert MapSet.equal?(scheduled, summarized),
             "sessions without summary: #{inspect(MapSet.difference(scheduled, summarized))}"
    end

    test "campaign has exactly one EposEntryEdited", %{events: events} do
      epos = for {_, %{"kind" => "EposEntryEdited"} = p} <- events, do: p
      assert length(epos) == 1, "expected exactly 1 EposEntryEdited, got #{length(epos)}"

      [%{"new_md" => md}] = epos
      assert String.length(md) > 500, "epos content suspiciously short (#{String.length(md)} chars)"
    end

    test "chronik has at least one entry per akt", %{events: events} do
      chronik =
        for {_, %{"kind" => "ChronikEntryChanged"} = p} <- events,
            do: p["in_game_sort_key"]

      sort_keys = Enum.sort(chronik)
      assert length(sort_keys) >= 5, "expected ≥5 chronik entries (one per akt), got #{length(sort_keys)}"
      assert Enum.uniq(sort_keys) == sort_keys, "chronik in_game_sort_key has duplicates: #{inspect(sort_keys)}"
    end

    test "all four flavor slots (base, summary, epos, chronik) are set", %{events: events} do
      slots =
        for {_, %{"kind" => "CampaignFlavorSet", "slot" => slot}} <- events,
            into: MapSet.new(),
            do: slot

      expected = MapSet.new(~w(base summary epos chronik))
      assert MapSet.equal?(slots, expected), "missing flavor slots: #{inspect(MapSet.difference(expected, slots))}"
    end
  end

  describe "narrative markers" do
    test "every akt has at least one plot marker", %{events: events} do
      by_session =
        for {_, %{"kind" => "MarkerAdded"} = p} <- events do
          {p["session_id"], p["marker_kind"]}
        end
        |> Enum.group_by(fn {sid, _} -> sid end, fn {_, kind} -> kind end)

      sessions = for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events, do: sid

      for sid <- sessions do
        kinds = Map.get(by_session, sid, [])
        assert "plot" in kinds, "session #{sid} has no plot marker (kinds: #{inspect(kinds)})"
      end
    end
  end

  # ─── helpers ───────────────────────────────────────────────────────

  defp key_holds_discord_id?(key) when key in ~w(discord_id owner_discord_id created_by_discord_id),
    do: true

  defp key_holds_discord_id?(_), do: false

  describe "transform_for_caller/3 (Issue #78)" do
    alias Mix.Tasks.Lore.Seed.Romeo

    test "without --as-admin returns payload unchanged" do
      payload = %{
        "kind" => "CampaignCreated",
        "id" => @campaign_id,
        "owner_discord_id" => "100000000000000001",
        "owner_display_name" => "Erzähler"
      }

      assert Romeo.transform_for_caller(payload, nil, "Admin") == payload
    end

    test "with --as-admin replaces CampaignCreated owner fields" do
      payload = %{
        "kind" => "CampaignCreated",
        "id" => @campaign_id,
        "owner_discord_id" => "100000000000000001",
        "owner_display_name" => "Erzähler",
        "name" => "Romeo & Julia"
      }

      result = Romeo.transform_for_caller(payload, "615614311255244801", "Tom")

      assert result["owner_discord_id"] == "615614311255244801"
      assert result["owner_display_name"] == "Tom"
      # Other fields preserved
      assert result["kind"] == "CampaignCreated"
      assert result["id"] == @campaign_id
      assert result["name"] == "Romeo & Julia"
    end

    test "with --as-admin leaves non-CampaignCreated events untouched" do
      utterance = %{
        "kind" => "UtteranceAppended",
        "session_id" => "act-1",
        "discord_id" => "100000000000000002",
        "text" => "Was, jetzt schon?"
      }

      assert Romeo.transform_for_caller(utterance, "615614311255244801", "Tom") == utterance
    end

    test "with --as-admin leaves CampaignCreated for a different campaign id untouched" do
      foreign = %{
        "kind" => "CampaignCreated",
        "id" => "some-other-campaign",
        "owner_discord_id" => "999"
      }

      assert Romeo.transform_for_caller(foreign, "615614311255244801", "Tom") == foreign
    end
  end

  describe "skip_for_mode?/2 (Issue #78)" do
    alias Mix.Tasks.Lore.Seed.Romeo

    test "in :full mode skips nothing" do
      for kind <- ~w(SessionSummaryGenerated EposEntryEdited ChronikEntryChanged UtteranceAppended) do
        refute Romeo.skip_for_mode?(%{"kind" => kind}, :full)
      end
    end

    test "in :protocol_only mode skips LLM-output events" do
      assert Romeo.skip_for_mode?(%{"kind" => "SessionSummaryGenerated"}, :protocol_only)
      assert Romeo.skip_for_mode?(%{"kind" => "EposEntryEdited"}, :protocol_only)
      assert Romeo.skip_for_mode?(%{"kind" => "ChronikEntryChanged"}, :protocol_only)
    end

    test "in :protocol_only mode keeps protocol events" do
      for kind <- ~w(CampaignCreated UtteranceAppended MarkerAdded SessionStarted UserUpserted) do
        refute Romeo.skip_for_mode?(%{"kind" => kind}, :protocol_only)
      end
    end
  end
end
