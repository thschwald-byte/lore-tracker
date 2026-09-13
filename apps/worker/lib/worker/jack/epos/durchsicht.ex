defmodule Worker.Jack.Epos.Durchsicht do
  @moduledoc """
  Der dritte Lauf des Epos-Jack, die Durchsicht (E3, #1210): Jack liest sein
  Kapitel aus dem Schreiben Absatz für Absatz und macht es besser lesbar.
  Anders als beim Resümee (`Worker.Jack.Resuemee.Durchsicht`: gnädig, nur
  grobe Schnitzer) ist diese Durchsicht **auch stilistisch beauftragt**
  (Maintainer, 13.09.2026): Lesefluss, Rhythmus, Wiederholungen, der Ton nach
  der FORM, Übergänge zwischen den Szenen, der Anschluss an das vorige
  Kapitel — dazu wie beim Resümee **grobe Schnitzer gegen die Fakten**
  (falsche Figur, falscher Ort, falscher Ausgang, verdrehte Reihenfolge).
  Priorität hat guter Text; ein gelungener Absatz bleibt, wie er ist. Pur:
  Stand und Argumente hinein, neuer Stand und Ergebnis heraus.

  Die Werkzeuge: `durchsicht` (ein Absatz mit Titel, Text und Wortzahl, seine
  Szene mit ihren Fakten im Wortlaut, das Ende des Absatzes davor und der
  Anfang des Absatzes danach als Kontext, und die Hinweise aus
  `Worker.Jack.Epos.Hinweise`), `absatz_bestaetigen`, `absatz_ersetzen` und
  `absatz_streichen`, dazu `entwurf` aus `Worker.Jack.Epos.Entwurf`. Ersetzen
  und Streichen laufen durch `Worker.Jack.Epos.Entwurf.absatz_ersetzen/2` und
  `.absatz_streichen/2` — dieselbe Prüfung wie `absatz` im Schreiben (die
  Szene muss es geben, ein Absatz hat höchstens 400 Wörter, ein Titel
  höchstens 12). Beide verlangen einen `grund`, der ausdrücklich stilistisch
  sein darf; er steht im Journal (`durchsicht.jsonl`, dieselbe Datei wie beim
  Resümee). Die Hinweise lehnen nie etwas ab.

  **Durchgänge und Buchhaltung teilt der Epos-Jack mit dem Resümee**
  (`Worker.Jack.Resuemee.Durchsicht`: `offen/1`, `weiter/1`, `zaehler/1`,
  `naechster_schritt/1`, `status/2`, `gesehen?/2`, `setzen/3`, `austragen/2`,
  `journal/2`, `abbild/2`, `zaehlwerte/2`) — sie hängen an Absätzen, nicht an
  Sätzen. Jeder Absatz wird in einem Durchgang bestätigt, ersetzt oder
  gestrichen; bestätigen lässt er sich erst, wenn Jack ihn in diesem
  Durchgang seit seiner letzten Änderung mit `durchsicht` gelesen hat. Wurde
  ersetzt, beginnt ein weiterer Durchgang nur über die ersetzten Absätze,
  höchstens `Worker.Jack.Resuemee.Durchsicht.max_durchgaenge/0` (3, gegriffen,
  nicht gemessen). `fertig` (`Worker.Jack.Epos.Abschluss`) lehnt ab, solange
  im laufenden Durchgang ein Absatz offen ist.

  **Was hier fehlt, weil das Epos frei geschrieben wird:** eine Länge (das
  Kapitel hat keine) und ein Weg, der vollständig bleiben müsste (die Szenen
  trägt der Überblick). Eine Ersetzung, die ihre Szene verliert, geht durch;
  die Antwort sagt es.

  **Benannte Grenzen.** Der letzte Absatz lässt sich nicht streichen — ohne
  `absatz` gäbe es keinen Weg zurück, und ein Kapitel ohne Absatz gibt es
  nicht. Ob eine Ersetzung den Text wirklich besser macht und die Handlung
  treu bleibt, prüft kein Code — der `grund` macht es nachlesbar, nicht
  richtig. Der Kontext davor und danach ist auf 40 Wörter gekürzt
  (gegriffen); den ganzen Text zeigt `entwurf()`. Vor Absatz 1 steht als
  Kontext das Ende des vorigen Kapitels, damit der Anschluss prüfbar ist.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Epos.{Entwurf, Hinweise}
  alias Worker.Jack.Resuemee.Durchsicht, as: Buch
  alias Worker.Jack.Resuemee.{Laenge, Stand}

  @kontext_woerter 40

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc """
  Der Stand der Durchsicht: frisch aus der Eingabe mit den Notizen des
  Überblicks (`Worker.Jack.Resuemee.Stand.fuer_schreiben/2`, `art: :epos`),
  dazu das Kapitel aus dem Schreiben (`Worker.Jack.Epos.Entwurf.entwurf_aus/1`)
  und die Durchsicht im ersten Durchgang
  (`Worker.Jack.Resuemee.Stand.mit_durchsicht/2`).
  """
  @spec stand(map(), map() | nil, [map()] | nil) :: Stand.t()
  def stand(eingabe, ablage, entwurf) do
    eingabe
    |> Map.put(:art, :epos)
    |> Stand.fuer_schreiben(ablage)
    |> Stand.mit_durchsicht(Entwurf.entwurf_aus(entwurf))
  end

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    entwurf = s |> Entwurf.werkzeuge() |> Enum.find(&(&1.name == "entwurf"))

    [
      entwurf,
      %{
        name: "durchsicht",
        beschreibung:
          "Zeigt Absatz nummer zur Durchsicht: Titel, Text und Wortzahl, die Szene, die er " <>
            "erzählt, mit ihren Fakten im Wortlaut (ID, Figur, Aussage), das Ende des Absatzes " <>
            "davor und den Anfang des Absatzes danach, dazu die Hinweise — großgeschriebene " <>
            "Wörter ohne Fundstelle in den Fakten; ein Fingerzeig, keine Regel. Danach " <>
            "bestätigst, ersetzt oder streichst du den Absatz.",
        parameter: objekt(%{"nummer" => nummer_schema()}),
        wiederholung: :bis_aenderung,
        ausfuehren: &durchsicht/2
      },
      %{
        name: "absatz_bestaetigen",
        beschreibung:
          "Der Absatz bleibt, wie er ist — er liest sich gut, klingt nach deiner FORM und " <>
            "erzählt, was seine Szene sagt. Geht, nachdem du ihn in diesem Durchgang mit " <>
            "durchsicht(nummer) gelesen hast.",
        parameter: objekt(%{"nummer" => nummer_schema()}),
        aendert_bestand: true,
        ausfuehren: &absatz_bestaetigen/2
      },
      %{
        name: "absatz_ersetzen",
        beschreibung:
          "Ersetzt Absatz nummer durch eine bessere Fassung: text, titel und szene wie bei " <>
            "absatz() im Schreiben, höchstens #{Entwurf.max_woerter()} Wörter. titel und szene " <>
            "übernimmst du, wie sie stehen — was du weglässt, hat der Absatz danach nicht mehr. " <>
            "grund: was die neue Fassung besser macht, in einem Satz — Lesefluss, Rhythmus, " <>
            "eine Wiederholung, der Ton, ein Übergang oder ein grober Schnitzer gegen die Fakten.",
        parameter:
          Entwurf.schema(%{
            "nummer" => nummer_schema(),
            "grund" => %{
              "type" => "string",
              "description" => "was die neue Fassung besser macht, in einem Satz"
            }
          }),
        optional: ~w(titel szene),
        aendert_bestand: true,
        ausfuehren: &absatz_ersetzen/2
      },
      %{
        name: "absatz_streichen",
        beschreibung:
          "Streicht Absatz nummer, wenn er als Ganzes doppelt steht oder das Kapitel ohne ihn " <>
            "besser trägt. Die Absätze dahinter rücken um eins nach vorn; der letzte Absatz " <>
            "bleibt. grund: warum, in einem Satz.",
        parameter:
          objekt(%{
            "nummer" => nummer_schema(),
            "grund" => %{
              "type" => "string",
              "description" => "warum der Absatz geht, in einem Satz"
            }
          }),
        aendert_bestand: true,
        ausfuehren: &absatz_streichen/2
      }
    ]
  end

  defp objekt(props), do: %{"type" => "object", "properties" => props}

  defp nummer_schema,
    do: %{"type" => "integer", "minimum" => 1, "description" => "die Nummer aus entwurf()"}

  # ─── durchsicht ───────────────────────────────────────────────────────

  @doc "Einen Absatz zur Durchsicht zeigen (Werkzeug `durchsicht`)."
  @spec durchsicht(Stand.t(), map()) :: ergebnis()
  def durchsicht(%Stand{} = s, %{"nummer" => nr}) do
    if nummer_da?(s, nr) do
      a = Enum.at(s.entwurf, nr - 1)
      s = Buch.setzen(s, nr, &%{&1 | gesehen: true})

      {s,
       {:ok,
        Antwort.geordnet([
          {"absatz", nr},
          {"titel", a.titel},
          {"woerter", Laenge.anzahl(Entwurf.absatz_woerter(a))},
          {"durchgang", s.durchsicht.durchgang},
          {"status", Buch.status_wort(Buch.status(s, nr))},
          {"davor", davor(s, nr)},
          {"text", a.text},
          {"danach", danach(s, nr)},
          {"szene", szene_text(s, a)},
          {"hinweise", nil_wenn_leer(Hinweise.absatz(s, a))},
          {"hinweis", durchsicht_hinweis(s, nr)}
        ])}}
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  # Vor Absatz 1 das Ende des vorigen Kapitels (der Anschluss), sonst das Ende
  # des Absatzes davor.
  defp davor(s, 1) do
    case Hinweise.voriges_kapitel(s) do
      %{nummer: n, text: t} when is_binary(t) -> "Ende des Kapitels von Sitzung #{n}: " <> ende(t)
      _ -> nil
    end
  end

  defp davor(s, nr) do
    a = Enum.at(s.entwurf, nr - 2)
    "Absatz #{nr - 1}#{titel_teil(a.titel)}: " <> ende(a.text)
  end

  defp danach(s, nr) when nr >= length(s.entwurf), do: nil

  defp danach(s, nr) do
    a = Enum.at(s.entwurf, nr)
    w = String.split(a.text)
    mehr = if length(w) > @kontext_woerter, do: " …", else: ""

    "Absatz #{nr + 1}#{titel_teil(a.titel)}: " <>
      Enum.join(Enum.take(w, @kontext_woerter), " ") <> mehr
  end

  defp ende(text) do
    w = String.split(text)

    if length(w) > @kontext_woerter,
      do: "… " <> Enum.join(Enum.take(w, -@kontext_woerter), " "),
      else: Enum.join(w, " ")
  end

  defp titel_teil(nil), do: ""
  defp titel_teil(t), do: " (#{t})"

  defp szene_text(s, a) do
    case {Hinweise.szene(s, a), a.szene} do
      {%{} = sz, _} ->
        Antwort.geordnet([
          {"schluessel", sz.schluessel},
          {"zeile", sz.zeile},
          {"fakten", Enum.map(sz.fakten, &fakt_text(s, &1))}
        ])

      {nil, nil} ->
        "ohne Szene — eine Überleitung oder ein Bild zwischen zwei Szenen; die Hinweise " <>
          "vergleichen mit allen Fakten dieser Sitzung"

      {nil, k} ->
        "„#{k}“ — diese Szene steht nicht in deinen Notizen; die Hinweise vergleichen mit " <>
          "allen Fakten dieser Sitzung"
    end
  end

  defp fakt_text(s, id) do
    case Stand.fakt(s, id) do
      nil ->
        id

      f ->
        vor = if Stand.diese_sitzung?(s, f), do: "", else: "(Sitzung #{f.sitzung}) "
        figur = if f.figur, do: "Figur: #{f.figur} — ", else: ""
        "#{f.id} — #{vor}#{figur}#{f.aussage}"
    end
  end

  defp durchsicht_hinweis(s, nr) do
    case Buch.status(s, nr) do
      :offen ->
        "Lies den Absatz als Leser: liest er sich flüssig, klingt er nach deiner FORM, trägt " <>
          "der Übergang vom Absatz davor, wiederholen sich Wörter oder Bilder, erzählt er, was " <>
          "die Fakten seiner Szene sagen? Trägt er: absatz_bestaetigen(#{nr}). Lässt er sich " <>
          "besser erzählen oder steht ein grober Schnitzer darin: absatz_ersetzen(#{nr}, …) mit " <>
          "dem ganzen Absatz und dem grund. Die hinweise nennen großgeschriebene Wörter ohne " <>
          "Fundstelle — ein Fingerzeig, wo du genauer hinsiehst; entscheiden tun die Fakten."

      :bestaetigt ->
        "Absatz #{nr} hast du in diesem Durchgang bestätigt. " <> Buch.naechster_schritt(s)

      :ersetzt ->
        "Absatz #{nr} hast du in diesem Durchgang ersetzt. " <> Buch.naechster_schritt(s)

      :frei ->
        "Absatz #{nr} blieb im vorigen Durchgang unverändert und ist in diesem Durchgang " <>
          "entschieden. " <> Buch.naechster_schritt(s)
    end
  end

  # ─── bestätigen, ersetzen, streichen ──────────────────────────────────

  @doc "Einen Absatz bestätigen (Werkzeug `absatz_bestaetigen`)."
  @spec absatz_bestaetigen(Stand.t(), map()) :: ergebnis()
  def absatz_bestaetigen(%Stand{} = s, %{"nummer" => nr}) do
    cond do
      not nummer_da?(s, nr) ->
        {s, {:error, keine_nummer(s, nr)}}

      Buch.status(s, nr) != :offen ->
        {s, {:error, durchsicht_hinweis(s, nr)}}

      not Buch.gesehen?(s, nr) ->
        {s,
         {:error,
          "Lies Absatz #{nr} zuerst mit durchsicht(#{nr}) — dort stehen seine Szene mit ihren " <>
            "Fakten, der Kontext davor und danach und die Hinweise."}}

      true ->
        s =
          s
          |> Buch.setzen(nr, &%{&1 | status: :bestaetigt})
          |> Buch.journal(%{"art" => "bestaetigt", "absatz" => nr})

        antwort(s, [{"bestaetigt", nr}], "Absatz #{nr} bestätigt.")
    end
  end

  @doc "Einen Absatz ersetzen (Werkzeug `absatz_ersetzen`), geprüft wie `absatz` im Schreiben."
  @spec absatz_ersetzen(Stand.t(), map()) :: ergebnis()
  def absatz_ersetzen(%Stand{} = s, %{"nummer" => nr} = p) do
    grund = String.trim(to_string(p["grund"] || ""))

    cond do
      not nummer_da?(s, nr) ->
        {s, {:error, keine_nummer(s, nr)}}

      grund == "" ->
        {s, {:error, "grund ist leer. Nenn in einem Satz, was die neue Fassung besser macht."}}

      true ->
        alt = Enum.at(s.entwurf, nr - 1)

        case Entwurf.absatz_ersetzen(s, Map.delete(p, "grund")) do
          {neu, {:ok, _}} -> ersetzt(neu, nr, grund, alt)
          abgelehnt -> abgelehnt
        end
    end
  end

  defp ersetzt(neu, nr, grund, alt) do
    neu =
      neu
      |> Buch.setzen(nr, fn _ -> %{status: :ersetzt, gesehen: false} end)
      |> Buch.journal(%{"art" => "ersetzt", "absatz" => nr, "grund" => grund})

    a = Enum.at(neu.entwurf, nr - 1)

    antwort(
      neu,
      [
        {"ersetzt", nr},
        {"szene", a.szene},
        {"woerter", Laenge.anzahl(Entwurf.absatz_woerter(a))},
        {"hinweise", nil_wenn_leer(Hinweise.absatz(neu, a))}
      ],
      "Absatz #{nr} ersetzt." <> szene_verloren(alt, a) <> nachlese(neu)
    )
  end

  defp szene_verloren(%{szene: k}, %{szene: nil}) when is_binary(k),
    do:
      " Die neue Fassung ist keiner Szene zugeordnet (vorher „#{k}“) — erzählt sie diese " <>
        "Szene, ersetze sie noch einmal mit szene."

  defp szene_verloren(_alt, _neu), do: ""

  defp nachlese(s) do
    if s.durchsicht.durchgang < Buch.max_durchgaenge(),
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
          "Absatz 1 ist der einzige Absatz des Kapitels; er bleibt. Lässt er sich besser " <>
            "erzählen, ersetze ihn mit absatz_ersetzen(1, …)."}}

      grund == "" ->
        {s,
         {:error,
          "grund ist leer. Nenn in einem Satz, warum das Kapitel ohne den Absatz besser trägt."}}

      true ->
        {neu, {:ok, _}} = Entwurf.absatz_streichen(s, %{"nummer" => nr})

        neu =
          neu
          |> Buch.austragen(nr)
          |> Buch.journal(%{"art" => "gestrichen", "absatz" => nr, "grund" => grund})

        geruckt =
          if nr <= length(neu.entwurf),
            do: " Die Absätze dahinter sind um eins nach vorn gerückt.",
            else: ""

        antwort(neu, [{"gestrichen", nr}], "Absatz #{nr} gestrichen." <> geruckt)
    end
  end

  # Nach einer Entscheidung: der nächste Durchgang, falls fällig, dann die
  # Antwort mit dem nächsten Schritt.
  defp antwort(s, felder, text) do
    {s, uebergang} = Buch.weiter(s)

    {s,
     {:ok,
      Antwort.geordnet(
        [{"ok", true}] ++
          felder ++
          [
            {"durchgang", s.durchsicht.durchgang},
            {"offen", nil_wenn_leer(Buch.offen(s))},
            {"hinweis", Enum.join([text, uebergang || Buch.naechster_schritt(s)], " ")}
          ]
      )}}
  end

  defp nummer_da?(s, nr), do: is_integer(nr) and nr >= 1 and nr <= length(s.entwurf)

  defp keine_nummer(s, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht. Das Kapitel hat die Absätze 1 bis " <>
        "#{length(s.entwurf)}; entwurf() zeigt sie."

  defp nil_wenn_leer([]), do: nil
  defp nil_wenn_leer(l), do: l

  # ─── Stand, Abbild, Zählwerte ─────────────────────────────────────────

  @doc """
  Wo die Durchsicht steht, wie `notizen_lesen` und die Kompaktierung es
  zeigen: das Kapitel (Absätze, Wörter, Szenen), Durchgang, Zähler, offene
  Absätze und je Absatz Status und Zahl der Hinweise.
  """
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{} = s) do
    z = Buch.zaehler(s)
    offen = Buch.offen(s)

    absaetze =
      s.entwurf
      |> Enum.zip(s.durchsicht.absaetze)
      |> Enum.with_index(1)
      |> Enum.map_join(" · ", fn {{a, st}, n} ->
        "#{n} #{kurzwort(st.status)}" <> hinweise_teil(Hinweise.zahl(s, a))
      end)

    Enum.join(
      [
        "Sitzung #{s.sitzung.nummer}. Die Epos-Spalte heißt „#{s.ueberschrift}“.",
        Entwurf.stand_zeilen(s),
        "Durchsicht: Durchgang #{s.durchsicht.durchgang} von höchstens " <>
          "#{Buch.max_durchgaenge()}. Bisher bestätigt #{z.bestaetigt}, ersetzt #{z.ersetzt}, " <>
          "gestrichen #{z.gestrichen}.",
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
  defp kurzwort(st), do: Buch.status_wort(st)

  defp hinweise_teil(0), do: ""
  defp hinweise_teil(1), do: " (1 Hinweis)"
  defp hinweise_teil(h), do: " (#{h} Hinweise)"

  @doc """
  Die Durchsicht als JSON-fähige Map für den Beobachter — dieselbe Form wie
  beim Resümee (`Worker.Jack.Resuemee.Durchsicht.abbild/2`), mit den
  Hinweisen des Epos; daraus zählt der Melder des Laufbands.
  """
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{} = s), do: Buch.abbild(s, &Hinweise.anzahl/2)

  @doc """
  Die Zählwerte der Durchsicht, JSON-fähig: `durchgaenge`, `bestaetigt`,
  `ersetzt`, `gestrichen`, `ersetzungen` und `streichungen` je
  `%{"durchgang", "absatz", "grund"}`, die Hinweise vor und nach der
  Durchsicht (`Worker.Jack.Resuemee.Durchsicht.zaehlwerte/2` mit den Hinweisen
  des Epos).
  """
  @spec zaehlwerte(Stand.t()) :: map()
  def zaehlwerte(%Stand{} = s), do: Buch.zaehlwerte(s, &Hinweise.anzahl/2)
end
