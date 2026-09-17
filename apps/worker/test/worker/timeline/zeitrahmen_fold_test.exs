defmodule Worker.Timeline.ZeitrahmenFoldTest do
  @moduledoc """
  Issue #1069 (E7): der Session-Zeitrahmen in `session_anchors`.

  Zwei Producer schrieben dieselbe Row — der GM setzt das In-Game-Datum, der
  Zeit-Vorlauf schrieb den abgeleiteten Rahmen. Das ist genau die
  Konstellation, in der ein gemeinsamer Fold-Guard divergiert (#816):
  fold-granularer Guard plus feld-granulares Preserve. Deshalb zwei getrennte
  Fold-Keys, und deshalb diese Tests.

  **Issue #1213: den Vorlauf gibt es nicht mehr.** Neue
  `SessionZeitrahmenSet`-Ereignisse entstehen nicht, und gelesen wird die
  Spalte nirgends. Der Fold bleibt trotzdem, damit ein Replay des
  Ereignis-Logs alte Ereignisse anwendet und bestehende Zeilen unverändert
  bleiben — und genau das prüfen diese Tests. Sie lesen die Spalte deshalb
  roh aus der Tabelle statt über `Repo.get_session_anchor/1`, dessen
  `rahmen`-Feld mit #1213 entfallen ist.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-zeitrahmen"
  @sid "sess-zeitrahmen"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

    Builder.write!(Builder.campaign(@cid))
    Builder.write!(Builder.session(@sid, @cid, number: 1))
    :ok
  end

  # Die Spalte roh lesen: seit #1213 gibt es keinen Reader mehr, der sie
  # dekodiert. Geprüft wird trotzdem der Inhalt, nicht nur die Anwesenheit —
  # ein Fold, der irgendetwas schreibt, wäre kein Beleg.
  defp rahmen(sid) do
    {:atomic, json} =
      :mnesia.transaction(fn ->
        case :mnesia.read(S.session_anchors(), sid) do
          [{_, _, _, _, _, _, r}] -> r
          _ -> nil
        end
      end)

    case json do
      j when is_binary(j) -> Jason.decode!(j)
      other -> other
    end
  end

  defp rahmen_event(seq, opts \\ []) do
    event(
      "SessionZeitrahmenSet",
      %{
        "session_id" => @sid,
        "campaign_id" => @cid,
        "rahmen" => %{
          "tageszeit" => Keyword.get(opts, :tageszeit, "abend"),
          "tagesgrenzen" => Keyword.get(opts, :tagesgrenzen, 0),
          "jahr_kandidaten" => Keyword.get(opts, :jahre, [[2080, 2], [2070, 1]]),
          "harte_anker" => 3,
          "degradierte_anker" => 9,
          "belege" => [%{"block_id" => "b1", "wortlaut" => "Guten Abend"}]
        }
      },
      seq
    )
  end

  defp anker_event(seq, raw) do
    event(
      "SessionInGameAnchorSet",
      %{"session_id" => @sid, "campaign_id" => @cid, "in_game_date_raw" => raw},
      seq
    )
  end

  describe "ein Alt-Ereignis kommt im Replay weiter an" do
    test "und landet vollständig in der Spalte" do
      assert {:applied, 1} = Materializer.apply_event(rahmen_event(1))

      r = rahmen(@sid)
      assert r["tageszeit"] == "abend"
      assert r["tagesgrenzen"] == 0
      assert r["jahr_kandidaten"] == [[2080, 2], [2070, 1]]
      assert [%{"wortlaut" => "Guten Abend"}] = r["belege"]
    end

    test "ohne solches Ereignis bleibt die Spalte nil — nicht leer" do
      # „Kein Rahmen geschrieben" und „Rahmen geschrieben, aber leer" sind
      # verschiedene Aussagen; der Fold darf die erste nicht zur zweiten machen.
      assert {:applied, 1} = Materializer.apply_event(anker_event(1, "15.11.2080"))
      assert rahmen(@sid) == nil
    end
  end

  describe "zwei Producer, eine Row (D12)" do
    test "der GM-Anker löscht den Rahmen nicht" do
      assert {:applied, 1} = Materializer.apply_event(rahmen_event(1))
      assert {:applied, 2} = Materializer.apply_event(anker_event(2, "15.11.2080"))

      assert Repo.get_session_anchor(@sid).in_game_date_raw == "15.11.2080", "GM-Feld gesetzt"
      assert rahmen(@sid)["tageszeit"] == "abend", "Rahmen überlebt"
    end

    test "der Rahmen löscht das GM-Datum nicht" do
      assert {:applied, 1} = Materializer.apply_event(anker_event(1, "15.11.2080"))
      assert {:applied, 2} = Materializer.apply_event(rahmen_event(2))

      a = Repo.get_session_anchor(@sid)
      assert a.in_game_date_raw == "15.11.2080", "GM-Feld überlebt"
      assert is_integer(a.in_game_day), "und bleibt aufgelöst"
      assert rahmen(@sid)["tageszeit"] == "abend"
    end

    test "beide Reihenfolgen führen zum selben Zustand" do
      # Der Kern der Konvergenz: bei zwei Workern kommen die Events in
      # beliebiger Reihenfolge an. Divergieren sie hier, divergiert die
      # Kampagne.
      zustand = fn ->
        a = Repo.get_session_anchor(@sid)
        {a.in_game_date_raw, a.in_game_day, rahmen(@sid)["tageszeit"]}
      end

      Materializer.apply_event(rahmen_event(1))
      Materializer.apply_event(anker_event(2, "15.11.2080"))
      erst_rahmen = zustand.()

      clear_all_tables!()
      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session(@sid, @cid, number: 1))

      Materializer.apply_event(anker_event(3, "15.11.2080"))
      Materializer.apply_event(rahmen_event(4))
      erst_anker = zustand.()

      assert erst_rahmen == erst_anker
    end
  end

  describe "LWW innerhalb des eigenen Folds" do
    test "ein neuerer Rahmen ersetzt den älteren" do
      Materializer.apply_event(rahmen_event(1, tageszeit: "morgen"))
      Materializer.apply_event(rahmen_event(2, tageszeit: "abend"))
      assert rahmen(@sid)["tageszeit"] == "abend"
    end

    test "ein Rahmen ohne session_id wird verworfen, nicht geschrieben" do
      ev = event("SessionZeitrahmenSet", %{"campaign_id" => @cid, "rahmen" => %{}}, 1)
      assert {:applied, 1} = Materializer.apply_event(ev)
      assert Repo.get_session_anchor(@sid) == nil
    end
  end
end
