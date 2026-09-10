defmodule HubWeb.CampaignLive.SourceRefsResolutionTest do
  @moduledoc """
  Issue #1094: `source_refs` zitieren seit #864 Block-IDs. Drei der vier
  Lesestellen wussten das nicht und zeigten das Ergebnis als Datenverlust an.

  Issue #1198: seitdem löst der **Worker** auf (`Worker.Repo.GlattQuellen`,
  getestet in `glatt_quellen_test.exs`) und schickt `quell_utterance_ids` mit.
  Im Hub bleibt EINE Lesestelle, `Refs.quell/1`. Diese Tests halten fest:

  1. `quell/1` nimmt das aufgelöste Feld und fällt nur ohne es auf die rohen
     Refs zurück (Altdaten, alter Worker).
  2. Beide Indizes lesen über `quell/1` — keine Stelle keyt wieder auf
     Block-IDs.
  3. Der Sync-Index trägt die gerenderten Blöcke und keine `utt_sessions` mehr.
  4. Kein neuer Konsument liest `source_refs` roh (Wächter).
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Refs

  describe "quell/1" do
    test "nimmt die vom Worker aufgelösten Utterances" do
      e = %{"source_refs" => ["b_aaa"], "quell_utterance_ids" => ["u1", "u2"]}
      assert Refs.quell(e) == ["u1", "u2"]
    end

    test "ohne aufgelöstes Feld: die rohen Refs (Altdaten, alter Worker)" do
      # Vor #864 waren source_refs Utterance-IDs — für sie ist der Rückfall
      # richtig. Für Block-IDs ist er die benannte Verschlechterung bis zum
      # Worker-Update.
      assert Refs.quell(%{"source_refs" => ["u7"]}) == ["u7"]
    end

    test "nil, fehlende und leere Refs sind kein Fehler" do
      assert Refs.quell(nil) == []
      assert Refs.quell(%{}) == []
      assert Refs.quell(%{"source_refs" => nil}) == []
    end

    test "eine leere aufgelöste Liste gewinnt gegen die rohen Refs" do
      # Der Worker hat aufgelöst und nichts gefunden — das ist eine Auskunft,
      # kein fehlendes Feld.
      assert Refs.quell(%{"source_refs" => ["b_x"], "quell_utterance_ids" => []}) == []
    end
  end

  describe "build_utterance_refs_index/3" do
    test "keyt auf Utterance-IDs, nicht auf Block-IDs" do
      summaries = [
        %{
          "session_id" => "sess-1",
          "source_refs" => ["b_aaa"],
          "quell_utterance_ids" => ["u1", "u2"]
        }
      ]

      index = Refs.build_utterance_refs_index(summaries, nil, [])

      # Vor #1094 stand hier `%{"b_aaa" => [...]}` — abgefragt wurde mit "u1".
      # Folge: 📎-Zähler dauerhaft 0, Rückwärts-Popover immer leer.
      assert Map.has_key?(index, "u1")
      assert Map.has_key?(index, "u2")
      refute Map.has_key?(index, "b_aaa")
      assert [%{kind: "summary", label: "Resümee"}] = index["u1"]
    end

    test "Epos und Chronik lesen genauso über quell/1" do
      epos = %{"id" => "e1", "source_refs" => ["b_bbb"], "quell_utterance_ids" => ["u3"]}

      chronik = [
        %{
          "id" => "c1",
          "label" => "Tag 1",
          "source_refs" => ["b_ccc"],
          "quell_utterance_ids" => ["u9"]
        }
      ]

      index = Refs.build_utterance_refs_index([], epos, chronik)

      assert [%{kind: "epos"}] = index["u3"]
      assert [%{kind: "chronik", label: "Tag 1"}] = index["u9"]
    end
  end

  describe "build_sync_index/6" do
    defp ansicht do
      [
        %{
          "session_id" => "sess-1",
          "blocks" => [
            %{"block_id" => "b_aaa", "quell_utterance_ids" => ["u1", "u2"]},
            %{"block_id" => "b_ohne", "quell_utterance_ids" => []}
          ]
        }
      ]
    end

    test "Derivationen über quell/1, gerenderte Blöcke als glatt-Einträge" do
      summaries = [%{"session_id" => "sess-1", "quell_utterance_ids" => ["u1", "u2"]}]

      idx = Refs.build_sync_index(summaries, nil, [], [], ansicht(), [])

      assert idx["entries_to_utts"]["summaries:sess-1"] == ["u1", "u2"]
      assert idx["entries_to_utts"]["glatt:b_aaa"] == ["u1", "u2"]

      refute Map.has_key?(idx["entries_to_utts"], "glatt:b_ohne"),
             "ein Block ohne Quellen ist kein Anker"
    end

    test "trägt keine utt_sessions mehr (#1198)" do
      # Die Karte kam zum größten Teil aus dem Block-Skelett. Der Hook brauchte
      # sie nur als Sperre; die Session findet der Server selbst.
      idx = Refs.build_sync_index([], nil, [], [], ansicht(), [])
      assert Map.keys(idx) |> Enum.sort() == ["entries_to_utts", "utts_to_entries"]
    end

    test "die Fakten-Zuordnung aus #1095 bleibt erhalten" do
      facts = [%{"id" => "f1", "session_id" => "sess-fakt", "quell_utterance_ids" => ["uX"]}]

      idx = Refs.build_sync_index([], nil, [], [], [], facts)

      assert idx["entries_to_utts"]["fakten:f1"] == ["uX"]
      assert [%{"col" => "fakten", "id" => "f1"}] = idx["utts_to_entries"]["uX"]
    end

    test "Resümee ohne Quellen fällt auf die geladenen Zeilen der Session zurück" do
      utterances = [%{"id" => "u1", "session_id" => "s"}, %{"id" => "u2", "session_id" => "s"}]

      idx = Refs.build_sync_index([%{"session_id" => "s"}], nil, [], utterances, [], [])

      assert idx["entries_to_utts"]["summaries:s"] == ["u1", "u2"]
    end
  end

  describe "Wächter: keine neue rohe source_refs-Lesestelle" do
    @erlaubt %{"refs.ex" => "hier wohnt `quell/1`, die EINE Lesestelle (#1198)"}

    test "kein Modul im hub_web-Layer liest source_refs ohne quell/1" do
      # Die Forderung aus #1094: die Auflösung gehört an EINE Stelle. Ein neuer
      # Konsument, der `source_refs` direkt liest, bekommt Block-IDs und sucht
      # sie in der Utterance-Liste — lautlos, weil eine leere Trefferliste wie
      # „keine Quellen" aussieht.
      treffer =
        Path.wildcard("lib/hub_web/**/*.ex")
        |> Enum.reject(fn f -> Map.has_key?(@erlaubt, Path.basename(f)) end)
        |> Enum.filter(fn f -> File.read!(f) =~ ~s("source_refs") end)
        |> Enum.map(&Path.relative_to(&1, "lib/hub_web"))

      assert treffer == [],
             "diese Dateien lesen `source_refs` roh: #{inspect(treffer)} — über " <>
               "Refs.quell/1 lesen, oder (wenn Block-IDs gewollt sind) in @erlaubt " <>
               "dieses Tests mit Begründung eintragen."
    end

    test "im Template nur als Zähler — zeilengenau geprüft" do
      # Der 📎-Zähler nennt Blöcke (der Tooltip sagt das seit #1094), dafür sind
      # die rohen Refs richtig. Jede andere Verwendung erwartet wahrscheinlich
      # Utterance-IDs und bekommt Block-IDs.
      verdaechtig =
        "lib/hub_web/live/campaign_live.html.heex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> line =~ "source_refs" end)
        |> Enum.reject(fn {line, _n} -> line =~ "length(" end)
        |> Enum.map(fn {line, n} -> "Z.#{n}: #{String.trim(line)}" end)

      assert verdaechtig == [],
             "diese Template-Zeilen benutzen `source_refs` nicht als reinen Zähler: " <>
               inspect(verdaechtig)
    end
  end
end
