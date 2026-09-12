defmodule Worker.Jack.StageKopieTest do
  # Ohne Prod: erfundene IDs, erfundene Figuren.
  use ExUnit.Case, async: true

  alias Worker.Jack.StageKopie

  @sl "100000000000000001"
  @a "100000000000000002"

  defp roh(ueber \\ %{}) do
    Map.merge(
      %{
        kampagne: %{
          id: "k1",
          name: "Die Werkstatt",
          icon_url: nil,
          theme_blurb: "Ein Uhrmacher verschwindet.",
          flavors: %{"base" => "trocken", "summary" => "  "},
          vorgaben: %{"summary" => %{name: "Protokoll", darstellungsform: "fliesstext"}}
        },
        mitglieder: [
          %{discord_id: @sl, role: :spielleiter, character_name: "Spielleiter"},
          %{discord_id: @a, role: :spieler, character_name: "Mira"}
        ],
        sitzung: %{
          id: "s3",
          campaign_id: "k1",
          number: 3,
          name: "Session 3",
          scheduled_for: nil,
          started_at: ~U[2026-08-23 18:00:00Z]
        },
        utterances: [
          %{
            id: "u1",
            discord_id: @sl,
            timestamp: ~U[2026-08-23 18:06:13.073Z],
            text: "Ihr steht im Regen.",
            confidence: %{mean_p: 0.9},
            status: :confirmed
          },
          %{
            id: "u2",
            discord_id: @a,
            timestamp: ~U[2026-08-23 18:06:20.000Z],
            text: "Ich klopfe.",
            confidence: nil,
            status: :confirmed
          }
        ]
      },
      ueber
    )
  end

  defp kinds(payloads), do: Enum.map(payloads, & &1["kind"])

  test "Reihenfolge: Kampagne, Spieler, Aliase, Vorgaben, Töne, Sitzung, Utterances, Ende" do
    assert {:ok, p} = StageKopie.ereignisse(roh())

    assert kinds(p) == ~w(CampaignCreated UserUpserted UserUpserted AdminMemberAdded
                          CampaignAliasSet CampaignAliasSet CampaignVorgabeSet CampaignFlavorSet
                          SessionScheduled SessionStarted UtteranceAppended UtteranceAppended
                          SessionEnded)
  end

  test "Spielleiter ist der Ersteller und bekommt kein AdminMemberAdded (sonst Reset auf :spieler)" do
    {:ok, p} = StageKopie.ereignisse(roh())
    [created | _] = p

    assert created["owner_discord_id"] == @sl
    assert created["owner_display_name"] == "Spielleiter"

    assert for(%{"kind" => "AdminMemberAdded"} = e <- p, do: e["discord_id"]) == [@a]
  end

  test "Anzeigenamen sind die Aliase, nie Discord-IDs oder Handles" do
    {:ok, p} = StageKopie.ereignisse(roh())

    namen = for %{"display_name" => n} <- p, do: n
    assert Enum.sort(Enum.uniq(namen)) == ["Mira", "Spielleiter"]

    assert for(
             %{"kind" => "CampaignAliasSet"} = e <- p,
             do: {e["discord_id"], e["character_name"]}
           ) ==
             [{@sl, "Spielleiter"}, {@a, "Mira"}]
  end

  test "Utterances behalten ID, Sprecher, Zeit und Text; Konfidenz als JSON" do
    {:ok, p} = StageKopie.ereignisse(roh())
    [u1, u2] = for %{"kind" => "UtteranceAppended"} = e <- p, do: e

    assert u1["id"] == "u1"
    assert u1["session_id"] == "s3"
    assert u1["discord_id"] == @sl
    assert u1["timestamp"] == "2026-08-23T18:06:13.073Z"
    assert u1["text"] == "Ihr steht im Regen."
    assert u1["confidence"] == %{"mean_p" => 0.9}
    assert u1["status"] == "confirmed"
    assert u2["confidence"] == nil
  end

  test "Sitzung behält Nummer und Namen; leere Töne fallen weg" do
    {:ok, p} = StageKopie.ereignisse(roh())
    [sched] = for %{"kind" => "SessionScheduled"} = e <- p, do: e

    assert {sched["number"], sched["name"], sched["scheduled_for"]} ==
             {3, "Session 3", "2026-08-23T18:00:00Z"}

    assert for(%{"kind" => "CampaignFlavorSet"} = e <- p, do: e["slot"]) == ["base"]

    assert [%{"stage" => "summary", "name" => "Protokoll"}] =
             for(%{"kind" => "CampaignVorgabeSet"} = e <- p, do: e)
  end

  test "kein Pipeline-Auslöser" do
    {:ok, p} = StageKopie.ereignisse(roh())
    refute "UtterancesTranscribed" in kinds(p)
  end

  test "Fehler: Mitglied ohne Alias, Sprecher ohne Mitgliedschaft, Spielleiter, leere Sitzung" do
    ohne_alias = [
      %{discord_id: @sl, role: :spielleiter, character_name: "Spielleiter"},
      %{discord_id: @a, role: :spieler, character_name: " "}
    ]

    assert {:error, {:mitglieder_ohne_alias, [@a]}} =
             StageKopie.ereignisse(roh(%{mitglieder: ohne_alias}))

    nur_sl = [%{discord_id: @sl, role: :spielleiter, character_name: "Spielleiter"}]

    assert {:error, {:sprecher_ohne_mitgliedschaft, [@a]}} =
             StageKopie.ereignisse(roh(%{mitglieder: nur_sl}))

    keiner = [
      %{discord_id: @sl, role: :spieler, character_name: "Spielleiter"},
      %{discord_id: @a, role: :spieler, character_name: "Mira"}
    ]

    assert {:error, {:kein_spielleiter}} = StageKopie.ereignisse(roh(%{mitglieder: keiner}))

    zwei = Enum.map(keiner, &%{&1 | role: :spielleiter})
    assert {:error, {:mehrere_spielleiter, 2}} = StageKopie.ereignisse(roh(%{mitglieder: zwei}))

    assert {:error, :keine_utterances} = StageKopie.ereignisse(roh(%{utterances: []}))
  end
end
