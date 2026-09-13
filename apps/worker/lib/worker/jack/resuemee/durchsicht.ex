defmodule Worker.Jack.Resuemee.Durchsicht do
  @moduledoc """
  Der dritte Lauf des Resümee-Jack, die Durchsicht (J5, #1209, B3): Jack
  liest seinen Entwurf aus dem Schreiben Absatz für Absatz gegen die Fakten
  und behebt **nur grobe Schnitzer** — ein Satz sagt etwas anderes als seine
  Fakten, nennt eine Figur oder einen Ort, den seine Fakten nicht kennen, ein
  Übergang trägt eigenen Stoff, ein Satz steht doppelt. Stil, Wortwahl,
  Satzbau und Länge sind kein Grund; im Zweifel bestätigt er (Maintainer:
  „der Nachlauf soll eher gnädig sein“). Pur wie
  `Worker.Jack.Resuemee.Entwurf`: Stand und Argumente hinein, neuer Stand und
  Ergebnis heraus.

  Die Werkzeuge: `durchsicht` (ein Absatz mit jedem Satz, seinen Fakten im
  Wortlaut und den Hinweisen aus `Worker.Jack.Resuemee.Hinweise`),
  `absatz_bestaetigen`, `absatz_ersetzen` und `absatz_streichen`, dazu
  `entwurf` aus `Worker.Jack.Resuemee.Entwurf`. Ersetzen und Streichen
  laufen durch `Entwurf.absatz_ersetzen/2` und `Entwurf.absatz_streichen/2`
  — dieselbe Prüfung je Satz wie im Schreiben. Beide verlangen hier einen
  `grund` (welcher grobe Schnitzer behoben wird); er steht im Journal
  (`journal_datei/0`). Die Hinweise lehnen nie etwas ab.

  **Durchgänge.** `s.durchsicht` trägt den laufenden Durchgang und je Absatz
  (parallel zum Entwurf) einen Status: `:offen` (in diesem Durchgang zu
  entscheiden), `:bestaetigt`, `:ersetzt` oder `:frei` (blieb im vorigen
  Durchgang unverändert, in diesem nicht zu prüfen), dazu `gesehen` —
  bestätigen lässt sich ein Absatz erst, wenn Jack ihn in diesem Durchgang
  seit seiner letzten Änderung mit `durchsicht` gelesen hat. Ist kein Absatz
  mehr offen und wurde im Durchgang einer ersetzt, beginnt sofort der
  nächste: die ersetzten sind wieder offen, alle anderen frei. Ein
  gestrichener Absatz hat nichts mehr zu bestätigen. Nach höchstens
  `max_durchgaenge/0` Durchgängen beginnt keiner mehr; `fertig`
  (`Worker.Jack.Resuemee.Abschluss`) geht durch, sobald nichts offen ist.

  **Die Länge bleibt (#1209).** `absatz_ersetzen` lehnt eine Fassung ab,
  mit der der Entwurf über `max_woerter` Wörter käme
  (`Worker.Jack.Resuemee.Stand.woerter/1`) — der Entwurf aus dem Schreiben
  liegt darunter (`fertig` hat es geprüft), und die Durchsicht soll ihn nicht
  wieder aufblähen. Streng genommen lehnt sie ab, wenn der Entwurf danach
  über der Grenze läge UND länger würde: in der Pipeline ist das dasselbe;
  nur ein von außen eingereichter Entwurf, der schon über der Grenze liegt,
  darf so noch gekürzt werden.

  **Benannte Grenzen.** Die Zahl der Durchgänge (3) ist gegriffen, nicht
  gemessen. Der letzte Absatz lässt sich nicht streichen — ohne `absatz`
  könnte Jack keinen neuen anlegen, und ein Resümee ohne Absatz gibt es
  nicht. Ob ein Handlungsbogen nach einer Ersetzung noch vorkommt, prüft die
  Durchsicht nicht: sie ist gnädig, die Pflicht dazu hatte das Schreiben.
  Ob eine Änderung wirklich einen groben Schnitzer behebt, prüft niemand —
  der `grund` macht es nachlesbar, nicht richtig.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Resuemee.{Entwurf, Hinweise, Stand}

  @max_durchgaenge 3
  @journal "durchsicht.jsonl"

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Datei im Journal, in die dieses Modul schreibt."
  @spec journal_datei() :: String.t()
  def journal_datei, do: @journal

  @doc "Die Höchstzahl der Durchgänge."
  @spec max_durchgaenge() :: pos_integer()
  def max_durchgaenge, do: @max_durchgaenge

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    entwurf = s |> Entwurf.werkzeuge() |> Enum.find(&(&1.name == "entwurf"))

    [
      entwurf,
      %{
        name: "durchsicht",
        beschreibung:
          "Zeigt Absatz nummer zur Durchsicht: jeden Satz mit seinen Fakten im Wortlaut " <>
            "(ID, Figur, Aussage) und den Hinweisen — großgeschriebene Wörter, die in den " <>
            "Fakten des Satzes nicht vorkommen; ein Fingerzeig, keine Regel. Danach bestätigst, " <>
            "ersetzt oder streichst du den Absatz.",
        parameter: objekt(%{"nummer" => nummer_schema()}),
        wiederholung: :bis_aenderung,
        ausfuehren: &durchsicht/2
      },
      %{
        name: "absatz_bestaetigen",
        beschreibung:
          "Der Absatz bleibt, wie er ist — er hat keinen groben Schnitzer. Geht, nachdem du " <>
            "ihn in diesem Durchgang mit durchsicht(nummer) gelesen hast.",
        parameter: objekt(%{"nummer" => nummer_schema()}),
        aendert_bestand: true,
        ausfuehren: &absatz_bestaetigen/2
      },
      %{
        name: "absatz_ersetzen",
        beschreibung:
          "Ersetzt Absatz nummer, weil er einen groben Schnitzer hat. Du schickst den ganzen " <>
            "Absatz, alle Sätze, geprüft wie beim Schreiben; Sätze ohne Schnitzer übernimmst " <>
            "du wörtlich. grund: welchen groben Schnitzer die Ersetzung behebt, in einem Satz. " <>
            "Das Resümee hat höchstens #{s.max_woerter} Wörter; eine Fassung, die es darüber " <>
            "brächte, wird abgelehnt.",
        parameter: Entwurf.absatz_schema(%{"nummer" => nummer_schema(), "grund" => grund()}),
        optional: Entwurf.optional(),
        aendert_bestand: true,
        ausfuehren: &absatz_ersetzen/2
      },
      %{
        name: "absatz_streichen",
        beschreibung:
          "Streicht Absatz nummer, wenn er als Ganzes doppelt steht oder nur aus einem groben " <>
            "Schnitzer besteht. Die Absätze dahinter rücken um eins nach vorn; der letzte " <>
            "Absatz bleibt. grund: warum, in einem Satz.",
        parameter: objekt(%{"nummer" => nummer_schema(), "grund" => grund()}),
        aendert_bestand: true,
        ausfuehren: &absatz_streichen/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}

  defp nummer_schema,
    do: %{"type" => "integer", "minimum" => 1, "description" => "die Nummer aus entwurf()"}

  defp grund,
    do: %{
      "type" => "string",
      "description" => "welchen groben Schnitzer du behebst, in einem Satz"
    }

  # ─── durchsicht ───────────────────────────────────────────────────────

  @doc "Einen Absatz zur Durchsicht zeigen (Werkzeug `durchsicht`)."
  @spec durchsicht(Stand.t(), map()) :: ergebnis()
  def durchsicht(%Stand{} = s, %{"nummer" => nr}) do
    if nummer_da?(s, nr) do
      a = Enum.at(s.entwurf, nr - 1)
      s = setzen(s, nr, &%{&1 | gesehen: true})

      saetze =
        a.saetze
        |> Enum.zip(Hinweise.absatz(s, a))
        |> Enum.with_index(1)
        |> Enum.map(fn {{satz, h}, i} ->
          Antwort.geordnet([
            {"satz", i},
            {"text", satz.text},
            {"art", art(satz)},
            {"fakten", nil_wenn_leer(Enum.map(satz.fakten, &fakt_text(s, &1)))},
            {"hinweise", nil_wenn_leer(h)}
          ])
        end)

      {s,
       {:ok,
        Antwort.geordnet([
          {"absatz", nr},
          {"titel", a.titel},
          {"durchgang", s.durchsicht.durchgang},
          {"status", status_wort(status(s, nr))},
          {"saetze", saetze},
          {"hinweis", durchsicht_hinweis(s, nr)}
        ])}}
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  defp art(%{uebergang: true}), do: "Übergang"
  defp art(%{rueckblick: true}), do: "Rückblick"
  defp art(_satz), do: nil

  defp fakt_text(s, id) do
    case Stand.fakt(s, id) do
      nil -> id
      %{figur: nil} = f -> "#{f.id} — #{f.aussage}"
      f -> "#{f.id} — Figur: #{f.figur} — #{f.aussage}"
    end
  end

  defp durchsicht_hinweis(s, nr) do
    case status(s, nr) do
      :offen ->
        "Prüf jeden Satz an seinen Fakten. Ohne groben Schnitzer: absatz_bestaetigen(#{nr}). " <>
          "Mit einem: absatz_ersetzen(#{nr}, …) mit dem ganzen Absatz und dem grund. Die " <>
          "hinweise nennen großgeschriebene Wörter ohne Fundstelle in den Fakten — ein " <>
          "Fingerzeig, wo du genauer hinsiehst; entscheiden tun die Fakten."

      :bestaetigt ->
        "Absatz #{nr} hast du in diesem Durchgang bestätigt. " <> naechster_schritt(s)

      :ersetzt ->
        "Absatz #{nr} hast du in diesem Durchgang ersetzt. " <> naechster_schritt(s)

      :frei ->
        "Absatz #{nr} blieb im vorigen Durchgang unverändert und ist in diesem Durchgang " <>
          "entschieden. " <> naechster_schritt(s)
    end
  end

  # ─── bestätigen, ersetzen, streichen ──────────────────────────────────

  @doc "Einen Absatz bestätigen (Werkzeug `absatz_bestaetigen`)."
  @spec absatz_bestaetigen(Stand.t(), map()) :: ergebnis()
  def absatz_bestaetigen(%Stand{} = s, %{"nummer" => nr}) do
    cond do
      not nummer_da?(s, nr) ->
        {s, {:error, keine_nummer(s, nr)}}

      status(s, nr) != :offen ->
        {s, {:error, durchsicht_hinweis(s, nr)}}

      not gesehen?(s, nr) ->
        {s,
         {:error,
          "Lies Absatz #{nr} zuerst mit durchsicht(#{nr}) — dort stehen seine Fakten im " <>
            "Wortlaut und die Hinweise."}}

      true ->
        s =
          s
          |> setzen(nr, &%{&1 | status: :bestaetigt})
          |> journal(%{"art" => "bestaetigt", "absatz" => nr})

        antwort(s, [{"bestaetigt", nr}], "Absatz #{nr} bestätigt.")
    end
  end

  @doc "Einen Absatz ersetzen (Werkzeug `absatz_ersetzen`), geprüft wie im Schreiben."
  @spec absatz_ersetzen(Stand.t(), map()) :: ergebnis()
  def absatz_ersetzen(%Stand{} = s, %{"nummer" => nr} = p) do
    grund = String.trim(to_string(p["grund"] || ""))

    cond do
      not nummer_da?(s, nr) ->
        {s, {:error, keine_nummer(s, nr)}}

      grund == "" ->
        {s, {:error, grund_fehlt("die Ersetzung")}}

      true ->
        case Entwurf.absatz_ersetzen(s, Map.delete(p, "grund")) do
          {neu, {:ok, _}} ->
            if zu_lang?(s, neu), do: zu_lang(s, neu, nr), else: ersetzt(neu, nr, grund)

          abgelehnt ->
            abgelehnt
        end
    end
  end

  # Über der Grenze UND länger als vorher, s. Moduldoc.
  defp zu_lang?(vorher, nachher),
    do: Stand.ueber_grenze?(nachher) and Stand.woerter(nachher) > Stand.woerter(vorher)

  # Der Stand bleibt der alte; nur das Journal hält den Versuch fest. Die
  # Antwort nennt, wie lang der Absatz sein darf: so viel, wie bis zur Grenze
  # Platz ist — mindestens so lang wie jetzt.
  defp zu_lang(s, neu, nr) do
    jetzt = Stand.woerter_in([Enum.at(s.entwurf, nr - 1)])
    erlaubt = max(s.max_woerter - (Stand.woerter(s) - jetzt), jetzt)
    s = journal(s, %{"art" => "zu_lang", "absatz" => nr, "woerter" => Stand.woerter(neu)})

    {s,
     {:error,
      "Nichts ersetzt: mit dieser Fassung hätte der Entwurf #{Stand.woerter_text(neu)}. Das " <>
        "Resümee bleibt bei höchstens #{s.max_woerter} Wörtern — behebe den Schnitzer mit " <>
        "einer Fassung von Absatz #{nr} mit höchstens #{erlaubt} Wörtern (Titel und Sätze)."}}
  end

  defp ersetzt(neu, nr, grund) do
    neu =
      neu
      |> setzen(nr, fn _ -> %{status: :ersetzt, gesehen: false} end)
      |> journal(%{"art" => "ersetzt", "absatz" => nr, "grund" => grund})

    hinweise =
      for {h, i} <- Enum.with_index(Hinweise.absatz(neu, Enum.at(neu.entwurf, nr - 1)), 1),
          h != [],
          do: Antwort.geordnet([{"satz", i}, {"hinweise", h}])

    antwort(
      neu,
      [{"ersetzt", nr}, {"hinweise", nil_wenn_leer(hinweise)}],
      "Absatz #{nr} ersetzt." <> nachlese(neu)
    )
  end

  defp nachlese(s) do
    if s.durchsicht.durchgang < @max_durchgaenge,
      do: " Im nächsten Durchgang liest du ihn noch einmal und bestätigst ihn.",
      else: " Das ist der letzte Durchgang; er bleibt so."
  end

  @doc "Einen Absatz streichen (Werkzeug `absatz_streichen`); der letzte bleibt."
  @spec absatz_streichen(Stand.t(), map()) :: ergebnis()
  def absatz_streichen(%Stand{} = s, %{"nummer" => nr} = p) do
    grund = String.trim(to_string(p["grund"] || ""))

    cond do
      not nummer_da?(s, nr) ->
        {s, {:error, keine_nummer(s, nr)}}

      length(s.entwurf) == 1 ->
        {s,
         {:error,
          "Absatz 1 ist der einzige Absatz, und ein Resümee hat mindestens einen. Hat er " <>
            "einen groben Schnitzer, ersetze ihn mit absatz_ersetzen(1, …)."}}

      grund == "" ->
        {s, {:error, grund_fehlt("das Streichen")}}

      true ->
        {neu, {:ok, _}} = Entwurf.absatz_streichen(s, %{"nummer" => nr})
        d = neu.durchsicht

        neu =
          %{neu | durchsicht: %{d | absaetze: List.delete_at(d.absaetze, nr - 1)}}
          |> journal(%{"art" => "gestrichen", "absatz" => nr, "grund" => grund})

        geruckt =
          if nr <= length(neu.entwurf),
            do: " Die Absätze dahinter sind um eins nach vorn gerückt.",
            else: ""

        antwort(neu, [{"gestrichen", nr}], "Absatz #{nr} gestrichen." <> geruckt)
    end
  end

  defp grund_fehlt(was),
    do: "grund ist leer. Nenn in einem Satz, welchen groben Schnitzer #{was} behebt."

  # Nach einer Entscheidung: der nächste Durchgang, falls fällig, dann die
  # Antwort mit dem nächsten Schritt.
  defp antwort(s, felder, text) do
    {s, uebergang} = weiter(s)

    {s,
     {:ok,
      Antwort.geordnet(
        [{"ok", true}] ++
          felder ++
          [
            {"durchgang", s.durchsicht.durchgang},
            {"offen", nil_wenn_leer(offen(s))},
            {"hinweis", Enum.join([text, uebergang || naechster_schritt(s)], " ")}
          ]
      )}}
  end

  @doc """
  Beginnt den nächsten Durchgang, wenn der laufende entschieden ist, darin
  ein Absatz ersetzt wurde und der Deckel nicht erreicht ist. Liefert den
  Stand und den Text für Jack (`nil`, wenn kein Durchgang begann).
  """
  @spec weiter(Stand.t()) :: {Stand.t(), String.t() | nil}
  def weiter(%Stand{durchsicht: d} = s) do
    stati = Enum.map(d.absaetze, & &1.status)

    if :offen not in stati and :ersetzt in stati and d.durchgang < @max_durchgaenge do
      absaetze =
        Enum.map(d.absaetze, fn
          %{status: :ersetzt} -> %{status: :offen, gesehen: false}
          _ -> %{status: :frei, gesehen: false}
        end)

      s = %{s | durchsicht: %{d | durchgang: d.durchgang + 1, absaetze: absaetze}}
      offen = offen(s)
      s = journal(s, %{"art" => "durchgang", "offen" => offen})

      {s,
       "Durchgang #{d.durchgang} ist durch, und du hast darin ersetzt. Durchgang " <>
         "#{d.durchgang + 1} beginnt: lies #{absatz_liste(offen)} noch einmal mit durchsicht() " <>
         "und bestätige — oder ersetze noch einmal, wenn ein grober Schnitzer geblieben ist. " <>
         "Alle anderen Absätze sind entschieden."}
    else
      {s, nil}
    end
  end

  defp absatz_liste([n]), do: "Absatz #{n}"
  defp absatz_liste(ns), do: "die Absätze #{Enum.join(ns, ", ")}"

  @doc "Was als Nächstes zu tun ist, für die Antworten und die Kompaktierung."
  @spec naechster_schritt(Stand.t()) :: String.t()
  def naechster_schritt(%Stand{} = s) do
    case offen(s) do
      [n | _] ->
        if gesehen?(s, n),
          do: "Absatz #{n} ist offen und gelesen: bestätige, ersetze oder streiche ihn.",
          else: "Weiter mit Absatz #{n}: durchsicht(#{n})."

      [] ->
        if s.durchsicht.durchgang >= @max_durchgaenge and
             Enum.any?(s.durchsicht.absaetze, &(&1.status == :ersetzt)),
           do:
             "Jeder Absatz ist entschieden. Das war der #{@max_durchgaenge}. Durchgang, mehr " <>
               "gibt es nicht — schließ mit fertig() ab.",
           else: "Jeder Absatz ist entschieden. Schließ mit fertig() ab."
    end
  end

  # ─── Buchhaltung ──────────────────────────────────────────────────────

  @doc "Die Nummern (ab 1) der Absätze, die im laufenden Durchgang offen sind."
  @spec offen(Stand.t()) :: [pos_integer()]
  def offen(%Stand{durchsicht: d}) do
    for {%{status: :offen}, n} <- Enum.with_index(d.absaetze, 1), do: n
  end

  @doc "Wie oft in der ganzen Durchsicht bestätigt, ersetzt und gestrichen wurde."
  @spec zaehler(Stand.t()) :: %{atom() => non_neg_integer()}
  def zaehler(%Stand{} = s) do
    arten = Enum.frequencies(for e <- eintraege(s), do: e["art"])

    %{
      bestaetigt: Map.get(arten, "bestaetigt", 0),
      ersetzt: Map.get(arten, "ersetzt", 0),
      gestrichen: Map.get(arten, "gestrichen", 0)
    }
  end

  defp eintraege(s), do: for({@journal, e} <- Stand.journal_liste(s), do: e)

  defp status(s, nr), do: Enum.at(s.durchsicht.absaetze, nr - 1).status
  defp gesehen?(s, nr), do: Enum.at(s.durchsicht.absaetze, nr - 1).gesehen

  defp setzen(%Stand{durchsicht: d} = s, nr, fun),
    do: %{s | durchsicht: %{d | absaetze: List.update_at(d.absaetze, nr - 1, fun)}}

  defp journal(s, eintrag),
    do: Stand.journal(s, @journal, Map.put(eintrag, "durchgang", s.durchsicht.durchgang))

  defp nummer_da?(s, nr), do: is_integer(nr) and nr >= 1 and nr <= length(s.entwurf)

  defp keine_nummer(s, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht. Der Entwurf hat die Absätze 1 bis " <>
        "#{length(s.entwurf)}; entwurf() zeigt sie."

  defp status_wort(:offen), do: "offen"
  defp status_wort(:bestaetigt), do: "bestätigt"
  defp status_wort(:ersetzt), do: "ersetzt"
  defp status_wort(:frei), do: "unverändert aus dem vorigen Durchgang"

  defp nil_wenn_leer([]), do: nil
  defp nil_wenn_leer(l), do: l

  # ─── Stand, Abbild, Zählwerte ─────────────────────────────────────────

  @doc """
  Wo die Durchsicht steht, wie `notizen_lesen` und die Kompaktierung es
  zeigen: Durchgang, Zähler, offene Absätze und je Absatz Status und Zahl der
  Hinweise — die Übersicht über den ganzen Entwurf.
  """
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{} = s) do
    z = zaehler(s)
    e = Stand.entwurf_zahlen(s)
    offen = offen(s)

    absaetze =
      s.entwurf
      |> Enum.zip(s.durchsicht.absaetze)
      |> Enum.with_index(1)
      |> Enum.map_join(" · ", fn {{a, st}, n} ->
        h = Hinweise.zahl(s, a)
        "#{n} #{kurzwort(st.status)}" <> if(h > 0, do: " (#{h} Hinweise)", else: "")
      end)

    Enum.join(
      [
        "Sitzung #{s.sitzung.nummer}. Die Resümee-Spalte heißt „#{s.ueberschrift}“.",
        "Entwurf: #{e.absaetze} Absätze, #{e.saetze} Sätze, #{Stand.woerter_text(s)}.",
        "Durchsicht: Durchgang #{s.durchsicht.durchgang} von höchstens #{@max_durchgaenge}. " <>
          "Bisher bestätigt #{z.bestaetigt}, ersetzt #{z.ersetzt}, gestrichen #{z.gestrichen}.",
        if(offen == [],
          do: "In diesem Durchgang ist jeder Absatz entschieden.",
          else: "Offen in diesem Durchgang: #{Enum.join(offen, ", ")}."
        ),
        "Absätze: " <> absaetze
      ],
      "\n"
    )
  end

  defp kurzwort(:frei), do: "unverändert"
  defp kurzwort(st), do: status_wort(st)

  @doc "Die Durchsicht als JSON-fähige Map für den Beobachter (Laufsicht)."
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{durchsicht: d} = s) do
    z = zaehler(s)

    %{
      "durchgang" => d.durchgang,
      "offen" => offen(s),
      "status" => Enum.map(d.absaetze, &Atom.to_string(&1.status)),
      "bestaetigt" => z.bestaetigt,
      "ersetzt" => z.ersetzt,
      "gestrichen" => z.gestrichen,
      "hinweise" => Hinweise.anzahl(s, s.entwurf)
    }
  end

  @doc """
  Die Zählwerte der Durchsicht, JSON-fähig: `durchgaenge`, `bestaetigt`,
  `ersetzt`, `gestrichen`, dazu `ersetzungen` und `streichungen` je
  `%{"durchgang", "absatz", "grund"}` in Reihenfolge, und die Hinweise im
  Entwurf vor (`hinweise_vorher`, der Entwurf aus dem Schreiben) und nach der
  Durchsicht (`hinweise_nachher`).
  """
  @spec zaehlwerte(Stand.t()) :: map()
  def zaehlwerte(%Stand{durchsicht: d} = s) do
    z = zaehler(s)
    e = eintraege(s)

    auswahl = fn art ->
      for %{"art" => ^art} = x <- e, do: Map.take(x, ~w(durchgang absatz grund))
    end

    %{
      "durchgaenge" => d.durchgang,
      "bestaetigt" => z.bestaetigt,
      "ersetzt" => z.ersetzt,
      "gestrichen" => z.gestrichen,
      "ersetzungen" => auswahl.("ersetzt"),
      "streichungen" => auswahl.("gestrichen"),
      "hinweise_vorher" => Hinweise.anzahl(s, d.ausgang),
      "hinweise_nachher" => Hinweise.anzahl(s, s.entwurf)
    }
  end
end
