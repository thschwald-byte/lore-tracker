defmodule Worker.Jack.Epos.PipelineTest do
  @moduledoc """
  J6 (#1210, E4): der Epos-Jack in der Pipeline — `run_wahrheitsbild/4` mit
  dem echten Epos-Jack auf einem geskripteten Modell (Muster
  `resuemee/pipeline_test.exs`), Fixtures über den Materializer. Das Resümee
  ist ein Stub, sein abgelegter Stand liegt vorab im Repo — daraus kommt der
  Weg. Kein Ollama.

  Abgedeckt: die drei Stufen im Band, das veröffentlichte Kapitel mit Kopf und
  genauen Quellen (auch durch `Worker.Repo.GlattQuellen` hindurch), der
  abgelegte Stand, die gescheiterte Durchsicht (eigene Klasse, Kapitel
  trotzdem da), das gescheiterte Schreiben (kein Kapitel, der Lauf geht
  weiter), ein Fehler vor den Läufen und ein Raise (Fehlschlag von
  „render_epos“), der #753-Schutz, der Setting-Leser, der Kapitelkopf, die
  Quellen und die Fehlerklassen.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Worker.TestHelper

  alias Worker.Jack.Epos.Pipeline, as: EP
  alias Worker.Materializer
  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Repo.GlattQuellen
  alias Worker.Settings

  @cid "camp-epos-e4-1210"
  @sid "#{@cid}-s1"
  @uhrmacher "Der verschwundene Uhrmacher"
  @absatz "Der Regen hing über der Werkstatt, als Mira an die Tür klopfte."
  @kopf "## Kapitel 1"

  # Spielt ein Skript ab und meldet den Auftrag jeder frischen Sitzung
  # (Muster `epos/durchsicht_lauf_test.exs`).
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      case nachrichten do
        [%{role: :system}, %{role: :user, content: auftrag}] ->
          send(Keyword.fetch!(opts, :test), {:sitzung, auftrag})

        _ ->
          :ok
      end

      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
             [kopf | rest] -> {kopf, rest}
             [] -> {nil, []}
           end) do
        nil -> raise "Skript erschöpft; zuletzt: #{inspect(Enum.take(nachrichten, -4))}"
        schritt -> {:ok, schritt}
      end
    end
  end

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1], apply: true)

    # Block 2 ist eine unkuratierte Lücke — und gehört zu einem Fakt, den
    # keine Szene nennt. Mit allen Belegen trüge das Kapitel den 🕳-Marker.
    apply!("TranscriptSmoothed", 1001, %{
      "session_id" => @sid,
      "campaign_id" => @cid,
      "smoothed_at" => "2026-09-13T08:00:00Z",
      "blocks" => [
        block(0, "Ihr steht vor der Werkstatt.", false),
        block(1, "Ich klopfe an.", false),
        block(2, "Draußen regnet es.", true)
      ],
      "ooc_verworfen" => [],
      "rules_version" => 7,
      "merge_gap_seconds" => 8
    })

    apply!("SessionFactsExtracted", 1010, %{
      "session_id" => @sid,
      "campaign_id" => @cid,
      "facts" => [
        fakt("f_a", "Die Gruppe steht vor der Werkstatt.", [@uhrmacher], ["#{@sid}-b0"]),
        fakt("f_b", "Mira klopft an die Tür.", [], ["#{@sid}-b1"]),
        fakt("f_c", "Draußen regnet es.", [], ["#{@sid}-b2"])
      ]
    })

    apply!("ThreadRegistryComputed", 1020, %{
      "campaign_id" => @cid,
      "cluster_map" => %{},
      "kinds" => %{}
    })

    # Der Stand des Resümee-Jack: eine Station, deren Satzquellen zum
    # heutigen Bestand passen — der Weg für den Epos-Jack.
    apply!("JackResuemeeStandAbgelegt", 1030, %{
      "session_id" => @sid,
      "campaign_id" => @cid,
      "stand" => %{
        "notizen" => [notiz("GLIEDERUNG", "1", "vor der Werkstatt", ["S1-F1", "S1-F2"], [])],
        "entwurf" => [],
        "satzquellen" => [
          %{
            "text" => "Die Gruppe steht vor der Werkstatt.",
            "fakten" => ["S1-F1"],
            "fakt_ids" => ["f_a"]
          }
        ],
        "zaehlwerte" => %{},
        "modell" => "resuemee-testmodell",
        "zeitpunkt" => "2026-09-13T09:00:00Z"
      }
    })

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
    :ok
  end

  defp apply!(kind, seq, payload),
    do: Materializer.apply_event(event(kind, payload, seq, event_id: "e4-#{seq}"))

  defp block(i, text, luecke?),
    do: %{
      "id" => "#{@sid}-b#{i}",
      "speaker_discord_id" => "did-owner",
      "text" => text,
      "quell_utterance_ids" => ["#{@sid}-u#{i + 1}"],
      "hat_luecke" => luecke?
    }

  defp fakt(id, claim, threads, refs),
    do: %{
      "id" => id,
      "claim" => claim,
      "threads" => threads,
      "source_refs" => refs,
      "fact_type" => "ereignis",
      "narration_time" => "present",
      "verified?" => true
    }

  defp notiz(abschnitt, schluessel, zeile, fakten, boegen),
    do: %{
      "abschnitt" => abschnitt,
      "schluessel" => schluessel,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => boegen
    }

  # ─── Skript ─────────────────────────────────────────────────────────

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp ohne_aufruf, do: %{text: "bin durch", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    {Skript, skript: s, test: self()}
  end

  # Alle drei Fakten lesen; eine Szene trägt die Station des Wegs — S1-F3
  # nennt sie nicht.
  defp ueberblick do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 3})]),
      antwort([
        aufruf("notiz", %{
          "eintraege" => [
            notiz("FORM", "Form", "Heldenlied in Szenen, nah an der Gruppe", [], []),
            notiz("SZENEN", "Tür", "Regen, vor der Werkstatt", ["S1-F1", "S1-F2"], [@uhrmacher])
          ]
        })
      ]),
      antwort([aufruf("fertig", %{"fakten" => 3, "szenen" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp schreiben do
    [
      antwort([aufruf("absatz", %{"text" => @absatz, "szene" => "Tür"})]),
      antwort([aufruf("fertig", %{"absaetze" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp durchsicht do
    [
      antwort([aufruf("durchsicht", %{"nummer" => 1})]),
      antwort([aufruf("absatz_bestaetigen", %{"nummer" => 1})]),
      antwort([aufruf("fertig", %{"bestaetigt" => 1, "ersetzt" => 0, "offen_geblieben" => ""})])
    ]
  end

  defp nie_fertig(erster), do: [erster] ++ List.duplicate(ohne_aufruf(), 4)

  # ─── Lauf ───────────────────────────────────────────────────────────

  defp session, do: %{id: @sid, campaign_id: @cid, number: 1}

  defp lauf(schritte, extra \\ %{}) do
    parent = self()

    deps =
      Map.merge(
        %{
          run_id: "r-e4",
          extract: fn -> {:ok, []} end,
          resolve: fn -> {:ok, %{}} end,
          resolve_threads: fn -> {:ok, %{}} end,
          render: fn _ -> {:ok, %{md: "resümee."}} end,
          render_arc_progression: fn _, _, _ ->
            send(parent, {:step, :bogen})
            {:ok, %{md: "bogen."}}
          end,
          epos: [
            modell: skript(schritte),
            kontext_fenster: 20_000,
            modell_name: "epos-testmodell"
          ]
        },
        extra
      )

    {ergebnis, _log} =
      with_log(fn -> Pipeline.run_wahrheitsbild(session(), Repo.get_campaign(@cid), [], deps) end)

    ergebnis
  end

  defp stufen(acc \\ []) do
    receive do
      {:pipeline_stage, %{"kind" => "pipeline_stage"} = p} ->
        stufen([{p["stage"], p["status"]} | acc])

      {:pipeline_stage, _fortschritt} ->
        stufen(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp epos_stufen(alle),
    do:
      Enum.filter(alle, fn {s, _} ->
        s in ["epos_ueberblick", "render_epos", "epos_durchsicht"]
      end)

  # epos_backend/epos_model: 8./9. Feld der epos_entries-Zeile.
  defp herkunft do
    [row] = :mnesia.dirty_read(Worker.Schema.Mnesia.epos_entries(), @sid)
    {elem(row, 7), elem(row, 8)}
  end

  defp fehler(stage) do
    Worker.Repo.Snapshots.last_n_pipeline_errors(20) |> Enum.find(&(&1.stage == stage))
  end

  defp kapitel do
    case Repo.list_epos_chapters(@cid) do
      [k] -> k
      [] -> nil
    end
  end

  # ─── Tests ──────────────────────────────────────────────────────────

  test "drei Läufe, drei Stufen: das Kapitel mit Kopf, genauen Quellen und dem Stand" do
    assert :ok = lauf(ueberblick() ++ schreiben() ++ durchsicht())

    alle = stufen()

    assert epos_stufen(alle) == [
             {"epos_ueberblick", "started"},
             {"epos_ueberblick", "ended"},
             {"render_epos", "started"},
             {"render_epos", "ended"},
             {"epos_durchsicht", "started"},
             {"epos_durchsicht", "ended"}
           ]

    # Reihenfolge im Lauf: Resümee → Chronik → Epos → Bogen-Progressionen.
    reihe = alle |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert Enum.filter(
             reihe,
             &(&1 in ["timeline", "epos_ueberblick", "epos_durchsicht", "render_arc_progressions"])
           ) == ["timeline", "epos_ueberblick", "epos_durchsicht", "render_arc_progressions"]

    # Der Weg kam aus dem abgelegten Stand des Resümee-Jack.
    assert_received {:sitzung, auftrag}
    assert auftrag =~ "hält den Weg der Gruppe in einer Station fest"

    # Das Kapitel: deterministischer Kopf, dann das Markdown des Jack.
    k = kapitel()
    assert k.id == @sid
    assert k.content_md == @kopf <> "\n\n" <> @absatz
    # Nur die Fakten der zugeordneten Szene: Block 2 (S1-F3) nennt sie nicht.
    assert Enum.sort(k.source_refs) == ["#{@sid}-b0", "#{@sid}-b1"]
    assert herkunft() == {"jack", "epos-testmodell"}

    # Der Stand liegt ab — die Notizen sind „vorige Gedanken“ späterer Sitzungen.
    assert %{stand: stand} = Repo.jack_epos_stand_for_session(@sid)

    assert [%{"abschnitt" => "FORM"}, %{"abschnitt" => "SZENEN", "schluessel" => "Tür"}] =
             stand["notizen"]

    assert stand["entwurf"] == [%{"titel" => nil, "text" => @absatz, "szene" => "Tür"}]

    assert stand["quellen"] == [
             %{
               "absatz" => 1,
               "titel" => nil,
               "szene" => "Tür",
               "fakten" => ["S1-F1", "S1-F2"],
               "fakt_ids" => ["f_a", "f_b"]
             }
           ]

    assert stand["zaehlwerte"]["durchsicht"]["bestaetigt"] == 1
    assert stand["zaehlwerte"]["absaetze_mit_szene"] == 1
    assert stand["modell"] == "epos-testmodell"
    assert is_binary(stand["zeitpunkt"])
  end

  test "die genauen Quellen kommen durch GlattQuellen richtig an: Utterances und 🕳-Marker" do
    assert :ok = lauf(ueberblick() ++ schreiben() ++ durchsicht())
    k = kapitel()
    index = GlattQuellen.block_index(@cid)

    # Die Lücke ist offen — mit allen Belegen trüge das Kapitel den Marker.
    assert GlattQuellen.offen?(["#{@sid}-b2"], index)
    refute "epos_chapter:#{@sid}" in GlattQuellen.marker(@cid, index)

    # Sprungmarken und Sync-Index lesen die aufgelösten Utterances.
    %{"epos_chapters" => [eintrag]} =
      GlattQuellen.anreichern(%{"epos_chapters" => [%{"source_refs" => k.source_refs}]}, %{
        "id" => @cid
      })

    assert Enum.sort(eintrag["quell_utterance_ids"]) == ["#{@sid}-u1", "#{@sid}-u2"]
  end

  test "gescheiterte Durchsicht: eigene Klasse in /admin/errors, das Kapitel aus dem Schreiben wird veröffentlicht" do
    schritte =
      ueberblick() ++ schreiben() ++ nie_fertig(antwort([aufruf("durchsicht", %{"nummer" => 1})]))

    assert :ok = lauf(schritte)

    assert {"epos_durchsicht", "failed"} in stufen()

    assert %{error_type: "epos_durchsicht_gescheitert", session_id: @sid} =
             fehler("epos_durchsicht")

    assert kapitel().content_md == @kopf <> "\n\n" <> @absatz

    %{stand: stand} = Repo.jack_epos_stand_for_session(@sid)
    assert is_binary(stand["zaehlwerte"]["durchsicht"]["gescheitert"])
  end

  test "gescheitertes Schreiben: kein neues Kapitel, das bisherige bleibt, der Lauf geht weiter" do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => @sid,
        "campaign_id" => @cid,
        "parent_id" => @cid,
        "new_md" => "## Kapitel 1\n\nDas bisherige Kapitel.",
        "edited_by" => "llm",
        "source" => "llm"
      })

    schritte = ueberblick() ++ nie_fertig(antwort([aufruf("absatz", %{"text" => @absatz})]))

    assert :ok = lauf(schritte)
    alle = stufen()

    assert epos_stufen(alle) == [
             {"epos_ueberblick", "started"},
             {"epos_ueberblick", "ended"},
             {"render_epos", "started"},
             {"render_epos", "failed"}
           ]

    assert %{error_type: "epos_schreiben_ohne_abschluss"} = fehler("render_epos")
    assert kapitel().content_md =~ "Das bisherige Kapitel."
    assert Repo.jack_epos_stand_for_session(@sid) == nil

    # Best-effort: das Resümee steht, die Bogen-Progressionen laufen danach.
    assert Repo.get_session_summary(@sid).content_md == "resümee."
    assert {"render_arc_progressions", "started"} in alle
  end

  test "gescheiterter Überblick: kein Kapitel, eigene Klasse, der Lauf geht weiter" do
    assert :ok = lauf(nie_fertig(antwort([aufruf("fakten", %{"von" => 1, "bis" => 3})])))
    alle = stufen()

    assert epos_stufen(alle) == [{"epos_ueberblick", "started"}, {"epos_ueberblick", "failed"}]
    assert %{error_type: "epos_ueberblick_ohne_abschluss"} = fehler("epos_ueberblick")
    assert kapitel() == nil
    assert {"render_arc_progressions", "started"} in alle
  end

  test "ein Fehler vor den Läufen ist ein Fehlschlag von „render_epos“ — kein Rückfall, der Lauf geht weiter" do
    # Ohne `deps.epos` liest der Epos-Jack die Einstellungen; ohne Endpunkt
    # startet er nicht.
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    assert :ok = lauf([], %{epos: []})
    alle = stufen()

    assert epos_stufen(alle) == [{"render_epos", "started"}, {"render_epos", "failed"}]
    assert %{error_type: "no_local_endpoint_configured"} = fehler("render_epos")
    assert kapitel() == nil
    assert {"render_arc_progressions", "started"} in alle
  end

  test "ein Raise reißt den Lauf nicht mit — Fehlschlag von „render_epos“" do
    assert :ok = lauf([], %{render_epos: fn _ -> raise "kaputt" end})
    alle = stufen()

    assert {"render_epos", "failed"} in alle
    assert %{session_id: @sid} = fehler("render_epos")
    assert kapitel() == nil
    assert {"render_arc_progressions", "started"} in alle
  end

  test "#753: ein Kapitel mit GM-Edit schreibt der Epos-Jack nicht neu — kein Modellaufruf" do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.epos_entry_edited(),
        "entry_id" => @sid,
        "campaign_id" => @cid,
        "parent_id" => @cid,
        "new_md" => "## Kapitel 1\n\nGM-Fassung.",
        "edited_by" => "gm-did",
        "source" => "manual"
      })

    # Ein leeres Skript wirft beim ersten Aufruf — es darf keinen geben.
    assert :ok = lauf([])

    assert epos_stufen(stufen()) == [{"render_epos", "started"}, {"render_epos", "ended"}]
    assert kapitel().content_md =~ "GM-Fassung."
    assert Repo.jack_epos_stand_for_session(@sid) == nil
    refute_received {:sitzung, _}
  end

  describe "Modell des Epos-Jack (`epos_jack_model`)" do
    setup do
      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
      Settings.put(:local_endpoint, "http://x:1")
      Settings.put(:model_stage2_local, "jack-modell")
      :ok
    end

    test "ungesetzt oder leer: Jacks Modell" do
      assert EP.modell_name() == "jack-modell"

      Settings.put(:epos_jack_model, "   ")
      assert EP.modell_name() == "jack-modell"
    end

    test "gesetzt: eigenes Modell, Endpunkt und Regler wie Jack — unabhängig vom Resümee-Jack" do
      Settings.put(:epos_jack_model, " epos-modell ")
      Settings.put(:resuemee_jack_model, "resuemee-modell")
      Settings.put(:jack_temperature, 0.3)

      assert EP.modell_name() == "epos-modell"
      assert {:ok, {Worker.Agent.Modell.Ollama, o}} = EP.modell()
      assert o[:modell] == "epos-modell"
      assert o[:endpunkt] == "http://x:1"
      assert o[:temperatur] == 0.3
    end

    test "ohne jedes Modell ein Fehler, kein stiller Rückfall" do
      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
      Settings.put(:local_endpoint, "http://x:1")
      assert EP.modell() == {:error, {:no_model_configured, 2}}
    end

    test "der Key steht in der Schreib-Whitelist" do
      assert :epos_jack_model in Settings.known_keys()
    end
  end

  describe "Veröffentlichen" do
    test "von Hand: der Kopf kommt aus der gespeicherten Chronik, die Quellen aus den Absätzen" do
      facts = Repo.get_session_facts(@sid).facts

      rendered = %{
        md: @absatz,
        quellen: [%{"absatz" => 1, "szene" => "Tür", "fakt_ids" => ["f_b"]}],
        zaehlwerte: %{"absaetze" => 1},
        modell: "hand-modell"
      }

      assert :ok = EP.veroeffentlichen(session(), Repo.get_campaign(@cid), facts, rendered)

      k = kapitel()
      assert k.content_md == @kopf <> "\n\n" <> @absatz
      assert k.source_refs == ["#{@sid}-b1"]
      assert herkunft() == {"jack", "hand-modell"}
    end

    test "kopf/3: Nummer der Sitzung, das Datum aus den Einträgen der Chronik (#752/#1092)" do
      campaign = Repo.get_campaign(@cid)
      # Ohne datierte Einträge der nackte Kopf — auch aus der leeren Chronik.
      assert EP.kopf(session(), campaign, []) == @kopf
      assert EP.kopf(session(), campaign, nil) == @kopf

      # Mit datiertem Eintrag das Datum im Kalender der Kampagne (Standard:
      # gregorianisch), kein roher Tageszähler.
      k = EP.kopf(session(), campaign, [%{in_game_day: 5, precision: "day"}])
      assert k =~ ~r/^## Kapitel 1 — \S/
      refute k =~ "Tag 5"
    end

    test "quellen/2: nur Fakten dieser Sitzung aus den Szenen der Absätze, ohne Doppelte (pur)" do
      facts = [
        %{"id" => "f1", "source_refs" => ["b0", "b1"]},
        %{"id" => "f2", "source_refs" => ["b1", "b2"]},
        %{"id" => "f3", "source_refs" => ["b3"]}
      ]

      quellen = [
        %{"absatz" => 1, "szene" => "A", "fakt_ids" => ["f2", "f1"]},
        %{"absatz" => 2, "szene" => nil, "fakt_ids" => []},
        %{"absatz" => 3, "szene" => "B", "fakt_ids" => ["aus-frueherer-sitzung"]}
      ]

      assert EP.quellen(quellen, facts) == ["b0", "b1", "b2"]
      assert EP.quellen([], facts) == []
    end
  end

  test "Fehlerklassen des Epos-Jack" do
    c = &Pipeline.classify_pipeline_error/1

    assert c.({:epos_durchsicht, {:epos_durchsicht_ohne_abschluss, :x}}) ==
             "epos_durchsicht_gescheitert"

    assert c.({:epos_durchsicht, :entwurf_leer}) == "epos_durchsicht_gescheitert"
    assert c.({:epos_ueberblick_ohne_abschluss, :x}) == "epos_ueberblick_ohne_abschluss"
    assert c.({:epos_schreiben_ohne_abschluss, :x}) == "epos_schreiben_ohne_abschluss"
    assert c.({:no_model_configured, 2}) == "no_model_configured"
  end
end
