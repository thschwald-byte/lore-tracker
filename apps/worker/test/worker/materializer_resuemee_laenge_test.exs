defmodule Worker.MaterializerResuemeeLaengeTest do
  @moduledoc """
  J5 (#1209): Konvergenz und Cascade für die Länge des Resümees
  (`CampaignResuemeeLaengeSet` → `worker_campaign_resuemee_laengen`) — und
  der Grund für den eigenen Fold-Slot: Name und Länge der Resümee-Vorgabe
  überschreiben einander nicht, in keiner Reihenfolge (#766-/#816-Klasse).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-resuemee-laenge-1209"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp laenge_ev(n, seq, event_id) do
    event(
      "CampaignResuemeeLaengeSet",
      %{"campaign_id" => @cid, "max_woerter" => n, "set_by" => "gm-did"},
      seq,
      event_id: event_id
    )
  end

  defp name_ev(name, seq, event_id) do
    event(
      "CampaignVorgabeSet",
      %{"campaign_id" => @cid, "stage" => "summary", "name" => name, "set_by" => "gm-did"},
      seq,
      event_id: event_id
    )
  end

  defp read(tbl, key) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(tbl, key) end)
    rows
  end

  # Die Row direkt: `:keine_row` unterscheidet „nie gesetzt“ von „auf nil gesetzt“.
  defp laenge do
    case read(S.campaign_resuemee_laengen(), @cid) do
      [{_, _cid, n, _ts}] -> n
      [] -> :keine_row
    end
  end

  defp name do
    case read(S.campaign_vorgaben(), "#{@cid}:summary") do
      [{_, _key, _cid, _stage, n, _form}] -> n
      [] -> nil
    end
  end

  test "ohne Ereignis nil, gesetzt reist sie mit get_campaign und campaign_meta zum Hub" do
    build_campaign(campaign_id: @cid, apply: true)
    assert Repo.get_campaign(@cid).resuemee_max_woerter == nil

    assert {:applied, 100} = Materializer.apply_event(laenge_ev(120, 100, "rl-1"))
    assert Repo.get_campaign(@cid).resuemee_max_woerter == 120

    snap =
      Repo.snapshot(%{
        "kind" => "campaign_meta",
        "id" => @cid,
        "viewer_discord_id" => "did-owner"
      })

    assert snap["campaign"]["resuemee_max_woerter"] == 120
  end

  test "zurücksetzen schreibt eine Row mit nil — kein Delete" do
    Materializer.apply_event(laenge_ev(120, 1, "rl-1"))
    assert laenge() == 120

    Materializer.apply_event(laenge_ev(nil, 2, "rl-2"))
    assert laenge() == nil
    assert read(S.campaign_resuemee_laengen(), @cid) != []
  end

  test "ein Text mit einer Zahl im Bereich gilt; ungültige Werte gelten als Standard, laut" do
    Materializer.apply_event(laenge_ev("200", 1, "rl-1"))
    assert laenge() == 200

    for {wert, i} <- Enum.with_index([5, 1001, "viel", 75.5, %{}], 2) do
      log = capture_log(fn -> Materializer.apply_event(laenge_ev(wert, i, "rl-#{i}")) end)
      assert log =~ "ungültige Länge"
      assert laenge() == nil
    end
  end

  test "bad campaign_id wird verworfen statt zu crashen" do
    ev = event("CampaignResuemeeLaengeSet", %{"campaign_id" => nil, "max_woerter" => 100}, 1)
    assert {:applied, 1} = Materializer.apply_event(ev)
  end

  test "LWW: der höhere event_id gewinnt, jede Reihenfolge konvergiert" do
    events = [laenge_ev(120, 1, "rl-1"), laenge_ev(nil, 2, "rl-2"), laenge_ev(300, 3, "rl-3")]
    results = materialize_permutations(events, &laenge/0)
    assert Enum.uniq(results) == [300]
  end

  test "Name und Länge überschreiben einander nicht, in keiner Reihenfolge" do
    setzen = [
      name_ev("Rückblick", 1, "rl-1"),
      laenge_ev(120, 2, "rl-2"),
      name_ev("Protokoll", 3, "rl-3")
    ]

    assert Enum.uniq(materialize_permutations(setzen, fn -> {laenge(), name()} end)) == [
             {120, "Protokoll"}
           ]

    # Ein Name-Ereignis ohne Namen löscht die Vorgabe-Row — die Länge bleibt.
    loeschen = [laenge_ev(120, 1, "rl-1"), name_ev("X", 2, "rl-2"), name_ev(nil, 3, "rl-3")]

    assert Enum.uniq(materialize_permutations(loeschen, fn -> {laenge(), name()} end)) == [
             {120, nil}
           ]

    # Ein Zurücksetzen der Länge lässt den Namen stehen.
    zurueck = [
      name_ev("Rückblick", 1, "rl-1"),
      laenge_ev(120, 2, "rl-2"),
      laenge_ev(nil, 3, "rl-3")
    ]

    assert Enum.uniq(materialize_permutations(zurueck, fn -> {laenge(), name()} end)) == [
             {nil, "Rückblick"}
           ]
  end

  test "ein Alt-Event ohne event_id überschreibt eine geschlüsselte Row nicht" do
    Materializer.apply_event(laenge_ev(120, 1, "rl-keyed"))

    Materializer.apply_event(
      event("CampaignResuemeeLaengeSet", %{"campaign_id" => @cid, "max_woerter" => 500}, 2)
    )

    assert laenge() == 120
  end

  test "CampaignDeleted-Cascade räumt Row und fold_meta" do
    build_campaign(campaign_id: @cid, apply: true)
    Materializer.apply_event(laenge_ev(120, 10, "rl-c"))

    fold_key = {S.campaign_resuemee_laengen(), @cid, :campaign_resuemee_laenge_set}
    assert read(S.fold_meta(), fold_key) != []

    Materializer.apply_event(event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 11))

    assert laenge() == :keine_row
    assert read(S.fold_meta(), fold_key) == []
  end
end
