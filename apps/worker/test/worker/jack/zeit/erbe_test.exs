defmodule Worker.Jack.Zeit.ErbeTest do
  @moduledoc """
  #1247: was der Prüf-Lauf vom Einsortier-Lauf erbt — **geprüft am ganzen
  Weg**, nicht an einem von Hand gebauten Stand.

  Der Anlass ist ein echter Totalverlust (20.09.2026, Teststage, seattleV5
  S1): `pruefen/3` legte `kette` in die Eingabe, `stand/2` packte sie nie
  aus. Der Prüf-Lauf startete vor einer leeren Kette, baute keine — sein
  Auftrag sagt ihm, er solle von den Befunden ausgehen — und sein Stand
  gewinnt am Ende. Die gesamte Einsortier-Arbeit eines fünfstündigen Laufs
  war damit weg; im abgelegten Stand stand `eingeordnet: 2168` neben
  `glieder: 0`.

  **Warum die bestehenden Tests das nicht fangen konnten:** Sie bauen ihren
  Stand direkt mit `Stand.neu(:pruefen, …, kette: …)` und reihen selbst ein.
  Damit prüfen sie die Schranke des Prüf-Laufs — und gehen an der Übergabe
  vorbei, die zwischen den Läufen liegt. Dieselbe Klasse wie der Stub, der
  eine innere Form nachbaute (#1149).
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit
  alias Worker.Jack.Zeit.Stand
  alias Worker.Timeline.Kette

  # Spielt ein Skript ab (Muster `epos/lauf_test.exs`) — kein Ollama.
  defmodule Skript do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      case Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
             [kopf | rest] -> {kopf, rest}
             [] -> {nil, []}
           end) do
        nil -> raise "Skript erschöpft; zuletzt: #{inspect(Enum.take(nachrichten, -2))}"
        schritt -> {:ok, schritt}
      end
    end
  end

  defp antwort(aufrufe),
    do: %{text: nil, denken: nil, aufrufe: aufrufe, stopp: :werkzeuge, nutzung: nil}

  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp skript(schritte) do
    {:ok, s} = Agent.start_link(fn -> schritte end)
    [modell: {Skript, skript: s}]
  end

  defp zeile(nr, id, text),
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "SL",
      text: text,
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp eingabe do
    %{
      mitschnitt: [
        zeile(1, "u1", "Es ist jetzt zweiundzwanzig Uhr."),
        zeile(2, "u2", "Ihr geht los."),
        zeile(3, "u3", "Ihr kommt an.")
      ],
      session_id: "sess-erbe",
      campaign_id: "camp-erbe"
    }
  end

  # Gedächtnis → Einsortieren (baut zwei Glieder, reiht alles ein) →
  # Prüfen (schliesst sofort ab, wie im echten Lauf).
  defp drei_laeufe do
    skript([
      # Lauf 1: Gedächtnis
      antwort([aufruf("lies_sprechlinie", %{"ab" => 1, "anzahl" => 3})]),
      antwort([aufruf("fertig", %{})]),
      # Lauf 2: Einsortieren
      antwort([aufruf("lies_sprechlinie", %{"ab" => 1, "anzahl" => 3})]),
      antwort([aufruf("haenge_an_kette", %{"von" => 1, "bis" => 2, "grund" => "der Aufbruch"})]),
      antwort([aufruf("haenge_an_kette", %{"zeilen" => [3], "grund" => "die Ankunft"})]),
      antwort([aufruf("fertig", %{})]),
      # Lauf 3: Prüfen — er baut NICHTS, so wie sein Auftrag es vorsieht.
      antwort([aufruf("lies_kette", %{})]),
      antwort([aufruf("fertig", %{})])
    ])
  end

  describe "die Kette überlebt den Prüf-Lauf" do
    test "der abgelegte Stand trägt die Glieder des Einsortier-Laufs" do
      # Der Kern: Lauf 3 gewinnt, also muss er geerbt haben, was Lauf 2 getan
      # hat. Vor dem Fix war die Kette hier leer — und zwar ohne jeden Fehler.
      assert {:ok, r} = Zeit.laufen(eingabe(), drei_laeufe())

      assert r.geprueft?, "der Prüf-Lauf ist durchgelaufen"
      assert Kette.anzahl(r.stand.kette) == 2
      assert Kette.reihenfolge(r.stand.kette) == ~w(u1 u2 u3)
      assert Kette.glied_von(r.stand.kette, "u3").grund == "die Ankunft"
    end

    test "und die Zahlen widersprechen sich nicht" do
      # Der sichtbare Teil des Defekts war ein Widerspruch: alles eingeordnet,
      # nichts in der Kette. Genau das darf nicht wieder entstehen.
      {:ok, r} = Zeit.laufen(eingabe(), drei_laeufe())
      z = Stand.zahlen(r.stand)

      assert z.eingeordnet == 3
      assert z.in_der_kette == 3
      assert z.unentschieden == 0
      assert z.glieder == 2
    end
  end

  describe "jedes Erbstück kommt an" do
    test "die Liste ist vollständig — kein Feld wird still fallengelassen" do
      # `erbe/1` ist die EINE Liste, aus der beide Seiten lesen. Wer sie
      # erweitert, ohne dass `Stand.neu/3` das Feld kennt, bekommt hier rot
      # statt eines leeren Ergebnisses.
      voll = %Stand{
        anker: %{"z_1" => %{anker_id: "z_1", art: :zeitpunkt, utterance_ids: ["u1"]}},
        notizen: %{"k" => %{"text" => "t"}},
        gelesen: MapSet.new(["u1"]),
        einordnung: %{"u1" => :ingame},
        kette: Kette.neu() |> then(fn k -> elem(Kette.anhaengen(k, ["u1"]), 1) end),
        konflikte: [%{text: "widerspruch"}]
      }

      erbe = Zeit.erbe(voll)
      neu = Stand.neu(:pruefen, [], Map.to_list(erbe))

      assert map_size(neu.anker) == 1
      assert neu.notizen == voll.notizen
      assert neu.gelesen == voll.gelesen
      assert neu.einordnung == voll.einordnung
      assert neu.kette == voll.kette
      assert neu.konflikte == voll.konflikte

      for {feld, _} <- erbe do
        assert Map.get(neu, feld) not in [nil, %{}, [], MapSet.new()],
               "das Erbstück #{feld} ist in Stand.neu/3 nicht angekommen"
      end
    end
  end
end
