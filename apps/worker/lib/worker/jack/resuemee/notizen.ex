defmodule Worker.Jack.Resuemee.Notizen do
  @moduledoc """
  `notiz` und `notizen_lesen` des Resümee-Jack (J5, #1209) — das Gegenstück
  zu Jacks Gedächtnis (`Worker.Jack.Gedaechtnis`), mit drei Abschnitten:

    * **FORM** — genau ein Eintrag: welche Form das Resümee bekommt,
      abgeleitet aus der Überschrift der Resümee-Spalte. Ein zweiter Eintrag
      unter anderem Schlüssel wird abgelehnt; derselbe Schlüssel ersetzt.
      Die FORM steht zuerst, damit sie nachprüfbar in Laufsicht und Stand
      liegt, statt still im Modell (Maintainer, 12.09.2026).
    * **GLIEDERUNG** — die Punkte des Resümees in ihrer Reihenfolge, je mit
      den Fakt-IDs und den Bögen, die sie abdecken. Abgelehnt, solange die
      FORM fehlt: die Gliederung folgt der Form. Jeder Punkt nennt
      mindestens einen Fakt.
    * **OFFEN** — Stellen, an denen die Fakten zum Verstehen nicht reichen;
      dort schlägt Jack beim Schreiben nach.

  Wie im Gedächtnis: derselbe Schlüssel im selben Abschnitt ersetzt,
  `zeile: null` streicht, eine leere Zeile ist kein Eintrag, und ein Aufruf,
  der nichts geschrieben hat, ist `{:error, …}`. Ein ersetzter Eintrag behält
  seinen Platz; die GLIEDERUNG steht in der Reihenfolge, in der die Punkte
  angelegt wurden.

  **Nur Bekanntes:** eine Fakt-ID muss es in dieser oder einer früheren
  Sitzung geben, ein Bogen unter den Bögen dieser Sitzung oder den Strängen
  der Kampagne (`Worker.Jack.Resuemee.Stand.bogen/2`). Handlungsbögen
  erfindet Jack nicht neu. Gespeichert wird die Schreibweise des Bestands,
  nicht die des Aufrufs.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Resuemee.Stand

  @hinweis_unveraendert "So viele Einträge standen bereits genau so — sie wurden NICHT neu " <>
                          "geschrieben. Stehen deine Notizen, mach mit dem Lesen weiter."

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "notiz",
        beschreibung:
          "Deine Notizen zum Resümee. Sie überleben, was dein Kontext vergisst, und sind " <>
            "alles, was du beim Schreiben noch hast. Jeder Eintrag hat einen Abschnitt und " <>
            "einen Schlüssel; derselbe Schlüssel ERSETZT den alten Eintrag, zeile=null " <>
            "streicht ihn. Abschnitte: FORM (genau ein Eintrag: die Form, die du aus der " <>
            "Überschrift „#{s.ueberschrift}“ ableitest — sie kommt zuerst), GLIEDERUNG (die " <>
            "Punkte des Resümees in ihrer Reihenfolge, je mit den IDs der Fakten und den " <>
            "Titeln der Bögen, die sie abdecken), OFFEN (wo die Fakten zum Verstehen nicht " <>
            "reichen).",
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
                    "enum" => Stand.abschnitte(),
                    "description" => "FORM, GLIEDERUNG oder OFFEN"
                  },
                  "schluessel" => %{
                    "type" => "string",
                    "description" => "worüber der Eintrag geht: \"Form\", \"1\", \"Werkstatt\""
                  },
                  "zeile" => %{
                    "type" => ["string", "null"],
                    "description" => "der Eintrag; null streicht ihn"
                  },
                  "fakten" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die IDs der Fakten, die er abdeckt (erste Spalte von fakten())"
                  },
                  "boegen" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die Titel der Bögen, die er abdeckt (aus boegen() oder straenge())"
                  }
                }
              }
            }
          }
        },
        aendert_bestand: true,
        ausfuehren: &notiz/2
      },
      %{
        name: "notizen_lesen",
        beschreibung: lesen_beschreibung(s),
        parameter: %{"type" => "object", "properties" => %{}},
        wiederholung: :frei,
        ausfuehren: &notizen_lesen/2
      }
    ]
  end

  # Im Schreiben (B2) sind die Notizen nur noch zu lesen; „wo du stehst“ ist
  # dort der Entwurf.
  defp lesen_beschreibung(%Stand{lauf: :durchsicht}),
    do:
      "Gibt deine Notizen aus dem Überblick zurück (FORM, GLIEDERUNG, OFFEN), dazu wo die " <>
        "Durchsicht steht: Durchgang, welche Absätze offen sind, je Absatz Status und Zahl " <>
        "der Hinweise. Nutze es, wenn du nicht mehr weißt, wo du stehst."

  defp lesen_beschreibung(%Stand{lauf: :schreiben}),
    do:
      "Gibt deine Notizen aus dem Überblick zurück (FORM, GLIEDERUNG, OFFEN), dazu wo der " <>
        "Entwurf steht: Absätze, Sätze und welche Handlungsbögen noch keinen Satz haben. " <>
        "Nutze es, wenn du nicht mehr weißt, wo du stehst."

  defp lesen_beschreibung(%Stand{}),
    do:
      "Gibt deine Notizen zurück, dazu wo du stehst: wie viele Fakten du gelesen hast, " <>
        "ob die FORM steht und welche Handlungsbögen noch in keinem Gliederungspunkt " <>
        "vorkommen. Nutze es, wenn du nicht mehr weißt, wo du stehst."

  # ─── notiz ────────────────────────────────────────────────────────────

  @doc "Einträge schreiben, ersetzen oder streichen (Werkzeug `notiz`)."
  @spec notiz(Stand.t(), map()) :: ergebnis()
  def notiz(%Stand{} = s, %{"eintraege" => eintraege}) do
    z0 = %{neu: 0, ersetzt: 0, gestrichen: 0, unveraendert: 0, fehler: []}
    {s, z} = Enum.reduce(eintraege, {s, z0}, fn e, {s, z} -> eintrag(s, z, e) end)
    geaendert = z.neu + z.ersetzt + z.gestrichen > 0
    fehlt = fehlt(s)

    antwort =
      Antwort.geordnet([
        {"neu", z.neu},
        {"ersetzt", z.ersetzt},
        {"gestrichen", z.gestrichen},
        {"eintraege_gesamt", length(s.notizen)},
        {"unveraendert", if(z.unveraendert > 0, do: z.unveraendert)},
        {"hinweis_unveraendert", if(z.unveraendert > 0, do: @hinweis_unveraendert)},
        {"fehler", if(z.fehler != [], do: Enum.reverse(z.fehler))},
        {"es_fehlt", if(fehlt != [], do: fehlt)}
      ])

    {s, {if(geaendert, do: :ok, else: :error), antwort}}
  end

  defp fehlt(s) do
    wenn(Stand.form(s) == nil, "FORM") ++
      wenn(Stand.abschnitt(s, "GLIEDERUNG") == [], "GLIEDERUNG")
  end

  defp eintrag(s, z, e) do
    a = e["abschnitt"]
    k = String.trim(e["schluessel"])
    i = Enum.find_index(s.notizen, &(&1.abschnitt == a and &1.schluessel == k))

    cond do
      k == "" ->
        {s, fehler(z, "`schluessel` fehlt — ohne ihn ist der Eintrag später nicht zu finden.")}

      is_nil(e["zeile"]) ->
        streichen(s, z, i)

      true ->
        case pruefen(s, a, k, e) do
          {:ok, neu} when is_nil(i) -> anlegen(s, z, neu)
          {:ok, neu} -> aendern(s, z, i, neu)
          {:fehler, text} -> {s, fehler(z, text)}
        end
    end
  end

  defp pruefen(s, a, k, e) do
    zeile = e["zeile"]
    {fakten, fakten_weg} = aufloesen(e["fakten"], &Stand.fakt(s, &1), & &1.id)
    {boegen, boegen_weg} = aufloesen(e["boegen"], &Stand.bogen(s, &1), & &1)
    andere_form = Enum.find(s.notizen, &(&1.abschnitt == "FORM" and &1.schluessel != k))

    cond do
      String.trim(zeile) == "" ->
        {:fehler,
         "#{a}/#{k}: die Zeile ist leer. Schreib hin, was an dieser Stelle steht, oder " <>
           "lass den Eintrag weg (`zeile: null` streicht einen bestehenden)."}

      a == "FORM" and andere_form != nil ->
        {:fehler,
         "FORM hat schon einen Eintrag unter „#{andere_form.schluessel}“. Die Form ist genau " <>
           "eine: schreib unter demselben Schlüssel, um sie zu ändern."}

      a == "GLIEDERUNG" and Stand.form(s) == nil ->
        {:fehler,
         "GLIEDERUNG/#{k}: erst die FORM. Leite aus der Überschrift „#{s.ueberschrift}“ ab, " <>
           "welche Form das Resümee bekommt, und notier sie unter FORM — die Gliederung " <>
           "folgt dieser Form."}

      fakten_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Fakten gibt es nicht: #{Jason.encode!(fakten_weg)}. Die IDs stehen in " <>
           "der ersten Spalte von fakten()."}

      boegen_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Bögen gibt es nicht: #{Jason.encode!(boegen_weg)}. Nimm die Titel aus " <>
           "boegen() oder straenge(), wie sie dort stehen — die Gliederung baut auf den " <>
           "bekannten Bögen auf."}

      a == "GLIEDERUNG" and fakten == [] ->
        {:fehler,
         "GLIEDERUNG/#{k}: der Punkt nennt keinen Fakt. Ein Gliederungspunkt deckt Fakten " <>
           "ab — nenn ihre IDs in `fakten`."}

      true ->
        {:ok, %{abschnitt: a, schluessel: k, zeile: zeile, fakten: fakten, boegen: boegen}}
    end
  end

  # Löst jede Angabe über `finden` auf; gespeichert wird die Schreibweise des
  # Bestands (`form`), doppelte fallen weg. Liefert {aufgelöst, unbekannt}.
  defp aufloesen(angaben, finden, form) do
    {da, weg} =
      angaben
      |> Enum.map(&{&1, finden.(&1)})
      |> Enum.split_with(fn {_, x} -> x != nil end)

    {da |> Enum.map(fn {_, x} -> form.(x) end) |> Enum.uniq(), Enum.map(weg, &elem(&1, 0))}
  end

  defp streichen(s, z, nil), do: {s, z}

  defp streichen(s, z, i) do
    alt = Enum.at(s.notizen, i)

    s =
      %{s | notizen: List.delete_at(s.notizen, i)}
      |> Stand.journal("notizen_verlauf.txt", %{
        "art" => "-",
        "abschnitt" => alt.abschnitt,
        "schluessel" => alt.schluessel
      })

    {s, %{z | gestrichen: z.gestrichen + 1}}
  end

  defp anlegen(s, z, neu) do
    s =
      %{s | notizen: s.notizen ++ [neu]}
      |> Stand.journal("notizen_verlauf.txt", verlauf("+", neu))

    {s, %{z | neu: z.neu + 1}}
  end

  defp aendern(s, z, i, neu) do
    alt = Enum.at(s.notizen, i)
    schl = neu.abschnitt <> "/" <> neu.schluessel

    if alt == neu do
      n = Map.get(s.unveraendert, schl, 0) + 1
      s = %{s | unveraendert: Map.put(s.unveraendert, schl, n)}
      z = %{z | unveraendert: z.unveraendert + 1}

      z =
        if n >= 3,
          do:
            fehler(
              z,
              "#{schl} steht bereits genau so — das war der #{n}. gleichlautende Versuch. " <>
                "Ändere den Text, streiche den Eintrag mit zeile=null, oder lass ihn stehen " <>
                "und mach mit deiner eigentlichen Arbeit weiter."
            ),
          else: z

      {s, z}
    else
      s =
        %{
          s
          | notizen: List.replace_at(s.notizen, i, neu),
            unveraendert: Map.delete(s.unveraendert, schl)
        }
        |> Stand.journal("notizen_verlauf.txt", Map.put(verlauf("~", neu), "vorher", alt.zeile))

      {s, %{z | ersetzt: z.ersetzt + 1}}
    end
  end

  defp verlauf(art, n) do
    %{
      "art" => art,
      "abschnitt" => n.abschnitt,
      "schluessel" => n.schluessel,
      "zeile" => n.zeile,
      "fakten" => n.fakten,
      "boegen" => n.boegen
    }
  end

  defp fehler(z, text), do: %{z | fehler: [text | z.fehler]}

  defp wenn(true, text), do: [text]
  defp wenn(false, _text), do: []

  # ─── notizen_lesen ────────────────────────────────────────────────────

  @doc "Die Notizen zurückgeben, mit Schlüsseln und dem Stand der Arbeit (Werkzeug `notizen_lesen`)."
  @spec notizen_lesen(Stand.t(), map()) :: ergebnis()
  def notizen_lesen(%Stand{} = s, _args) do
    eintraege =
      Enum.map(s.notizen, fn n ->
        Antwort.geordnet([
          {"abschnitt", n.abschnitt},
          {"schluessel", n.schluessel},
          {"zeile", n.zeile},
          {"fakten", n.fakten},
          {"boegen", n.boegen}
        ])
      end)

    notizen =
      case String.trim(notizen_text(s)) do
        "" -> "(noch keine Notizen)"
        t -> t
      end

    {s,
     {:ok,
      Antwort.geordnet([{"stand", stand_text(s)}, {"eintraege", eintraege}, {"notizen", notizen}])}}
  end

  @doc """
  Wo die Arbeit steht, wie `notizen_lesen` und die Kompaktierung es zeigen;
  im Schreiben der Stand des Entwurfs (`Worker.Jack.Resuemee.Entwurf.stand_text/1`),
  in der Durchsicht der Stand der Durchsicht
  (`Worker.Jack.Resuemee.Durchsicht.stand_text/1`).
  """
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{lauf: :schreiben} = s), do: Worker.Jack.Resuemee.Entwurf.stand_text(s)

  def stand_text(%Stand{lauf: :durchsicht} = s),
    do: Worker.Jack.Resuemee.Durchsicht.stand_text(s)

  def stand_text(%Stand{} = s) do
    n = length(s.fakten)
    ungelesen = Stand.ungelesen(s)
    gliederung = Stand.abschnitt(s, "GLIEDERUNG")
    arc = Stand.arc_ohne_gliederung(s)

    [
      "Sitzung #{s.sitzung.nummer}. Die Resümee-Spalte heißt „#{s.ueberschrift}“.",
      "Fakten dieser Sitzung: #{MapSet.size(s.gelesen)} von #{n} gelesen." <>
        noch_ungelesen(ungelesen),
      case Stand.form(s) do
        nil -> "FORM: noch nicht notiert."
        f -> "FORM: " <> f.zeile
      end,
      "GLIEDERUNG: #{length(gliederung)} Punkte; sie nennen " <>
        "#{MapSet.size(Stand.abgedeckt(s))} von #{n} Fakten dieser Sitzung."
    ]
    |> Kernel.++(
      wenn(arc != [], "Handlungsbögen ohne Gliederungspunkt: " <> Enum.join(arc, ", "))
    )
    |> Enum.join("\n")
  end

  defp noch_ungelesen([]), do: ""

  defp noch_ungelesen(bereiche) do
    mehr = if length(bereiche) > 12, do: " …", else: ""
    " Noch nicht gelesen: " <> Enum.join(Enum.take(bereiche, 12), ", ") <> mehr <> "."
  end

  @doc "Die Notizen als Text, je Abschnitt `## NAME`."
  @spec notizen_text(Stand.t()) :: String.t()
  def notizen_text(%Stand{notizen: n}), do: text_aus(n)

  @doc """
  Notizen als Text — aus dem Stand (`notizen`) oder aus einer Ablage
  (`Worker.Jack.Resuemee.Stand.ablage/1`, String-Schlüssel), wie sie für
  frühere Sitzungen als „vorige Gedanken“ ankommt. `nil` ist leer. `kopf`
  steht vor jedem Abschnittsnamen (Default `"## "`; der Auftrag des
  Schreibens bettet die Notizen eine Ebene tiefer ein).
  """
  @spec text_aus(nil | map() | [map()], String.t()) :: String.t()
  def text_aus(ablage, kopf \\ "## ")
  def text_aus(nil, _kopf), do: ""
  def text_aus(%{"notizen" => n}, kopf), do: text_aus(n, kopf)
  def text_aus(%{notizen: n}, kopf), do: text_aus(n, kopf)

  def text_aus(eintraege, kopf) when is_list(eintraege) do
    Stand.abschnitte()
    |> Enum.flat_map(fn a ->
      case Enum.filter(eintraege, &(feld(&1, :abschnitt) == a)) do
        [] -> []
        rows -> [kopf <> a | Enum.map(rows, &zeile/1)] ++ [""]
      end
    end)
    |> Enum.join("\n")
  end

  def text_aus(_, _kopf), do: ""

  defp zeile(r) do
    extra =
      [
        liste("Fakten", feld(r, :fakten)),
        liste("Bögen", feld(r, :boegen))
      ]
      |> Enum.reject(&(&1 == nil))

    basis = "#{feld(r, :schluessel)} — #{feld(r, :zeile)}"
    if extra == [], do: basis, else: basis <> "  [" <> Enum.join(extra, " · ") <> "]"
  end

  defp liste(_titel, l) when l in [nil, []], do: nil
  defp liste(titel, l) when is_list(l), do: titel <> ": " <> Enum.join(l, ", ")
  defp liste(_titel, _l), do: nil

  defp feld(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
  defp feld(_m, _k), do: nil
end
