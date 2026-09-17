defmodule Worker.Jack.Demo do
  @moduledoc """
  Eine Demo der Laufsicht (#1202): echte Werkzeuge, echter Halter, echte
  Laufzeit, dazu ein Stub-Modell, das sein Denken Wort für Wort streamt.
  Die Blöcke sind erfunden, eine kleine Geschichte um einen verschwundenen
  Uhrmacher; kein Mitschnitt einer echten Runde, keine echten Namen. Ohne
  Ollama, ohne Worker-Start (kein Mnesia, kein Hub).

  Phase 1 liest die 40 Blöcke und legt das Gedächtnis an. Phase 2 sammelt
  vier Aussagen; eine Umformulierung legt das Verifikationstor als Vorlage
  vor. Beide Phasen enden mit `fertig`.

  Start: `mix lore.jack.demo`. Der Test fährt dieselbe Demo ohne Pausen und
  hält damit fest, dass ihre Aussagen gegen die Werkzeuge gültig bleiben.
  """

  alias Worker.Jack.{Halter, Stand, Werkzeuge}

  defmodule Modell do
    @moduledoc """
    Ein Modell, das ein Skript abspielt: je Runde ein Schritt mit Denken,
    Text und Werkzeugaufrufen. Mit `bei_delta` streamt es Wort für Wort;
    `tempo: 0` nimmt die Pausen heraus.
    """
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, _werkzeuge, opts) do
      tempo = Keyword.get(opts, :tempo, 1)

      schritt =
        Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
          [kopf | rest] -> {kopf, rest}
          [] -> {%{denken: "Nichts mehr zu tun.", text: "Fertig.", aufrufe: []}, []}
        end)

      Process.sleep(1400 * tempo)
      streamen(opts[:bei_delta], schritt, tempo)

      zeichen =
        nachrichten |> Enum.map(&String.length(to_string(&1[:content] || ""))) |> Enum.sum()

      aufrufe = schritt[:aufrufe] || []

      {:ok,
       %{
         text: schritt[:text],
         denken: schritt[:denken],
         aufrufe:
           Enum.map(aufrufe, fn {name, args} ->
             %{
               id: "demo_#{System.unique_integer([:positive])}",
               name: name,
               argumente: {:ok, args}
             }
           end),
         stopp: if(aufrufe == [], do: :stop, else: :werkzeuge),
         nutzung: %{
           eingabe: 1800 + div(zeichen, 3),
           ausgabe: 60 + length(woerter(schritt[:denken]))
         }
       }}
    end

    defp streamen(nil, _schritt, _tempo), do: :ok

    defp streamen(melden, schritt, tempo) do
      for {art, text} <- [denken: schritt[:denken], text: schritt[:text]], w <- woerter(text) do
        melden.(art, w)
        Process.sleep(55 * tempo)
      end
    end

    defp woerter(nil), do: []
    defp woerter(t), do: Regex.split(~r/(?<=\s)/u, t, trim: true)
  end

  @texte [
    {"SL", "Willkommen zurück am Tisch, wir machen da weiter, wo wir aufgehört haben."},
    {"SL", "Ihr steht im Regen vor der alten Werkstatt am Hafen."},
    {"Mira", "Ich klopfe zweimal an die Tür und warte."},
    {"SL", "Die Tür öffnet sich einen Spalt, drinnen brennt eine Öllampe."},
    {"Brann", "Ich halte die Hand am Griff meiner Axt."},
    {"SL", "Ein alter Mann mit Lederschürze mustert euch misstrauisch."},
    {"Tess", "Wir suchen den Uhrmacher, der die Spieldose gebaut hat."},
    {"SL", "Der Alte sagt, der Uhrmacher sei seit drei Wochen verschwunden."},
    {"Mira", "Hat er gesagt, wohin er wollte?"},
    {"SL", "Er habe von einer Reise nach Norden gesprochen, zu den Salzminen."},
    {"Brann", "Salzminen, das klingt nach Ärger."},
    {"SL", "Auf der Werkbank liegt eine halb fertige Spieldose mit einem Wappen."},
    {"Tess", "Ich sehe mir das Wappen genauer an."},
    {"SL", "Es zeigt einen Raben über zwei gekreuzten Schlüsseln."},
    {"Mira", "Das Wappen kenne ich, das gehört der Familie von Arnheim."},
    {"SL", "Der Alte wird blass, als ihr den Namen Arnheim nennt."},
    {"Brann", "Was weißt du über die Arnheims, Alter?"},
    {"SL", "Er flüstert, die Arnheims hätten den Uhrmacher bezahlt, damit er schweigt."},
    {"Tess", "Wir nehmen die Spieldose mit, wenn du erlaubst."},
    {"SL", "Er nickt und schiebt sie euch über den Tisch."},
    {"SL", "Am nächsten Morgen reist ihr mit der Postkutsche nach Norden."},
    {"Mira", "Ich schlafe die meiste Zeit der Fahrt."},
    {"SL", "Nach zwei Tagen erreicht ihr das Dorf am Rand der Salzminen."},
    {"Brann", "Ich frage im Wirtshaus nach dem Uhrmacher."},
    {"SL", "Die Wirtin erzählt, ein Fremder mit Werkzeugkiste sei in die alte Mine gegangen."},
    {"Tess", "Wann war das?"},
    {"SL", "Vor zehn Tagen, und seitdem habe ihn niemand mehr gesehen."},
    {"Mira", "Wir brauchen Laternen und ein Seil."},
    {"SL", "Die Wirtin verkauft euch zwei Laternen für drei Silbermünzen."},
    {"Brann", "Ich zahle, das Seil habe ich selbst dabei."},
    {"SL", "Der Eingang der Mine ist mit Brettern vernagelt."},
    {"Tess", "Ich breche die Bretter mit dem Brecheisen auf."},
    {"SL", "Dahinter führt ein Gang steil nach unten, es riecht nach Salz und Rauch."},
    {"Mira", "Rauch? Hier unten brennt jemand ein Feuer."},
    {"SL", "Nach hundert Schritten seht ihr ein flackerndes Licht."},
    {"Brann", "Ich gehe vorne, Axt in der Hand."},
    {"SL", "Am Feuer sitzt der Uhrmacher, gefesselt an einen Balken."},
    {"Tess", "Ich schneide seine Fesseln durch."},
    {"SL", "Er keucht, die Arnheims wollten die Spieldose um jeden Preis zurück."},
    {"SL", "Für heute machen wir hier Schluss."}
  ]

  @cast ["Mira", "Brann", "Tess", "der Uhrmacher"]

  @doc """
  Beide Phasen nacheinander. Optionen: `:sicht` (Beobachter, etwa
  `Worker.Jack.Sicht`), `:ablage` (Verzeichnis, je Phase ein Unterverzeichnis),
  `:tempo` (1 mit Pausen, 0 ohne). Liefert die Ergebnisse beider Läufe.
  """
  @spec laufen(keyword()) :: %{phase1: term(), phase2: term()}
  def laufen(opts) do
    {e1, s1} = phase(Stand.neu(stand_opts()), phase1(), "phase1", opts)
    if opts[:tempo] != 0, do: Process.sleep(4000)

    {e2, _} =
      phase(
        Stand.neu(stand_opts() ++ [register: s1.register, phase: 2]),
        phase2(),
        "phase2",
        opts
      )

    %{phase1: e1, phase2: e2}
  end

  @doc """
  Die erfundene Eingabe der Demo als `%{bloecke:, cast:, straenge:}` — für
  Probeläufe, bei denen nichts aus einem echten Mitschnitt das Haus
  verlassen soll (Referenzlauf mit Claude Code, `mix lore.jack.referenz --demo`).
  """
  @spec eingabe() :: %{bloecke: [map()], cast: [String.t()], straenge: [String.t()]}
  def eingabe, do: Map.new(stand_opts())

  defp stand_opts do
    bloecke =
      @texte
      |> Enum.with_index()
      |> Enum.map(fn {{sprecher, text}, i} ->
        %{text: text, sprecher: sprecher, block_id: "demo_b#{i}"}
      end)

    [bloecke: bloecke, cast: @cast, straenge: ["Die Werkstatt"]]
  end

  defp phase(stand, skript, name, opts) do
    dir = opts[:ablage] && Path.join(opts[:ablage], name)
    {:ok, halter} = Halter.start_link(stand, beobachter: opts[:sicht], ablage: dir)
    {:ok, s} = Agent.start_link(fn -> skript end)

    ergebnis =
      Worker.Agent.laufen(
        modell: {Modell, skript: s, tempo: Keyword.get(opts, :tempo, 1)},
        system: "Du bist Jack.",
        nachrichten: [%{role: :user, content: "Demo-Auftrag."}],
        werkzeuge: Werkzeuge.fuer(halter),
        beobachter: opts[:sicht],
        protokoll: dir && Path.join(dir, "protokoll.jsonl"),
        kontext: [fenster: 32_768, reserve: 4096, behalten: 8192]
      )

    {ergebnis, Halter.stand(halter)}
  end

  defp notiz(a, k, z, b), do: %{"abschnitt" => a, "schluessel" => k, "zeile" => z, "bloecke" => b}

  defp aussage(claim, wer, typ, faeden, refs, beleg) do
    %{
      "claim" => claim,
      "character" => wer,
      "cast_match" => wer,
      "narration_time" => "present",
      "time_anchor" => "session",
      "in_game_date" => "",
      "fact_type" => typ,
      "threads" => faeden,
      "source_refs" => refs,
      "beleg" => beleg
    }
  end

  defp phase1 do
    [
      %{
        denken:
          "Ich fange vorne an und lese den ersten Abschnitt, Block 0 bis 19. " <>
            "Danach lege ich das Gedächtnis an, bevor ich weiterlese.",
        aufrufe: [{"bloecke", %{"von" => 0, "bis" => 19}}]
      },
      %{
        denken:
          "Die Szene spielt in einer Werkstatt am Hafen. Der Uhrmacher ist verschwunden, " <>
            "das Wappen auf der Spieldose gehört den Arnheims. Das halte ich fest: Ablauf, " <>
            "die drei Figuren, der Auftrag und das Thema Spieldose.",
        aufrufe: [
          {"notiz",
           %{
             "eintraege" => [
               notiz(
                 "ABLAUF",
                 "0-19",
                 "Werkstatt am Hafen: der Uhrmacher ist verschwunden, Wappen der Arnheims",
                 [1, 7, 14]
               ),
               notiz("FIGUREN", "Mira", "Spielerfigur, kennt das Wappen der Arnheims", [14]),
               notiz("FIGUREN", "Brann", "Spielerfigur mit Axt", [4]),
               notiz("FIGUREN", "Tess", "Spielerfigur, sucht den Uhrmacher", [6]),
               notiz("AUFTRAG", "Uhrmacher", "den verschwundenen Uhrmacher finden", [6, 7]),
               notiz("THEMEN", "Spieldose", "die Spieldose mit dem Rabenwappen", [11, 13])
             ]
           }}
        ]
      },
      %{
        denken: "Weiter mit dem zweiten Abschnitt, Block 20 bis 39.",
        aufrufe: [{"bloecke", %{"von" => 20, "bis" => 39}}]
      },
      %{
        denken:
          "Die Gruppe reist zu den Salzminen und findet den Uhrmacher gefesselt in der Mine. " <>
            "Offen bleibt, wer dort das Feuer entzündet hat. Ich ergänze das Gedächtnis.",
        aufrufe: [
          {"notiz",
           %{
             "eintraege" => [
               notiz(
                 "ABLAUF",
                 "20-39",
                 "Reise zu den Salzminen, Abstieg in die Mine, der Uhrmacher wird gefunden",
                 [22, 30, 36]
               ),
               notiz(
                 "FIGUREN",
                 "der Uhrmacher",
                 "hat die Spieldose gebaut, gefangen in der Mine",
                 [36]
               ),
               notiz("THEMEN", "Arnheim", "die Familie von Arnheim will die Spieldose zurück", [
                 38
               ]),
               notiz("OFFEN", "Feuer", "wer hat das Feuer in der Mine entzündet?", [33]),
               notiz(
                 "OFFEN",
                 "Schweigegeld",
                 "wofür genau bezahlten die Arnheims den Uhrmacher?",
                 [17]
               )
             ]
           }}
        ]
      },
      %{
        denken: "Alles gelesen, das Gedächtnis deckt beide Bereiche ab. Ich melde den Abschluss.",
        aufrufe: [
          {"fertig",
           %{
             "bereiche" => 2,
             "eintraege" => 11,
             "offen_geblieben" => "Wer das Feuer in der Mine entzündet hat."
           }}
        ]
      }
    ]
  end

  defp phase2 do
    [
      %{
        denken:
          "Zweiter Durchgang: jetzt sammle ich Aussagen, Bereich für Bereich. Zuerst Block 0 bis 19.",
        aufrufe: [{"bloecke", %{"von" => 0, "bis" => 19}}]
      },
      %{
        denken: "Block 7: der Uhrmacher ist seit drei Wochen verschwunden. Das ist ein Zustand.",
        aufrufe: [
          {"aussage",
           aussage(
             "Der Uhrmacher ist seit drei Wochen verschwunden.",
             "",
             "zustand",
             ["Der Uhrmacher"],
             [7],
             "der Uhrmacher sei seit drei Wochen verschwunden"
           )}
        ]
      },
      %{
        denken:
          "Block 13 und 14: Mira erkennt das Wappen. Das ist eine Enthüllung, belegt aus beiden Blöcken.",
        aufrufe: [
          {"aussage",
           aussage(
             "Das Wappen auf der Spieldose gehört der Familie von Arnheim.",
             "Mira",
             "enthüllung",
             ["Arnheim"],
             [13, 14],
             "einen Raben über zwei gekreuzten Schlüsseln … das gehört der Familie von Arnheim"
           )}
        ]
      },
      %{
        denken:
          "Noch einmal Block 7, anders formuliert — mal sehen, ob das schon im Bestand steht.",
        aufrufe: [
          {"aussage",
           aussage(
             "Seit drei Wochen fehlt vom Uhrmacher jede Spur.",
             "",
             "zustand",
             ["Der Uhrmacher"],
             [7],
             "seit drei Wochen verschwunden"
           )}
        ]
      },
      %{
        denken:
          "Die bestehende Aussage sagt dasselbe. Ich lasse meine weg und lese den zweiten Abschnitt.",
        aufrufe: [{"bloecke", %{"von" => 20, "bis" => 39}}]
      },
      %{
        denken:
          "Block 38: die Arnheims wollen die Spieldose zurück. Eine Absicht, geäußert vom Uhrmacher.",
        aufrufe: [
          {"aussage",
           aussage(
             "Die Arnheims wollen die Spieldose um jeden Preis zurück.",
             "der Uhrmacher",
             "absicht",
             ["Arnheim"],
             [38],
             "die Arnheims wollten die Spieldose um jeden Preis zurück"
           )}
        ]
      },
      %{
        denken: "Block 36: der Uhrmacher sitzt gefesselt am Feuer.",
        aufrufe: [
          {"aussage",
           aussage(
             "Der Uhrmacher sitzt gefesselt in der alten Mine.",
             "der Uhrmacher",
             "zustand",
             ["Der Uhrmacher"],
             [36],
             "Am Feuer sitzt der Uhrmacher, gefesselt an einen Balken"
           )}
        ]
      },
      %{
        denken: "Beide Bereiche sind durch, vier Aussagen stehen im Bestand. Abschluss.",
        aufrufe: [
          {"fertig", %{"aussagen" => 4, "offen_geblieben" => "Wer das Feuer entzündet hat."}}
        ]
      }
    ]
  end
end
