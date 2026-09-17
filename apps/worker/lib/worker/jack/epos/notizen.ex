defmodule Worker.Jack.Epos.Notizen do
  @moduledoc """
  `notiz` und `notizen_lesen` des Epos-Jack im Überblick (E1, #1210) — mit
  der Mechanik der Resümee-Notizen (`Worker.Jack.Resuemee.Notizen.eintragen/3`:
  derselbe Schlüssel im selben Abschnitt ersetzt, `zeile: null` streicht, eine
  leere Zeile ist kein Eintrag, ein Aufruf ohne Wirkung ist ein Fehler, der
  dritte gleichlautende Versuch eine Warnung), aber mit eigenen Abschnitten
  (`Worker.Jack.Resuemee.Stand.abschnitte(:epos)`):

    * **FORM** — genau ein Eintrag: die Form des Kapitels aus der Überschrift
      der Epos-Spalte **und** die Erzählhaltung, die Stimme, aus dem
      Epos-Ton. Ein zweiter Eintrag unter anderem Schlüssel wird abgelehnt.
    * **SZENEN** — erst nach der FORM. Die Szenen des Kapitels in
      Erzählreihenfolge (der Reihenfolge, in der Jack sie anlegt), je mit Ort
      und Moment in der Zeile, den Fakten, die sie erzählt — mindestens einer
      **dieser** Sitzung —, und ihren Bögen. **Keine Obergrenze**
      (Maintainer, 13.09.2026): so viele, wie die Sitzung braucht.
    * **ABWEICHUNG** — Schlüssel ist der Schlüssel einer Station aus dem Weg
      des Resümees (`Worker.Jack.Epos.Weg`; Schreibweise egal, gespeichert
      wird die der Station), die Zeile der Grund, warum das Kapitel sie
      anders erzählt oder weglässt. Ein unbekannter Stationsschlüssel wird
      abgelehnt; ohne Weg gibt es keine Abweichung.
    * **OFFEN** — frei: was die Fakten zum Verstehen nicht hergeben, wo das
      Schreiben anknüpft.

  **Nur Bekanntes:** eine Fakt-ID muss es in dieser oder einer früheren
  Sitzung geben, ein Bogen unter den Bögen dieser Sitzung (`boegen()`), der
  Kampagne bis hierher (`boegen_kampagne()`) oder den Strängen
  (`straenge()`); gespeichert wird die Schreibweise des Bestands.

  Dazu das Abbild für Beobachter (`abbild/1`, mit `"jack" => "epos"`).
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Epos.{Durchsicht, Entwurf, Weg}
  alias Worker.Jack.Resuemee.{Bisher, Stand}
  alias Worker.Jack.Resuemee.Notizen, as: Mechanik

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Die Werkzeuge dieses Moduls für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "notiz",
        beschreibung:
          "Deine Notizen zum Epos-Kapitel. Sie überleben, was dein Kontext vergisst, und sind " <>
            "alles, was du beim Schreiben noch hast. Jeder Eintrag hat einen Abschnitt und " <>
            "einen Schlüssel; derselbe Schlüssel ERSETZT den alten Eintrag, zeile=null " <>
            "streicht ihn. Abschnitte: FORM (genau ein Eintrag: die Form, die du aus der " <>
            "Überschrift „#{s.ueberschrift}“ ableitest, und die Erzählhaltung aus dem " <>
            "Epos-Ton — sie kommt zuerst), SZENEN (die Szenen des Kapitels in der Reihenfolge, " <>
            "in der es erzählt, so viele, wie die Sitzung braucht; jede mit Ort und Moment in " <>
            "der Zeile, den IDs ihrer Fakten dieser Sitzung und den Titeln ihrer Bögen), " <>
            "ABWEICHUNG (Schlüssel = Schlüssel einer Station aus resuemee(); die Zeile sagt, " <>
            "warum das Kapitel sie anders erzählt oder weglässt), OFFEN (was die Fakten zum " <>
            "Verstehen nicht hergeben, wo du beim Schreiben anknüpfst).",
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
                    "enum" => Stand.abschnitte(:epos),
                    "description" => "FORM, SZENEN, ABWEICHUNG oder OFFEN"
                  },
                  "schluessel" => %{
                    "type" => "string",
                    "description" =>
                      "worüber der Eintrag geht: \"Form\", \"Regen am Hafen\"; bei ABWEICHUNG " <>
                        "der Schlüssel der Station"
                  },
                  "zeile" => %{
                    "type" => ["string", "null"],
                    "description" => "der Eintrag; null streicht ihn"
                  },
                  "fakten" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die IDs der Fakten, die er erzählt (erste Spalte von fakten())"
                  },
                  "boegen" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" =>
                      "die Titel der Bögen, zu denen er gehört (aus boegen(), " <>
                        "boegen_kampagne() oder straenge())"
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

  # Im Schreiben (E2) und in der Durchsicht (E3) sind die Notizen nur noch zu
  # lesen; „wo du stehst“ ist dort das Kapitel bzw. die Durchsicht.
  defp lesen_beschreibung(%Stand{lauf: :durchsicht}),
    do:
      "Gibt deine Notizen aus dem Überblick zurück (FORM, SZENEN, ABWEICHUNG, OFFEN), dazu wo " <>
        "die Durchsicht steht: den Durchgang, je Absatz, ob er offen, bestätigt oder ersetzt " <>
        "ist, und wie viele Hinweise er hat. Nutze es, wenn du nicht mehr weißt, wo du stehst."

  defp lesen_beschreibung(%Stand{lauf: :schreiben}),
    do:
      "Gibt deine Notizen aus dem Überblick zurück (FORM, SZENEN, ABWEICHUNG, OFFEN), dazu wo " <>
        "das Kapitel steht: Absätze, Wörter, Wörter je Absatz und — als Hinweis — die Szenen, " <>
        "denen noch kein Absatz zugeordnet ist. Nutze es, wenn du nicht mehr weißt, wo du stehst."

  defp lesen_beschreibung(%Stand{}),
    do:
      "Gibt deine Notizen zurück, dazu wo du stehst: wie viele Fakten du gelesen hast, ob " <>
        "die FORM steht, wie viele Szenen du hast, welche Stationen aus dem Weg des " <>
        "Resümees noch weder in einer Szene noch unter ABWEICHUNG stehen und von welchem " <>
        "bis zu welchem Block die Fakten deiner Szenen reichen. Nutze es, wenn du nicht " <>
        "mehr weißt, wo du stehst."

  # ─── notiz ────────────────────────────────────────────────────────────

  @doc "Einträge schreiben, ersetzen oder streichen (Werkzeug `notiz`)."
  @spec notiz(Stand.t(), map()) :: ergebnis()
  def notiz(%Stand{} = s, %{"eintraege" => eintraege}) do
    Mechanik.eintragen(s, Enum.map(eintraege, &kanonisch(s, &1)), %{
      pruefen: &pruefen/4,
      fehlt: &fehlt/1,
      weg: &hinweis/1
    })
  end

  # Der Schlüssel einer ABWEICHUNG in der Schreibweise der Station — damit
  # „station 1“ und „Station 1“ denselben Eintrag ersetzen oder streichen.
  defp kanonisch(s, %{"abschnitt" => "ABWEICHUNG", "schluessel" => k} = e) when is_binary(k) do
    case Weg.station(s, k) do
      nil -> e
      st -> Map.put(e, "schluessel", st.schluessel)
    end
  end

  defp kanonisch(_s, e), do: e

  defp fehlt(s) do
    wenn(Stand.form(s) == nil, "FORM") ++ wenn(Stand.abschnitt(s, "SZENEN") == [], "SZENEN")
  end

  defp pruefen(s, a, k, e) do
    zeile = e["zeile"]
    {fakten, fakten_weg} = Mechanik.aufloesen(e["fakten"], &Stand.fakt(s, &1), & &1.id)
    {boegen, boegen_weg} = Mechanik.aufloesen(e["boegen"], &bogen(s, &1), & &1)
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

      a == "SZENEN" and Stand.form(s) == nil ->
        {:fehler,
         "SZENEN/#{k}: erst die FORM. Leite aus der Überschrift „#{s.ueberschrift}“ die Form " <>
           "des Kapitels und aus dem Epos-Ton seine Erzählhaltung ab und notier beides unter " <>
           "FORM — die Szenen folgen dieser Form."}

      a == "ABWEICHUNG" and Weg.stationen(s) == [] ->
        {:fehler,
         "ABWEICHUNG/#{k}: aus dem Resümee liegt kein Weg vor, von dem das Kapitel abweichen " <>
           "könnte. Deine SZENEN sind der Weg der Gruppe."}

      a == "ABWEICHUNG" and Weg.station(s, k) == nil ->
        {:fehler,
         "ABWEICHUNG/#{k}: eine Station „#{k}“ gibt es im Weg aus dem Resümee nicht. Der " <>
           "Schlüssel einer Abweichung ist der Schlüssel einer Station, wie resuemee() ihn " <>
           "zeigt: " <> Enum.map_join(Weg.stationen(s), ", ", &"„#{&1.schluessel}“") <> "."}

      fakten_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Fakten gibt es nicht: #{Jason.encode!(fakten_weg)}. Die IDs stehen in " <>
           "der ersten Spalte von fakten()."}

      boegen_weg != [] ->
        {:fehler,
         "#{a}/#{k}: Bögen gibt es nicht: #{Jason.encode!(boegen_weg)}. Nimm die Titel aus " <>
           "boegen(), boegen_kampagne() oder straenge(), wie sie dort stehen."}

      a == "SZENEN" and fakten == [] ->
        {:fehler,
         "SZENEN/#{k}: die Szene nennt keinen Fakt. Eine Szene erzählt Fakten — nenn ihre " <>
           "IDs in `fakten`."}

      a == "SZENEN" and not Enum.any?(fakten, &eigener?(s, &1)) ->
        {:fehler,
         "SZENEN/#{k}: die Szene nennt keinen Fakt dieser Sitzung. Das Kapitel erzählt " <>
           "Sitzung #{s.sitzung.nummer} — jede Szene nennt die Fakten dieser Sitzung, die sie " <>
           "erzählt; frühere Fakten dürfen dazukommen."}

      true ->
        {:ok, %{abschnitt: a, schluessel: k, zeile: zeile, fakten: fakten, boegen: boegen}}
    end
  end

  defp eigener?(s, id), do: Enum.any?(s.fakten, &(&1.id == id))

  @doc """
  Der Titel eines bekannten Bogens, wie er geschrieben steht: unter den Bögen
  dieser Sitzung, den Bögen der Kampagne bis hierher
  (`Worker.Jack.Resuemee.Bisher.alle_boegen/1`) oder den Strängen — sonst
  `nil`. Handlungsbögen erfindet Jack nicht neu.
  """
  @spec bogen(Stand.t(), String.t()) :: String.t() | nil
  def bogen(%Stand{} = s, titel) when is_binary(titel) do
    k = Worker.ThreadOverride.normalize(titel)

    (Enum.map(s.boegen, & &1.titel) ++
       Enum.map(Bisher.alle_boegen(s), & &1.titel) ++ s.mitschnitt.straenge)
    |> Enum.find(&(Worker.ThreadOverride.normalize(&1) == k))
  end

  def bogen(_s, _titel), do: nil

  @doc """
  Der Hinweis nach einer Änderung (Antwort von `notiz`, unter `weg`): die
  Spanne der Szenen und der Stand des Wegs aus dem Resümee.
  """
  @spec hinweis(Stand.t()) :: String.t() | nil
  def hinweis(%Stand{} = s) do
    case Enum.reject([Weg.hinweis(s), Weg.stand_zeile(s)], &is_nil/1) do
      [] -> nil
      teile -> Enum.join(teile, " ")
    end
  end

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
  im Schreiben der Stand des Kapitels (`Worker.Jack.Epos.Entwurf.stand_text/1`).
  """
  @spec stand_text(Stand.t()) :: String.t()
  def stand_text(%Stand{lauf: :schreiben} = s), do: Entwurf.stand_text(s)
  def stand_text(%Stand{lauf: :durchsicht} = s), do: Durchsicht.stand_text(s)

  def stand_text(%Stand{} = s) do
    n = length(s.fakten)
    szenen = Stand.abschnitt(s, "SZENEN")

    Enum.join(
      Enum.reject(
        [
          "Sitzung #{s.sitzung.nummer}. Die Epos-Spalte heißt „#{s.ueberschrift}“.",
          "Fakten dieser Sitzung: #{MapSet.size(s.gelesen)} von #{n} gelesen." <>
            noch_ungelesen(Stand.ungelesen(s)),
          case Stand.form(s) do
            nil -> "FORM: noch nicht notiert."
            f -> "FORM: " <> f.zeile
          end,
          "SZENEN: #{length(szenen)}; sie nennen #{length(abgedeckt(s))} von #{n} Fakten " <>
            "dieser Sitzung.",
          Weg.stand_zeile(s),
          Weg.hinweis(s)
        ],
        &is_nil/1
      ),
      "\n"
    )
  end

  # Die IDs der Fakten dieser Sitzung, die eine Szene nennt.
  defp abgedeckt(s) do
    for szene <- Stand.abschnitt(s, "SZENEN"),
        id <- szene.fakten,
        f = Stand.fakt(s, id),
        f != nil,
        Stand.diese_sitzung?(s, f),
        uniq: true,
        do: f.id
  end

  defp noch_ungelesen([]), do: ""

  defp noch_ungelesen(bereiche) do
    mehr = if length(bereiche) > 12, do: " …", else: ""
    " Noch nicht gelesen: " <> Enum.join(Enum.take(bereiche, 12), ", ") <> mehr <> "."
  end

  @doc "Die Notizen als Text, je Abschnitt `kopf` + Name (Default `## `), FORM zuerst."
  @spec notizen_text(Stand.t(), String.t()) :: String.t()
  def notizen_text(%Stand{notizen: n}, kopf \\ "## "),
    do: Mechanik.text_aus(n, kopf, Stand.abschnitte(:epos))

  # ─── Abbild ───────────────────────────────────────────────────────────

  @doc """
  Der Stand als JSON-fähige Map für einen Beobachter (über den Halter,
  Option `:abbild`): `"jack" => "epos"`, Lauf, Sitzung, Überschrift,
  Lesestand, FORM, Zahl der Szenen und Abweichungen, die Pflicht-Stationen des
  Wegs und die noch offenen (je `%{"schluessel", "zeile"}`), die Notizen und
  das Journal (je Datei gezählt). Im Schreiben dazu das Kapitel
  (`Worker.Jack.Epos.Entwurf.abbild/1`: Zahlen, Wortstand, Markdown, Szenen
  ohne Absatz); in der Durchsicht dasselbe und `durchsicht`
  (`Worker.Jack.Epos.Durchsicht.abbild/1`: Durchgang, offene Absätze, Status
  je Absatz, Zähler, Hinweise — die Form, aus der der Melder zählt).
  """
  @spec abbild(Stand.t()) :: map()
  def abbild(%Stand{lauf: :schreiben} = s), do: Map.merge(abbild_basis(s), Entwurf.abbild(s))

  def abbild(%Stand{lauf: :durchsicht} = s) do
    abbild_basis(s)
    |> Map.merge(Entwurf.abbild(s))
    |> Map.put("durchsicht", Durchsicht.abbild(s))
  end

  def abbild(%Stand{} = s), do: abbild_basis(s)

  defp abbild_basis(s) do
    %{
      "jack" => "epos",
      "lauf" => to_string(s.lauf),
      "sitzung" => s.sitzung.nummer,
      "ueberschrift" => s.ueberschrift,
      "fakten" => length(s.fakten),
      "gelesen" => MapSet.size(s.gelesen),
      "ungelesen" => Stand.ungelesen(s),
      "form" => with(%{zeile: z} <- Stand.form(s), do: z),
      "szenen" => length(Stand.abschnitt(s, "SZENEN")),
      "abweichungen" => length(Stand.abschnitt(s, "ABWEICHUNG")),
      "stationen" => length(Weg.pflicht(s)),
      "stationen_offen" => Worker.Jack.Resuemee.Weg.abbild(Weg.offen(s)),
      "notizen" => Stand.ablage(s)["notizen"],
      "journal" => s |> Stand.journal_liste() |> Enum.frequencies_by(&elem(&1, 0))
    }
  end
end
