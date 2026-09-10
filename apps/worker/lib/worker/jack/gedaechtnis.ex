defmodule Worker.Jack.Gedaechtnis do
  @moduledoc """
  `notiz` und `notizen_lesen`, also Jacks Gedächtnis, dazu die Texte, die aus
  Gedächtnis und Stand abgeleitet werden: das Gedächtnis als Text
  (`notizen_text/1`), der Arbeitsstand (`stand_text/1`) und die Abdeckung des
  Mitschnitts durch ABLAUF (`ablauf_luecken/1`). Die Kompaktierung setzt
  daraus ihre Zusammenfassung zusammen, statt das Modell zusammenfassen zu
  lassen.

  Portiert aus dem Spike (`werkzeuge.ts`, Stand Lauf 6), Texte wörtlich:

    * Jeder Eintrag hat Abschnitt und Schlüssel; derselbe Schlüssel ersetzt,
      `zeile: null` streicht.
    * Eine leere Zeile ist kein Eintrag. gpt-oss:20b hatte zehn leere
      Einträge geschrieben, um das Gerüst zu erfüllen.
    * ABLAUF-Schlüssel sind Blockbereiche („180-400“), keine Selbstauskunft
      über den Arbeitsstand, und ein neuer Bereich darf keinen bestehenden
      überlappen.
    * Ein Schreibvorgang, der nichts ändert, wird nicht als „ersetzt“
      quittiert; beim dritten gleichlautenden Versuch ist er ein Fehler (im
      Spike 175-mal derselbe Eintrag in 1003 Modellrunden).

  **Abweichungen vom Spike:**

    * Abschnitt, Schlüssel, Zeile und Blöcke prüft das Schema vorab. Der
      Abschnitt ist ein Enum; der Spike schrieb `"## figuren"` still zu
      `FIGUREN` um. Die Blöcke sind ganze Zahlen; der Spike filterte andere
      still heraus. Mindestens ein Eintrag ist Pflicht.
    * Ein ABLAUF-Bereich mit vertauschten Grenzen („400-180“) gilt als
      180-400. Im Spike übersah ihn die Überlappungsprüfung, und die
      Lückenprüfung meldete einen Bereich als offen, der abgedeckt war.
    * Ein Aufruf, der nichts geschrieben hat, ist `{:error, …}` — wie bei
      `aussage` (Regel der Wiederholungssperre, #1197).
  """

  alias Worker.Jack.{Antwort, Stand}

  @bereich ~r/^\s*(\d+)\s*[-–]\s*(\d+)\s*$/u
  # Für Alt-Bestand: der Spike las ABLAUF-Schlüssel wie „0 bis 180“ so.
  @bereich_locker ~r/(\d+)\s*[-–bis]+\s*(\d+)/u

  @hinweis_unveraendert "So viele Eintraege standen bereits genau so — sie wurden NICHT neu " <>
                          "geschrieben. Steht dein Gedaechtnis, mach mit dem Sammeln weiter."

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "notiz",
        beschreibung:
          "Dein Gedaechtnis. Es ueberlebt, was dein Kontext vergisst — schreib hinein, " <>
            "was du spaeter brauchst, und halte es aktuell. Jeder Eintrag hat einen " <>
            "Abschnitt und einen Schluessel; schreibst du denselben Schluessel erneut, " <>
            "ERSETZT das den alten Eintrag. Mit zeile=null streichst du ihn. " <>
            "Abschnitte: FIGUREN (wer vorkommt), ABLAUF (was in welchem Blockbereich " <>
            "geschieht), AUFTRAG (worum es geht), THEMEN (die Straenge), OFFEN " <>
            "(Widersprueche und ungeklaerte Fragen). Geht nicht in das Ergebnis ein.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "eintraege" => %{
              "type" => "array",
              "minItems" => 1,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "abschnitt" => %{
                    "type" => "string",
                    "enum" => Stand.abschnitte_alle(),
                    "description" => "FIGUREN, ABLAUF, AUFTRAG, THEMEN oder OFFEN"
                  },
                  "schluessel" => %{
                    "type" => "string",
                    "description" =>
                      "worueber der Eintrag geht: \"Lucky\", \"0-180\", \"Uhrzeit\""
                  },
                  "zeile" => %{
                    "type" => ["string", "null"],
                    "description" => "der Eintrag; null streicht ihn"
                  },
                  "bloecke" => %{
                    "type" => "array",
                    "items" => %{"type" => "integer"},
                    "description" => "die Blocknummern, aus denen er stammt"
                  }
                }
              }
            }
          }
        },
        ausfuehren: &notiz/2
      },
      %{
        name: "notizen_lesen",
        beschreibung:
          "Gibt deine bisherigen Notizen zurueck. Nutze es, wenn du nicht mehr weisst, " <>
            "wo du stehst — dann arbeitest du von dort weiter statt neu zu beginnen.",
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &notizen_lesen/2
      }
    ]
  end

  # ─── notiz ────────────────────────────────────────────────────────────

  @doc "Einträge schreiben, ersetzen oder streichen (Werkzeug `notiz`)."
  @spec notiz(Stand.t(), map()) :: ergebnis()
  def notiz(%Stand{} = s, %{"eintraege" => eintraege}) do
    z0 = %{neu: 0, ersetzt: 0, gestrichen: 0, unveraendert: 0, fehler: []}
    {s, z} = Enum.reduce(eintraege, {s, z0}, fn e, {s, z} -> eintrag(s, z, e) end)
    fehlt = Stand.geruest_fehlt(s)
    geaendert = z.neu + z.ersetzt + z.gestrichen > 0

    antwort =
      Antwort.geordnet([
        {"neu", z.neu},
        {"ersetzt", z.ersetzt},
        {"gestrichen", z.gestrichen},
        {"eintraege_gesamt", length(s.register)},
        {"unveraendert", if(z.unveraendert > 0, do: z.unveraendert)},
        {"hinweis_unveraendert", if(z.unveraendert > 0, do: @hinweis_unveraendert)},
        {"fehler", if(z.fehler != [], do: Enum.reverse(z.fehler))},
        {"geruest_unvollstaendig", if(fehlt != [], do: fehlt)}
      ])

    {s, {if(geaendert, do: :ok, else: :error), antwort}}
  end

  defp eintrag(s, z, e) do
    a = e["abschnitt"]
    k = String.trim(e["schluessel"])
    zeile = e["zeile"]
    bl = e["bloecke"]
    i = Enum.find_index(s.register, &(&1.abschnitt == a and &1.schluessel == k))

    cond do
      k == "" ->
        {s, fehler(z, "`schluessel` fehlt — ohne ihn ist der Eintrag spaeter nicht zu finden.")}

      is_nil(zeile) ->
        streichen(s, z, a, k, i)

      true ->
        case pruefen(s, a, k, zeile, bl, i) do
          :ok when is_nil(i) ->
            anlegen(s, z, %{abschnitt: a, schluessel: k, zeile: zeile, bloecke: bl})

          :ok ->
            aendern(s, z, i, %{abschnitt: a, schluessel: k, zeile: zeile, bloecke: bl})

          {:fehler, text} ->
            {s, fehler(z, text)}
        end
    end
  end

  defp pruefen(s, a, k, zeile, bl, i) do
    weg = Enum.reject(bl, &Map.has_key?(s.bloecke, &1))

    cond do
      String.trim(zeile) == "" ->
        {:fehler,
         "#{a}/#{k}: die Zeile ist leer. Ein Eintrag ohne Inhalt hilft niemandem — " <>
           "schreib hin, was an dieser Stelle steht, oder lass den Eintrag weg " <>
           "(`zeile: null` streicht einen bestehenden)."}

      weg != [] ->
        {:fehler, "Bloecke gibt es nicht: #{Jason.encode!(weg)}."}

      a == "ABLAUF" and is_nil(bereich(k)) ->
        {:fehler,
         "ABLAUF/#{k}: der Schluessel muss ein Blockbereich sein, z. B. \"180-400\". " <>
           "ABLAUF beschreibt, WAS im Mitschnitt geschieht — nicht, wie weit du " <>
           "gekommen bist. Deinen Arbeitsstand fuehrt das Werkzeug selbst."}

      a == "ABLAUF" and is_nil(i) ->
        ueberlappung(s.register, k)

      true ->
        :ok
    end
  end

  defp ueberlappung(register, k) do
    case ablauf_ueberlappt(register, k) do
      nil ->
        :ok

      ue ->
        {:fehler,
         "ABLAUF/#{k} ueberschneidet sich mit ABLAUF/#{ue.schluessel} " <>
           "(\"#{String.slice(ue.zeile, 0, 60)}\"). Ein Bereich gehoert genau einmal in die " <>
           "Landkarte. Schreib entweder unter #{ue.schluessel} weiter (derselbe " <>
           "Schluessel ersetzt), oder waehle Grenzen, die an den bestehenden " <>
           "anschliessen statt sie zu ueberlappen."}
    end
  end

  defp streichen(s, z, _a, _k, nil), do: {s, z}

  defp streichen(s, z, a, k, i) do
    s =
      %{s | register: List.delete_at(s.register, i)}
      |> Stand.journal("notizen_verlauf.txt", %{"art" => "-", "abschnitt" => a, "schluessel" => k})

    {s, %{z | gestrichen: z.gestrichen + 1}}
  end

  defp anlegen(s, z, neu) do
    s =
      %{s | register: s.register ++ [neu]}
      |> Stand.journal("notizen_verlauf.txt", %{
        "art" => "+",
        "abschnitt" => neu.abschnitt,
        "schluessel" => neu.schluessel,
        "zeile" => neu.zeile
      })

    {s, %{z | neu: z.neu + 1}}
  end

  defp aendern(s, z, i, neu) do
    alt = Enum.at(s.register, i)
    schl = neu.abschnitt <> "/" <> neu.schluessel

    if alt.zeile == neu.zeile and alt.bloecke == neu.bloecke do
      n = Map.get(s.unveraendert, schl, 0) + 1
      s = %{s | unveraendert: Map.put(s.unveraendert, schl, n)}
      z = %{z | unveraendert: z.unveraendert + 1}

      z =
        if n >= 3,
          do:
            fehler(
              z,
              "#{schl} steht bereits genau so — das war der #{n}. gleichlautende Versuch. " <>
                "Aendere den Text, streiche den Eintrag mit zeile=null, oder lass ihn stehen " <>
                "und mach mit deiner eigentlichen Arbeit weiter."
            ),
          else: z

      {s, z}
    else
      s =
        %{
          s
          | register: List.replace_at(s.register, i, neu),
            unveraendert: Map.delete(s.unveraendert, schl)
        }
        |> Stand.journal("notizen_verlauf.txt", %{
          "art" => "~",
          "abschnitt" => neu.abschnitt,
          "schluessel" => neu.schluessel,
          "vorher" => alt.zeile,
          "zeile" => neu.zeile
        })

      {s, %{z | ersetzt: z.ersetzt + 1}}
    end
  end

  defp fehler(z, text), do: %{z | fehler: [text | z.fehler]}

  # ─── notizen_lesen ────────────────────────────────────────────────────

  @doc """
  Das Gedächtnis zurückgeben (Werkzeug `notizen_lesen`), mit den Schlüsseln:
  ohne sie müsste Jack raten, wie ein Eintrag heißt, den er ersetzen will,
  und legte stattdessen einen zweiten an.
  """
  @spec notizen_lesen(Stand.t(), map()) :: ergebnis()
  def notizen_lesen(%Stand{} = s, _args) do
    eintraege =
      Enum.map(s.register, fn r ->
        Antwort.geordnet([
          {"abschnitt", r.abschnitt},
          {"schluessel", r.schluessel},
          {"zeile", r.zeile},
          {"bloecke", r.bloecke}
        ])
      end)

    notizen =
      case String.trim(notizen_text(s)) do
        "" -> "(noch keine Notizen)"
        t -> t
      end

    antwort =
      Antwort.geordnet([{"stand", stand_text(s)}, {"eintraege", eintraege}, {"notizen", notizen}])

    {s, {:ok, antwort}}
  end

  # ─── Abgeleitete Texte ────────────────────────────────────────────────

  @doc "Das Gedächtnis als Text, je Abschnitt `## NAME` und darunter `schluessel — zeile  [blöcke]`."
  @spec notizen_text(Stand.t()) :: String.t()
  def notizen_text(%Stand{register: register}) do
    Stand.abschnitte_alle()
    |> Enum.flat_map(fn a -> abschnitt_text(a, Enum.filter(register, &(&1.abschnitt == a))) end)
    |> Enum.join("\n")
  end

  defp abschnitt_text(_a, []), do: []
  defp abschnitt_text(a, rows), do: ["## " <> a] ++ Enum.map(rows, &notiz_zeile/1) ++ [""]

  defp notiz_zeile(%{bloecke: []} = r), do: r.schluessel <> " — " <> r.zeile

  defp notiz_zeile(r),
    do: r.schluessel <> " — " <> r.zeile <> "  [" <> Enum.join(r.bloecke, ", ") <> "]"

  @doc """
  Der Arbeitsstand, wie ihn `notizen_lesen` und die Kompaktierung zeigen. Im
  Beppo-Modus ohne jede Angabe zur Größe des Mitschnitts — sonst holte sich
  das Modell den Horizont hier zurück.
  """
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{beppo: true} = s) do
    Enum.join(
      [
        "Eingetragene Aussagen: #{s.lfd}",
        if(s.beppo_pos == 0,
          do: "Du hast noch keinen Abschnitt geholt. Fang mit weiter() an.",
          else:
            "Zuletzt bearbeitet bis Block #{s.beppo_pos - 1}. " <>
              "Der naechste Abschnitt kommt mit weiter()."
        )
      ],
      "\n"
    )
  end

  def stand_text(%Stand{} = s) do
    [
      "Eingetragene Aussagen: #{s.lfd}",
      "Der Mitschnitt hat die Bloecke 0 bis #{s.max_block}.",
      lesestand(s)
    ]
    |> Kernel.++(luecken_hinweis(groesste_luecke(s)))
    |> Enum.join("\n")
  end

  defp lesestand(%Stand{lfd: 0, gelesen: []}), do: "Du liest noch. Gelesen: noch nichts"

  defp lesestand(%Stand{lfd: 0} = s),
    do: "Du liest noch. Gelesen: " <> Enum.map_join(s.gelesen, ", ", fn {v, b} -> "#{v}-#{b}" end)

  defp lesestand(s),
    do: "Beim Sammeln durchgearbeitet bis Block #{bis_wohin_gesammelt(s)} von #{s.max_block}."

  defp luecken_hinweis(""), do: []
  defp luecken_hinweis(l), do: ["Groesster Bereich ohne Aussage: #{l} — sieh dort nach."]

  @doc "Der höchste Block, bis zu dem beim Sammeln gelesen wurde, sonst -1."
  @spec bis_wohin_gesammelt(Stand.t()) :: integer()
  def bis_wohin_gesammelt(%Stand{sammelnd: []}), do: -1
  def bis_wohin_gesammelt(%Stand{sammelnd: s}), do: s |> Enum.map(&elem(&1, 1)) |> Enum.max()

  # Der breiteste Abstand zwischen zwei belegten Blöcken, ab 121 Blöcken — als
  # Hinweis, nicht als Vorwurf: dort lohnt Nachsehen.
  defp groesste_luecke(%Stand{belegte_bloecke: b}) do
    {von, breite} =
      b
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce({0, 0}, &breiter/2)

    if breite > 120, do: "#{von}-#{von + breite}", else: ""
  end

  # Bei Gleichstand bleibt die erste Lücke, wie im Spike.
  defp breiter([x, y], {_von, breite}) when y - x > breite, do: {x, y - x}
  defp breiter(_paar, acc), do: acc

  # ─── ABLAUF ───────────────────────────────────────────────────────────

  @doc "Ein ABLAUF-Schlüssel als Bereich `{von, bis}`, sonst `nil`."
  @spec bereich(String.t()) :: {integer(), integer()} | nil
  def bereich(schluessel) do
    case Regex.run(@bereich, schluessel) do
      [_, v, b] ->
        {v, b} = {String.to_integer(v), String.to_integer(b)}
        {min(v, b), max(v, b)}

      nil ->
        nil
    end
  end

  @doc """
  Der bestehende ABLAUF-Eintrag, den ein Bereich schneidet — auch unter
  anderem Schlüssel. In allen vier gemessenen Läufen hat der Agent den
  hinteren Teil zweimal aufgeteilt („1101-1180“ neben „1081-1140“).
  """
  @spec ablauf_ueberlappt([Stand.notiz()], String.t()) :: Stand.notiz() | nil
  def ablauf_ueberlappt(register, schluessel) do
    with {n0, n1} <- bereich(schluessel) do
      Enum.find(register, fn r ->
        r.abschnitt == "ABLAUF" and r.schluessel != schluessel and
          match?({a0, a1} when n0 <= a1 and a0 <= n1, bereich(r.schluessel))
      end)
    end
  end

  @doc """
  Die Teile des Mitschnitts, die ABLAUF nicht abdeckt; `["ABLAUF ist leer"]`
  ohne einen einzigen Bereich. Geprüft wird die Vereinigung, nicht die Zahl der
  Zeilen: zehn Zeilen über die ersten 200 Blöcke sind kein Gedächtnis der
  Sitzung.
  """
  @spec ablauf_luecken(Stand.t()) :: [String.t()]
  def ablauf_luecken(%Stand{} = s) do
    bereiche =
      for r <- s.register,
          r.abschnitt == "ABLAUF",
          String.trim(r.zeile || "") != "",
          [_, v, b] <- [Regex.run(@bereich_locker, r.schluessel)],
          do: {String.to_integer(v), String.to_integer(b)}

    if bereiche == [], do: ["ABLAUF ist leer"], else: Stand.luecken(bereiche, s.max_block)
  end
end
