defmodule Worker.Jack.Resuemee.PipelineTest do
  @moduledoc """
  J5 (#1209, B4): der Resümee-Jack in der Pipeline — `run_wahrheitsbild/4`
  mit dem echten Resümee-Jack auf einem geskripteten Modell (Muster
  `durchsicht_lauf_test.exs`), Fixtures über den Materializer (Muster
  `eingabe_test.exs`). Kein Ollama.

  Abgedeckt: die drei Stufen im Band, das veröffentlichte Resümee mit genauen
  Quellen (auch durch `Worker.Repo.GlattQuellen` hindurch), der abgelegte
  Stand, die gescheiterte Durchsicht (eigene Klasse, Resümee trotzdem da),
  der gescheiterte Überblick (kein Resümee, Lauf endet), ein Fehler vor den
  Läufen (Fehlschlag von „render“), der Setting-Leser und die Fehlerklassen.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Jack.Resuemee.Pipeline, as: RP
  alias Worker.Materializer
  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Repo.GlattQuellen
  alias Worker.Settings

  @cid "camp-resuemee-b4-1209"
  @sid "#{@cid}-s1"
  @uhrmacher "Der verschwundene Uhrmacher"
  @md "**Vor der Werkstatt**\nDie Gruppe steht vor der Werkstatt. Mira klopft an die Tür."

  # Spielt ein Skript ab (Muster `durchsicht_lauf_test.exs`).
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
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
    # kein Satz zitiert. Früher trug das Resümee alle Belege und damit den
    # 🕳-Marker; jetzt nicht mehr.
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

    Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
    :ok
  end

  defp apply!(kind, seq, payload),
    do: Materializer.apply_event(event(kind, payload, seq, event_id: "rb4-#{seq}"))

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

  # ─── Skript ─────────────────────────────────────────────────────────

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp ohne_aufruf, do: %{text: "bin durch", denken: nil, aufrufe: [], stopp: :stop, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    {Skript, skript: s}
  end

  defp notiz(abschnitt, schluessel, zeile, fakten, boegen),
    do: %{
      "abschnitt" => abschnitt,
      "schluessel" => schluessel,
      "zeile" => zeile,
      "fakten" => fakten,
      "boegen" => boegen
    }

  # Alle drei Fakten lesen; die Gliederung nennt nur zwei — S1-F3 hat keinen
  # Bogen und darf fehlen.
  defp ueberblick do
    [
      antwort([aufruf("fakten", %{"von" => 1, "bis" => 3})]),
      antwort([
        aufruf("notiz", %{
          "eintraege" => [
            notiz("FORM", "Form", "chronologische Nacherzählung", [], []),
            notiz("GLIEDERUNG", "1", "vor der Werkstatt", ["S1-F1", "S1-F2"], [@uhrmacher])
          ]
        })
      ]),
      antwort([aufruf("fertig", %{"fakten" => 3, "gliederung" => 1, "offen_geblieben" => ""})])
    ]
  end

  defp schreiben do
    [
      antwort([
        aufruf("absatz", %{
          "titel" => "Vor der Werkstatt",
          "saetze" => [
            %{"text" => "Die Gruppe steht vor der Werkstatt.", "fakten" => ["S1-F1"]},
            %{"text" => "Mira klopft an die Tür.", "fakten" => ["S1-F2"]}
          ]
        })
      ]),
      antwort([
        aufruf("fertig", %{
          "absaetze" => 1,
          "saetze" => 2,
          "ausgelassen" => [],
          "laenge_begruendung" => "",
          "offen_geblieben" => ""
        })
      ])
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
          run_id: "r-b4",
          extract: fn -> {:ok, []} end,
          resolve: fn -> {:ok, %{}} end,
          resolve_threads: fn -> {:ok, %{}} end,
          render_epos: fn _ ->
            send(parent, {:step, :render_epos})
            {:ok, %{md: "kapitel."}}
          end,
          render_arc_progression: fn _, _, _ -> {:ok, %{md: "bogen."}} end,
          resuemee: [
            modell: skript(schritte),
            kontext_fenster: 20_000,
            modell_name: "resuemee-testmodell"
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

  defp resuemee_stufen,
    do:
      Enum.filter(
        stufen(),
        fn {s, _} -> s in ["resuemee_ueberblick", "render", "resuemee_durchsicht"] end
      )

  # render_backend/render_model: 9./10. Feld der Summary-Zeile.
  defp herkunft do
    [row] = :mnesia.dirty_read(Worker.Schema.Mnesia.session_summaries(), @sid)
    {elem(row, 8), elem(row, 9)}
  end

  defp fehler(stage) do
    Worker.Repo.Snapshots.last_n_pipeline_errors(20) |> Enum.find(&(&1.stage == stage))
  end

  # ─── Tests ──────────────────────────────────────────────────────────

  test "drei Läufe, drei Stufen: das Resümee mit genauen Quellen und der Stand" do
    assert :ok = lauf(ueberblick() ++ schreiben() ++ durchsicht())

    assert resuemee_stufen() == [
             {"resuemee_ueberblick", "started"},
             {"resuemee_ueberblick", "ended"},
             {"render", "started"},
             {"render", "ended"},
             {"resuemee_durchsicht", "started"},
             {"resuemee_durchsicht", "ended"}
           ]

    summary = Repo.get_session_summary(@sid)
    assert summary.content_md == @md
    # Nur die zitierten Fakten: Block 2 (S1-F3) nennt kein Satz.
    assert Enum.sort(summary.source_refs) == ["#{@sid}-b0", "#{@sid}-b1"]
    # Die Herkunft liegt in der Zeile (der Leser gibt sie bewusst nicht aus, #783).
    assert herkunft() == {"jack", "resuemee-testmodell"}

    # Danach laufen die Geschwister weiter.
    assert_received {:step, :render_epos}

    # Der Stand liegt ab — die Notizen sind die „vorigen Gedanken“ der nächsten Sitzung.
    assert %{stand: stand} = Repo.jack_resuemee_stand_for_session(@sid)
    assert [%{"abschnitt" => "FORM"}, %{"abschnitt" => "GLIEDERUNG"}] = stand["notizen"]
    assert [%{"titel" => "Vor der Werkstatt", "saetze" => [_, _]}] = stand["entwurf"]

    assert [%{"fakt_ids" => ["f_a"], "uebergang" => false}, %{"fakt_ids" => ["f_b"]}] =
             stand["satzquellen"]

    assert stand["zaehlwerte"]["durchsicht"]["bestaetigt"] == 1
    assert stand["modell"] == "resuemee-testmodell"
    assert is_binary(stand["zeitpunkt"])
  end

  test "die genauen Quellen kommen durch GlattQuellen richtig an: Utterances und 🕳-Marker" do
    assert :ok = lauf(ueberblick() ++ schreiben() ++ durchsicht())
    summary = Repo.get_session_summary(@sid)
    index = GlattQuellen.block_index(@cid)

    # Die Lücke ist offen — mit allen Belegen trüge das Resümee den Marker.
    assert GlattQuellen.offen?(["#{@sid}-b2"], index)
    refute "summary:#{@sid}" in GlattQuellen.marker(@cid, index)

    # Sprungmarken und Sync-Index lesen die aufgelösten Utterances.
    %{"summaries" => [eintrag]} =
      GlattQuellen.anreichern(%{"summaries" => [%{"source_refs" => summary.source_refs}]}, %{
        "id" => @cid
      })

    assert Enum.sort(eintrag["quell_utterance_ids"]) == ["#{@sid}-u1", "#{@sid}-u2"]
  end

  test "gescheiterte Durchsicht: eigene Klasse in /admin/errors, der Entwurf wird veröffentlicht" do
    schritte =
      ueberblick() ++ schreiben() ++ nie_fertig(antwort([aufruf("durchsicht", %{"nummer" => 1})]))

    assert :ok = lauf(schritte)

    assert {"resuemee_durchsicht", "failed"} in resuemee_stufen()

    assert %{error_type: "resuemee_durchsicht_gescheitert", session_id: @sid} =
             fehler("resuemee_durchsicht")

    summary = Repo.get_session_summary(@sid)
    assert summary.content_md == @md
    assert Enum.sort(summary.source_refs) == ["#{@sid}-b0", "#{@sid}-b1"]

    # Der Lauf geht weiter, und der Stand sagt, dass die Durchsicht fehlt.
    assert_received {:step, :render_epos}
    %{stand: stand} = Repo.jack_resuemee_stand_for_session(@sid)
    assert is_binary(stand["zaehlwerte"]["durchsicht"]["gescheitert"])
  end

  test "gescheiterter Überblick: kein Resümee, eigene Klasse, der Lauf endet" do
    assert {:error, {:render, {:ueberblick_ohne_abschluss, _}}} =
             lauf(nie_fertig(antwort([aufruf("fakten", %{"von" => 1, "bis" => 3})])))

    assert resuemee_stufen() == [
             {"resuemee_ueberblick", "started"},
             {"resuemee_ueberblick", "failed"}
           ]

    assert %{error_type: "resuemee_ueberblick_ohne_abschluss"} = fehler("resuemee_ueberblick")
    assert Repo.get_session_summary(@sid) == nil
    assert Repo.jack_resuemee_stand_for_session(@sid) == nil
    refute_received {:step, :render_epos}
  end

  test "ein Fehler vor den Läufen ist ein Fehlschlag von „render“ — kein Rückfall auf den alten Render" do
    # Ohne `deps.resuemee` liest der Resümee-Jack die Einstellungen; ohne
    # Endpunkt startet er nicht.
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    assert {:error, {:render, :no_local_endpoint_configured}} =
             lauf([], %{resuemee: []})

    assert resuemee_stufen() == [{"render", "started"}, {"render", "failed"}]
    assert %{error_type: "no_local_endpoint_configured"} = fehler("render")
    assert Repo.get_session_summary(@sid) == nil
  end

  describe "Modell des Resümee-Jack (`resuemee_jack_model`)" do
    setup do
      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
      Settings.put(:local_endpoint, "http://x:1")
      Settings.put(:model_stage2_local, "jack-modell")
      :ok
    end

    test "ungesetzt oder leer: Jacks Modell" do
      assert RP.modell_name() == "jack-modell"

      Settings.put(:resuemee_jack_model, "   ")
      assert RP.modell_name() == "jack-modell"
    end

    test "gesetzt: eigenes Modell, Endpunkt und Regler wie Jack" do
      Settings.put(:resuemee_jack_model, " resuemee-modell ")
      Settings.put(:jack_temperature, 0.3)

      assert RP.modell_name() == "resuemee-modell"
      assert {:ok, {Worker.Agent.Modell.Ollama, o}} = RP.modell()
      assert o[:modell] == "resuemee-modell"
      assert o[:endpunkt] == "http://x:1"
      assert o[:temperatur] == 0.3
    end

    test "ohne jedes Modell ein Fehler, kein stiller Rückfall" do
      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
      Settings.put(:local_endpoint, "http://x:1")
      assert RP.modell() == {:error, {:no_model_configured, 2}}
    end

    test "der Key steht in der Schreib-Whitelist" do
      assert :resuemee_jack_model in Settings.known_keys()
    end
  end

  test "quellen/2: nur Fakten dieser Sitzung, die ein Satz nennt, ohne Doppelte (pur)" do
    facts = [
      %{"id" => "f1", "source_refs" => ["b0", "b1"]},
      %{"id" => "f2", "source_refs" => ["b1", "b2"]},
      %{"id" => "f3", "source_refs" => ["b3"]}
    ]

    satzquellen = [
      %{"fakt_ids" => ["f2", "f1"]},
      %{"fakt_ids" => []},
      %{"fakt_ids" => ["aus-frueherer-sitzung"]}
    ]

    assert RP.quellen(satzquellen, facts) == ["b0", "b1", "b2"]
    assert RP.quellen([], facts) == []
  end

  test "Fehlerklassen des Resümee-Jack" do
    c = &Pipeline.classify_pipeline_error/1

    assert c.({:resuemee_durchsicht, {:durchsicht_ohne_abschluss, :x}}) ==
             "resuemee_durchsicht_gescheitert"

    assert c.({:resuemee_durchsicht, :entwurf_leer}) == "resuemee_durchsicht_gescheitert"
    assert c.({:ueberblick_ohne_abschluss, :x}) == "resuemee_ueberblick_ohne_abschluss"
    assert c.({:schreiben_ohne_abschluss, :x}) == "resuemee_schreiben_ohne_abschluss"
    assert c.({:render, {:ueberblick_ohne_abschluss, :x}}) == "resuemee_ueberblick_ohne_abschluss"
    # Aus der Eingabe geerbt (keine Glättung) — fiel vorher auf „other“.
    assert c.({:render, {:extraction, {:jack, :keine_glaettung}}}) == "keine_glaettung"
    assert c.({:render, {:no_model_configured, 2}}) == "no_model_configured"
    assert c.({:auftrag_fehlt, "/pfad"}) == "auftrag_fehlt"
  end
end
