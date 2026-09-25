defmodule Worker.Jack.Zeit.Vorbehalte do
  @moduledoc """
  #1247: die drei Werkzeuge, mit denen der Zeit-Jack **nichts datiert** —
  `melde_konflikt`, `kettenplatz_unklar`, `zweifel`.

  ## Warum sie zusammengehören

  Alles andere in `Worker.Jack.Zeit.Anker` legt eine Zeit fest. Diese drei
  halten fest, dass **keine** festgelegt wird, und sagen warum:

    * **Konflikt** — eine abgesegnete Stelle stimmt nach Jacks Fund nicht.
      Ein Mensch entscheidet; bis dahin bleibt sie, wie sie ist.
    * **Unklarer Platz** — Jack kann sich nicht entscheiden. Die Zeile bleibt
      auf der Linie, aber es wird keine Zeit aus ihr abgeleitet.
    * **Zweifel** — ein Vermerk an einer Stelle, ohne sie aus der Rechnung zu
      nehmen.

  Sie schreiben in dieselben Speicher wie die Anker (derselbe Fold, dieselbe
  Adressierung) und sind deshalb keine eigene Schicht, sondern eine eigene
  **Absicht**.

  ## Der Schnitt ist am Merge-Tor entstanden, und das ist benannt

  `anker.ex` riss mit `nimm_anker_zurueck` die 600-Code-Zeilen-Grenze (648).
  CLAUDE.md sagt zu genau dieser Lage: Ein Schnitt, der entsteht, weil Credo
  rot ist, ist kein Verfahren — die letzten beiden im Repo fielen nur
  zufällig kohäsiv aus (#1097).

  Deshalb ist hier **nicht** nach Zeilen geschnitten (Definitionen gegen
  Ausführung wäre der billige Schnitt gewesen und hätte zwei Hälften
  derselben Sache getrennt), sondern nach der Frage, die ein Leser stellt:
  *setzt dieses Werkzeug eine Zeit, oder hält es fest, dass keine gesetzt
  wird?* Dass die drei zusammen knapp reichen, war Glück; dass sie
  zusammengehören, ist es nicht.
  """

  alias Worker.Jack.Zeit.{Kettenwerkzeuge, Mitschnitt, Setzen, Stand}
  alias Worker.Timeline.Kette

  @doc """
  Die drei Werkzeug-Definitionen. `Anker.werkzeuge/0` hängt sie an seine Liste
  an — die Reihenfolge dort ist die, in der die Arbeit gedacht ist (erst
  einreihen, dann datieren, dann vermerken).
  """
  @spec werkzeuge() :: [map()]
  def werkzeuge do
    [
      %{
        name: "melde_konflikt",
        beschreibung:
          "Trägt einen Widerspruch zu einer abgesegneten Stelle ein. Eine " <>
            "Festlegung, die ein Mensch getroffen hat, überschreibt niemand — auch " <>
            "du nicht. Wenn du triftige Gründe hast, dass sie nicht stimmt, schreib " <>
            "sie hier auf: Ein Mensch sieht sich das an. Nenne, WAS du gefunden " <>
            "hast und WORAUS — ohne das kann niemand entscheiden, ohne deine Arbeit " <>
            "zu wiederholen. **Auch für Fehler in einer ANDEREN Sitzung:** Findest " <>
            "du dort einen falschen Anker, den du nicht selbst beheben kannst " <>
            "(ankern geht nur in deiner Sitzung), meld ihn hier mit der " <>
            "Glied-Nummer aus lies_kette(). Das ist der Weg — nicht schweigen, " <>
            "weil dir die Werkzeuge fehlen.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" =>
                "Die Zeilen DEINER Sitzung, um die es geht. Für eine Stelle in einer anderen Sitzung nimm stattdessen glied."
            },
            "glied" => %{
              "type" => "integer",
              "description" =>
                "Die Nummer eines Kettengliedes aus lies_kette() — auch eines aus einer ANDEREN Sitzung. Nimm das, wenn du dort einen Fehler findest, den du selbst nicht beheben kannst."
            },
            "befund" => %{
              "type" => "string",
              "description" =>
                "WAS du gefunden hast: der Widerspruch in einem Satz, so dass ein Mensch entscheiden kann, ohne deine Arbeit zu wiederholen."
            },
            "beleg" => %{
              "type" => "string",
              "description" => "WORAUS: das wörtliche Zitat, auf das sich dein Befund stützt."
            }
          },
          "required" => ~w(befund beleg)
        },
        optional: ~w(zeilen glied),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_konflikt/2
      },
      %{
        name: "kettenplatz_unklar",
        beschreibung:
          "Hält fest, dass du dich an einer Stelle NICHT entscheiden kannst — und " <>
            "setzt nichts. **Das ist zugleich die Einordnung „unklar“**: Die Zeile " <>
            "bleibt auf der Linie, ist aber vermerkt, und ich leite keine Zeit " <>
            "aus ihr ab. Beide Unklarheiten gehören hierher: „Welt oder Tisch?“ " <>
            "und „gespielt schon, aber die Zeitangabe verstehe ich nicht“. " <>
            "Zweifeln soll so billig sein wie Setzen: Lieber keine " <>
            "Angabe als eine geratene. Der häufigste Fall ist die Welt-Frage: Aus " <>
            "„drei viertel elf“ allein geht nicht hervor, ob die Uhr am Tisch oder " <>
            "in der Welt gemeint ist. Lies dann zuerst die Zeilen davor — die Frage " <>
            "steht oft drei Zeilen früher, mit fremden Einwürfen dazwischen.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" =>
                "Einzelne Zeilennummern. Für zusammenhängende Abschnitte lieber von/bis."
            },
            "von" => %{
              "type" => "integer",
              "description" => "Erste Zeile des Abschnitts (mit bis)."
            },
            "bis" => %{
              "type" => "integer",
              "description" => "Letzte Zeile des Abschnitts (mit von)."
            },
            "text" => %{
              "type" => "string",
              "description" =>
                "Was du nicht entscheiden kannst — beides gehört hierher: „Welt oder Tisch?“ und „ingame, aber die Zeit ist unklar“."
            }
          },
          "required" => ["text"]
        },
        optional: ~w(zeilen von bis),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_zweifel/2
      }
    ]
  end

  # ─── Ausführung ─────────────────────────────────────────────────────

  # **Ein Fehler in einer fremden Sitzung braucht einen Weg** (#1247,
  # 25.09.2026). Jack fand im Prüf-Lauf einen falschen Anker in S1 — „um 10"
  # als Uhrzeit gelesen, gemeint war das Jahr 2010 — und schrieb:
  #
  #     „Both point to the same S1/85 anchor being wrong (it's the year 2010,
  #      not a time). But I can't anchor in S1. So what can I do?"
  #
  # Nichts, bis hierher: `nimm_anker_zurueck` und `melde_konflikt` verlangten
  # Zeilen der eigenen Sitzung, `anker_ersetzen` eine Rückfrage-Kennung. Er sah
  # einen Fehler in fremden Daten und hatte keinen Kanal dafür.
  #
  # Die Begründung für die Sperre bleibt richtig („deren Zeilen hat der Lauf
  # jener Sitzung entschieden") — aber ein falscher Anker ist kein Entscheid,
  # sondern ein Fehler, und er verbiegt die Linie kampagnenweit. Melden darf er
  # ihn also; ändern nicht. Adresse ist die Glied-Nummer aus `lies_kette()`,
  # dieselbe wie bei den Ketten-Werkzeugen.
  defp w_konflikt(s, %{"glied" => nr} = f) when is_integer(nr) do
    case Kettenwerkzeuge.glied_nach_nummer(s, nr) do
      {:ok, glied} ->
        eintrag = %{
          utterance_ids: Worker.Timeline.Kette.alle_utts(glied),
          glied_id: glied.id,
          befund: to_string(f["befund"]),
          beleg: to_string(f["beleg"])
        }

        {Stand.konflikt(s, eintrag),
         {:ok,
          "Konflikt an Glied #{nr} („#{glied.grund || "ohne Titel"}“) eingetragen. " <>
            "Ein Mensch sieht sich das an; an der Stelle selbst ändert sich nichts — " <>
            "auch dann nicht, wenn sie aus einer anderen Sitzung stammt."}}

      {:fehler, text} ->
        {s, {:error, text}}
    end
  end

  defp w_konflikt(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f["zeilen"]) do
      eintrag = %{
        utterance_ids: ids,
        befund: to_string(f["befund"]),
        beleg: to_string(f["beleg"])
      }

      {Stand.gelesen(s, zeilen) |> Stand.konflikt(eintrag),
       {:ok,
        "Konflikt eingetragen. Ein Mensch sieht sich das an; die abgesegnete Stelle " <>
          "bleibt bis dahin, wie sie ist."}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  defp w_zweifel(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f) do
      anker =
        Setzen.bauen(%{
          utterance_ids: ids,
          art: :zweifel,
          wert: "",
          welt: "",
          beleg: "",
          zweifel: to_string(f["text"])
        })

      # **Unklar heisst: in der Kette, aber vermerkt** (#1247, 20.09.2026).
      # Der Zweifel setzte bis dahin nur einen Anker und liess die Zeilen
      # unentschieden — sie blieben offen, und `fertig()` fragte weiter nach
      # ihnen. Für eine Stelle, an der Jack sich NICHT entscheiden kann, ist
      # das ein Widerspruch: Er hat entschieden, dass er es nicht
      # entscheiden kann. Die Zeilen gehören also in die Kette, an ihrer
      # Stelle, mit dem Zweifel daran.
      s = Stand.gelesen(s, zeilen)

      s =
        case Stand.kette(s, &Kette.anhaengen(&1, Kette.offene(s.kette, ids))) do
          {:ok, s, _} -> s
          {:fehler, _} -> s
        end

      s = s |> Stand.einordnen(zeilen, :unklar) |> Stand.setzen(anker)

      {s,
       {:ok,
        "Zweifel festgehalten — keine Zeit gesetzt, #{length(ids)} Zeile(n) in der " <>
          "Kette und als unklar vermerkt. " <> Kettenwerkzeuge.kettenstand(s)}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end
end
