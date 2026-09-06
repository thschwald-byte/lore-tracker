defmodule Hub.SpeicherRueckgabeTest do
  @moduledoc """
  Issue #1148 (Epic #1146): Quelltext-Wächter für die drei Stellen, an denen
  der Hub großen Durchgangs-Müll ans System zurückgibt.

  **Warum ein Quelltext-Test und kein Verhaltenstest.** Die Wirkung ist
  Speicherfreigabe — sie hat keinen beobachtbaren Rückgabewert, keinen
  Nebeneffekt im State, keine Log-Zeile. Ein `:erlang.memory/0`-Vergleich im
  Test wäre von GC-Zufall dominiert und damit flaky. Was prüfbar ist: dass die
  drei Eingriffe überhaupt noch dastehen.

  **Und genau das ist der Fehlermodus.** Fällt ein `:hibernate` bei einem
  späteren Umbau weg (etwa weil jemand die Klausel umschreibt und das 3-Tupel
  für einen Tippfehler hält), wächst der betroffene Prozess wieder still auf
  seinen alten Wert — 29 MB beim Reader, gemessen. Nichts wird rot, kein Test
  schlägt fehl, und auffallen würde es erst beim nächsten OOM-Kill in Prod.
  Dieselbe Silent-Failure-Klasse, gegen die dieses Repo an mehreren Stellen
  Quelltext-Wächter hält (`recorder_stop_order_test.exs`,
  `voice_session_anchor_test.exs`, `local_time_guard_test.exs`).

  Gegenprobe beim Bau: jede der drei Assertions wurde durch Entfernen des
  jeweiligen Eingriffs rot gesehen.
  """

  use ExUnit.Case, async: true

  @reader "lib/hub/reader.ex"
  @channel "lib/hub_web/channels/worker_channel.ex"
  @campaign_live "lib/hub_web/live/campaign_live.ex"

  defp quelle(pfad), do: File.read!(Path.join(__DIR__, "../../" <> pfad))

  describe "Reader gibt den Payload-Heap nach dem Weiterreichen frei" do
    test "der finale Reply-Pfad hibernated" do
      # Der Reader SPEICHERT nichts — er reicht durch. Ohne :hibernate bleibt
      # der Snapshot-Term als Müll liegen, weil die generationelle GC eines
      # dauerhaft warmen Prozesses ihn nicht einsammelt.
      src = quelle(@reader)

      assert src =~
               ~r/GenServer\.reply\(entry\.from, \{:ok, payload\}\)\s*\n(\s*#[^\n]*\n)*\s*\{:noreply, %\{state \| pending: pending_map\}, :hibernate\}/,
             "reader.ex: der {:ok, payload}-Reply muss mit :hibernate enden (#1148) — " <>
               "sonst wächst der Reader wieder auf ~29 MB Durchgangsmüll"
    end

    test "der finale Timeout-Pfad hibernated" do
      src = quelle(@reader)

      assert src =~
               ~r/GenServer\.reply\(entry\.from, \{:error, :timeout\}\)\s*\n(\s*#[^\n]*\n)*\s*\{:noreply, %\{state \| pending: pending_map\}, :hibernate\}/,
             "reader.ex: auch der Timeout-Reply muss hibernaten (#1148) — " <>
               "ein Timeout bedeutet Last, und dann ist der Heap am vollsten"
    end
  end

  describe "WorkerChannel gibt den dekodierten Frame frei" do
    test "snapshot_response hibernated nach der Weitergabe an den Reader" do
      # Dieser Prozess dekodiert den WebSocket-Frame: 3,3 MB JSON zu einem Term
      # mit zehntausenden Maps. Nach dem cast an den Reader ist alles davon
      # Müll, ankert aber weiter das große refc-Binary.
      src = quelle(@channel)

      assert src =~ ~r/def handle_in\("snapshot_response".*?:hibernate\}?\s*\n\s*end/s,
             "worker_channel.ex: snapshot_response muss mit :hibernate enden (#1148)"
    end
  end

  describe "CampaignLive räumt nach großen Applies auf" do
    test "der Helfer existiert und ruft garbage_collect" do
      src = quelle(@campaign_live)

      assert src =~ ~r/defp collect_after_big_apply\(socket\) do/,
             "campaign_live.ex: collect_after_big_apply/1 fehlt (#1148)"

      assert src =~ ~r/:erlang\.garbage_collect\(self\(\)\)/,
             "campaign_live.ex: der Helfer muss tatsächlich sammeln (#1148)"
    end

    test "beide großen Apply-Pfade rufen ihn" do
      # Voll-Snapshot UND Scope-Apply — der Scope-Pfad trägt mit
      # campaign_luecken (2,4 MB) den größeren Brocken von beiden.
      src = quelle(@campaign_live)

      pfade =
        src
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "collect_after_big_apply"))
        |> Enum.reject(&(&1 =~ "defp "))

      assert length(pfade) >= 2,
             "campaign_live.ex: collect_after_big_apply/1 muss an BEIDEN großen " <>
               "Apply-Pfaden hängen (Voll-Snapshot + Scope), gefunden: #{length(pfade)} (#1148)"
    end

    test "der Helfer hängt NICHT an jedem Event-Pfad" do
      # Gegenrichtung: ein GC pro eingehendem Utterance-Event wäre teurer als
      # der Müll, den er einsammelt. Der Eingriff ist bewusst auf die zwei
      # Stellen begrenzt, an denen große Mengen ERSETZT werden.
      src = quelle(@campaign_live)

      aufrufe =
        src
        |> String.split("\n")
        |> Enum.count(&(&1 =~ "collect_after_big_apply" and not (&1 =~ "defp ")))

      assert aufrufe <= 3,
             "campaign_live.ex: #{aufrufe} Aufrufe von collect_after_big_apply/1 — " <>
               "der Eingriff soll auf die großen Applies begrenzt bleiben (#1148)"
    end
  end
end
