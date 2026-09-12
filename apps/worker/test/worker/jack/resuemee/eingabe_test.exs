defmodule Worker.Jack.Resuemee.EingabeTest do
  @moduledoc """
  J5 (#1209, B1): die Eingabe des Resümee-Jack aus Mnesia — Fakten dieser und
  früherer Sitzungen, Bögen, vorige Resümees und Gedanken, Mitschnitt,
  Überschrift und Ton. Fixtures über den Materializer (Muster
  `materializer_jack_stand_test.exs`).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Jack.Resuemee.{Eingabe, Lesen, Stand}
  alias Worker.Materializer

  @cid "camp-resuemee-1209"
  @s1 "#{@cid}-s1"
  @s2 "#{@cid}-s2"
  @s3 "#{@cid}-s3"
  @uhrmacher "Der verschwundene Uhrmacher"
  @arnheim "Die Familie von Arnheim"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1], apply: true)

    smooth!(@s1, ["Die Gruppe betritt die Werkstatt."], 1000)

    smooth!(
      @s2,
      [
        "Ihr steht im Regen vor der Werkstatt am Hafen.",
        "Der Alte zeigt euch eine Spieldose.",
        "Das Wappen gehört der Familie von Arnheim.",
        "Nach zwei Tagen erreicht ihr die Salzminen."
      ],
      1001
    )

    facts!(@s1, [fakt("f_1", "Tess nimmt den Auftrag an.", [@uhrmacher], ["#{@s1}-b0"])], 1010)

    facts!(
      @s2,
      [
        fakt("f_2a", "Der Alte zeigt eine Spieldose.", [@uhrmacher], ["#{@s2}-b1"]),
        fakt("f_2b", "Das Wappen gehört den Arnheims.", [@arnheim], ["#{@s2}-b2", "fremd"]),
        Map.put(fakt("f_2c", "Ungeprüft.", [], ["#{@s2}-b3"]), "verified?", false)
      ],
      1011
    )

    facts!(@s3, [fakt("f_3", "Später.", [@uhrmacher], ["#{@s3}-b0"])], 1012)

    registry!(%{Worker.ThreadOverride.normalize(@arnheim) => "context"}, 1020)
    summary!(@s1, "Die Gruppe nimmt den Auftrag an.", 1030)
    summary!(@s3, "Später.", 1031)

    apply!("JackStandAbgelegt", 1040, %{
      "session_id" => @s1,
      "campaign_id" => @cid,
      "stand" => %{
        "aussagen" => [],
        "fortsetzung" => %{
          "register" => [
            %{
              "abschnitt" => "FIGUREN",
              "schluessel" => "Tess",
              "zeile" => "Spielfigur",
              "bloecke" => [0]
            }
          ]
        },
        "bloecke" => ["#{@s1}-b0"]
      }
    })

    # B4: der Stand des Resümee-Jack zu Sitzung 1 — seine Notizen sind die
    # „vorigen Gedanken“ für Sitzung 2.
    apply!("JackResuemeeStandAbgelegt", 1041, %{
      "session_id" => @s1,
      "campaign_id" => @cid,
      "stand" => %{
        "notizen" => [
          %{
            "abschnitt" => "FORM",
            "schluessel" => "Form",
            "zeile" => "Rückblick in drei Absätzen",
            "fakten" => [],
            "boegen" => []
          }
        ],
        "entwurf" => [],
        "satzquellen" => [],
        "zaehlwerte" => %{},
        "modell" => "test-modell",
        "zeitpunkt" => "2026-09-13T10:00:00Z"
      }
    })

    # Ein Alt-Event mit Darstellungsform — bleibt lesbar, die Form liest keiner.
    apply!("CampaignVorgabeSet", 1050, %{
      "campaign_id" => @cid,
      "stage" => "summary",
      "name" => "Rückblick",
      "darstellungsform" => "fliesstext"
    })

    apply!("CampaignFlavorSet", 1051, %{
      "campaign_id" => @cid,
      "slot" => "base",
      "flavor" => "Düster"
    })

    apply!("CampaignFlavorSet", 1052, %{
      "campaign_id" => @cid,
      "slot" => "summary",
      "flavor" => "Knapp"
    })

    :ok
  end

  defp apply!(kind, seq, payload),
    do: Materializer.apply_event(event(kind, payload, seq, event_id: "rj-#{seq}"))

  defp smooth!(sid, texte, seq) do
    blocks =
      for {text, i} <- Enum.with_index(texte) do
        %{
          "id" => "#{sid}-b#{i}",
          "speaker_discord_id" => "did-owner",
          "text" => text,
          "quell_utterance_ids" => ["#{sid}-u#{i + 1}"],
          "hat_luecke" => false
        }
      end

    apply!("TranscriptSmoothed", seq, %{
      "session_id" => sid,
      "campaign_id" => @cid,
      "smoothed_at" => "2026-09-12T08:00:00Z",
      "blocks" => blocks,
      "ooc_verworfen" => [],
      "rules_version" => 7,
      "merge_gap_seconds" => 8
    })
  end

  defp fakt(id, claim, threads, refs) do
    %{
      "id" => id,
      "claim" => claim,
      "threads" => threads,
      "source_refs" => refs,
      "fact_type" => "ereignis",
      "narration_time" => "present",
      "verified?" => true
    }
  end

  defp facts!(sid, facts, seq),
    do:
      apply!("SessionFactsExtracted", seq, %{
        "session_id" => sid,
        "campaign_id" => @cid,
        "facts" => facts
      })

  defp registry!(kinds, seq),
    do:
      apply!("ThreadRegistryComputed", seq, %{
        "campaign_id" => @cid,
        "cluster_map" => %{},
        "kinds" => kinds
      })

  defp summary!(sid, md, seq) do
    apply!("SessionSummaryGenerated", seq, %{
      "session_id" => sid,
      "campaign_id" => @cid,
      "content_md" => md,
      "source" => "llm",
      "flagged_claims" => []
    })
  end

  test "Sitzung 2: Fakten dieser und früherer Sitzungen, Bögen, Vorgeschichte, Überschrift, Ton" do
    assert {:ok, e} = Eingabe.aus_repo(@s2)

    assert e.sitzung == %{id: @s2, nummer: 2, name: "Session 2"}

    # Nur geprüfte Fakten; Blocknummern aus der Kontextliste der Sitzung.
    assert [
             %{id: "S2-F1", fakt_id: "f_2a", bloecke: [1], ohne_block: 0} = f1,
             %{id: "S2-F2", fakt_id: "f_2b", bloecke: [2], ohne_block: 1} = f2
           ] = e.fakten

    assert f1.boegen == [%{titel: @uhrmacher, art: "arc"}]
    assert f2.boegen == [%{titel: @arnheim, art: "context"}]

    assert [
             %{titel: @uhrmacher, art: "arc", status: "offen", fakten: ["S2-F1"]},
             %{titel: @arnheim, art: "context"}
           ] =
             e.boegen

    # Früher heißt: kleinere Nummer — Sitzung 3 bleibt draußen.
    assert [%{nummer: 1, name: "Session 1", fakten: [%{id: "S1-F1", bloecke: []}]}] = e.fruehere

    assert e.vorige_resuemees == [
             %{nummer: 1, name: "Session 1", text: "Die Gruppe nimmt den Auftrag an."}
           ]

    assert [
             %{
               nummer: 1,
               fakten_jack: [%{"abschnitt" => "FIGUREN", "schluessel" => "Tess"}],
               resuemee_jack: %{"notizen" => [%{"zeile" => "Rückblick in drei Absätzen"}]}
             }
           ] = e.vorige_gedanken

    assert e.ueberschrift == "Rückblick"
    assert e.flavor == %{base: "Düster", summary: "Knapp"}

    # Der Mitschnitt wie beim Fakten-Jack: Sprecher mit Namen, nie eine Discord-ID.
    assert length(e.bloecke) == 4
    assert Enum.all?(e.bloecke, &(is_binary(&1.sprecher) and &1.sprecher != "did-owner"))
    assert @uhrmacher in e.straenge and @arnheim in e.straenge

    # Der reine Kern arbeitet damit.
    s = Stand.neu(e)
    {_s, {:ok, t}} = Lesen.vorige_gedanken(s, %{"sitzung" => 1})
    assert t =~ "Tess — Spielfigur"
    # B4: die Notizen des Resümee-Jack zu Sitzung 1 stehen darunter.
    assert t =~ "Rückblick in drei Absätzen"
    refute t =~ "(keine abgelegt)"
  end

  test "ohne abgelegten Stand des Resümee-Jack: resuemee_jack ist nil, das Werkzeug sagt es" do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.jack_resuemee_staende())

    assert {:ok, e} = Eingabe.aus_repo(@s2)
    assert [%{nummer: 1, resuemee_jack: nil}] = e.vorige_gedanken

    {_s, {:ok, t}} = Lesen.vorige_gedanken(Stand.neu(e), %{"sitzung" => 1})
    assert t =~ "(keine abgelegt)"
  end

  test "die erste Sitzung hat keine Vorgeschichte — die Werkzeuge sagen es neutral" do
    assert {:ok, e} = Eingabe.aus_repo(@s1)

    assert e.fruehere == []
    assert e.vorige_resuemees == []
    assert e.vorige_gedanken == []

    assert {_s,
            {:ok,
             "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."}} =
             Lesen.vorige_resuemees(Stand.neu(e), %{})
  end

  test "ohne Sitzung oder ohne Glättung: Fehler" do
    assert {:error, :keine_sitzung} = Eingabe.aus_repo("gibt-es-nicht")
    assert {:error, {:extraction, {:jack, :keine_glaettung}}} = Eingabe.aus_repo(@s3)
  end

  test "Überschrift: ohne Vorgabe „Resümee“" do
    assert Eingabe.ueberschrift(%{vorgaben: %{}}) == "Resümee"
    assert Eingabe.ueberschrift(%{vorgaben: %{"summary" => %{name: "  "}}}) == "Resümee"

    assert Eingabe.ueberschrift(%{vorgaben: %{"summary" => %{name: " Stichpunkte "}}}) ==
             "Stichpunkte"
  end
end
