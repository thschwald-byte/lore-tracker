defmodule Worker.Jack.AbzugTest do
  # Ohne Prod: erfundene IDs, erfundene Handles, erfundene Figuren.
  use ExUnit.Case, async: true

  alias Worker.Jack.Abzug

  @sl "100000000000000001"
  @a "100000000000000002"
  @b "100000000000000003"

  defp roh(ueber \\ %{}) do
    Map.merge(
      %{
        bloecke: [
          %{
            "id" => "b_1",
            "speaker_discord_id" => @sl,
            "text" => "Ihr steht im Regen.",
            "hat_luecke" => false,
            "quell_utterance_ids" => ["u1"]
          },
          %{
            "id" => "b_2",
            "speaker_discord_id" => @a,
            "text" => "Ich klopfe.",
            "hat_luecke" => true,
            "asr_unsicher" => true
          },
          %{"id" => "b_3", "speaker_discord_id" => @b, "text" => "Ich warte."}
        ],
        spielleiter: @sl,
        figuren: %{@a => "Mira"},
        roster: ["Mira", "Der Uhrmacher", "nutzer_b7"],
        straenge: ["Die Werkstatt", "", "Die Werkstatt"],
        fakten: [%{"claim" => "x"}],
        meta: %{"session_id" => "s1"}
      },
      ueber
    )
  end

  @namen %{@b => "Brann", "nutzer_b7" => "Brann"}

  test "die Namensdatei: Kommentare und Leerzeilen zählen nicht, eine halbe Zeile ist ein Fehler" do
    assert {:ok, %{"x" => "Mira", @b => "Brann"}} =
             Abzug.namen_aus_text("# Kommentar\n\nx\tMira\n#{@b}\t Brann \n")

    assert {:error, {:namenszeile, 2}} = Abzug.namen_aus_text("x\tMira\nnur_ein_feld\n")
  end

  test "aufbereiten: Sprecher und Roster auf Figuren, keine ID und kein Handle im Ergebnis" do
    assert {:ok, d} = Abzug.aufbereiten(roh(), @namen)

    assert Enum.map(d["bloecke"], &{&1["nummer"], &1["sprecher"]}) ==
             [{0, "Spielleiter"}, {1, "Mira"}, {2, "Brann"}]

    assert %{
             "block_id" => "b_2",
             "hat_luecke" => true,
             "asr_unsicher" => true,
             "quell_utterance_ids" => []
           } =
             Enum.at(d["bloecke"], 1)

    assert d["cast"] == ["Mira", "Der Uhrmacher", "Brann"]
    assert d["straenge"] == ["Die Werkstatt"]
    assert d["meta"]["bloecke"] == 3
    assert d["meta"]["sprecher"] == ["Spielleiter", "Mira", "Brann"]

    json = Jason.encode!(Map.take(d, ["bloecke", "cast", "meta"]))
    refute json =~ @sl or json =~ @a or json =~ @b or json =~ "nutzer_b7"
  end

  test "ein Sprecher ohne Namen und ein Handle im Roster sind Fehler, kein Durchlassen" do
    assert {:error, {:sprecher_ohne_namen, [@b]}} =
             Abzug.aufbereiten(roh(), %{"nutzer_b7" => "Brann"})

    assert {:error, {:roster_handles, ["nutzer_b7"]}} = Abzug.aufbereiten(roh(), %{@b => "Brann"})
  end

  @tag :tmp_dir
  test "ablegen und laden; eine Discord-ID als Sprecher lässt das Laden scheitern", %{
    tmp_dir: dir
  } do
    {:ok, d} = Abzug.aufbereiten(roh(), @namen)
    :ok = Abzug.schreiben(dir, d)
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(Path.join(dir, "bloecke.json")).mode |> Bitwise.band(0o777) == 0o600

    assert {:ok, a} = Abzug.laden(dir)

    assert hd(a.bloecke) == %{
             text: "Ihr steht im Regen.",
             sprecher: "Spielleiter",
             block_id: "b_1"
           }

    s = Abzug.stand(a, phase: 2)
    assert {s.max_block, s.phase, s.cast} == {2, 2, ["Mira", "Der Uhrmacher", "Brann"]}

    kaputt = put_in(d, ["bloecke", Access.at(0), "sprecher"], @sl)
    :ok = Abzug.schreiben(dir, kaputt)
    assert {:error, {:discord_id_als_sprecher, 1}} = Abzug.laden(dir)

    File.rm!(Path.join(dir, "cast.json"))
    assert {:error, {:abzug_unvollstaendig, _}} = Abzug.laden(dir)
  end
end
