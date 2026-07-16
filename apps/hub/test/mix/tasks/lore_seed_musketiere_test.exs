defmodule Mix.Tasks.Lore.Seed.MusketiereTest do
  @moduledoc """
  Structural property-tests für die Drei-Musketiere-Demo-Seeds (Issue #423).

  Analog zu lore_seed_romeo_test.exs — verifiziert dass die JSONL-Files
  intern konsistent sind: jede Zeile parst, Cross-References auflösen,
  Discord-IDs im reservierten Test-Range.
  """

  use ExUnit.Case, async: true

  @seeds_dir Path.expand("../../../priv/seeds/musketiere", __DIR__)
  @campaign_id "drei-musketiere-demo"
  @reserved_id_prefix "20000000000000000"

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
    test "all 5 seed files exist (setup + 4 sessions)", %{files: files} do
      basenames = Enum.map(files, &Path.basename/1)

      assert "01_setup.jsonl" in basenames
      assert "02_session1.jsonl" in basenames
      assert "03_session2.jsonl" in basenames
      assert "04_session3.jsonl" in basenames
      assert "05_session4.jsonl" in basenames
    end

    test "files are sorted lexicographically (apply order = narrative order)", %{files: files} do
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
          CampaignCreated CampaignFlavorSet
          InviteCreated InviteRedeemed CampaignAliasSet
          UserUpserted UserRoleSet
          SessionScheduled SessionStarted SessionEnded
          UtteranceAppended
        )

      for {file, %{"kind" => kind}} <- events do
        assert kind in known_kinds, "#{file}: unknown event kind #{inspect(kind)}"
      end
    end
  end

  describe "campaign consistency" do
    test "every campaign-scoped event references the musketiere campaign id", %{events: events} do
      campaign_scoped =
        ~w(CampaignAliasSet CampaignFlavorSet InviteCreated SessionScheduled)

      for {file, %{"kind" => kind} = payload} <- events, kind in campaign_scoped do
        cid = payload["campaign_id"]

        assert cid == @campaign_id,
               "#{file}: #{kind} has campaign_id #{inspect(cid)}, expected #{@campaign_id}"
      end
    end

    test "exactly one CampaignCreated declares the musketiere campaign id", %{events: events} do
      created = for {_, %{"kind" => "CampaignCreated"} = p} <- events, do: p
      assert length(created) == 1
      [%{"id" => id}] = created
      assert id == @campaign_id
    end

    test "all three flavor slots (summary, epos, chronik) are set", %{events: events} do
      slots =
        for {_, %{"kind" => "CampaignFlavorSet", "slot" => slot}} <- events,
            into: MapSet.new(),
            do: slot

      expected = MapSet.new(~w(summary epos chronik))

      assert MapSet.equal?(slots, expected),
             "missing flavor slots: #{inspect(MapSet.difference(expected, slots))}"
    end
  end

  describe "session references" do
    test "exactly 4 sessions are declared", %{events: events} do
      scheduled = for {_, %{"kind" => "SessionScheduled"} = p} <- events, do: p
      assert length(scheduled) == 4

      numbers = scheduled |> Enum.map(& &1["number"]) |> Enum.sort()
      assert numbers == [1, 2, 3, 4]
    end

    test "every session has both SessionStarted and SessionEnded", %{events: events} do
      scheduled =
        for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events,
            into: MapSet.new(),
            do: sid

      started =
        for {_, %{"kind" => "SessionStarted", "id" => sid}} <- events, into: MapSet.new(), do: sid

      ended =
        for {_, %{"kind" => "SessionEnded", "id" => sid}} <- events, into: MapSet.new(), do: sid

      assert MapSet.equal?(scheduled, started),
             "sessions without SessionStarted: #{inspect(MapSet.difference(scheduled, started))}"

      assert MapSet.equal?(scheduled, ended),
             "sessions without SessionEnded: #{inspect(MapSet.difference(scheduled, ended))}"
    end

    test "every UtteranceAppended references a real session", %{events: events} do
      declared =
        for {_, %{"kind" => "SessionScheduled", "id" => sid}} <- events,
            into: MapSet.new(),
            do: sid

      for {file, %{"kind" => "UtteranceAppended", "session_id" => sid}} <- events do
        assert sid in declared,
               "#{file}: UtteranceAppended references unknown session #{inspect(sid)}"
      end
    end
  end

  describe "discord ids" do
    test "every discord_id is in the reserved test range (starts with #{@reserved_id_prefix})", %{
      events: events
    } do
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

    test "exactly 5 users are upserted (1 SL + 4 cast)", %{events: events} do
      upserts =
        for {_, %{"kind" => "UserUpserted", "discord_id" => did}} <- events,
            uniq: true,
            do: did

      assert length(upserts) == 5,
             "expected 5 UserUpserted events, got #{length(upserts)}: #{inspect(upserts)}"
    end

    test "SL gets :admin role", %{events: events} do
      role_sets = for {_, %{"kind" => "UserRoleSet"} = p} <- events, do: p
      admin_sets = Enum.filter(role_sets, &(&1["role"] == "admin"))
      assert length(admin_sets) >= 1, "no admin role assignment found"
    end

    test "every cast member has an alias set", %{events: events} do
      aliases =
        for {_, %{"kind" => "CampaignAliasSet", "discord_id" => did, "character_name" => name}} <-
              events,
            do: {did, name}

      # 4 PCs: D'Artagnan, Athos, Porthos, Aramis
      assert length(aliases) == 4
      char_names = aliases |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert char_names == ["Aramis", "Athos", "D'Artagnan", "Porthos"]
    end
  end

  describe "protocol-only nature (LLM-Eval-Demo)" do
    test "no SessionSummaryGenerated events (LLM should generate these)", %{events: events} do
      summaries = for {_, %{"kind" => "SessionSummaryGenerated"}} <- events, do: 1

      assert summaries == [],
             "musketiere-Seeds sind protocol-only — Stage 2 darf NICHT vorgeseedet sein"
    end

    test "no EposEntryEdited events (LLM should generate these)", %{events: events} do
      epos = for {_, %{"kind" => "EposEntryEdited"}} <- events, do: 1

      assert epos == [],
             "musketiere-Seeds sind protocol-only — Stage 3 darf NICHT vorgeseedet sein"
    end

    test "no ChronikEntryChanged events (LLM should generate these)", %{events: events} do
      chronik = for {_, %{"kind" => "ChronikEntryChanged"}} <- events, do: 1

      assert chronik == [],
             "musketiere-Seeds sind protocol-only — Stage 4 darf NICHT vorgeseedet sein"
    end
  end

  describe "session size (Issue #423 acceptance)" do
    test "every session has 25k-40k Wörter (LLM-Eval-Range)", %{events: events} do
      by_session =
        events
        |> Enum.filter(fn {_, e} -> e["kind"] == "UtteranceAppended" end)
        |> Enum.group_by(fn {_, e} -> e["session_id"] end, fn {_, e} -> e["text"] end)

      for {session_id, texts} <- by_session do
        word_count =
          texts
          |> Enum.join(" ")
          |> String.split(~r/\s+/, trim: true)
          |> length()

        assert word_count >= 25_000 and word_count <= 40_000,
               "Session #{session_id} hat #{word_count} Wörter — Acceptance verlangt 25k-40k"
      end
    end
  end

  describe "transform_for_caller/4 (Issue #78)" do
    alias Mix.Tasks.Lore.Seed.Musketiere

    test "without --as-admin returns payload unchanged" do
      payload = %{
        "kind" => "CampaignCreated",
        "id" => @campaign_id,
        "owner_discord_id" => "200000000000000001",
        "owner_display_name" => "Erzähler"
      }

      assert Musketiere.transform_for_caller(payload, @campaign_id, nil, "Admin") == payload
    end

    test "with --as-admin replaces CampaignCreated owner fields" do
      payload = %{
        "kind" => "CampaignCreated",
        "id" => @campaign_id,
        "owner_discord_id" => "200000000000000001",
        "owner_display_name" => "Erzähler",
        "name" => "Die drei Musketiere"
      }

      result = Musketiere.transform_for_caller(payload, @campaign_id, "615614311255244801", "Tom")

      assert result["owner_discord_id"] == "615614311255244801"
      assert result["owner_display_name"] == "Tom"
      assert result["kind"] == "CampaignCreated"
      assert result["id"] == @campaign_id
      assert result["name"] == "Die drei Musketiere"
    end

    test "with --as-admin leaves non-CampaignCreated events untouched" do
      utterance = %{
        "kind" => "UtteranceAppended",
        "session_id" => "session-musk-1",
        "discord_id" => "200000000000000002",
        "text" => "Gascogne — die Heimat des Stolzes."
      }

      assert Musketiere.transform_for_caller(utterance, @campaign_id, "615614311255244801", "Tom") ==
               utterance
    end
  end

  defp key_holds_discord_id?(key)
       when key in ~w(discord_id owner_discord_id created_by_discord_id),
       do: true

  defp key_holds_discord_id?(_), do: false
end
