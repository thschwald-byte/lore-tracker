defmodule Worker.Recording.Pipeline.TimeAnchorTest do
  @moduledoc """
  Issue #1075 (E4): `time_anchor` wird seit diesem Umbau vom Extraktions-Prompt
  abgefragt. Bis dahin kam das Feld ausschliesslich aus der GM-Kuration — die
  Formen `"session"` und `"event:…"` gab es in echten Daten **null Mal**, obwohl
  `Worker.Timeline.{Resolver,Graph}` seit #724 einen kompletten Apparat dafür
  halten (Fuzzy-Match, Kahn-Fixpunkt, Zyklusschutz). Der Graph war Infrastruktur
  ohne Producer.

  Diese Datei pinnt die KETTE, nicht die Einzelteile: was der Prompt als Form
  nennt, muss der Parser erhalten und der Resolver in einen eigenen Zweig
  führen. Bricht ein Glied, ist der Effekt sonst unsichtbar — das Modell
  liefert brav einen Anker, `normalize_anchor/1` macht `nil` daraus, und der
  Fakt landet still im Präsens-Fallback. Kein Fehler, kein Log, nur eine
  Chronik, die etwas anderes zeigt als das Transkript sagt.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.{Parsing, Prompts, Stages}
  alias Worker.Timeline.{Calendar, Graph, Resolver}

  defp utts, do: [%{id: "id-a"}, %{id: "id-b"}]

  defp parse_one(anchor_json) do
    raw =
      ~s({"facts":[{"claim":"Kodex durchsucht die Ruine.","character":"Kodex",) <>
        anchor_json <> ~s(,"source_refs":["u1"]}]})

    assert {:ok, [fact]} = Parsing.parse_facts_json(raw, utts())
    fact
  end

  describe "der Parser erhält jede Form, die der Prompt nennt" do
    test ~s("absolute") do
      assert parse_one(~s("time_anchor":"absolute","in_game_date":"20. März 1888"))["time_anchor"] ==
               "absolute"
    end

    test ~s("session") do
      assert parse_one(~s("time_anchor":"session"))["time_anchor"] == "session"
    end

    test ~s("event:<Stichwort>" — inkl. des Beispiels aus dem Prompt) do
      assert parse_one(~s("time_anchor":"event:Turmbrand"))["time_anchor"] == "event:turmbrand"
    end

    test ~s("unknown") do
      assert parse_one(~s("time_anchor":"unknown"))["time_anchor"] == "unknown"
    end

    test "Modell-Garbage fällt auf nil, statt zu crashen" do
      assert parse_one(~s("time_anchor":"irgendwas"))["time_anchor"] == nil
      assert parse_one(~s("time_anchor":42))["time_anchor"] == nil
      # `event:` ohne Stichwort ist keine Referenz — der Graph hätte nichts zu
      # matchen und degradierte ohnehin zu unknown.
      assert parse_one(~s("time_anchor":"event:"))["time_anchor"] == nil
    end
  end

  describe "der Resolver führt jede Form in einen EIGENEN Zweig" do
    # Gregorianischer Default-Kalender, Session-Anker auf einem bekannten Tag.
    defp cal, do: Calendar.default()
    defp anchor_day, do: 689_120

    test ~s("absolute" datiert aus dem Text, nicht vom Session-Anker) do
      fact = %{"time_anchor" => "absolute", "in_game_date" => "20. März 1888"}

      assert %{anchor_status: :resolved, in_game_day: day} =
               Resolver.resolve_one(fact, cal(), nil)

      # Ohne Session-Anker aufgelöst → die Quelle ist wirklich der Text.
      assert is_integer(day)
    end

    test ~s("session" datiert vom Session-Anker) do
      fact = %{"time_anchor" => "session"}

      assert %{anchor_status: :resolved, in_game_day: day} =
               Resolver.resolve_one(fact, cal(), anchor_day())

      assert day == anchor_day()
    end

    # Die Ereignis-Form geht über `Graph.resolve/4` statt über den Resolver
    # allein: dazwischen sitzt der Fuzzy-Match, der das vom Modell geschriebene
    # STICHWORT erst in die Ziel-Fakt-ID übersetzt (`normalize_event_anchor/3`).
    # Nur dieser Weg prüft, was ein echtes `"event:Turmbrand"` bewirkt — der
    # Resolver für sich sähe bereits eine ID und wüsste vom Stichwort nichts.
    test ~s("event:<Stichwort>" datiert relativ zum genannten Ereignis) do
      ziel = %{"claim" => "Der Turmbrand vernichtet das Archiv", "time_anchor" => "session"}

      quelle = %{
        "claim" => "Kodex durchsucht die Ruine",
        "time_anchor" => "event:Turmbrand",
        "time_offset" => %{"value" => 2, "unit" => "day"}
      }

      assert [r_ziel, r_quelle] = Graph.resolve([ziel, quelle], cal(), anchor_day())
      assert r_ziel["in_game_day"] == anchor_day()
      assert r_quelle["in_game_day"] == anchor_day() + 2
      assert r_quelle["anchor_status"] == "resolved"
    end

    test ~s("event:…" ohne auffindbares Ziel wird unknown, statt falsch datiert) do
      quelle = %{"claim" => "Kodex durchsucht die Ruine", "time_anchor" => "event:nie-erwähnt"}

      assert [r] = Graph.resolve([quelle], cal(), anchor_day())
      assert r["in_game_day"] == nil
      assert r["anchor_status"] == "unknown"
    end

    test ~s(mehrdeutiges Stichwort wird unknown — lieber Review-Queue als falsche Kante) do
      a = %{"claim" => "Der Turmbrand beginnt", "time_anchor" => "session"}
      b = %{"claim" => "Der Turmbrand erlischt", "time_anchor" => "session"}
      c = %{"claim" => "Kodex kommt an", "time_anchor" => "event:Turmbrand"}

      assert [_, _, r_c] = Graph.resolve([a, b, c], cal(), anchor_day())
      assert r_c["in_game_day"] == nil
    end
  end

  describe "Prompt und Schema nennen dieselben Formen" do
    defp prompt do
      Prompts.build_facts_extraction_prompt(
        [%{id: "id-a", discord_id: "d", text: "x", timestamp: ~U[2026-01-01 20:00:00Z]}],
        %{"d" => "SL"},
        ["Kodex"]
      )
    end

    defp anchor_description do
      get_in(Stages.facts_json_schema(["Kodex"]), [
        "properties",
        "facts",
        "items",
        "properties",
        "time_anchor",
        "description"
      ])
    end

    test "beide nennen alle vier Formen" do
      for form <- ~w(absolute session event: unknown) do
        assert prompt() =~ form, "Prompt nennt #{form} nicht"
        assert anchor_description() =~ form, "Schema-description nennt #{form} nicht"
      end
    end

    test "time_anchor ist required — optionale Felder lässt qwen zu ~100 % weg (#676)" do
      required =
        get_in(Stages.facts_json_schema([]), ["properties", "facts", "items", "required"])

      assert "time_anchor" in required
    end

    test "jedes Beispiel im Prompt trägt das Feld — sonst lernt das Modell es als weglassbar" do
      beispiele = Regex.scan(~r/\{"claim":.*?\}/, prompt()) |> Enum.map(&hd/1)
      assert length(beispiele) >= 7

      for b <- beispiele do
        assert b =~ ~s("time_anchor"), "Beispiel ohne time_anchor: #{String.slice(b, 0, 60)}…"
      end
    end
  end
end
