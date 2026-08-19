defmodule HubWeb.CampaignLive.SourceRefsResolutionTest do
  @moduledoc """
  Issue #1094: `source_refs` zitieren seit #864 Block-IDs. Drei der vier
  Lesestellen wussten das nicht, suchten Block-IDs in der Utterance-Liste und
  zeigten das Ergebnis als Datenverlust an.

  Die Tests halten drei Dinge fest, die alle drei still versagen können:

  1. Die Auflösung selbst — inklusive des Durchreiche-Falls, ohne den
     Bestandskampagnen ohne Glättung ihre Refs verlieren würden.
  2. Die Session-Zuordnung für Zeilen, die gar nicht geladen sind. Fehlt sie,
     ist das Popover repariert und der Sprung bricht trotzdem stumm ab.
  3. Dass `GapMarker` NICHT aufgelöst — die eine Stelle, die Block-IDs
     ausdrücklich braucht.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.GapMarker
  alias HubWeb.CampaignLive.Refs

  # Ein Glättungs-Snapshot wie ihn der Worker liefert: EIN Eintrag pro Session,
  # `session_id` am Eintrag (NICHT am Block — der Block hat das Feld gar nicht).
  defp smoothed do
    [
      %{
        "session_id" => "sess-1",
        "blocks" => [
          %{"block_id" => "b_aaa", "quell_utterance_ids" => ["u1", "u2"]},
          %{"block_id" => "b_bbb", "quell_utterance_ids" => ["u3"]}
        ]
      },
      %{
        "session_id" => "sess-2",
        "blocks" => [
          %{"block_id" => "b_ccc", "quell_utterance_ids" => ["u9", "u10"]}
        ]
      }
    ]
  end

  describe "block_source_map/1" do
    test "nimmt die session_id vom umschließenden Eintrag, nicht vom Block" do
      # Der Block trägt kein `session_id` — an echten Prod-Daten nachgemessen.
      # Wer sie am Block liest, bekommt nil und schließt die Lücke nicht.
      map = Refs.block_source_map(smoothed())

      assert map["b_aaa"] == %{utts: ["u1", "u2"], session_id: "sess-1"}
      assert map["b_ccc"] == %{utts: ["u9", "u10"], session_id: "sess-2"}
    end

    test "leerer/fehlender Snapshot ergibt eine leere Karte" do
      assert Refs.block_source_map([]) == %{}
      assert Refs.block_source_map(nil) == %{}
    end
  end

  describe "resolve_source_refs/2" do
    test "löst Block-IDs zu ihren Quell-Utterances auf" do
      assert Refs.resolve_source_refs(["b_aaa", "b_bbb"], Refs.block_source_map(smoothed())) ==
               ["u1", "u2", "u3"]
    end

    test "reicht unbekannte Refs unverändert durch" do
      # Der Fall, der NICHT gefiltert werden darf: vor #864 waren source_refs
      # echte Utterance-IDs, und Kampagnen ohne Glättung haben keine Blöcke.
      # Filtern statt Durchreichen würde deren Quellen löschen.
      assert Refs.resolve_source_refs(["u42", "u43"], %{}) == ["u42", "u43"]
    end

    test "gemischt: Block-IDs auflösen, Alt-IDs behalten" do
      assert Refs.resolve_source_refs(["b_aaa", "u99"], Refs.block_source_map(smoothed())) ==
               ["u1", "u2", "u99"]
    end

    test "ein Block ohne Quell-Utterances wird durchgereicht, nicht verschluckt" do
      map =
        Refs.block_source_map([
          %{
            "session_id" => "s",
            "blocks" => [%{"block_id" => "b_x", "quell_utterance_ids" => []}]
          }
        ])

      # Sonst verschwindet die Zeile lautlos aus dem Popover.
      assert Refs.resolve_source_refs(["b_x"], map) == ["b_x"]
    end

    test "entdoppelt: zwei Blöcke mit derselben Quell-Utterance" do
      map =
        Refs.block_source_map([
          %{
            "session_id" => "s",
            "blocks" => [
              %{"block_id" => "b_1", "quell_utterance_ids" => ["u1", "u2"]},
              %{"block_id" => "b_2", "quell_utterance_ids" => ["u2", "u3"]}
            ]
          }
        ])

      assert Refs.resolve_source_refs(["b_1", "b_2"], map) == ["u1", "u2", "u3"]
    end

    test "nil und leere Liste sind kein Fehler" do
      assert Refs.resolve_source_refs(nil, %{}) == []
      assert Refs.resolve_source_refs([], %{}) == []
    end
  end

  describe "block_utterance_sessions/1" do
    test "kennt die Session auch für nicht geladene Zeilen" do
      # Das ist der Punkt: u1/u3/u9 stehen nirgends in `utterances` (seit dem
      # #1087-Ladefenster sind alte Sessions gar nicht geladen), die Zuordnung
      # kommt allein aus den Blöcken. Ohne sie verlässt column_sync.js
      # `tryAutoExpand` über `if (!sid) return` — der Klick tut nichts.
      sessions = smoothed() |> Refs.block_source_map() |> Refs.block_utterance_sessions()

      assert sessions == %{
               "u1" => "sess-1",
               "u2" => "sess-1",
               "u3" => "sess-1",
               "u9" => "sess-2",
               "u10" => "sess-2"
             }
    end

    test "Blöcke ohne session_id werden übersprungen, nicht mit nil eingetragen" do
      # Ein `%{"u1" => nil}` wäre schlimmer als ein fehlender Key: der JS-Hook
      # prüft auf Falsy, aber der Elixir-Merge würde eine echte Zuordnung
      # überschreiben.
      map =
        Refs.block_source_map([
          %{"blocks" => [%{"block_id" => "b_x", "quell_utterance_ids" => ["u1"]}]}
        ])

      assert Refs.block_utterance_sessions(map) == %{}
    end
  end

  describe "build_utterance_refs_index/4" do
    test "keyt auf Utterance-IDs, nicht auf Block-IDs" do
      summaries = [%{"session_id" => "sess-1", "source_refs" => ["b_aaa"]}]

      index = Refs.build_utterance_refs_index(summaries, nil, [], smoothed())

      # Vorher stand hier `%{"b_aaa" => [...]}` — abgefragt wurde mit "u1".
      # Folge: 📎-Zähler dauerhaft 0, Rückwärts-Popover immer leer.
      assert Map.has_key?(index, "u1")
      assert Map.has_key?(index, "u2")
      refute Map.has_key?(index, "b_aaa")
      assert [%{kind: "summary", label: "Resümee"}] = index["u1"]
    end

    test "ohne Glättung bleiben Alt-Refs als Key erhalten" do
      summaries = [%{"session_id" => "s", "source_refs" => ["u7"]}]

      assert Map.has_key?(Refs.build_utterance_refs_index(summaries, nil, [], []), "u7")
    end

    test "Epos und Chronik werden genauso aufgelöst" do
      epos = %{"id" => "e1", "source_refs" => ["b_bbb"]}
      chronik = [%{"id" => "c1", "label" => "Tag 1", "source_refs" => ["b_ccc"]}]

      index = Refs.build_utterance_refs_index([], epos, chronik, smoothed())

      assert [%{kind: "epos"}] = index["u3"]
      assert [%{kind: "chronik", label: "Tag 1"}] = index["u9"]
    end
  end

  describe "GapMarker bleibt auf Block-IDs" do
    test "vergleicht Block-IDs direkt — Auflösen wäre hier ein Fehler" do
      # gap_ids sind Block-IDs (eine Lücke hat der Block, nicht die Utterance).
      # Würde man hier expandieren, verglich man zwei disjunkte Mengen und der
      # 🕳-Marker verschwände still.
      assert GapMarker.derivation_touches_gap?(["b_aaa"], MapSet.new(["b_aaa"]))
      refute GapMarker.derivation_touches_gap?(["u1", "u2"], MapSet.new(["b_aaa"]))
    end
  end

  describe "Wächter: keine neue rohe source_refs-Lesestelle" do
    @erlaubt %{
      "gap_marker.ex" => "arbeitet bewusst auf Block-IDs (siehe Test oben)",
      "refs.ex" => "hier wohnt die Auflösung selbst",
      "components.ex" => "eine einzige Zeile, ein GapMarker-Aufruf (Epos-Kapitel)"
    }

    test "kein Modul im hub_web-Layer liest source_refs ohne Auflösung" do
      # Die Forderung aus #1094: die Auflösung gehört an EINE Stelle, und
      # Konsumenten sollen nicht wählen können, ob sie sie benutzen. Ein neuer
      # Konsument, der `source_refs` direkt liest, wiederholt sonst genau
      # diesen Bug — lautlos, weil eine leere Trefferliste wie „keine Quellen"
      # aussieht.
      treffer =
        Path.wildcard("lib/hub_web/**/*.ex")
        |> Enum.reject(fn f -> Map.has_key?(@erlaubt, Path.basename(f)) end)
        |> Enum.filter(fn f -> File.read!(f) =~ ~s("source_refs") end)
        |> Enum.map(&Path.relative_to(&1, "lib/hub_web"))

      assert treffer == [],
             "diese Dateien lesen `source_refs` roh: #{inspect(treffer)} — über " <>
               "Refs.resolve_source_refs/2 auflösen, oder (wenn Block-IDs " <>
               "gewollt sind) in @erlaubt dieses Tests mit Begründung eintragen."
    end

    test "im Template nur Block-Ebene-Verwendungen — zeilengenau geprüft" do
      # Das Template ist EINE riesige Datei; ein dateiweises „erlaubt" würde
      # jede künftige Fehlverwendung mit durchlassen. Also pro Zeile: wer
      # `source_refs` anfasst, muss sie entweder an den GapMarker geben (der
      # will Block-IDs) oder bloß zählen (der 📎-Zähler nennt Blöcke, und der
      # Tooltip sagt das seit #1094 auch).
      verdaechtig =
        "lib/hub_web/live/campaign_live.html.heex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> line =~ "source_refs" end)
        |> Enum.reject(fn {line, _n} ->
          line =~ "derivation_touches_gap?" or line =~ "length("
        end)
        |> Enum.map(fn {line, n} -> "Z.#{n}: #{String.trim(line)}" end)

      assert verdaechtig == [],
             "diese Template-Zeilen benutzen `source_refs` weder als Block-IDs " <>
               "für den GapMarker noch als reinen Zähler: #{inspect(verdaechtig)} — " <>
               "sie erwarten also wahrscheinlich Utterance-IDs und bekommen seit " <>
               "#864 Block-IDs."
    end
  end
end
