defmodule Worker.CaptureLogFlushGuardTest do
  @moduledoc """
  Issue #1157: Quelltext-Wächter gegen eine Fehlerklasse, die sich nicht
  testen lässt, indem man sie auslöst.

  `Materializer.apply_event/1` ist ein `GenServer.call`. Ein `Logger`-Aufruf
  darin entsteht im **Materializer-Prozess**, nicht im Testprozess. Der Call
  kehrt zurück, sobald der Server geantwortet hat — ob der Logger die
  Nachricht bis dahin verarbeitet hat, ist nicht zugesichert. Schließt
  `capture_log` vorher, ist die Zeile weg und die Zusicherung scheitert mit
  `left: ""`.

  **Warum ein Wächter und kein Reproduktions-Test:** die Lücke hängt am
  Überlast-Verhalten des OTP-Loggers (unterhalb `sync_mode_qlen` wird
  synchron zugestellt, darüber asynchron). Auf einer ruhigen Maschine bleibt
  sie deshalb dauerhaft geschlossen — über zwei Sessions hinweg **0 von ~12**
  lokalen Läufen getroffen, darunter Läufe mit exakt der CI-Umgebung. Ein
  grüner Lauf beweist hier also nichts, und ein Test, der die Lücke öffnen
  will, müsste den Logger-Zustand global verbiegen und wäre selbst der
  nächste Flake.

  Was sich dagegen prüfen lässt: dass die Zeile **dasteht**. Genau dieselbe
  Bauart wie `recorder_stop_order_test.exs` (#1011) und
  `voice_session_anchor_test.exs` (#1060) — beides Invarianten, deren Bruch
  keinen Fehler erzeugt, sondern ein falsches Ergebnis.
  """
  use ExUnit.Case, async: true

  @dateien [
    "test/worker/materializer_bucket_c_convergence_test.exs",
    "test/worker/materializer_bucket_c2_convergence_test.exs"
  ]

  # Ein `capture_log(fn -> … end)`-Block, der einen dieser Prozess-wechselnden
  # Aufrufe enthält. Bewusst NICHT alle GenServer-Calls des Repos: der Wächter
  # soll die belegte Klasse festhalten, nicht eine Regel erfinden, die niemand
  # geprüft hat.
  @prozesswechsel ["Materializer.apply_event", "Materializer.apply_batch"]

  describe "capture_log um einen Prozesswechsel" do
    test "jeder betroffene Block ruft Logger.flush/0" do
      for datei <- @dateien do
        quelle = File.read!(Path.join(__DIR__, "../..") |> Path.join(datei))

        for {block, nr} <- capture_log_bloecke(quelle),
            Enum.any?(@prozesswechsel, &String.contains?(block, &1)) do
          assert String.contains?(block, "Logger.flush()"),
                 """
                 #{datei}: capture_log-Block ab Zeile #{nr} umschließt einen \
                 GenServer-Call, ruft aber kein Logger.flush/0.

                 Der Log entsteht dann in einem anderen Prozess, und ob er vor \
                 dem Schließen des Blocks verarbeitet ist, ist nicht zugesichert \
                 — der Test fällt sporadisch mit `left: ""` (Issue #1157).

                 Block:
                 #{block}
                 """
        end
      end
    end

    test "der Wächter findet die Blöcke überhaupt — sonst wäre er stumm grün" do
      # Ohne diese Gegenprobe wäre ein kaputter Parser nicht von „alles sauber"
      # zu unterscheiden. Beide Dateien MÜSSEN betroffene Blöcke haben.
      for datei <- @dateien do
        quelle = File.read!(Path.join(__DIR__, "../..") |> Path.join(datei))

        betroffen =
          capture_log_bloecke(quelle)
          |> Enum.filter(fn {b, _} -> Enum.any?(@prozesswechsel, &String.contains?(b, &1)) end)

        assert betroffen != [], "#{datei}: kein capture_log-Block mit Prozesswechsel gefunden"
      end
    end
  end

  # Schneidet `capture_log(` bis zum balancierten `end)` heraus. Klammer-Zählung
  # statt Regex, weil die Blöcke selbst Klammern und Zeilenumbrüche enthalten.
  defp capture_log_bloecke(quelle) do
    zeilen = String.split(quelle, "\n")

    zeilen
    |> Enum.with_index(1)
    |> Enum.filter(fn {z, _} -> String.contains?(z, "capture_log(fn") end)
    |> Enum.map(fn {_, nr} ->
      block =
        zeilen
        |> Enum.drop(nr - 1)
        |> Enum.reduce_while({[], 0, false}, fn z, {acc, tiefe, begonnen?} ->
          neue_tiefe =
            tiefe + count(z, "(") - count(z, ")")

          acc = [z | acc]

          cond do
            begonnen? and neue_tiefe <= 0 -> {:halt, {acc, neue_tiefe, true}}
            true -> {:cont, {acc, neue_tiefe, true}}
          end
        end)
        |> elem(0)
        |> Enum.reverse()
        |> Enum.join("\n")

      {block, nr}
    end)
  end

  defp count(s, zeichen), do: s |> String.graphemes() |> Enum.count(&(&1 == zeichen))
end
