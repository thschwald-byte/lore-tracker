defmodule Worker.Jack.Epos.Entwurf do
  @moduledoc """
  Die schreibenden Werkzeuge des Epos-Jack im zweiten Lauf, dem Schreiben
  (E2, #1210): `absatz`, `absatz_ersetzen`, `absatz_streichen` und
  `entwurf`. Pur: Stand und Argumente hinein, neuer Stand und Ergebnis heraus.

  **Der Epos-Jack schreibt frei** (Maintainer, 13.09.2026). Ein Absatz ist
  freie Prosa (`text`), mit einem Titel, wenn die FORM Zwischenüberschriften
  vorsieht, und optional mit dem Schlüssel der **Szene** aus den Notizen, die
  er erzählt (`szene`). Es gibt keine Fakten je Satz, keine Markierungen,
  keine Prüfung je Satz, keine Länge des Kapitels und keine Pflicht, jede
  Szene zu erzählen — anders als beim Resümee-Jack
  (`Worker.Jack.Resuemee.Entwurf`), wo der Satz die Prüfeinheit ist. Die
  Treue zur Handlung tragen der Überblick (Szenen mit ihren Fakten) und der
  Auftrag („Handlung treu, Erzählweise frei“), kein Werkzeug.

  Ein Absatz ist `%{titel:, text:, szene:}` im `entwurf` des Stands
  (`Worker.Jack.Resuemee.Stand`); die Funktionen zu Sätzen und Wörtern dort
  gelten nur für den Resümee-Jack, gezählt wird hier (`woerter/1`) — nach
  derselben Regel: was durch Leerraum getrennt ist, Titel eingeschlossen.

  **Die Szene ordnet zu, sie prüft nicht.** Ist sie angegeben, muss es sie
  unter SZENEN geben (Groß-/Kleinschreibung und Leerraum egal, gespeichert
  wird die Schreibweise der Notiz), sonst wird der Absatz abgelehnt. Über sie
  führt der Weg Absatz → Szene → Fakten (`Worker.Jack.Epos.Ergebnis.quellen/1`),
  aus dem der Einbau (E4) die Quellen des Kapitels baut. Ohne Szene steht ein
  Absatz für sich — eine Überleitung, ein Bild zwischen zwei Szenen.

  **Die Antworten sind Information:** die Wörter des Kapitels („X Wörter“),
  die Wörter je Absatz und die Szenen, denen noch kein Absatz zugeordnet ist —
  ausdrücklich als Hinweis, nicht als Pflicht (`hinweis_szenen/1`).

  **Benannte Grenzen, gegriffen, nicht gemessen:** ein Absatz hat höchstens
  400 Wörter, ein Titel höchstens 12. Die 400 sind großzügig gewählt und
  halten einen Absatz als Absatz: ohne Grenze ließe sich das ganze Kapitel in
  einen Aufruf legen — die Zuordnung zu Szenen würde grob, ein abgebrochener
  Aufruf verlöre alles auf einmal, und die Durchsicht (E3) hätte keine
  Einheit, die sie einzeln ersetzen kann. Leerraum im Text wird zu einem
  Leerzeichen zusammengezogen: einen neuen Absatz beginnt `absatz()`.

  **Ganz oder gar nicht:** ein Absatz mit einem Fehler (leer, zu lang,
  leerer oder zu langer Titel, unbekannte Szene) geht nicht in den Entwurf;
  die Antwort nennt die Gründe, das Journal (`journal_datei/0`) ihre Codes.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Epos.Ergebnis
  alias Worker.Jack.Resuemee.{Laenge, Stand}

  @max_woerter 400
  @max_titel_woerter 12
  @kurz_woerter 30
  @journal "entwurf_verlauf.jsonl"
  @optional ~w(titel szene)

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}
  @typedoc "Ein Absatz des Kapitels: freie Prosa, optional mit Titel und Szene."
  @type absatz :: %{titel: String.t() | nil, text: String.t(), szene: String.t() | nil}

  @doc "Die Datei im Journal, in die dieses Modul schreibt."
  @spec journal_datei() :: String.t()
  def journal_datei, do: @journal

  @doc "Die Höchstzahl der Wörter eines Absatzes."
  @spec max_woerter() :: pos_integer()
  def max_woerter, do: @max_woerter

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "absatz",
        beschreibung:
          "Hängt einen Absatz ans Ende des Kapitels. text ist der Absatz, frei erzählt. titel " <>
            "ist optional — ohne ihn ist der Absatz Fließtext; eine Überschrift setzt du, wenn " <>
            "deine FORM sie vorsieht. szene ist optional: der Schlüssel der Szene aus deinen " <>
            "Notizen, die der Absatz erzählt — so lässt sich später zeigen, auf welche Fakten " <>
            "er sich stützt. Ein Absatz hat höchstens #{@max_woerter} Wörter. Die Antwort nennt " <>
            "die Wörter des Kapitels, die Wörter je Absatz und, als Hinweis, die Szenen, denen " <>
            "noch kein Absatz zugeordnet ist.",
        parameter: schema(%{}),
        optional: @optional,
        aendert_bestand: true,
        ausfuehren: &absatz/2
      },
      %{
        name: "absatz_ersetzen",
        beschreibung:
          "Ersetzt Absatz nummer (aus entwurf()) durch einen neuen — text, titel und szene wie " <>
            "bei absatz(). Der Absatz behält seinen Platz; was du weglässt, hat er danach nicht " <>
            "mehr.",
        parameter: schema(%{"nummer" => nummer_schema()}),
        optional: @optional,
        aendert_bestand: true,
        ausfuehren: &absatz_ersetzen/2
      },
      %{
        name: "absatz_streichen",
        beschreibung:
          "Streicht Absatz nummer (aus entwurf()). Die Absätze dahinter rücken um eins nach vorn.",
        parameter: %{"type" => "object", "properties" => %{"nummer" => nummer_schema()}},
        aendert_bestand: true,
        ausfuehren: &absatz_streichen/2
      },
      %{
        name: "entwurf",
        beschreibung:
          "Gibt dein Kapitel zurück: jeden Absatz mit Nummer, Titel, Szene, Wortzahl und Text, " <>
            "dazu die Wörter des Kapitels und die Szenen, denen noch kein Absatz zugeordnet ist.",
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &entwurf/2
      }
    ]
  end

  defp nummer_schema,
    do: %{"type" => "integer", "minimum" => 1, "description" => "die Nummer aus entwurf()"}

  @doc """
  Das Schema eines Absatzes (`text`, `titel`, `szene`), dazu die Felder aus
  `extra` — für `absatz_ersetzen` die `nummer`.
  """
  @spec schema(map()) :: map()
  def schema(extra) do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(
          %{
            "text" => %{
              "type" => "string",
              "description" => "der Absatz, frei erzählt, wie er im Kapitel steht"
            },
            "titel" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Überschrift des Absatzes; ohne sie ist der Absatz Fließtext"
            },
            "szene" => %{
              "type" => "string",
              "minLength" => 1,
              "description" =>
                "der Schlüssel der Szene aus deinen Notizen (SZENEN), die der Absatz erzählt"
            }
          },
          extra
        )
    }
  end

  # ─── absatz, absatz_ersetzen, absatz_streichen ────────────────────────

  @doc "Einen Absatz ans Ende des Kapitels hängen (Werkzeug `absatz`)."
  @spec absatz(Stand.t(), map()) :: ergebnis()
  def absatz(%Stand{} = s, p) do
    case pruefen(s, p) do
      {:ok, neu} ->
        nr = length(s.entwurf) + 1

        s =
          %{s | entwurf: s.entwurf ++ [neu]}
          |> Stand.journal(@journal, %{"art" => "+", "absatz" => nr, "neu" => als_json(neu)})

        {s, {:ok, eingetragen(s, nr, "Eingetragen als Absatz #{nr}.")}}

      {:abgelehnt, gruende} ->
        ablehnen(s, "absatz", nil, gruende)
    end
  end

  @doc "Einen Absatz ersetzen (Werkzeug `absatz_ersetzen`)."
  @spec absatz_ersetzen(Stand.t(), map()) :: ergebnis()
  def absatz_ersetzen(%Stand{} = s, %{"nummer" => nr} = p) do
    if nummer_da?(s, nr) do
      alt = Enum.at(s.entwurf, nr - 1)

      case pruefen(s, p) do
        {:ok, ^alt} ->
          {s,
           {:error,
            "Absatz #{nr} steht bereits genau so — nichts geändert. Nimm dir den nächsten " <>
              "Schritt vor."}}

        {:ok, neu} ->
          s =
            %{s | entwurf: List.replace_at(s.entwurf, nr - 1, neu)}
            |> Stand.journal(@journal, %{
              "art" => "~",
              "absatz" => nr,
              "neu" => als_json(neu),
              "vorher" => als_json(alt)
            })

          {s, {:ok, eingetragen(s, nr, "Absatz #{nr} ersetzt.")}}

        {:abgelehnt, gruende} ->
          ablehnen(s, "absatz_ersetzen", nr, gruende)
      end
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  @doc "Einen Absatz streichen (Werkzeug `absatz_streichen`)."
  @spec absatz_streichen(Stand.t(), map()) :: ergebnis()
  def absatz_streichen(%Stand{} = s, %{"nummer" => nr}) do
    if nummer_da?(s, nr) do
      alt = Enum.at(s.entwurf, nr - 1)

      s =
        %{s | entwurf: List.delete_at(s.entwurf, nr - 1)}
        |> Stand.journal(@journal, %{"art" => "-", "absatz" => nr, "vorher" => als_json(alt)})

      hinweis =
        if nr <= length(s.entwurf),
          do:
            "Absatz #{nr} gestrichen. Die Absätze dahinter sind um eins nach vorn gerückt: " <>
              "der bisherige Absatz #{nr + 1} ist jetzt Absatz #{nr}.",
          else: "Absatz #{nr} gestrichen."

      {s,
       {:ok,
        Antwort.geordnet([
          {"ok", true},
          {"gestrichen", nr},
          {"entwurf", absaetze_text(s)},
          {"woerter", woerter_text(s)},
          {"woerter_je_absatz", nil_wenn_leer(je_absatz(s))},
          {"hinweis_szenen", hinweis_szenen(s)},
          {"hinweis", hinweis}
        ])}}
    else
      {s, {:error, keine_nummer(s, nr)}}
    end
  end

  defp nummer_da?(s, nr), do: is_integer(nr) and nr >= 1 and nr <= length(s.entwurf)

  defp keine_nummer(%Stand{entwurf: []}, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht — das Kapitel ist noch leer. Leg Absätze mit absatz() an."

  defp keine_nummer(s, nr),
    do:
      "Einen Absatz #{nr} gibt es nicht. Das Kapitel hat die Absätze 1 bis " <>
        "#{length(s.entwurf)}; entwurf() zeigt sie."

  defp eingetragen(s, nr, hinweis) do
    Antwort.geordnet([
      {"ok", true},
      {"absatz", nr},
      {"szene", Enum.at(s.entwurf, nr - 1).szene},
      {"entwurf", absaetze_text(s)},
      {"woerter", woerter_text(s)},
      {"woerter_je_absatz", je_absatz(s)},
      {"hinweis_szenen", hinweis_szenen(s)},
      {"hinweis", hinweis}
    ])
  end

  defp ablehnen(s, werkzeug, nr, gruende) do
    s =
      Stand.journal(s, @journal, %{
        "art" => "abgelehnt",
        "werkzeug" => werkzeug,
        "absatz" => nr,
        "gruende" => Enum.map(gruende, &elem(&1, 0))
      })

    {s,
     {:error,
      Antwort.geordnet([
        {"ok", false},
        {"hinweis",
         "Nichts eingetragen. Bring die genannten Stellen in Ordnung und schick den Absatz noch " <>
           "einmal vollständig."},
        {"gruende", Enum.map(gruende, &elem(&1, 1))}
      ])}}
  end

  # ─── Prüfung ──────────────────────────────────────────────────────────

  # {:ok, absatz} oder {:abgelehnt, [{code, text}]}.
  defp pruefen(s, p) do
    text = zusammenziehen(p["text"])
    {titel, titel_gruende} = titel_pruefen(p["titel"])
    {szene, szene_gruende} = szene_pruefen(s, p["szene"])
    gruende = text_gruende(text) ++ titel_gruende ++ szene_gruende

    if gruende == [],
      do: {:ok, %{titel: titel, text: text, szene: szene}},
      else: {:abgelehnt, gruende}
  end

  defp text_gruende(""), do: [{"leer", "Der Absatz ist leer. Schreib ihn aus."}]

  defp text_gruende(text) do
    case woerter_in(text) do
      n when n > @max_woerter ->
        [
          {"zu_lang",
           "Der Absatz hat #{n} Wörter, ein Absatz hat höchstens #{@max_woerter}. Teil ihn in " <>
             "zwei Absätze, dort, wo die Szene weitergeht oder der Blick wechselt."}
        ]

      _ ->
        []
    end
  end

  defp titel_pruefen(nil), do: {nil, []}

  defp titel_pruefen(roh) do
    t = zusammenziehen(roh)
    n = woerter_in(t)

    cond do
      t == "" ->
        {nil,
         [
           {"titel_leer",
            "Der Titel ist leer. Für einen Absatz Fließtext lässt du titel ganz weg; sonst " <>
              "schreib die Überschrift hin."}
         ]}

      n > @max_titel_woerter ->
        {nil,
         [
           {"titel_zu_lang",
            "Der Titel hat #{n} Wörter, eine Überschrift hat höchstens #{@max_titel_woerter}. " <>
              "Was er erzählt, gehört in den Absatz."}
         ]}

      true ->
        {t, []}
    end
  end

  defp szene_pruefen(_s, nil), do: {nil, []}

  defp szene_pruefen(s, roh) do
    case {szene(s, roh), Stand.abschnitt(s, "SZENEN")} do
      {%{schluessel: k}, _} ->
        {k, []}

      {nil, []} ->
        {nil,
         [
           {"szene_unbekannt",
            "Eine Szene „#{roh}“ gibt es nicht: in deinen Notizen stehen keine SZENEN. Lass " <>
              "szene weg."}
         ]}

      {nil, szenen} ->
        {nil,
         [
           {"szene_unbekannt",
            "Eine Szene „#{roh}“ gibt es in deinen Notizen nicht. Deine Szenen heißen: " <>
              Enum.map_join(szenen, ", ", &"„#{&1.schluessel}“") <>
              ". Nimm den Schlüssel, wie notizen_lesen() ihn zeigt, oder lass szene weg."}
         ]}
    end
  end

  @doc "Eine SZENE der Notizen über ihren Schlüssel (Groß-/Kleinschreibung und Leerraum egal)."
  @spec szene(Stand.t(), term()) :: Stand.notiz() | nil
  def szene(%Stand{} = s, schluessel) when is_binary(schluessel) do
    k = kanonisch(schluessel)
    Enum.find(Stand.abschnitt(s, "SZENEN"), &(kanonisch(&1.schluessel) == k))
  end

  def szene(_s, _schluessel), do: nil

  defp kanonisch(t), do: t |> String.split() |> Enum.join(" ") |> String.downcase()

  defp zusammenziehen(t) when is_binary(t), do: t |> String.split() |> Enum.join(" ")
  defp zusammenziehen(_), do: ""

  @doc """
  Ein Kapitel als Liste von `t:absatz/0` — aus dem Stand des Schreibens
  (Atom-Schlüssel) oder als JSON (String-Schlüssel, wie der Einbau es ablegen
  kann), für die Durchsicht (E3, `Worker.Jack.Epos.Durchsicht`). Leerraum
  wird zusammengezogen wie in `absatz`; ein Absatz ohne Text fällt weg, ein
  leerer Titel und eine leere Szene gelten als `nil`.
  """
  @spec entwurf_aus([map()] | nil) :: [absatz()]
  def entwurf_aus(entwurf) do
    for a <- List.wrap(entwurf),
        is_map(a),
        text = zusammenziehen(wert(a, :text)),
        text != "" do
      %{
        titel: leer_nil(zusammenziehen(wert(a, :titel))),
        text: text,
        szene: leer_nil(zusammenziehen(wert(a, :szene)))
      }
    end
  end

  defp wert(a, k), do: Map.get(a, k, Map.get(a, Atom.to_string(k)))

  defp leer_nil(""), do: nil
  defp leer_nil(t), do: t

  defp als_json(a), do: %{"titel" => a.titel, "text" => a.text, "szene" => a.szene}

  # ─── Zählen und Hinweise ──────────────────────────────────────────────

  @doc "Die Wörter des Kapitels: alle Absatztexte und Titel, getrennt durch Leerraum."
  @spec woerter(Stand.t()) :: non_neg_integer()
  def woerter(%Stand{entwurf: e}), do: e |> Enum.map(&absatz_woerter/1) |> Enum.sum()

  @doc "Die Wörter eines Absatzes, Titel eingeschlossen."
  @spec absatz_woerter(absatz()) :: non_neg_integer()
  def absatz_woerter(a), do: woerter_in(a.titel || "") + woerter_in(a.text)

  defp woerter_in(t), do: t |> String.split() |> length()

  defp woerter_text(s), do: Laenge.anzahl(woerter(s))

  defp je_absatz(%Stand{entwurf: e}),
    do:
      for({a, n} <- Enum.with_index(e, 1), do: "Absatz #{n}: #{Laenge.anzahl(absatz_woerter(a))}")

  defp absaetze_text(%Stand{entwurf: [_]}), do: "1 Absatz"
  defp absaetze_text(%Stand{entwurf: e}), do: "#{length(e)} Absätze"

  @doc "Die SZENEN der Notizen, denen noch kein Absatz zugeordnet ist, in ihrer Reihenfolge."
  @spec ohne_absatz(Stand.t()) :: [Stand.notiz()]
  def ohne_absatz(%Stand{} = s) do
    erzaehlt = MapSet.new(s.entwurf, & &1.szene)
    Enum.reject(Stand.abschnitt(s, "SZENEN"), &MapSet.member?(erzaehlt, &1.schluessel))
  end

  @doc """
  Der Hinweis auf die Szenen ohne Absatz, für die Antworten — ausdrücklich
  keine Pflicht. `nil`, wenn jeder Szene ein Absatz zugeordnet ist.
  """
  @spec hinweis_szenen(Stand.t()) :: String.t() | nil
  def hinweis_szenen(%Stand{} = s) do
    case ohne_absatz(s) do
      [] -> nil
      l -> "Noch keinem Absatz zugeordnet — ein Hinweis, keine Pflicht: #{szenen_text(l)}."
    end
  end

  defp szenen_text(szenen), do: Enum.map_join(szenen, "; ", &"„#{&1.schluessel}“ — #{&1.zeile}")

  defp nil_wenn_leer([]), do: nil
  defp nil_wenn_leer(l), do: l

  # ─── entwurf und Stand ────────────────────────────────────────────────

  @doc "Das Kapitel zurückgeben (Werkzeug `entwurf`)."
  @spec entwurf(Stand.t(), map()) :: ergebnis()
  def entwurf(%Stand{} = s, _args), do: {s, {:ok, entwurf_text(s)}}

  @doc """
  Das Kapitel als Text: vorn der Stand (`stand_zeilen/1`), dann je Absatz
  Nummer, Titel, Wortzahl, Szene und der Text.
  """
  @spec entwurf_text(Stand.t()) :: String.t()
  def entwurf_text(%Stand{entwurf: []} = s),
    do:
      Enum.join(
        ["Das Kapitel ist noch leer. Erzähl die erste Szene mit absatz()."] ++
          szenen_zeile(s),
        "\n"
      )

  def entwurf_text(%Stand{} = s) do
    absaetze =
      s.entwurf
      |> Enum.with_index(1)
      |> Enum.map(fn {a, n} ->
        "Absatz #{n}#{titel_teil(a.titel)} · #{Laenge.anzahl(absatz_woerter(a))}" <>
          "#{szene_teil(a.szene)}\n#{a.text}"
      end)

    Enum.join([stand_zeilen(s) | absaetze], "\n\n")
  end

  defp titel_teil(nil), do: " (Fließtext)"
  defp titel_teil(t), do: " — " <> t

  defp szene_teil(nil), do: " · ohne Szene"
  defp szene_teil(k), do: " · Szene „#{k}“"

  @doc """
  Der Entwurf gekürzt, für die Kompaktierung: je Absatz Nummer, Titel,
  Szene und die ersten #{@kurz_woerter} Wörter.
  """
  @spec entwurf_kurz(Stand.t()) :: String.t()
  def entwurf_kurz(%Stand{entwurf: []}), do: "(noch kein Absatz)"

  def entwurf_kurz(%Stand{} = s) do
    s.entwurf
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {a, n} ->
      w = String.split(a.text)
      mehr = if length(w) > @kurz_woerter, do: " …", else: ""

      "#{n}.#{titel_teil(a.titel)}#{szene_teil(a.szene)}: " <>
        Enum.join(Enum.take(w, @kurz_woerter), " ") <> mehr
    end)
  end

  @doc "Wo das Schreiben steht, wie `notizen_lesen` und die Kompaktierung es zeigen."
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{} = s) do
    "Sitzung #{s.sitzung.nummer}. Die Epos-Spalte heißt „#{s.ueberschrift}“.\n" <>
      stand_zeilen(s)
  end

  @doc """
  Der Stand des Kapitels in Zeilen: Absätze und Wörter, die Wörter je Absatz
  und — als Hinweis — die Zuordnung der Szenen.
  """
  @spec stand_zeilen(Stand.t()) :: String.t()
  def stand_zeilen(%Stand{} = s) do
    je = if s.entwurf == [], do: "", else: " Je Absatz: " <> Enum.join(je_absatz(s), ", ") <> "."

    Enum.join(["Kapitel: #{absaetze_text(s)}, #{woerter_text(s)}.#{je}"] ++ szenen_zeile(s), "\n")
  end

  defp szenen_zeile(s) do
    n = length(Stand.abschnitt(s, "SZENEN"))

    case ohne_absatz(s) do
      _ when n == 0 ->
        []

      [] ->
        ["Szenen: jeder der #{n} Szenen deiner Notizen ist ein Absatz zugeordnet."]

      l ->
        [
          "Szenen: #{n - length(l)} von #{n} Szenen deiner Notizen ist ein Absatz zugeordnet. " <>
            "Noch ohne Absatz — ein Hinweis, keine Pflicht: #{szenen_text(l)}."
        ]
    end
  end

  @doc """
  Was das Abbild für einen Beobachter im Schreiben dazu bekommt
  (`Worker.Jack.Epos.Notizen.abbild/1`): die Zahlen des Entwurfs, den
  Wortstand, das Kapitel als Markdown und die Szenen ohne Absatz.
  """
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{} = s) do
    %{
      "entwurf" => %{
        "absaetze" => length(s.entwurf),
        "mit_szene" => Enum.count(s.entwurf, &(&1.szene != nil)),
        "woerter" => woerter(s)
      },
      "woerter" => woerter(s),
      "markdown" => Ergebnis.markdown(s),
      "szenen_ohne_absatz" =>
        Enum.map(ohne_absatz(s), &%{"schluessel" => &1.schluessel, "zeile" => &1.zeile})
    }
  end
end
