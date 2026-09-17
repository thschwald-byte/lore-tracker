defmodule Worker.MaterializerJackEposStandTest do
  @moduledoc """
  J6 (#1210, E4): Konvergenz und Kaskade für den Stand des Epos-Jack je
  Sitzung (`worker_jack_epos_staende`). Whole-Snapshot ⇒ Voll-Ersatz: nur der
  letzte Stand zählt, in jeder Reihenfolge (Muster
  `materializer_jack_resuemee_stand_test.exs`).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo

  @cid "camp-epos-stand-1210"
  @sid "sess-epos-stand-1210"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp stand(n),
    do: %{
      "notizen" => [
        %{
          "abschnitt" => "SZENEN",
          "schluessel" => "Regen",
          "zeile" => "Fassung #{n}",
          "fakten" => ["S1-F1"],
          "boegen" => []
        }
      ],
      "entwurf" => [%{"titel" => nil, "text" => "Absatz #{n}.", "szene" => "Regen"}],
      "quellen" => [
        %{
          "absatz" => 1,
          "titel" => nil,
          "szene" => "Regen",
          "fakten" => ["S1-F1"],
          "fakt_ids" => ["f_a"]
        }
      ],
      "zaehlwerte" => %{"absaetze" => 1},
      "modell" => "test-modell",
      "zeitpunkt" => "2026-09-13T10:00:00Z"
    }

  defp stand_ev(n, seq, event_id, sid \\ @sid) do
    event(
      "JackEposStandAbgelegt",
      %{"session_id" => sid, "campaign_id" => @cid, "stand" => stand(n)},
      seq,
      event_id: event_id
    )
  end

  defp zeile(sid \\ @sid) do
    case Repo.jack_epos_stand_for_session(sid) do
      %{stand: %{"notizen" => [%{"zeile" => z}]}} -> z
      nil -> nil
    end
  end

  test "der Stand kommt mit allen Feldern zurück" do
    Materializer.apply_event(stand_ev(1, 1, "01J0000000000000000000000A"))

    assert %{stand: s, event_id: "01J0000000000000000000000A"} =
             Repo.jack_epos_stand_for_session(@sid)

    assert s == stand(1)
  end

  test "LWW nach event_id: der jüngere Stand gewinnt, in beiden Reihenfolgen" do
    alt = stand_ev(1, 1, "01J0000000000000000000000A")
    neu = stand_ev(2, 2, "01J0000000000000000000000B")

    Materializer.apply_event(alt)
    Materializer.apply_event(neu)
    assert zeile() == "Fassung 2"

    reset_for_permutation!()
    Materializer.apply_event(neu)
    Materializer.apply_event(alt)
    assert zeile() == "Fassung 2"
  end

  test "ein kaputtes Ereignis wird verworfen, der Stand bleibt" do
    Materializer.apply_event(stand_ev(1, 1, "01J0000000000000000000000A"))

    Materializer.apply_event(
      event(
        "JackEposStandAbgelegt",
        %{"session_id" => @sid, "campaign_id" => @cid},
        2,
        event_id: "01J0000000000000000000000B"
      )
    )

    assert zeile() == "Fassung 1"
    assert Repo.jack_epos_stand_for_session("gibt-es-nicht") == nil
  end

  test "die Stände des Fakten-Jack und des Resümee-Jack bleiben davon unberührt — eigene Tabelle" do
    Materializer.apply_event(stand_ev(1, 1, "01J0000000000000000000000A"))
    assert Repo.jack_stand_for_session(@sid) == nil
    assert Repo.jack_resuemee_stand_for_session(@sid) == nil
  end

  test "SessionDeleted räumt den Stand der Sitzung, nicht den der anderen" do
    build_campaign(campaign_id: @cid, sessions: [1, 1], apply: true)
    s1 = "#{@cid}-s1"
    s2 = "#{@cid}-s2"

    Materializer.apply_event(stand_ev(1, 100, "01J0000000000000000000000A", s1))
    Materializer.apply_event(stand_ev(2, 101, "01J0000000000000000000000B", s2))

    Materializer.apply_event(
      event("SessionDeleted", %{"session_id" => s1, "campaign_id" => @cid}, 102,
        event_id: "01J0000000000000000000000C"
      )
    )

    assert Repo.jack_epos_stand_for_session(s1) == nil
    assert zeile(s2) == "Fassung 2"
  end

  test "CampaignDeleted räumt alle Stände der Kampagne" do
    build_campaign(campaign_id: @cid, sessions: [1], apply: true)
    s1 = "#{@cid}-s1"
    Materializer.apply_event(stand_ev(1, 100, "01J0000000000000000000000A", s1))

    Materializer.apply_event(
      event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 101,
        event_id: "01J0000000000000000000000B"
      )
    )

    assert Repo.jack_epos_stand_for_session(s1) == nil
  end
end
