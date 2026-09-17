defmodule Worker.Jack.Resuemee.LesebasisTest do
  # E0 (#1210): die gemeinsame Lesebasis des Resümee-Jack — suche_sitzung,
  # suche_bisher mit Blättern, der Mitschnitt früherer Sitzungen (erst beim
  # Zugriff geladen), fakt(id) mit alten Belegen, boegen_kampagne und
  # vorige_kapitel. Rein auf dem Stand, der Lader ist ein Fake. Beispiele aus
  # der Demo-Welt (Werkstatt am Hafen).
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee.{Bisher, Eingabe, Halter, Lesen, Stand, Suche, Werkzeuge}
  alias Worker.Jack.Resuemee.Zusammenfassung

  @uhrmacher "Der verschwundene Uhrmacher"
  @spieldose "Die Spieldose"
  @keine_frueheren "Es gibt keine früheren Sitzungen — mit dieser Sitzung beginnt die Aufzeichnung."

  @s1_bloecke [
    %{text: "Tess legt den Brief auf den Tisch.", sprecher: "SL", block_id: "s1-b0"},
    %{text: "Der Alte stellt die Spieldose ins Regal.", sprecher: "SL", block_id: "s1-b1"}
  ]

  defp zuordnung do
    %{
      "f_1" => [%{titel: @spieldose, kind: "arc"}],
      "f_2" => [%{titel: @uhrmacher, kind: "arc"}],
      "f_3a" => [%{titel: @spieldose, kind: "arc"}],
      "f_3b" => [%{titel: @uhrmacher, kind: "arc"}]
    }
  end

  defp threads do
    [
      %{
        canonical: @spieldose,
        leitfrage: "Wem gehört die Spieldose?",
        arc_status: "offen",
        status: :offen
      },
      %{
        canonical: @uhrmacher,
        leitfrage: "Wo ist der Uhrmacher?",
        arc_status: "offen",
        status: :offen
      }
    ]
  end

  defp roh(id, claim, refs),
    do: %{"id" => id, "claim" => claim, "source_refs" => refs, "narration_time" => "present"}

  defp viele(n),
    do:
      for(
        i <- 0..(n - 1),
        do: %{text: "Die Uhr Nummer #{i} tickt.", sprecher: "SL", block_id: "u#{i}"}
      )

  # Sitzung 3; davor Sitzung 1 (mit Mitschnitt) und Sitzung 2 (ohne Glättung).
  defp eingabe(opts) do
    test = self()

    bloecke =
      Keyword.get(opts, :bloecke, [
        %{text: "Die Spieldose zeigt nach Norden.", sprecher: "SL", block_id: "b0"},
        %{text: "Ich kaufe Laternen.", sprecher: "Brann", block_id: "b1"}
      ])

    positionen = bloecke |> Enum.with_index() |> Map.new(fn {b, i} -> {b.block_id, i} end)

    fakten =
      Eingabe.fakten(
        [
          roh("f_3a", "Die Spieldose zeigt nach Norden.", ["b0"]),
          roh("f_3b", "Brann kauft Laternen für den Uhrmacher.", ["b1"])
        ],
        3,
        zuordnung(),
        positionen
      )

    s1 =
      Eingabe.fakten(
        [roh("f_1", "Der Alte stellt die Spieldose ins Regal.", ["s1-b1", "weg"])],
        1,
        zuordnung(),
        nil
      )

    s2 = Eingabe.fakten([roh("f_2", "Tess sucht den Uhrmacher.", ["s2-b0"])], 2, zuordnung(), nil)

    lader =
      Keyword.get(opts, :lader, fn nummer ->
        send(test, {:geladen, nummer})

        case nummer do
          1 -> {:ok, @s1_bloecke}
          _ -> {:error, {:extraction, {:jack, :keine_glaettung}}}
        end
      end)

    %{
      sitzung: %{id: "s3", nummer: 3, name: "Nach Norden"},
      fakten: fakten,
      fruehere: [
        %{nummer: 1, name: "Die Werkstatt", fakten: s1},
        %{nummer: 2, name: "Der Brief", fakten: s2}
      ],
      boegen: Eingabe.boegen(fakten, threads()),
      boegen_kampagne: Eingabe.boegen(s1 ++ s2 ++ fakten, threads()),
      vorige_resuemees: [
        %{nummer: 1, name: "Die Werkstatt", text: "Die Gruppe findet die Spieldose."}
      ],
      vorige_gedanken: [
        %{
          nummer: 1,
          name: "Die Werkstatt",
          fakten_jack: [
            %{
              "abschnitt" => "FIGUREN",
              "schluessel" => "Mira",
              "zeile" => "kennt die Spieldose",
              "bloecke" => [1]
            }
          ],
          resuemee_jack: %{
            "notizen" => [
              %{
                "abschnitt" => "GLIEDERUNG",
                "schluessel" => "1",
                "zeile" => "Spieldose im Regal",
                "fakten" => ["S1-F1"],
                "boegen" => []
              }
            ]
          },
          # J6 (#1210, E4): die Notizen des Epos-Jack jener Sitzung.
          epos_jack: %{
            "notizen" => [
              %{
                "abschnitt" => "SZENEN",
                "schluessel" => "Regal",
                "zeile" => "Die Spieldose im Regal, bei Kerzenlicht",
                "fakten" => ["S1-F1"],
                "boegen" => []
              }
            ]
          }
        },
        %{nummer: 2, name: "Der Brief", fakten_jack: nil, resuemee_jack: nil}
      ],
      kapitel: [
        %{
          nummer: 1,
          name: "Die Werkstatt",
          text:
            "## Kapitel 1 — Herbst\n\nRegen über dem Hafen.\n\nDie Spieldose schweigt im Regal."
        },
        %{
          nummer: 3,
          name: "Nach Norden",
          text: "## Kapitel 3\n\nEine alte Fassung mit der Spieldose."
        }
      ],
      chronik: [
        %{
          nummer: 1,
          datum: "3. Oktober",
          label: "Der Auftrag",
          text: "Tess vergibt den Auftrag, die Spieldose zu finden."
        },
        %{nummer: nil, datum: nil, label: "Ohne Sitzung", text: "Nichts dazu."}
      ],
      resuemee_diese: "Bisher: die Spieldose weist nach Norden.",
      register_diese: [
        %{"abschnitt" => "ABLAUF", "schluessel" => "0-1", "zeile" => "Spieldose und Laternen"}
      ],
      mitschnitt_laden: lader,
      bloecke: bloecke,
      cast: ["Mira", "Brann", "Tess"],
      straenge: [@spieldose, @uhrmacher],
      ueberschrift: "Resümee",
      flavor: %{base: nil, summary: nil}
    }
  end

  defp stand(opts \\ []), do: Stand.neu(eingabe(opts))

  defp defs(s), do: Map.new(Lesen.werkzeuge(s), &{&1.name, &1})

  describe "suche_sitzung" do
    test "Fakten, Mitschnitt und Bögen dieser Sitzung, je Quelle gruppiert; Früheres bleibt draußen" do
      {_s, {:ok, t}} = Suche.suche_sitzung(stand(), %{"begriff" => "SPIELDOSE"})

      assert t =~ "Suche nach „SPIELDOSE“ in Sitzung 3"

      assert t =~
               "## Fakten — 1 Treffer, hier 1 bis 1, keine weiteren\n" <>
                 "S3-F1 · Die Spieldose zeigt nach Norden."

      assert t =~
               "## Mitschnitt — 1 Treffer, hier 1 bis 1, keine weiteren\n" <>
                 "S3 Block 0 · SL · Die Spieldose zeigt nach Norden."

      assert t =~
               "## Bögen — 1 Treffer, hier 1 bis 1, keine weiteren\n" <>
                 "Bogen „#{@spieldose}“ · arc, offen · " <>
                 "#{@spieldose} — Leitfrage: Wem gehört die Spieldose?"

      refute t =~ "S1-F1"
      refute t =~ "Regal"
      refute_received {:geladen, _}
    end

    test "ein Wortteil genügt; Quellen ohne Treffer werden genannt" do
      {_s, {:ok, t}} = Suche.suche_sitzung(stand(), %{"begriff" => "laterne"})

      assert t =~ "S3-F2 · Brann kauft Laternen für den Uhrmacher."
      assert t =~ "S3 Block 1 · Brann · Ich kaufe Laternen."
      assert t =~ "Ohne Treffer: Bögen."
    end

    test "ohne Treffer und mit zu kurzem Begriff" do
      assert {_s, {:ok, t}} = Suche.suche_sitzung(stand(), %{"begriff" => "Salzmine"})
      assert t =~ "Keine Treffer."

      assert {_s, {:error, t}} = Suche.suche_bisher(stand(), %{"begriff" => " Uh "})
      assert t =~ "mindestens drei Zeichen"
    end
  end

  describe "suche_bisher" do
    test "alle Quellen bis einschließlich dieser Sitzung, je Treffer mit Adresse" do
      s = stand()

      s = %{
        s
        | notizen: [
            %{
              abschnitt: "OFFEN",
              schluessel: "Dose",
              zeile: "Wer spielte die Spieldose?",
              fakten: [],
              boegen: []
            }
          ]
      }

      {s, {:ok, t}} = Suche.suche_bisher(s, %{"begriff" => "spieldose"})

      assert t =~ "Suche nach „spieldose“ in allem bis einschließlich Sitzung 3."

      assert t =~
               "## Fakten — 2 Treffer, hier 1 bis 2, keine weiteren\n" <>
                 "S1-F1 · Der Alte stellt die Spieldose ins Regal.\n" <>
                 "S3-F1 · Die Spieldose zeigt nach Norden."

      assert t =~ "## Mitschnitt — 2 Treffer, hier 1 bis 2, keine weiteren"
      assert t =~ "S1 Block 1 · SL · Der Alte stellt die Spieldose ins Regal."
      assert t =~ "S3 Block 0 · SL · Die Spieldose zeigt nach Norden."

      assert t =~ "## Resümees — 2 Treffer"
      assert t =~ "Resümee S1, Absatz 1 · Die Gruppe findet die Spieldose."

      assert t =~
               "Resümee S3 (bisherige Fassung), Absatz 1 · Bisher: die Spieldose weist nach Norden."

      assert t =~ "## Epos-Kapitel — 2 Treffer"
      assert t =~ "Kapitel S1, Absatz 3 · Die Spieldose schweigt im Regal."

      assert t =~
               "Kapitel S3 (bisherige Fassung), Absatz 2 · Eine alte Fassung mit der Spieldose."

      assert t =~ "## Notizen der Jacks — 5 Treffer"
      assert t =~ "S1 Gedächtnis FIGUREN / Mira · kennt die Spieldose"
      assert t =~ "S1 Resümee-Notiz GLIEDERUNG / 1 · Spieldose im Regal"
      # J6 (#1210, E4): die Szenen des Epos-Jack sind durchsuchbar.
      assert t =~ "S1 Epos-Notiz SZENEN / Regal · Die Spieldose im Regal, bei Kerzenlicht"
      assert t =~ "S3 Gedächtnis ABLAUF / 0-1 · Spieldose und Laternen"
      assert t =~ "S3 Resümee-Notiz OFFEN / Dose · Wer spielte die Spieldose?"

      assert t =~ "## Bögen — 1 Treffer"

      assert t =~
               "## Chronik — 1 Treffer, hier 1 bis 1, keine weiteren\n" <>
                 "Chronik S1 · 3. Oktober · Der Auftrag · " <>
                 "Tess vergibt den Auftrag, die Spieldose zu finden."

      # Sitzung 2 ist nicht geglättet: ein Hinweis, kein Absturz.
      assert t =~
               "Mitschnitt nicht durchsucht: Zu Sitzung 2 liegt kein Mitschnitt vor: " <>
                 "sie ist nicht geglättet."

      # Jede frühere Sitzung wird genau einmal geladen, danach aus dem Stand.
      assert_received {:geladen, 1}
      assert_received {:geladen, 2}
      assert s.mitschnitte |> Map.keys() |> Enum.sort() == [1, 2]

      {_s, {:ok, t}} = Suche.suche_bisher(s, %{"begriff" => "Brief"})
      assert t =~ "S1 Block 0 · SL · Tess legt den Brief auf den Tisch."
      refute_received {:geladen, _}
    end
  end

  describe "Deckel und Blättern" do
    test "höchstens 20 je Quelle; weiter liefert die nächsten, bis nichts mehr folgt" do
      s = stand(bloecke: viele(45))

      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "uhr"})

      assert t =~
               "## Mitschnitt — 45 Treffer, hier 1 bis 20, 25 folgen " <>
                 "(derselbe Begriff mit weiter: true)"

      assert t =~ "S3 Block 19 · SL"
      refute t =~ "S3 Block 20 ·"
      # „Uhrmacher“: ein Wortteil genügt, im Fakt wie im Bogentitel.
      assert t =~ "## Fakten — 1 Treffer, hier 1 bis 1, keine weiteren"
      assert t =~ "## Bögen — 1 Treffer, hier 1 bis 1, keine weiteren"

      # Groß-/Kleinschreibung egal, auch beim Blättern; wer nichts mehr hat,
      # fällt heraus.
      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "UHR", "weiter" => true})
      assert t =~ "Die nächsten Treffer."
      assert t =~ "## Mitschnitt — 45 Treffer, hier 21 bis 40, 5 folgen"
      assert t =~ "S3 Block 20 · SL"
      refute t =~ "## Fakten"
      refute t =~ "## Bögen"
      refute t =~ "Ohne Treffer"

      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "uhr", "weiter" => true})
      assert t =~ "## Mitschnitt — 45 Treffer, hier 41 bis 45, keine weiteren"

      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "uhr", "weiter" => true})
      assert t =~ "Keine weiteren Treffer — alle Treffer zu diesem Begriff sind gezeigt."
      refute t =~ "## "

      # Ohne weiter: von vorn.
      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "uhr"})
      assert t =~ "## Mitschnitt — 45 Treffer, hier 1 bis 20"

      # Ein neuer Begriff mit weiter beginnt ebenfalls vorn.
      {s, {:ok, t}} = Suche.suche_sitzung(s, %{"begriff" => "tickt", "weiter" => true})
      assert t =~ "Zu diesem Begriff gab es noch keine Suche — hier die ersten Treffer."
      assert t =~ "## Mitschnitt — 45 Treffer, hier 1 bis 20"

      # Die Position gilt je Werkzeug.
      {_s, {:ok, t}} = Suche.suche_bisher(s, %{"begriff" => "uhr", "weiter" => true})
      assert t =~ "Zu diesem Begriff gab es noch keine Suche"
    end

    test "das Merkmal der Sperre bewegt sich, solange Blättern Neues bringt" do
      m = Suche.merkmal("suche_sitzung")
      w = %{"begriff" => "uhr", "weiter" => true}
      s = stand(bloecke: viele(45))

      assert m.(s, %{"begriff" => "uhr"}) == :vorn

      {merkmale, _s} =
        Enum.map_reduce(1..5, s, fn _, acc ->
          k = m.(acc, w)
          {acc, {:ok, _}} = Suche.suche_sitzung(acc, w)
          {k, acc}
        end)

      # 1: noch keine Suche · 2: nach 20 · 3: nach 40 · 4: nach 45 (nichts mehr) · 5: gleich
      [a, b, c, d, e] = merkmale
      assert length(Enum.uniq([a, b, c, d])) == 4
      assert d == e
    end

    test "Ausschnitt um den Treffer, gekürzt; kurze Texte ganz" do
      lang =
        String.duplicate("Regen fällt auf den Hafen. ", 12) <>
          "Die Spieldose klingt leise. " <> String.duplicate("Wind weht. ", 30)

      a = Suche.ausschnitt(lang, "spieldose")
      assert a =~ "Die Spieldose klingt"
      assert String.starts_with?(a, "…") and String.ends_with?(a, "…")
      assert String.length(a) <= 162

      assert Suche.ausschnitt("Kurz  und\nknapp.", "knapp") == "Kurz und knapp."
    end
  end

  describe "Mitschnitt früherer Sitzungen" do
    test "bloecke und block mit sitzung: beim ersten Zugriff geladen, dann aus dem Stand" do
      s = stand()
      d = defs(s)

      {s, {:ok, t}} = d["bloecke"].ausfuehren.(s, %{"von" => 0, "bis" => 1, "sitzung" => 1})
      assert t =~ "Mitschnitt von Sitzung 1:\n0\tSL\tTess legt den Brief"
      assert_received {:geladen, 1}

      {s, {:ok, t}} = d["block"].ausfuehren.(s, %{"nummer" => 1, "sitzung" => 1})
      assert t == "Mitschnitt von Sitzung 1:\n1\tSL\tDer Alte stellt die Spieldose ins Regal."
      refute_received {:geladen, _}

      # Ohne sitzung oder mit der eigenen Nummer: diese Sitzung.
      {_s, {:ok, t}} = d["block"].ausfuehren.(s, %{"nummer" => 1})
      assert t == "1\tBrann\tIch kaufe Laternen."
      assert {_s, {:ok, ^t}} = d["block"].ausfuehren.(s, %{"nummer" => 1, "sitzung" => 3})

      # Grenzen gelten für den geladenen Mitschnitt.
      assert {_s, {:error, e}} = d["block"].ausfuehren.(s, %{"nummer" => 9, "sitzung" => 1})
      assert e =~ "Sitzung 1: Block 9 gibt es nicht. Gültig sind 0 bis 1."

      assert d["bloecke"].beschreibung =~ "Mit sitzung liest du den Mitschnitt einer früheren"
      assert "sitzung" in d["block"].optional
    end

    test "ohne Glättung, unbekannte Sitzung, ohne Lader, werfender Lader: klare Antworten" do
      s = stand()
      d = defs(s)

      {s, {:error, t}} = d["bloecke"].ausfuehren.(s, %{"von" => 0, "bis" => 5, "sitzung" => 2})
      assert t == "Zu Sitzung 2 liegt kein Mitschnitt vor: sie ist nicht geglättet."
      assert_received {:geladen, 2}

      # Auch der Fehler steht im Stand — kein zweiter Ladeversuch.
      {_s, {:error, _}} = d["block"].ausfuehren.(s, %{"nummer" => 0, "sitzung" => 2})
      refute_received {:geladen, 2}

      {_s, {:error, t}} = d["block"].ausfuehren.(s, %{"nummer" => 0, "sitzung" => 7})
      assert t =~ "Sitzung 7 gehört nicht zu den früheren Sitzungen. Früher sind: 1, 2."

      {_s, {:error, t}} =
        d["block"].ausfuehren.(stand(lader: nil), %{"nummer" => 0, "sitzung" => 1})

      assert t =~ "Der Mitschnitt von Sitzung 1 ist in diesem Lauf nicht verfügbar"

      wirft = stand(lader: fn _ -> raise "Platte voll" end)
      {_s, {:error, t}} = d["block"].ausfuehren.(wirft, %{"nummer" => 0, "sitzung" => 1})
      assert t =~ "ließ sich nicht laden"
      assert t =~ "Platte voll"

      erste = %{stand() | fruehere: []}

      assert {_s, {:ok, @keine_frueheren}} =
               d["block"].ausfuehren.(erste, %{"nummer" => 0, "sitzung" => 1})
    end

    test "fakt(id): ein früherer Fakt zeigt seine Belegblöcke aus dem Mitschnitt jener Sitzung" do
      {s, {:ok, t}} = Lesen.fakt(stand(), %{"id" => "s1-f1"})

      assert t =~
               "Der Fakt stammt aus Sitzung 1.\n" <>
                 "Belegblöcke im Mitschnitt von Sitzung 1 (block(nummer, sitzung)):\n" <>
                 "1\tSL\tDer Alte stellt die Spieldose ins Regal."

      assert t =~ "1 Beleg(e) liegen außerhalb des Mitschnitts von Sitzung 1"
      # Ein früherer Fakt zählt nicht als gelesen; der Mitschnitt bleibt geladen.
      assert s.gelesen == MapSet.new()
      assert {:ok, _} = s.mitschnitte[1]

      {_s, {:ok, t}} = Lesen.fakt(stand(), %{"id" => "S2-F1"})

      assert t =~
               "Der Fakt stammt aus Sitzung 2. Zu Sitzung 2 liegt kein Mitschnitt vor: " <>
                 "sie ist nicht geglättet."
    end
  end

  describe "boegen_kampagne und vorige_kapitel" do
    test "boegen_kampagne: jeder Bogen mit seinen Fakten aus allen Sitzungen bis hierher" do
      {_s, {:ok, t}} = Bisher.boegen_kampagne(stand(), %{})

      assert t =~ "bis einschließlich Sitzung 3"

      assert t =~
               "#{@spieldose}\tArt: arc\tStatus: offen\tLeitfrage: Wem gehört die Spieldose?\t" <>
                 "Fakten: S1-F1, S3-F1"

      assert t =~
               "#{@uhrmacher}\tArt: arc\tStatus: offen\tLeitfrage: Wo ist der Uhrmacher?\t" <>
                 "Fakten: S2-F1, S3-F2"

      # boegen() bleibt die Sicht dieser Sitzung.
      {_s, {:ok, b}} = Lesen.boegen(stand(), %{})
      refute b =~ "S1-F1"

      # Ohne Angabe in der Eingabe: aus den Fakten abgeleitet, ohne Leitfrage.
      {_s, {:ok, t}} = Bisher.boegen_kampagne(%{stand() | boegen_kampagne: nil}, %{})
      assert t =~ "#{@spieldose}\tArt: arc\tStatus: —\tLeitfrage: —\tFakten: S1-F1, S3-F1"
    end

    test "vorige_kapitel: frühere Kapitel mit Kopf, ein Bereich, nie das dieser Sitzung" do
      {_s, {:ok, t}} = Bisher.vorige_kapitel(stand(), %{})

      assert t ==
               "## Sitzung 1 — Die Werkstatt\n\n## Kapitel 1 — Herbst\n\nRegen über dem Hafen." <>
                 "\n\nDie Spieldose schweigt im Regal."

      assert {_s, {:ok, "Zu den früheren Sitzungen 2 bis 2 liegt kein Epos-Kapitel vor."}} =
               Bisher.vorige_kapitel(stand(), %{"von" => 2, "bis" => 2})

      assert {_s, {:ok, "Zu den früheren Sitzungen 3 bis 5 liegt kein Epos-Kapitel vor."}} =
               Bisher.vorige_kapitel(stand(), %{"von" => 3, "bis" => 5})

      assert {_s, {:error, _}} = Bisher.vorige_kapitel(stand(), %{"von" => 2, "bis" => 1})

      assert {_s, {:ok, @keine_frueheren}} =
               Bisher.vorige_kapitel(%{stand() | fruehere: []}, %{})
    end
  end

  describe "Werkzeuge und Stand" do
    test "in allen drei Läufen, streng: begriff Pflicht, weiter und sitzung optional" do
      s = stand()

      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        namen = Werkzeuge.namen(%{s | lauf: lauf})

        for n <- ~w(suche_sitzung suche_bisher boegen_kampagne vorige_kapitel bloecke block),
            do: assert(n in namen)

        refute "suche" in namen
      end

      {:ok, h} = Halter.start_link(s)
      by = h |> Werkzeuge.fuer() |> Map.new(&{&1.name, &1})

      assert by["suche_sitzung"].parameter["required"] == ["begriff"]
      assert by["suche_bisher"].parameter["required"] == ["begriff"]
      assert Enum.sort(by["bloecke"].parameter["required"]) == ["bis", "von"]
      assert by["block"].parameter["required"] == ["nummer"]
      assert Map.get(by["vorige_kapitel"].parameter, "required", []) == []
      assert by["boegen_kampagne"].wiederholung == :frei
      assert by["suche_bisher"].beschreibung =~ "für diese Sitzung allein nimm suche_sitzung"
      assert by["suche_sitzung"].beschreibung =~ "für alles bis hierher nimm suche_bisher"

      # Das Merkmal liest den Stand im Halter.
      m = by["suche_sitzung"].wiederholung_merkmal
      w = %{"begriff" => "Spieldose", "weiter" => true}
      vorher = m.(w)
      assert {:ok, _} = by["suche_sitzung"].ausfuehren.(%{"begriff" => "Spieldose"})
      refute m.(w) == vorher
      assert m.(%{"begriff" => "Spieldose"}) == :vorn
      assert m.(%{"begriff" => 42, "weiter" => true}) == :vorn
    end

    test "Abbild und Zusammenfassung tragen weder Suchpositionen noch geladene Mitschnitte" do
      {s, {:ok, _}} = Suche.suche_bisher(stand(bloecke: viele(45)), %{"begriff" => "uhr"})

      assert map_size(s.suche) == 1
      assert Map.has_key?(s.mitschnitte, 1)

      a = Stand.abbild(s)
      refute Map.has_key?(a, "suche")
      refute Map.has_key?(a, "mitschnitte")
      json = Jason.encode!(a)
      refute json =~ "Uhr Nummer"
      refute json =~ "Tess legt den Brief"

      z = Zusammenfassung.text(s)
      refute z =~ "Uhr Nummer"
      refute z =~ "Tess legt den Brief"
    end
  end
end
