defmodule Worker.MaterializerDiscordConfigTest do
  @moduledoc """
  Issue #985 Slice 1: Konvergenz + Cascade für das CampaignDiscordConfigSet-
  Whole-Snapshot-Artefakt (`worker_campaign_discord_configs`). Reine
  Metadaten-Verwaltung, keine funktionale Wirkung — der Bot existiert noch
  nicht.

  Kern-Invariante wie bei CampaignCalendarSet/ThreadRegistryComputed:
  **Whole-Snapshot ⇒ Voll-Ersatz, kein Feld-Merge**. Zwei DIVERGENTE
  Payloads → der höhere event_id gewinnt KOMPLETT.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-discord-cfg-985"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp cfg_ev(guild_id, voice_channel_id, seq, event_id) do
    event(
      "CampaignDiscordConfigSet",
      %{
        "campaign_id" => @cid,
        "guild_id" => guild_id,
        "voice_channel_id" => voice_channel_id,
        "set_by" => "gm-did"
      },
      seq,
      event_id: event_id
    )
  end

  defp read_row(tbl, key) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(tbl, key) end)
    rows
  end

  defp fold_meta_row(tbl, key, fold) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.fold_meta(), {tbl, key, fold}) end)
    rows
  end

  test "materialisiert → Repo.get_campaign_discord_config liest zurück" do
    assert {:applied, 1} = Materializer.apply_event(cfg_ev("111", "222", 1, "dc-ev-1"))

    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => "111",
             "voice_channel_id" => "222"
           }
  end

  test "fehlende Row → beide Felder nil" do
    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => nil,
             "voice_channel_id" => nil
           }
  end

  test "Reset-Pfad: beide Felder leer gespeichert → Reader liefert wieder nil/nil" do
    Materializer.apply_event(cfg_ev("111", "222", 1, "dc-ev-1"))
    assert Repo.get_campaign_discord_config(@cid)["guild_id"] == "111"

    assert {:applied, 2} = Materializer.apply_event(cfg_ev("", "", 2, "dc-ev-2"))

    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => nil,
             "voice_channel_id" => nil
           }

    # Die Row existiert weiterhin (kein Delete) — nur die Werte sind leer.
    assert read_row(S.campaign_discord_configs(), @cid) != []
  end

  test "non-binary Werte werden defensiv auf \"\" normalisiert statt zu crashen" do
    ev =
      event(
        "CampaignDiscordConfigSet",
        %{"campaign_id" => @cid, "guild_id" => nil, "voice_channel_id" => 12_345},
        1,
        event_id: "dc-ev-bad"
      )

    assert {:applied, 1} = Materializer.apply_event(ev)

    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => nil,
             "voice_channel_id" => nil
           }
  end

  test "bad campaign_id wird verworfen statt zu crashen" do
    ev = event("CampaignDiscordConfigSet", %{"campaign_id" => nil, "guild_id" => "1"}, 1)
    assert {:applied, 1} = Materializer.apply_event(ev)
  end

  test "LWW: zwei DIVERGENTE Payloads, höherer event_id gewinnt KOMPLETT (kein Feld-Merge), jede Reihenfolge konvergiert" do
    events = [cfg_ev("111", "222", 1, "dc-ev-1"), cfg_ev("999", "888", 2, "dc-ev-2")]

    results =
      materialize_permutations(events, fn -> Repo.get_campaign_discord_config(@cid) end)

    expected = %{"guild_id" => "999", "voice_channel_id" => "888"}
    Enum.each(results, fn r -> assert r == expected end)
    assert Enum.uniq(results) == [expected]
  end

  test "nil-event_id (schlüsselloses Alt-Event) clobbert eine geschlüsselte Row NICHT" do
    reset_for_permutation!()
    Materializer.apply_event(cfg_ev("111", "222", 1, "dc-ev-keyed"))

    Materializer.apply_event(
      event(
        "CampaignDiscordConfigSet",
        %{"campaign_id" => @cid, "guild_id" => "legacy", "voice_channel_id" => "legacy"},
        2
      )
    )

    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => "111",
             "voice_channel_id" => "222"
           }
  end

  test "CampaignDeleted-Cascade räumt Row + fold_meta" do
    reset_for_permutation!()
    build_campaign(campaign_id: @cid, apply: true)

    Materializer.apply_event(cfg_ev("111", "222", 10, "dc-ev-c"))

    assert Repo.get_campaign_discord_config(@cid) != %{
             "guild_id" => nil,
             "voice_channel_id" => nil
           }

    assert read_row(S.campaign_discord_configs(), @cid) != []
    assert fold_meta_row(S.campaign_discord_configs(), @cid, :campaign_discord_config_set) != []

    Materializer.apply_event(event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 11))

    assert Repo.get_campaign_discord_config(@cid) == %{
             "guild_id" => nil,
             "voice_channel_id" => nil
           }

    assert read_row(S.campaign_discord_configs(), @cid) == []
    assert fold_meta_row(S.campaign_discord_configs(), @cid, :campaign_discord_config_set) == []
  end
end
