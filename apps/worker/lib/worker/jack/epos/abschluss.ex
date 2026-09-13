defmodule Worker.Jack.Epos.Abschluss do
  @moduledoc """
  `fertig` des Epos-Jack, je Lauf (#1210) — die Mechanik ist die des
  Resümee-Jack (`Worker.Jack.Resuemee.Abschluss.mit_regeln/3`: Ablehnung mit
  den offenen Punkten, Zahlenabgleich, der dritte Versuch mit falschen Zahlen
  geht durch, die Abweichung steht dann im Journal), die Regeln sind eigen.

  **Offen ist der Überblick** (E1), solange

    * ein Fakt dieser Sitzung ungelesen ist (die Szenen dürfen nur über
      Fakten reden, die Jack vor sich hatte),
    * die FORM fehlt,
    * die SZENEN leer sind, oder
    * eine Station aus dem Weg des Resümees, die einen Fakt dieser Sitzung
      nennt, **weder** von einer Szene getragen wird (eine Szene nennt einen
      ihrer Fakten) **noch** unter ABWEICHUNG steht (`Worker.Jack.Epos.Weg.offen/1`).

  Keine Obergrenze für die Zahl der Szenen. Zahlen: `fakten` (gelesene Fakten
  dieser Sitzung) und `szenen` (Einträge unter SZENEN), dazu
  `offen_geblieben` in Worten. Ablehnung und Abschluss nennen unter `weg` die
  Spanne der Szenen in Blocknummern — ein Hinweis, kein Hindernis.

  **Offen ist das Schreiben** (E2) nur, solange das Kapitel keinen Absatz
  hat. Maintainer, 13.09.2026: der Epos-Jack schreibt frei — keine Länge,
  keine Prüfung je Satz, keine Pflicht, jede Szene zu erzählen. Deshalb gibt
  es hier, anders als beim Resümee-Jack, weder `ausgelassen` noch
  `laenge_begruendung`: die Auswahl trifft der Überblick (SZENEN, begründete
  ABWEICHUNG), und eine Länge, die zu begründen wäre, gibt es nicht. Zahl:
  `absaetze`, dazu `offen_geblieben` in Worten. Der Abschluss hält im Journal
  die Wörter, die Absätze mit Szene und die Szenen ohne Absatz fest.
  """

  alias Worker.Jack.Epos.{Entwurf, Weg}
  alias Worker.Jack.Resuemee.Abschluss, as: Mechanik
  alias Worker.Jack.Resuemee.Stand

  @zahlen ~w(fakten szenen)
  @zahlen_schreiben ~w(absaetze)

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{lauf: :schreiben}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet das Epos-Kapitel als geschrieben — der EINZIGE gültige Abschluss. Ein Satz " <>
            "in der letzten Nachricht zählt nicht. Das Werkzeug LEHNT AB, solange das Kapitel " <>
            "keinen Absatz hat. Erwartete Zahl: absaetze (Absätze im Kapitel). Deine Zahl und " <>
            "die Buchhaltung werden verglichen.",
        parameter: schema_schreiben(),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  def werkzeuge(%Stand{}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet den Überblick zum Epos-Kapitel als abgeschlossen — der EINZIGE gültige " <>
            "Abschluss. Ein Satz in der letzten Nachricht zählt nicht. Das Werkzeug rechnet " <>
            "nach und LEHNT AB, solange Arbeit offen ist — solange ein Fakt dieser Sitzung " <>
            "ungelesen ist, die FORM oder die SZENEN fehlen oder eine Station aus dem Weg des " <>
            "Resümees weder in einer Szene noch unter ABWEICHUNG steht; in der Ablehnung " <>
            "steht, was genau fehlt. Erwartete Zahlen: fakten (wie viele Fakten dieser " <>
            "Sitzung du gelesen hast) und szenen (Zahl der Einträge unter SZENEN). Deine " <>
            "Zahlen und die Buchhaltung werden verglichen.",
        parameter: schema(),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  @doc "Die Parameter von `fertig` im Überblick."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "fakten" => %{"type" => "integer", "minimum" => 0},
        "szenen" => %{"type" => "integer", "minimum" => 0},
        "offen_geblieben" => offen_geblieben()
      }
    }
  end

  @doc "Die Parameter von `fertig` im Schreiben."
  @spec schema_schreiben() :: map()
  def schema_schreiben do
    %{
      "type" => "object",
      "properties" => %{
        "absaetze" => %{"type" => "integer", "minimum" => 0},
        "offen_geblieben" => offen_geblieben()
      }
    }
  end

  defp offen_geblieben,
    do: %{
      "type" => "string",
      "minLength" => 0,
      "description" => "was die Fakten zum Verstehen nicht hergeben — in Worten, nicht als Zahl"
    }

  @doc "Den Lauf abschließen (Werkzeug `fertig`)."
  @spec fertig(Stand.t(), map()) :: ergebnis()
  def fertig(%Stand{lauf: :schreiben} = s, p) do
    Mechanik.mit_regeln(s, p, %{
      hindernisse: hindernisse(s),
      zahlen: @zahlen_schreiben,
      ist: ist_zahlen(s),
      weg: fn _s -> nil end,
      abschluss: fn s, eintrag ->
        {s,
         Map.merge(eintrag, %{
           "jack" => "epos",
           "woerter" => Entwurf.woerter(s),
           "absaetze_mit_szene" => Enum.count(s.entwurf, &(&1.szene != nil)),
           "szenen_ohne_absatz" => Enum.map(Entwurf.ohne_absatz(s), & &1.schluessel)
         })}
      end
    })
  end

  def fertig(%Stand{} = s, p) do
    Mechanik.mit_regeln(s, p, %{
      hindernisse: hindernisse(s),
      zahlen: @zahlen,
      ist: ist_zahlen(s),
      weg: &Weg.hinweis/1,
      abschluss: fn s, eintrag ->
        {s,
         Map.merge(eintrag, %{
           "jack" => "epos",
           "weg" => Weg.hinweis(s),
           "stationen" => length(Weg.pflicht(s)),
           "abweichungen" => length(Stand.abschnitt(s, "ABWEICHUNG"))
         })}
      end
    })
  end

  @doc "Die Zahlen, wie die Buchhaltung sie kennt."
  @spec ist_zahlen(Stand.t()) :: %{String.t() => non_neg_integer()}
  def ist_zahlen(%Stand{lauf: :schreiben} = s), do: %{"absaetze" => length(s.entwurf)}

  def ist_zahlen(%Stand{} = s) do
    %{
      "fakten" => MapSet.size(s.gelesen),
      "szenen" => length(Stand.abschnitt(s, "SZENEN"))
    }
  end

  @doc "Was den Abschluss verhindert. Leer heißt: fertig."
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{lauf: :schreiben, entwurf: []}),
    do: [
      "Das Kapitel hat noch keinen Absatz. Erzähl es Szene für Szene mit absatz(), im Stil und " <>
        "in der FORM deiner Notizen."
    ]

  def hindernisse(%Stand{lauf: :schreiben}), do: []

  def hindernisse(%Stand{} = s) do
    ungelesen = Stand.ungelesen(s)
    mehr = if length(ungelesen) > 12, do: " …", else: ""
    offen = Weg.offen(s)

    wenn(
      ungelesen != [],
      "Diese Fakten dieser Sitzung hast du noch nicht gelesen: " <>
        "#{ungelesen |> Enum.take(12) |> Enum.join(", ")}#{mehr}. Hol sie mit " <>
        "fakten(von, bis) — die Szenen sprechen nur über Fakten, die du vor dir hattest."
    ) ++
      wenn(
        Stand.form(s) == nil,
        "Die FORM fehlt. Leite aus der Überschrift „#{s.ueberschrift}“ die Form des Kapitels " <>
          "und aus dem Epos-Ton seine Erzählhaltung ab und notier beides unter FORM."
      ) ++
      wenn(
        Stand.abschnitt(s, "SZENEN") == [],
        "Die SZENEN fehlen. Stell die Szenen des Kapitels auf — so viele, wie die Sitzung " <>
          "braucht, in der Reihenfolge, in der das Kapitel erzählt —, jede mit den Fakten " <>
          "dieser Sitzung, die sie erzählt."
      ) ++
      wenn(
        offen != [],
        "Diese Stationen aus dem Weg des Resümees stehen weder in einer Szene noch unter " <>
          "ABWEICHUNG: #{Weg.text(offen)}. Nimm jede in eine Szene auf — eine Szene, die " <>
          "einen ihrer Fakten nennt — oder notier sie unter ABWEICHUNG: Schlüssel ist der " <>
          "Schlüssel der Station, die Zeile sagt, warum das Kapitel sie anders erzählt oder " <>
          "weglässt."
      )
  end

  defp wenn(true, text), do: [text]
  defp wenn(false, _text), do: []
end
