defmodule Worker.Jack.AussageTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Aussage, Stand, Tor}

  # Erfundene Minimaltexte — die Prüfregeln brauchen keinen echten Mitschnitt.
  @bloecke [
    %{
      text: "Der Monitor piept laut, und Kodex flucht über den Deckel.",
      sprecher: "Spielleiter",
      block_id: "b_0"
    },
    %{text: "Ich trinke den Kaffee aus und gehe zur Tür.", sprecher: "Kodex", block_id: "b_1"},
    %{
      text: "Draußen regnet es seit drei Tagen ohne Pause.",
      sprecher: "Spielleiter",
      block_id: "b_2"
    },
    %{
      text: "Kommt der Wagen heute noch? Er kommt um acht Uhr am Tor.",
      sprecher: "Lucky",
      block_id: "b_3"
    },
    %{
      text: "Die Villa liegt oben am Hang über der Bucht.",
      sprecher: "Spielleiter",
      block_id: "b_4"
    }
  ]

  defp register do
    for {a, i} <- Enum.with_index(Stand.abschnitte() ++ Stand.abschnitte()),
        do: %{abschnitt: a, schluessel: "k#{i}", zeile: "Eintrag #{i}", bloecke: []}
  end

  defp stand(opts \\ []) do
    [
      bloecke: @bloecke,
      cast: ["Kodex", "Lucky"],
      register: register(),
      guid_quelle: fn n -> "guid-#{n}" end
    ]
    |> Keyword.merge(opts)
    |> Stand.neu()
  end

  defp aussage(felder \\ %{}) do
    Map.merge(
      %{
        "claim" => "Der Monitor piept laut.",
        "character" => "",
        "cast_match" => "",
        "narration_time" => "present",
        "time_anchor" => "session",
        "in_game_date" => "",
        "fact_type" => "zustand",
        "threads" => ["Einbruch"],
        "source_refs" => [0],
        "beleg" => "Der Monitor piept laut"
      },
      felder
    )
  end

  defp entscheidung(guid, ent, felder \\ %{}) do
    %{
      "verifikations_guid" => guid,
      "entscheidung" => ent,
      "begruendung" => "Sie nennt einen anderen Sachverhalt.",
      "weitere_guids" => []
    }
    |> Map.merge(felder)
    |> aussage()
  end

  # Eine Aussage eintragen und eine zweite an derselben Stelle vorlegen lassen.
  defp mit_vorlage(
         zweite \\ %{"claim" => "Kodex flucht über den Deckel.", "beleg" => "Kodex flucht"}
       ) do
    {s, {:ok, _}} = Aussage.einreichen(stand(), aussage())
    {s, {:error, %{"outcome" => "verify"} = a}} = Aussage.einreichen(s, aussage(zweite))
    {s, a}
  end

  defp guid(%{"aussagen" => aussagen}),
    do: Enum.find_value(aussagen, & &1["verifikations_guid"])

  test "eine Vorlage zählt als Ablehnung, wie im Spike, aber ohne abgelehnt.jsonl" do
    {s, _a} = mit_vorlage()
    assert s.abgelehnt == 1
    assert Enum.any?(Stand.journal_liste(s), &match?({"dubletten.jsonl", _}, &1))
    refute Enum.any?(Stand.journal_liste(s), &match?({"abgelehnt.jsonl", _}, &1))
  end

  describe "einreichen — Gerüst und Felder" do
    test "ohne Gerüst im Gedächtnis: no_scaffold, nichts eingetragen" do
      assert {s, {:error, a}} = Aussage.einreichen(stand(register: []), aussage())
      assert %{"outcome" => "no_scaffold", "bestand" => 0, "fehler" => [f]} = a
      assert f =~ "Dem Gerüst in deinem Gedächtnis fehlt: ## FIGUREN"
      assert [{"abgelehnt.jsonl", _}] = Stand.journal_liste(s)
    end

    test "zu dünnes Gedächtnis wird beim Namen genannt" do
      duenn = Enum.take(register(), 5)

      assert {_, {:error, %{"fehler" => [f]}}} =
               Aussage.einreichen(stand(register: duenn), aussage())

      assert f == "Dein Gedächtnis ist zu dünn: 5 Einträge mit Inhalt, mindestens 10."
    end

    test "Blöcke, die es nicht gibt" do
      assert {_, {:error, %{"outcome" => "fix", "fehler" => [f]}}} =
               Aussage.einreichen(stand(), aussage(%{"source_refs" => [9]}))

      assert f == "`source_refs` nennt Blöcke, die es nicht gibt: [9]. Gültig sind 0 bis 4."
    end

    test "cast_match nur aus cast(), der alte Escape-Wert ist abgewiesen" do
      assert {_, {:error, %{"fehler" => [f1]}}} =
               Aussage.einreichen(stand(), aussage(%{"cast_match" => "Deadman"}))

      assert f1 =~ "steht nicht in cast()"

      assert {_, {:error, %{"fehler" => [f2]}}} =
               Aussage.einreichen(stand(), aussage(%{"cast_match" => "(kein Cast-Treffer)"}))

      assert f2 =~ "gibt es nicht"

      assert {_, {:error, %{"fehler" => [f3]}}} =
               Aussage.einreichen(stand(), aussage(%{"character" => "(kein Cast-Treffer)"}))

      assert f3 =~ "benennt keine Figur"
    end
  end

  describe "formfehler/4 — was das Schema abweist, beantwortet das Werkzeug wie der Spike" do
    test "leere Pflichtfelder: fix mit den Texten des Spikes, zählt in den Versuchsdeckel" do
      # "" statt " ": ein Leerzeichen ist in JS „wahr“ — dann meldet der Spike
      # (und der Port) zusätzlich „keiner der erlaubten Werte“.
      f = aussage(%{"source_refs" => [], "fact_type" => "", "beleg" => ""})

      assert {s, {:error, %{"outcome" => "fix", "fehler" => fehler, "hinweis" => h}}} =
               Aussage.formfehler(stand(), f, "aussage", ["source_refs: zu kurz"])

      assert fehler == [
               "`source_refs` ist leer. Nenne mindestens einen Block, aus dem die Aussage stammt.",
               "`fact_type` ist leer. Erlaubt: ereignis, zustand, zustandsänderung, beziehung, " <>
                 "absicht, enthüllung, auflösung",
               "`beleg` ist leer. Zitier aus jedem Block in source_refs die Stelle, die die " <>
                 "Aussage trägt."
             ]

      assert h ==
               "Nichts eingetragen. Korrigiere die genannten Felder und rufe aussage() erneut auf."

      assert s.abgelehnt == 1
      assert [{"abgelehnt.jsonl", %{"versuch" => 1}}] = Stand.journal_liste(s)
    end

    test "fehlendes Feld, falscher Typ, unbekannter Enum-Wert, time_offset — in der Reihenfolge des Spikes" do
      f =
        aussage(%{
          "narration_time" => "gestern",
          "threads" => "Einbruch",
          "time_offset" => %{"value" => 1.5, "unit" => "stunde"}
        })
        |> Map.delete("beleg")

      {_, {:error, %{"fehler" => fehler}}} = Aussage.formfehler(stand(), f, "aussage", ["x"])

      assert fehler == [
               "`beleg` fehlt",
               "`threads` erwartet Liste, bekommen string",
               ~s(`narration_time` = "gestern" ist keiner der erlaubten Werte. ) <>
                 "Erlaubt: present, flashback, future, unknown",
               "`time_offset.value` erwartet eine ganze Zahl",
               ~s(`time_offset.unit` = "stunde" ist keine erlaubte Einheit. ) <>
                 "Erlaubt: day, week, month, year"
             ]
    end

    test "findet die Prüfung des Spikes nichts, gehen die Meldungen des Schemas durch; ohne Gerüst zuerst no_scaffold" do
      assert {_, {:error, %{"outcome" => "fix", "fehler" => ["fremd: nicht erlaubt"]}}} =
               Aussage.formfehler(stand(), Map.put(aussage(), "fremd", 1), "aussage", [
                 "fremd: nicht erlaubt"
               ])

      assert {_, {:error, %{"outcome" => "no_scaffold"}}} =
               Aussage.formfehler(stand(register: []), %{}, "aussage", ["claim: fehlt"])
    end
  end

  describe "einreichen — Belegzwang" do
    test "Beleg nicht im Block: fix, mit dem Text des unzitierten Blocks" do
      assert {_, {:error, %{"outcome" => "fix", "fehler" => fehler}}} =
               Aussage.einreichen(stand(), aussage(%{"beleg" => "Die Tür ist verschlossen"}))

      assert Enum.any?(fehler, &(&1 =~ "stehen in keinem der genannten Blöcke"))
      assert Enum.any?(fehler, &(&1 =~ "fehlt ein Zitat: [0]"))

      assert ~s(Block 0 lautet: "Spielleiter: Der Monitor piept laut, und Kodex flucht über den Deckel.") in fehler
    end

    test "mehrere Zitate mit „…“ über zwei Blöcke" do
      f =
        aussage(%{
          "source_refs" => [0, 1],
          "beleg" => "Der Monitor piept laut … trinke den Kaffee aus"
        })

      assert {_, {:ok, %{"outcome" => "written"}}} = Aussage.einreichen(stand(), f)
    end

    test "Frageprüfung: reine Frage abgelehnt, Frage mit Antwort trägt" do
      frage =
        aussage(%{
          "source_refs" => [3],
          "claim" => "Der Wagen kommt.",
          "beleg" => "Kommt der Wagen heute noch?"
        })

      assert {_, {:error, %{"fehler" => [f]}}} = Aussage.einreichen(stand(), frage)
      assert f =~ "Der Beleg besteht nur aus Fragen."

      mit_antwort = %{
        frage
        | "beleg" => "Kommt der Wagen heute noch? Er kommt um acht Uhr am Tor."
      }

      assert {_, {:ok, %{"outcome" => "written"}}} = Aussage.einreichen(stand(), mit_antwort)
    end

    test "der fünfte vergebliche Versuch mit derselben Aussage: exhausted; ein richtiger danach wird eingetragen" do
      falsch = aussage(%{"beleg" => "steht nirgends im Block"})

      s =
        Enum.reduce(1..4, stand(), fn _, s ->
          {s, {:error, %{"outcome" => "fix"}}} = Aussage.einreichen(s, falsch)
          s
        end)

      assert {s, {:error, %{"outcome" => "exhausted", "hinweis" => h}}} =
               Aussage.einreichen(s, falsch)

      assert h =~ "Das war dein 5. vergeblicher Versuch"
      assert {"abgelehnt.jsonl", %{"aufgegeben" => true}} = List.last(Stand.journal_liste(s))

      assert {s, {:ok, _}} = Aussage.einreichen(s, aussage())
      assert Stand.bestand_von(s, 1)["_versuche"] == 6
    end
  end

  describe "einreichen — eintragen" do
    test "die erste Aussage wird eingetragen; Jack sieht keine Nummer" do
      assert {s, {:ok, a}} = Aussage.einreichen(stand(), aussage())

      assert %{"outcome" => "written", "bestand" => 1, "themen" => ["Einbruch"], "fehler" => []} =
               a

      assert [%{"status" => "neu", "claim" => "Der Monitor piept laut."} = e] = a["aussagen"]
      refute Map.has_key?(e, "nummer")
      assert a["hinweis"] == "Gespeichert.\nMach mit deiner nächsten Aussage weiter."

      assert %{"nummer" => 1, "_pos" => 0, "_belegt" => true, "_iter" => 1, "_iter0" => 1} =
               Stand.bestand_von(s, 1)
    end

    test "Rückbezug ohne zweiten Block: Hinweis, aber eingetragen" do
      f =
        aussage(%{
          "claim" => "Kodex flucht wieder über den Deckel.",
          "beleg" => "Kodex flucht über den Deckel"
        })

      assert {_, {:ok, %{"hinweis" => h}}} = Aussage.einreichen(stand(), f)
      assert h =~ ~s(Der claim enthaelt "wieder" und nennt nur einen Block.)
    end
  end

  describe "einreichen — Verifikationstor" do
    test "eine Kollision wird mit GUID vorgelegt, nicht eingetragen" do
      {s, a} = mit_vorlage()
      assert %{"bestand" => 1, "fehler" => []} = a

      assert [
               %{"status" => "vorgelegt"},
               %{"status" => "bestehend", "verifikations_guid" => "guid-1"}
             ] = a["aussagen"]

      assert a["hinweis"] =~ "Du hast eine mögliche Übereinstimmung gefunden — verifiziere."
      assert a["hinweis"] =~ "aussage_entscheiden()"
      assert s.kollisionen == %{1 => 1}
      assert Tor.offen(s, "guid-1") == %{nr: 1, refs: [0]}
    end

    test "unabhängig wiedergefunden: der Bestand zählt die Bestätigung" do
      {s, _} = mit_vorlage(%{"claim" => "Der Monitor piept sehr laut."})
      assert Stand.bestand_von(s, 1)["_bestaetigt"] == 2
    end
  end

  describe "entscheiden" do
    test "neu: als eigene Aussage eingetragen, mit der Begründung im Bestand" do
      {s, a} = mit_vorlage()

      f =
        entscheidung(guid(a), "neu", %{
          "claim" => "Kodex flucht über den Deckel.",
          "beleg" => "Kodex flucht"
        })

      assert {s, {:ok, %{"outcome" => "written", "bestand" => 2, "aussagen" => [e]}}} =
               Aussage.entscheiden(s, f)

      assert e["entscheidung"] == %{
               "art" => "neu",
               "grund" => "Sie nennt einen anderen Sachverhalt."
             }

      assert Stand.bestand_von(s, 2)["entscheidung"]["gegen"] == 1
      refute Map.has_key?(Stand.bestand_von(s, 2), "verifikations_guid")
      assert Tor.schicksal(s, "guid-1") == :eingeloest
    end

    test "ersetzt: die bestehende Aussage nimmt die neue Fassung auf, der Bestand wächst nicht" do
      {s, a} = mit_vorlage()

      f =
        entscheidung(guid(a), "ersetzt", %{
          "claim" => "Kodex flucht über den Deckel.",
          "beleg" => "Kodex flucht"
        })

      assert {s, {:ok, %{"outcome" => "modify", "bestand" => 1}}} = Aussage.entscheiden(s, f)

      assert %{"claim" => "Kodex flucht über den Deckel.", "_ersetzt" => true} =
               Stand.bestand_von(s, 1)
    end

    test "ersetzt mit weitere_guids verwirft die mitabgelösten Aussagen" do
      {s, a} = mit_vorlage()
      zweite = %{"claim" => "Kodex flucht über den Deckel.", "beleg" => "Kodex flucht"}
      {s, {:ok, _}} = Aussage.entscheiden(s, entscheidung(guid(a), "neu", zweite))

      {s, {:error, %{"outcome" => "verify", "aussagen" => [_ | vorlagen]}}} =
        Aussage.einreichen(
          s,
          aussage(%{
            "claim" => "Der Monitor piept, Kodex flucht.",
            "beleg" => "Der Monitor piept laut, und Kodex flucht"
          })
        )

      [g1, g2] = Enum.map(vorlagen, & &1["verifikations_guid"])
      gegen = Tor.offen(s, g1).nr
      andere = Tor.offen(s, g2).nr

      f =
        entscheidung(g1, "ersetzt", %{
          "claim" => "Der Monitor piept, Kodex flucht.",
          "beleg" => "Der Monitor piept laut, und Kodex flucht",
          "weitere_guids" => [g2]
        })

      assert {s, {:ok, %{"outcome" => "modify", "aussagen" => aussagen, "hinweis" => h}}} =
               Aussage.entscheiden(s, f)

      assert Enum.map(aussagen, & &1["status"]) == ["ersetzt", "verworfen"]
      assert h =~ "Die Aussage aus weitere_guids wurde verworfen"
      assert %{"_verworfen" => true, "_abgeloest_von" => ^gegen} = Stand.bestand_von(s, andere)
    end

    test "erfundene GUID: fraud" do
      {s, _} = mit_vorlage()

      assert {s, {:error, %{"outcome" => "fraud", "fehler" => [f]}}} =
               Aussage.entscheiden(s, entscheidung("ausgedacht", "neu"))

      assert f =~ "nie ausgegeben"
      assert s.geraten == 1
    end

    test "eine GUID, die beim nächsten Aufruf nicht genannt wurde, ist verfallen" do
      {s, a} = mit_vorlage()

      other =
        aussage(%{
          "claim" => "Draußen regnet es.",
          "source_refs" => [2],
          "beleg" => "Draußen regnet es"
        })

      {s, {:ok, _}} = Aussage.einreichen(s, other)

      assert {_, {:error, %{"outcome" => "expired", "fehler" => [f]}}} =
               Aussage.entscheiden(s, entscheidung(guid(a), "neu"))

      assert f =~ "verfallen"
    end

    test "eine eingelöste GUID gilt kein zweites Mal" do
      {s, a} = mit_vorlage()

      f =
        entscheidung(guid(a), "neu", %{
          "claim" => "Kodex flucht über den Deckel.",
          "beleg" => "Kodex flucht"
        })

      {s, {:ok, _}} = Aussage.entscheiden(s, f)

      assert {_, {:error, %{"outcome" => "expired", "fehler" => [text]}}} =
               Aussage.entscheiden(s, f)

      assert text =~ "schon eingelöst"
    end

    test "GUID für eine andere Stelle: misplaced, die GUID ist verbraucht" do
      {s, a} = mit_vorlage()

      woanders = %{
        "claim" => "Die Villa liegt am Hang.",
        "source_refs" => [4],
        "beleg" => "Die Villa liegt oben am Hang"
      }

      assert {s, {:error, %{"outcome" => "misplaced", "fehler" => [f], "hinweis" => h}}} =
               Aussage.entscheiden(s, entscheidung(guid(a), "neu", woanders))

      assert f =~ "gehört zu Block 0, deine Aussage steht an Block 4"
      assert h =~ "An deiner Stelle steht nichts"
      assert Tor.schicksal(s, "guid-1") == :eingeloest
    end

    test "Riegel bei „neu“: wortgleich an denselben Blöcken ist dieselbe Aussage" do
      {s, a} = mit_vorlage(%{})

      assert {_, {:error, %{"outcome" => "verify", "aussagen" => [_, identisch], "hinweis" => h}}} =
               Aussage.entscheiden(s, entscheidung(guid(a), "neu"))

      assert identisch["status"] == "identisch"
      assert h =~ "Das ist dieselbe Aussage, kein zweiter Fund."
    end

    test "ersetzt durch den eigenen Wortlaut: kein Riegel, die abgelöste Aussage ist ausgenommen" do
      {s, a} = mit_vorlage(%{})

      assert {s, {:ok, %{"outcome" => "modify"}}} =
               Aussage.entscheiden(s, entscheidung(guid(a), "ersetzt"))

      assert length(s.eingetragen) == 1
    end

    test "Riegel bei „ersetzt“: wortgleich mit einer ANDEREN Aussage an denselben Blöcken" do
      kodex = %{"claim" => "Kodex flucht über den Deckel.", "beleg" => "Kodex flucht"}

      # #1 „Der Monitor piept laut.“, #2 wortgleich mit `kodex`, beide an Block 0
      {s, a} = mit_vorlage(kodex)

      {s, {:ok, %{"outcome" => "written"}}} =
        Aussage.entscheiden(s, entscheidung(guid(a), "neu", kodex))

      # eine dritte Fassung legt beide vor; ersetzt wird #1 — mit dem Wortlaut von #2
      dritte = %{"claim" => "Kodex flucht laut über den Deckel.", "beleg" => "Kodex flucht"}
      {s, {:error, %{"outcome" => "verify"} = v}} = Aussage.einreichen(s, aussage(dritte))

      g1 =
        Enum.find_value(v["aussagen"], fn e ->
          e["claim"] == "Der Monitor piept laut." && e["verifikations_guid"]
        end)

      assert {s, {:error, %{"outcome" => "verify", "hinweis" => h}}} =
               Aussage.entscheiden(s, entscheidung(g1, "ersetzt", kodex))

      assert h =~ "Nichts geändert. Deine Fassung steht wortgleich und aus denselben Blöcken"

      assert Enum.map(s.eingetragen, & &1.voll["claim"]) == [
               "Der Monitor piept laut.",
               kodex["claim"]
             ]

      assert {"dubletten.jsonl", %{"hart_abgelehnt" => 2, "entscheidung" => "ersetzt"}} =
               List.last(Stand.journal_liste(s))
    end

    test "zu knappe Begründung: fix, die GUID gilt beim nächsten Aufruf weiter" do
      {s, a} = mit_vorlage()
      zweite = %{"claim" => "Kodex flucht über den Deckel.", "beleg" => "Kodex flucht"}

      assert {s,
              {:error,
               %{"outcome" => "fix", "fehler" => ["`begruendung` fehlt oder ist zu knapp."]}}} =
               Aussage.entscheiden(
                 s,
                 entscheidung(guid(a), "neu", Map.put(zweite, "begruendung", "anders"))
               )

      assert {_, {:ok, %{"outcome" => "written"}}} =
               Aussage.entscheiden(s, entscheidung(guid(a), "neu", zweite))
    end

    test "weitere_guids bei „neu“ wird abgelehnt statt still übergangen" do
      {s, a} = mit_vorlage()

      f =
        entscheidung(guid(a), "neu", %{
          "claim" => "Kodex flucht über den Deckel.",
          "beleg" => "Kodex flucht",
          "weitere_guids" => ["x"]
        })

      assert {_, {:error, %{"outcome" => "fix", "fehler" => [text]}}} = Aussage.entscheiden(s, f)
      assert text =~ "gibt es nur bei entscheidung \"ersetzt\""
    end
  end
end
