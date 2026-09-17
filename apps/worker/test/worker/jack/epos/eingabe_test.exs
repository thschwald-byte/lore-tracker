defmodule Worker.Jack.Epos.EingabeTest do
  @moduledoc """
  J6 (#1210, E1): die Eingabe des Epos-Jack aus Mnesia — die Lesebasis des
  Resümee-Jack, dazu Überschrift und Ton der Epos-Spalte aus „Stil setzen“
  und der Weg aus dem abgelegten Resümee-Stand. Fixtures über
  den Materializer (Muster `resuemee/eingabe_test.exs`).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Jack.Epos.{Eingabe, Weg}
  alias Worker.Jack.Resuemee.{Stand, Suche}
  alias Worker.Materializer

  @cid "camp-epos-1210"
  @s1 "#{@cid}-s1"
  @s2 "#{@cid}-s2"
  @uhrmacher "Der verschwundene Uhrmacher"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1, 1], apply: true)

    smooth!(@s1, ["Tess liest den Brief."], 1000)

    smooth!(
      @s2,
      [
        "Ihr steht im Regen vor der Werkstatt.",
        "Der Alte zeigt euch eine Spieldose.",
        "Nach zwei Tagen erreicht ihr die Salzminen."
      ],
      1001
    )

    facts!(@s1, [fakt("f_1", "Tess nimmt den Auftrag an.", ["#{@s1}-b0"])], 1010)

    facts!(
      @s2,
      [
        fakt("f_2a", "Die Gruppe steht im Regen vor der Werkstatt.", ["#{@s2}-b0"]),
        fakt("f_2b", "Der Alte zeigt eine Spieldose.", ["#{@s2}-b1"]),
        fakt("f_2c", "Die Gruppe erreicht die Salzminen.", ["#{@s2}-b2"])
      ],
      1011
    )

    summary!(
      @s2,
      "Die Gruppe erreicht im Regen die Werkstatt.\n\nDer Alte zeigt die Spieldose.",
      1030
    )

    # Der abgelegte Stand des Resümee-Jack zu Sitzung 2: sein Weg und die
    # Satzquellen, an denen die Eingabe prüft, ob der Weg noch passt.
    resuemee_stand!([%{"fakten" => ["S2-F1", "S1-F1"], "fakt_ids" => ["f_2a", "f_1"]}], 1040)

    apply!("CampaignVorgabeSet", 1050, %{
      "campaign_id" => @cid,
      "stage" => "epos",
      "name" => " Heldenlied "
    })

    for {slot, ton, seq} <- [
          {"base", "Düster", 1051},
          {"epos", "Nah an der Gruppe", 1052},
          {"summary", "Knapp", 1053}
        ] do
      apply!("CampaignFlavorSet", seq, %{"campaign_id" => @cid, "slot" => slot, "flavor" => ton})
    end

    :ok
  end

  defp apply!(kind, seq, payload),
    do: Materializer.apply_event(event(kind, payload, seq, event_id: "ej-#{seq}"))

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
      "smoothed_at" => "2026-09-13T08:00:00Z",
      "blocks" => blocks,
      "ooc_verworfen" => [],
      "rules_version" => 7,
      "merge_gap_seconds" => 8
    })
  end

  defp fakt(id, claim, refs) do
    %{
      "id" => id,
      "claim" => claim,
      "threads" => [@uhrmacher],
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

  defp summary!(sid, md, seq) do
    apply!("SessionSummaryGenerated", seq, %{
      "session_id" => sid,
      "campaign_id" => @cid,
      "content_md" => md,
      "source" => "llm",
      "flagged_claims" => []
    })
  end

  defp resuemee_stand!(satzquellen, seq) do
    notiz = fn a, k, zeile, fakten, boegen ->
      %{
        "abschnitt" => a,
        "schluessel" => k,
        "zeile" => zeile,
        "fakten" => fakten,
        "boegen" => boegen
      }
    end

    apply!("JackResuemeeStandAbgelegt", seq, %{
      "session_id" => @s2,
      "campaign_id" => @cid,
      "stand" => %{
        "notizen" => [
          notiz.("FORM", "Form", "Rückblick in wenigen Absätzen", [], []),
          notiz.("GLIEDERUNG", "1", "Ankunft im Regen", ["S2-F1"], [@uhrmacher]),
          notiz.("GLIEDERUNG", "2", "die Spieldose", ["S2-F2"], []),
          notiz.("OFFEN", "Zeit", "wie lange die Reise dauert", [], [])
        ],
        "entwurf" => [],
        "satzquellen" => satzquellen,
        "zaehlwerte" => %{},
        "modell" => "test-modell",
        "zeitpunkt" => "2026-09-13T10:00:00Z"
      }
    })
  end

  test "Sitzung 2: die Lesebasis, dazu Stil des Epos und der Weg aus dem Resümee" do
    assert {:ok, e} = Eingabe.aus_repo(@s2)

    assert e.art == :epos
    assert e.ueberschrift == "Heldenlied"
    assert e.flavor == %{base: "Düster", epos: "Nah an der Gruppe"}
    # Eine Länge hat das Kapitel nicht (Maintainer, 13.09.2026).
    refute Map.has_key?(e, :max_woerter)
    refute Map.has_key?(e, :mindest_woerter)

    # Die Lesebasis des Resümee-Jack.
    assert [%{id: "S2-F1", fakt_id: "f_2a"}, %{id: "S2-F2"}, %{id: "S2-F3"}] = e.fakten
    assert [%{nummer: 1, fakten: [%{id: "S1-F1"}]}] = e.fruehere
    assert is_function(e.mitschnitt_laden, 1)

    # Das Resümee dieser Sitzung und sein Weg (nur die GLIEDERUNG).
    assert e.resuemee_diese ==
             "Die Gruppe erreicht im Regen die Werkstatt.\n\nDer Alte zeigt die Spieldose."

    assert e.resuemee_weg == [
             %{
               schluessel: "1",
               zeile: "Ankunft im Regen",
               fakten: ["S2-F1"],
               boegen: [@uhrmacher]
             },
             %{schluessel: "2", zeile: "die Spieldose", fakten: ["S2-F2"], boegen: []}
           ]

    # Durchgereicht bis zu den Werkzeugen und in den Auftrag.
    s = Stand.neu(e)
    assert s.art == :epos
    assert length(Weg.pflicht(s)) == 2

    {_s, {:ok, t}} = Weg.resuemee(s, %{})
    assert t =~ "Der Alte zeigt die Spieldose."
    assert t =~ "Station „1“ — Ankunft im Regen  (noch offen)"

    {_s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "Spieldose"})
    assert t =~ "Resümee S2, Absatz 2 · Der Alte zeigt die Spieldose."

    assert Stand.ton(s.flavor, :epos) ==
             "**Grundton der Kampagne:** Düster\n\n**Ton des Epos:** Nah an der Gruppe"

    assert {:ok, a} = Worker.Jack.Epos.auftrag(e)
    assert a =~ "heißt **„Heldenlied“**"
    assert a =~ "in 2 Stationen fest"
    assert a =~ "**Ton des Epos:** Nah an der Gruppe"
    refute a =~ "Knapp"
    refute a =~ "{{"
  end

  test "ohne abgelegten Resümee-Stand: kein Weg, laut im Log, das Werkzeug sagt es" do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.jack_resuemee_staende())

    {{:ok, e}, log} = with_log(fn -> Eingabe.aus_repo(@s2) end)

    assert e.resuemee_weg == []
    assert log =~ "zu Sitzung 2 liegt kein abgelegter Stand des Resümee-Jack vor"

    {_s, {:ok, t}} = Weg.resuemee(Stand.neu(e), %{})
    assert t =~ "Der Alte zeigt die Spieldose."
    assert t =~ "Aus dem Resümee liegt kein Weg der Gruppe vor."
  end

  test "ein veralteter Weg wird nicht benutzt — nur Fakten dieser Sitzung zählen dafür" do
    # Ein früherer Fakt mit anderer echter ID macht den Weg nicht ungültig.
    resuemee_stand!([%{"fakten" => ["S1-F1"], "fakt_ids" => ["f_irgendwo"]}], 1060)
    assert {:ok, %{resuemee_weg: [_, _]}} = Eingabe.aus_repo(@s2)

    # S2-F1 zeigt heute auf einen anderen Fakt als beim Resümee-Lauf.
    resuemee_stand!([%{"fakten" => ["S2-F1"], "fakt_ids" => ["f_anders"]}], 1061)
    {{:ok, e}, log} = with_log(fn -> Eingabe.aus_repo(@s2) end)

    assert e.resuemee_weg == []
    assert log =~ "passt nicht mehr zum Faktenbestand (S2-F1"
  end

  test "Überschrift: ohne Vorgabe der Epos-Spalte „Epos“; Ton ohne Vorgabe nil" do
    assert Eingabe.ueberschrift(%{vorgaben: %{}}) == "Epos"
    assert Eingabe.ueberschrift(%{vorgaben: %{"summary" => %{name: "Rückblick"}}}) == "Epos"
    assert Eingabe.ueberschrift(%{vorgaben: %{"epos" => %{name: "  "}}}) == "Epos"

    assert Eingabe.ueberschrift(%{vorgaben: %{"epos" => %{name: " Chronik des Hauses "}}}) ==
             "Chronik des Hauses"

    assert Eingabe.flavor(%{}) == %{base: nil, epos: nil}
  end

  test "ohne Sitzung: der Fehler der Lesebasis" do
    assert {:error, :keine_sitzung} = Eingabe.aus_repo("gibt-es-nicht")
    assert {:error, :keine_sitzung} = Worker.Jack.Epos.kapitel("gibt-es-nicht")
  end

  # E2 (#1210): das Kapitel einer Sitzung aus dem Repo — Überblick, dann
  # Schreiben, mit einem Stub-Modell. Die Quellen führen über die Szene zu den
  # echten Fakt-IDs.
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      with [%{role: :system}, %{role: :user, content: auftrag}] <- nachrichten,
           do: send(Keyword.fetch!(opts, :test), {:sitzung, auftrag})

      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
             [kopf | rest] -> {kopf, rest}
             [] -> {nil, []}
           end) do
        nil -> raise "Skript erschöpft"
        schritt -> {:ok, schritt}
      end
    end
  end

  test "kapitel/2: Überblick und Schreiben für eine Sitzung aus dem Repo" do
    aufruf = fn name, args ->
      %{
        text: nil,
        denken: nil,
        aufrufe: [%{id: "id_#{name}", name: name, argumente: {:ok, args}}],
        stopp: :werkzeuge,
        nutzung: nil
      }
    end

    notiz = fn a, k, zeile, fakten ->
      %{"abschnitt" => a, "schluessel" => k, "zeile" => zeile, "fakten" => fakten, "boegen" => []}
    end

    text = "Im Regen stand die Gruppe vor der Werkstatt, und der Alte zog die Spieldose auf."

    schritte = [
      aufruf.("fakten", %{"von" => 1, "bis" => 3}),
      aufruf.("notiz", %{
        "eintraege" => [
          notiz.("FORM", "Form", "Heldenlied in Szenen", []),
          notiz.("SZENEN", "Ankunft", "Regen, Werkstatt, Spieldose", ["S2-F1", "S2-F2"])
        ]
      }),
      aufruf.("fertig", %{"fakten" => 3, "szenen" => 1, "offen_geblieben" => ""}),
      aufruf.("absatz", %{"text" => text, "szene" => "ankunft"}),
      aufruf.("fertig", %{"absaetze" => 1, "offen_geblieben" => ""})
    ]

    {:ok, skript} = Agent.start_link(fn -> schritte end)

    assert {:ok, %{markdown: ^text, schreiben: %{stand: s}}} =
             Worker.Jack.Epos.kapitel(@s2,
               modell: {Skript, skript: skript, test: self()},
               kontext_fenster: 20_000
             )

    assert [%{szene: "Ankunft", fakt_ids: ["f_2a", "f_2b"]}] =
             Worker.Jack.Epos.Ergebnis.quellen(s)

    assert_received {:sitzung, _ueberblick}
    assert_received {:sitzung, schreiben}
    assert schreiben =~ "# Das Epos-Kapitel von Sitzung 2"
    assert schreiben =~ "Spalte **„Heldenlied“**"
    assert schreiben =~ "**Ton des Epos:** Nah an der Gruppe"
    refute schreiben =~ "Knapp"
  end
end
