defmodule Worker.GlattAnsichtTest do
  @moduledoc """
  Issue #1198: der Scope `campaign_glatt_ansicht` liefert die Geglättet-Spalte
  so, wie sie angezeigt wird — nur das Fenster, dafür mit Text.

  Die Filter- und Fensterregeln lebten bis #1198 im Hub
  (`Components.glatt_view_for/2`, `glatt_blocks/2`, `window_slice/3`). Diese
  Tests halten fest, dass der Worker dieselben Antworten gibt — und dass er
  nie mehr als ein Fenster schickt.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Repo.{GlattAnsicht, Luecken}

  @cid "glatt-ansicht-camp"
  @other "glatt-ansicht-other"
  @owner "did-owner-ga"
  @member "did-member-ga"
  @stranger "did-stranger-ga"
  @s1 "#{@cid}-s1"
  @s2 "#{@cid}-s2"

  # S1: 250 Blöcke, jeder fünfte mit Lücke (50). Block 5 wird bestätigt,
  # Block 10 als unbrauchbar markiert — bleiben 48 kuratierbare.
  @gross 250
  @klein 5

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      owner_did: @owner,
      members: [@member],
      sessions: [@gross, @klein],
      apply: true
    )

    build_campaign(
      campaign_id: @other,
      owner_did: @stranger,
      sessions: [3],
      base_seq: 50_000,
      apply: true
    )

    smooth!(@s1, @gross, fn i -> rem(i, 5) == 0 end, 40_000)
    smooth!(@s2, @klein, fn _ -> false end, 40_001)
    kuriere!(@s1, 5, "bestaetigt", 40_002)
    kuriere!(@s1, 10, "unbrauchbar", 40_003)

    :ok
  end

  defp smooth!(sid, n, luecke?, seq) do
    blocks =
      for i <- 1..n//1 do
        %{
          "id" => "#{sid}-b#{i}",
          "speaker_discord_id" => @owner,
          "text" => "Block #{i} geglättet",
          "quell_utterance_ids" => ["#{sid}-u#{i}"],
          "hat_luecke" => luecke?.(i)
        }
      end

    Materializer.apply_event(
      event(
        "TranscriptSmoothed",
        %{
          "session_id" => sid,
          "campaign_id" => @cid,
          "smoothed_at" => "2026-09-10T08:00:00Z",
          "blocks" => blocks,
          "ooc_verworfen" => [],
          "rules_version" => 7,
          "merge_gap_seconds" => 8
        },
        seq,
        event_id: "ga-sm-#{sid}"
      )
    )
  end

  defp kuriere!(sid, i, status, seq) do
    Materializer.apply_event(
      event(
        "LueckenKurationSet",
        %{
          "session_id" => sid,
          "campaign_id" => @cid,
          "block_id" => "#{sid}-b#{i}",
          "status" => status,
          "bestaetigter_text" => "von Hand",
          "quell_utterance_ids" => ["#{sid}-u#{i}"],
          "set_by" => @member
        },
        seq,
        event_id: "ga-lk-#{i}"
      )
    )
  end

  defp lies(extra \\ %{}) do
    Repo.snapshot(
      Map.merge(
        %{"kind" => "campaign_glatt_ansicht", "id" => @cid, "viewer_discord_id" => @member},
        extra
      )
    )
  end

  defp sitzung(antwort, sid), do: Enum.find(antwort["glatt_ansicht"], &(&1["session_id"] == sid))
  defp nummern(sitzung), do: Enum.map(sitzung["blocks"], &block_nr/1)
  defp block_nr(b), do: b["block_id"] |> String.split("-b") |> List.last() |> String.to_integer()

  defp wunsch(sid, w), do: %{"sitzungen" => %{sid => w}}

  describe "Zugang" do
    test "Nicht-Mitglied bekommt nichts" do
      assert Repo.snapshot(%{
               "kind" => "campaign_glatt_ansicht",
               "id" => @cid,
               "viewer_discord_id" => @stranger
             }) == %{"forbidden" => true}
    end
  end

  describe "Ansicht und Zähler" do
    test "ohne Wunsch: kuratieren, solange es Kuratierbares gibt, sonst einfach" do
      antwort = lies()

      assert sitzung(antwort, @s1)["ansicht"] == "kuratieren"
      assert sitzung(antwort, @s1)["ansicht_auto"] == "kuratieren"
      assert sitzung(antwort, @s2)["ansicht"] == "einfach"
    end

    test "die drei Zahlen, die der Hub zeigt" do
      s1 = sitzung(lies(), @s1)

      assert s1["block_count"] == @gross
      # 50 Lücken, eine bestätigt, eine unbrauchbar.
      assert s1["kuratieren_count"] == 48
      assert s1["gefiltert_total"] == 48
    end

    test "die drei Filter entsprechen den bisherigen Hub-Filtern" do
      kur =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "kuratieren", "fenster" => %{"tail" => 200}})),
          @s1
        )

      assert nummern(kur) == for(i <- 15..250//5, do: i)

      einf =
        sitzung(
          lies(
            wunsch(@s1, %{"ansicht" => "einfach", "fenster" => %{"from" => 0, "count" => 12}})
          ),
          @s1
        )

      assert einf["gefiltert_total"] == @gross - 1
      assert nummern(einf) == Enum.to_list(1..9) ++ [11, 12, 13]

      alles =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => 0, "count" => 12}})),
          @s1
        )

      assert alles["gefiltert_total"] == @gross
      assert nummern(alles) == Enum.to_list(1..12)
    end

    test "eine unbekannte Ansicht fällt auf den Auto-Vorschlag zurück" do
      assert sitzung(lies(wunsch(@s1, %{"ansicht" => "quatsch"})), @s1)["ansicht"] == "kuratieren"
    end
  end

  describe "Fenster" do
    test "Tail: die letzten n der gefilterten Liste" do
      s1 = sitzung(lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"tail" => 5}})), @s1)

      assert s1["from"] == 245
      assert nummern(s1) == Enum.to_list(246..250)
    end

    # #1204: 50 statt 150 — im Lesen-Modus ist diese Spalte fast der ganze Render.
    test "ohne Fenster: Tail 50" do
      s1 = sitzung(lies(wunsch(@s1, %{"ansicht" => "alles"})), @s1)

      assert s1["from"] == 200
      assert length(s1["blocks"]) == 50
    end

    test "from/count wird auf die Liste geklemmt" do
      spaet =
        sitzung(
          lies(
            wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => 248, "count" => 50}})
          ),
          @s1
        )

      assert spaet["from"] == 248
      assert nummern(spaet) == [249, 250]

      negativ =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => -3, "count" => 2}})),
          @s1
        )

      assert negativ["from"] == 0
      assert nummern(negativ) == [1, 2]
    end

    test "nie mehr als 200 Blöcke, auch wenn mehr verlangt wird" do
      viel =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => 0, "count" => 999}})),
          @s1
        )

      assert length(viel["blocks"]) == GlattAnsicht.max_fenster()

      tail =
        sitzung(lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"tail" => 999}})), @s1)

      assert length(tail["blocks"]) == GlattAnsicht.max_fenster()
    end

    test "ein kaputtes Fenster crasht nicht, sondern bekommt den Tail" do
      s1 = sitzung(lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => "kaputt"})), @s1)
      assert s1["from"] == 200
    end
  end

  describe "Inhalt" do
    test "jeder gelieferte Block trägt den vollen Feldsatz mit Text" do
      alle = Enum.sort(Luecken.text_keys() ++ Luecken.skelett_keys())

      s1 =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => 0, "count" => 3}})),
          @s1
        )

      for b <- s1["blocks"], do: assert(Enum.sort(Map.keys(b)) == alle)

      [erster | _] = s1["blocks"]
      assert erster["text"] == "Block 1 geglättet"
      assert erster["roh_text"] == "Utterance 1 in #{@s1}"
    end

    test "Kuration steht am Block: Status und Override" do
      s1 =
        sitzung(
          lies(wunsch(@s1, %{"ansicht" => "alles", "fenster" => %{"from" => 4, "count" => 1}})),
          @s1
        )

      assert [%{"status" => "bestaetigt", "override" => %{"set_by" => @member}}] = s1["blocks"]
    end

    test "der Kopf ist derselbe wie im alten Scope" do
      [alt] =
        Enum.filter(Repo.smoothed_for_campaign(@cid, fenster: true), &(&1["session_id"] == @s2))

      neu = sitzung(lies(), @s2)

      assert Map.drop(alt, ["blocks"]) ==
               Map.take(neu, Map.keys(alt) -- ["blocks"])
    end
  end

  describe "nur" do
    test "liefert nur die angefragten Sessions und nennt sie im Echo" do
      antwort = lies(%{"nur" => [@s2]})

      assert Enum.map(antwort["glatt_ansicht"], & &1["session_id"]) == [@s2]
      assert antwort["nur"] == [@s2]
    end

    test "eine fremde Session lässt sich so nicht lesen" do
      antwort = lies(%{"nur" => ["#{@other}-s1"]})
      assert antwort["glatt_ansicht"] == []
    end

    test "ohne nur: alle Sessions, Echo nil" do
      antwort = lies()
      assert Enum.map(antwort["glatt_ansicht"], & &1["session_id"]) == [@s1, @s2]
      assert antwort["nur"] == nil
    end
  end

  describe "Marker" do
    test "trägt den kampagnenweiten 🕳-Marker, auch bei einer Teilantwort" do
      Materializer.apply_event(
        event(
          "SessionSummaryGenerated",
          %{
            "session_id" => @s1,
            "campaign_id" => @cid,
            "content_md" => "Resümee",
            "source" => "llm",
            "source_refs" => ["#{@s1}-b15"]
          },
          40_010,
          event_id: "ga-sum"
        )
      )

      assert lies(%{"nur" => [@s2]})["luecken_marker"] == ["summary:#{@s1}"]
    end
  end
end
