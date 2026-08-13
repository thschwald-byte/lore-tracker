defmodule Worker.Discord.AnnounceQueueTest do
  @moduledoc """
  Issue #1013: die Entscheidungs-Seite der Beitritts-Ansagen. Jede dieser
  Regeln war der Grund, warum die Ansagen in #1005 bewusst NICHT verdrahtet
  wurden — hier sind sie einzeln festgenagelt, ohne Nostrum/GenServer.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.AnnounceQueue, as: Q

  describe "note_join/2 — Begrüßung nur beim ersten Mal" do
    test "erster Beitritt grüßt, jeder weitere nicht" do
      {v1, q} = Q.note_join(Q.new(), "111")
      {v2, q} = Q.note_join(q, "111")
      {v3, _} = Q.note_join(q, "111")

      assert v1 == :greet
      assert v2 == :skip
      assert v3 == :skip
    end

    test "REGRESSION-Schutz Reconnect-Schleife: Leave+Join+Leave+Join grüßt genau einmal" do
      # Ein instabiles Netz erzeugt Join-Transitionen im Minutentakt — ohne
      # Dedup würde der Bot die Person bei jedem Reconnect neu begrüßen.
      q = Q.new()

      verdicts =
        Enum.map_reduce(1..5, q, fn _, q -> Q.note_join(q, "flaky") end)
        |> elem(0)

      assert Enum.count(verdicts, &(&1 == :greet)) == 1
    end

    test "verschiedene Personen werden unabhängig gegrüßt" do
      {v1, q} = Q.note_join(Q.new(), "a")
      {v2, _} = Q.note_join(q, "b")

      assert {v1, v2} == {:greet, :greet}
    end

    test "seed_greeted: wer beim Bot-Join schon da war, wird NICHT nachbegrüßt" do
      # Die #989-Erst-Ansage spricht den ganzen Raum an — Einzelbegrüßungen
      # danach wären doppelt.
      q = Q.seed_greeted(Q.new(), ["alt-1", "alt-2"])

      assert {:skip, _} = Q.note_join(q, "alt-1")
      assert {:greet, _} = Q.note_join(q, "neu")
    end

    test "Integer- und String-IDs meinen dieselbe Person" do
      q = Q.seed_greeted(Q.new(), [111])
      assert {:skip, _} = Q.note_join(q, "111")
    end
  end

  describe "pending_batch/2 — Erinnerungs-Deckel" do
    test "liefert die fällige Gruppe und zählt hoch" do
      {batch, q} = Q.pending_batch(Q.new(), ["a", "b"])
      assert Enum.sort(batch) == ["a", "b"]

      # Zweite und dritte Erinnerung: noch erlaubt (Deckel ist seit #1032 drei).
      {batch2, q} = Q.pending_batch(q, ["a", "b"])
      assert Enum.sort(batch2) == ["a", "b"]

      {batch3, q} = Q.pending_batch(q, ["a", "b"])
      assert Enum.sort(batch3) == ["a", "b"]

      # Vierte: der Deckel greift — niemand mehr fällig.
      {batch4, _} = Q.pending_batch(q, ["a", "b"])
      assert batch4 == []
    end

    test "reset_pending_told/1 startet die Runde neu (Issue #1032)" do
      # Ein Beitritt setzt den Zähler zurück: die Lage im Kanal hat sich
      # geändert, also bekommt auch eine ausgeschöpfte Person wieder
      # Erinnerungen. Ohne diesen Reset wäre ein Spätankömmling nie erinnert
      # worden, weil die Runde ihr Kontingent längst verbraucht hätte.
      q =
        Enum.reduce(1..Q.max_pending_reminders(), Q.new(), fn _, q ->
          {_, q} = Q.pending_batch(q, ["a"])
          q
        end)

      assert {[], q} = Q.pending_batch(q, ["a"])
      assert {["a"], _} = Q.pending_batch(Q.reset_pending_told(q), ["a"])
    end

    test "REGRESSION-Schutz Nag-Loop: ein fremder Bot wird nie öfter als der Deckel erinnert" do
      # Ein Bot im Kanal kann nie zustimmen — ohne Deckel würde jeder
      # Timer-Ablauf eine neue Erinnerung mit seinem Namen produzieren.
      q = Q.new()

      total =
        Enum.map_reduce(1..10, q, fn _, q -> Q.pending_batch(q, ["fremder-bot"]) end)
        |> elem(0)
        |> Enum.count(&(&1 != []))

      assert total == Q.max_pending_reminders()
    end

    test "der Deckel zählt pro Person, nicht global" do
      q =
        Enum.reduce(1..Q.max_pending_reminders(), Q.new(), fn _, q ->
          {_, q} = Q.pending_batch(q, ["a"])
          q
        end)

      # a ist ausgeschöpft, b ist frisch → nur b fällig.
      {batch, _} = Q.pending_batch(q, ["a", "b"])
      assert batch == ["b"]
    end

    test "gezählt wird nur, wer wirklich angesagt wird — nicht das Vormerken" do
      # Ein leeres Fenster (alle weg/zugestimmt) verbraucht keinen Deckel.
      {[], q} = Q.pending_batch(Q.new(), [])
      {batch, _} = Q.pending_batch(q, ["a"])
      assert batch == ["a"]
    end

    test "doppelte IDs im selben Fenster zählen einmal" do
      {batch, q} = Q.pending_batch(Q.new(), ["a", "a"])
      assert batch == ["a"]

      {batch2, _} = Q.pending_batch(q, ["a"])
      assert batch2 == ["a"], "Dedup im Fenster darf nur EINE Erinnerung verbrauchen"
    end
  end

  describe "Namens-Cache" do
    test "merkt sich Namen und liefert sie zurück" do
      q = Q.note_name(Q.new(), "111", "Grognak")
      assert Q.name_for(q, "111") == "Grognak"
      assert Q.name_for(q, 111) == "Grognak"
    end

    test "nil/leer/Whitespace überschreibt einen bekannten Namen NICHT" do
      # Discord garantiert das member-Feld nicht — ein Event ohne Namen darf
      # den Cache nicht löschen.
      q = Q.note_name(Q.new(), "111", "Grognak")
      q = Q.note_name(q, "111", nil)
      q = Q.note_name(q, "111", "")
      q = Q.note_name(q, "111", "   ")

      assert Q.name_for(q, "111") == "Grognak"
    end

    test "unbekannte Person → nil (die Texte haben eine namenlose Fassung)" do
      assert Q.name_for(Q.new(), "999") == nil
    end
  end

  describe "Warteschlange" do
    test "FIFO: push hinten, pop vorne" do
      q = Q.new() |> Q.push({:join, "A"}) |> Q.push({:granted, "B"})

      {i1, q} = Q.pop(q)
      {i2, q} = Q.pop(q)
      {i3, _} = Q.pop(q)

      assert i1 == {:join, "A"}
      assert i2 == {:granted, "B"}
      assert i3 == nil
    end

    test "push_front legt das busy-abgelehnte Item wieder NACH VORNE" do
      # Voice.play hat abgelehnt — das Item ist noch nicht gesprochen und darf
      # seinen Platz nicht an später Gereihtes verlieren.
      q =
        Q.new()
        |> Q.push({:granted, "B"})
        |> Q.push_front({:join, "A"})

      {first, _} = Q.pop(q)
      assert first == {:join, "A"}
    end

    test "empty?/1" do
      assert Q.empty?(Q.new())
      refute Q.empty?(Q.push(Q.new(), {:join, nil}))
    end
  end
end
