defmodule Worker.GlattAnsichtGroesseTest do
  @moduledoc """
  Issue #1198: Größen-Wächter in Seattle-Größe.

  Am 10.09.2026 hat ein einziger Tab der Seattle-Kampagne den Prod-Hub dreimal
  umgebracht; der Auslöser war der Skelett-Read `campaign_luecken` (5.317
  Blöcke). Dieser Test baut dieselbe Blockverteilung nach (vier Sessions mit
  734 / 1574 / 1802 / 1207 Blöcken, rund ein Drittel mit Lücke — gemessen an
  seattleV4 zwischen 26 und 33 %) und vergleicht die neue Anzeige-Antwort mit
  der alten.

  Verglichen wird **relativ** zum alten Scope, nicht gegen eine feste
  Byte-Zahl: die Texte hier sind künstlich, eine absolute Grenze bewiese
  nichts über Prod. Was der Test belegt, ist die Struktur — die neue Antwort
  enthält nur Fenster, keine Liste aller Blöcke. Die echte Zahl kommt aus der
  Messung am laufenden `worker_prod` (Go/No-Go in #1198).
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Repo.Luecken

  @cid "glatt-groesse-camp"
  @owner "did-owner-gg"
  @groessen [734, 1574, 1802, 1207]

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      owner_did: @owner,
      sessions: List.duplicate(1, length(@groessen)),
      apply: true
    )

    for {n, idx} <- Enum.with_index(@groessen, 1) do
      sid = "#{@cid}-s#{idx}"

      blocks =
        for i <- 1..n//1 do
          %{
            "id" => "#{sid}-b#{i}",
            "speaker_discord_id" => @owner,
            "text" => "Block #{i} " <> String.duplicate("gesprochenes Wort ", 12),
            "quell_utterance_ids" => ["#{sid}-u#{i}", "#{sid}-u#{i}x"],
            "hat_luecke" => rem(i, 3) == 0
          }
        end

      Materializer.apply_event(
        event(
          "TranscriptSmoothed",
          %{
            "session_id" => sid,
            "campaign_id" => @cid,
            "smoothed_at" => "2026-09-10T08:00:00Z",
            "blocks" => blocks,
            "ooc_verworfen" => [],
            "rules_version" => 7,
            "merge_gap_seconds" => 8
          },
          60_000 + idx,
          event_id: "gg-sm-#{idx}"
        )
      )
    end

    :ok
  end

  test "die Anzeige-Antwort ist ein Bruchteil des alten Skelett-Reads" do
    {alt_us, alt} = :timer.tc(fn -> Luecken.panel(@cid, %{"glatt" => "fenster"}) end)

    {neu_us, neu} =
      :timer.tc(fn ->
        Repo.snapshot(%{
          "kind" => "campaign_glatt_ansicht",
          "id" => @cid,
          "viewer_discord_id" => @owner
        })
      end)

    alt_bytes = byte_size(Jason.encode!(alt))
    neu_bytes = byte_size(Jason.encode!(neu))

    # Messwerte nur auf Anfrage (`LORE_MESSWERTE=1 mix test …`): der Testlauf
    # loggt erst ab :warning, und eine Zeile je Lauf in jeder CI-Ausgabe wäre Rauschen.
    if System.get_env("LORE_MESSWERTE") do
      IO.puts(
        "[#1198] Skelett-Read #{div(alt_bytes, 1024)} KB in #{div(alt_us, 1000)} ms — " <>
          "Anzeige #{div(neu_bytes, 1024)} KB in #{div(neu_us, 1000)} ms"
      )
    end

    # Alt: jeder der 5.317 Blöcke reist mit.
    assert alt["smoothed"] |> Enum.map(&length(&1["blocks"])) |> Enum.sum() == Enum.sum(@groessen)

    # Neu: pro Session höchstens ein Fenster (Tail 150), sonst nichts.
    zahlen = Enum.map(neu["glatt_ansicht"], &length(&1["blocks"]))
    assert zahlen == [150, 150, 150, 150]

    # Die Blockzahl der Session steht trotzdem korrekt im Kopf.
    assert Enum.map(neu["glatt_ansicht"], & &1["block_count"]) == @groessen

    assert neu_bytes * 2 < alt_bytes,
           "Anzeige #{neu_bytes} B ist nicht einmal halb so groß wie der Skelett-Read #{alt_bytes} B"
  end
end
