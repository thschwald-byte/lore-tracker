defmodule Worker.Jack.Zeit.Anker do
  @moduledoc """
  #1247 (Z2): die **setzenden** Werkzeuge des Zeit-Jack — Definitionen und
  Ausführung in einem Modul, wie `Worker.Jack.Zeit.Lesen` für die lesenden
  und `Worker.Jack.Zeit.Notizen` für die notierenden.

  Herausgeschnitten aus `Worker.Jack.Zeit.Werkzeuge`, als dort mit den
  Feldbeschreibungen die God-Module-Grenze fiel. Der Schnitt folgt der
  Gruppierung, die das Modul ohnehin trug (`@lesend` / `@notierend` /
  `@setzend`): Im Dispatch-Modul bleiben die Laufarten, der Abschluss und
  `fertig()` — hier liegt alles, was einen Anker entstehen lässt.

  **Die Regeln stehen in den Beschreibungen, die Felderklärungen an den
  Feldern** (#1075-Lehre, nachgezogen 19.09.2026): Ein Auftrag wird einmal
  gelesen und ist nach einer Kompaktierung weg; eine Werkzeugbeschreibung
  steht bei jedem Aufruf da, und ein Feld, das nichts über sich sagt, wird
  geraten.
  """

  alias Worker.Jack.Zeit.{Kettenwerkzeuge, Mitschnitt, Setzen, Stand}
  alias Worker.Timeline.Kette
  alias Worker.Timeline.Ausdruck

  @doc "Die setzenden Werkzeuge — Definitionen für `Worker.Jack.Zeit.Werkzeuge`."
  def werkzeuge do
    [
      %{
        name: "setz_zeitpunkt",
        beschreibung:
          "Hängt einen ZEITPUNKT an eine oder mehrere Zeilen: etwas, das im Spiel " <>
            "als Zeit GESAGT wurde — „drei viertel elf“, „am 15. November“, „kurz " <>
            "nach zwölf“. Nicht ableiten, nicht rechnen: nur was dasteht, und in " <>
            "wert genau so, wie es gesagt wurde. Wortformen sind ausdrücklich " <>
            "erwünscht: Ich lese „halb elf“, „viertel vor zwölf“, „kurz nach " <>
            "zwei“ — schreib sie nicht in Ziffern um. " <>
            "ZUERST die Welt-Frage, bei JEDEM Anker: welt ist „spielwelt“, wenn " <>
            "die Zeit in der erzählten Welt gilt, und „tisch“, wenn sie den Abend " <>
            "meint (Restzeit, Pause, wann wir aufhören, wann jemand aufstehen " <>
            "muss). Das ist fast ein Münzwurf, keine Ausnahmebehandlung: Über " <>
            "vier von Hand bewertete Sitzungen sind 121 Angaben Spielwelt und 90 " <>
            "Tisch — in zweien davon ist Tisch die Mehrheit. Steht es nicht da, " <>
            "nimm zweifel statt zu raten. " <>
            "EINE ZAHL IST KEINE ZEIT: Geldbeträge („2000 jeder“), Seitenzahlen " <>
            "(„Seite 42“), Modifikatoren („um eins erhöht“), Entfernungen („5 bis " <>
            "50 Meter“), Schadenswerte („um sechs K“), Würfelergebnisse — die " <>
            "gehören mit loesen heraus, nicht hierher. " <>
            "UND UNSERE WELT IST NICHT DIE SPIELWELT: „diese Mannschaft ist leidend " <>
            "seit 2014“, „die sind vor vier Jahren hingegangen“, „in den letzten " <>
            "30 Jahren zweimal“ — Smalltalk über Sport, Filme, Politik. Das " <>
            "sind echte Zeitangaben mit echten Jahreszahlen, und sie sehen " <>
            "überzeugender aus als jede Küchenuhr; für die Linie sind sie " <>
            "genauso falsch. Allein in einer Sitzung neun Stellen, meist in den " <>
            "ersten Blöcken, bevor das Spiel anfängt. Raus damit über loesen. " <>
            "VORSICHT bei ziffernförmigen Uhrzeiten in einem Satz über " <>
            "Weltgeschichte: „ab um etwa 20:10 Uhr gebären Menschen …“ ist die " <>
            "JAHRESZAHL 2010, die die Spracherkennung als Uhrzeit geschrieben " <>
            "hat. Ich kann das nicht sehen, du am Satz drumherum schon. " <>
            "EIN ZEITPUNKT BRAUCHT KEINEN KALENDER: „Tag 2 unserer " <>
            "Bekanntschaft“, „am Tag nach dem Überfall“ ordnen, auch wenn " <>
            "niemand weiß, welches Datum das ist — setz sie. In dieser Kampagne " <>
            "hat der Spielleiter das Datum ausdrücklich offengelassen („nur das " <>
            "Jahr, ich habe noch nicht entschieden, wann das ist“); die Reihe " <>
            "trägt trotzdem. " <>
            "Die Felder erklärt dir hilfe(werkzeug: \"zeitpunkt\") im Einzelnen.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" =>
                "Die Zeilennummern, an denen der Zeitpunkt hängt — eine, mehrere oder eine ganze Szene."
            },
            "wert" => %{
              "type" => "string",
              "description" =>
                "NUR der Zeitausdruck, WIE er gesagt wurde: „drei viertel elf“, „am 15. November“, " <>
                  "„kurz nach zwölf“, „2070“. Wortformen bleiben Wortformen — nicht in Ziffern " <>
                  "umschreiben, nicht umrechnen. KEINE Erläuterung dazu: nicht „2070 (Konzernkriege)“, " <>
                  "nicht zwei Ausdrücke mit Schrägstrich („Ende 2011 / am 24. Dezember 2011“ — nimm " <>
                  "den genaueren). Was der Zeitpunkt bedeutet, steht im beleg; hier steht nur, woran " <>
                  "ich rechne. Ein Zusatz macht den Wert unlesbar, und dann datiert der Anker nichts."
            },
            "welt" => %{
              "type" => "string",
              "enum" => ~w(spielwelt tisch),
              "description" =>
                "„spielwelt“, wenn die Zeit in der erzählten Welt gilt; „tisch“, wenn sie den Abend meint (Pause, Restzeit, wann wir aufhören). Steht es nicht da: nicht raten, sondern kettenplatz_unklar() nehmen."
            },
            "beleg" => %{
              "type" => "string",
              "description" => "Das wörtliche Zitat aus der Zeile, in dem die Zeit vorkommt."
            },
            "halbtag" => %{
              "type" => "string",
              "enum" => ~w(vormittag nachmittag unklar),
              "description" =>
                "Nur wenn BELEGT — steht im selben Satz eine Tageszeit („nachts um halb zwei“, „morgens um zehn“). Sonst weglassen: Ich löse den Halbtag aus der Reihe der Anker auf."
            },
            "kettenplatz_unklar" => %{
              "type" => "string",
              "minLength" => 0,
              "description" =>
                "Optionale Notiz, wenn du den Anker setzt, aber unsicher bist. Der Anker gilt und trägt deinen Vorbehalt mit."
            }
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ~w(halbtag kettenplatz_unklar),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_zeitpunkt/2
      },
      %{
        name: "setz_spanne",
        beschreibung:
          "Hängt eine DAUER an Zeilen: „zwei Stunden marschiert“, „eine halbe " <>
            "Stunde später“. Das ist der Mechanismus, mit dem am Tisch Spielzeit " <>
            "vergeht, ohne dass jemand eine Uhr nennt — ohne Spannen steht die " <>
            "Linie still. Verrechnet wird sie an der HÖCHSTEN der Zeilennummern, " <>
            "die du nennst: „wir sind zwei Stunden marschiert“ fällt, wenn der " <>
            "Marsch vorbei ist — dort ist die Zeit bereits vergangen. " <>
            "Eine generische Wirkdauer ist KEINE Spanne („eine Stunde hat man Zeit, " <>
            "um das zu benutzen“ sagt, wie lange etwas dauert, nicht wann es " <>
            "geschieht) — die gehört mit loesen heraus. Eine konkrete Restzeit " <>
            "dieser Figur an dieser Stelle dagegen schon. " <>
            "Führt die Spanne über eine NACHT („es vergeht eine Nacht“, „am " <>
            "nächsten Morgen“), setz tageswechsel — am Wortlaut erkennen kann " <>
            "ich das nicht, du schon.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" =>
                "Die Zeilen, an denen die Dauer hängt. Verrechnet wird sie an der HÖCHSTEN dieser Nummern — dort ist die Zeit bereits vergangen."
            },
            "wert" => %{
              "type" => "string",
              "description" =>
                "Die Dauer, wie sie gesagt wurde: „zwei Stunden“, „eine halbe Stunde später“, „vier oder fünf Minuten“."
            },
            "welt" => %{
              "type" => "string",
              "enum" => ~w(spielwelt tisch),
              "description" =>
                "Wie bei zeitpunkt: Vergeht die Zeit in der erzählten Welt oder am Tisch?"
            },
            "beleg" => %{
              "type" => "string",
              "description" => "Das wörtliche Zitat, in dem die Dauer genannt wird."
            },
            "tageswechsel" => %{
              "type" => "boolean",
              "description" =>
                "true, wenn die Spanne über eine NACHT führt („es vergeht eine Nacht“, „am nächsten Morgen“). Dann zählt nicht die Stundenzahl, sondern der Morgen danach — den rechne ich."
            },
            "kettenplatz_unklar" => %{
              "type" => "string",
              "minLength" => 0,
              "description" => "Optionale Notiz, wenn die Spanne gilt, du aber unsicher bist."
            }
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ~w(tageswechsel kettenplatz_unklar),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_spanne/2
      },
      %{
        name: "setz_frist",
        beschreibung:
          "EINE FRIST BEWEGT DIE LINIE NIE — sie wird nur festgehalten. " <>
            "Hält eine Dauer fest, die NACH VORN zeigt: „die Verhandlungen dauern " <>
            "noch eine Woche“, „ihr habt bis Freitag“, „in zwei Stunden kommt der " <>
            "Kurier“. Das ist keine `spanne` — bei der ist die Zeit schon " <>
            "vergangen, hier steht sie noch bevor. Sie verschiebt deshalb nichts " <>
            "auf der Linie; sie wird festgehalten, weil sie später gebraucht " <>
            "wird: Wenn jemand sagt „die Verhandlungen sind vorbei“, ergibt sich " <>
            "aus beidem eine Spanne. Eine generische Wirkdauer ist auch hier " <>
            "KEINE Frist („eine Stunde hat man Zeit, das zu benutzen“ sagt, wie " <>
            "lange etwas wirkt, nicht wie lange es noch dauert).",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" =>
                "Die Zeilen, an denen die angekündigte Dauer genannt wird. Die Linie bewegt sich dadurch NICHT."
            },
            "wert" => %{
              "type" => "string",
              "description" =>
                "Die angekündigte Dauer, wie gesagt: „noch eine Woche“, „in zwei Stunden“, „bis Freitag“."
            },
            "welt" => %{
              "type" => "string",
              "enum" => ~w(spielwelt tisch),
              "description" =>
                "Wie bei zeitpunkt: Gilt die Frist in der erzählten Welt oder am Tisch?"
            },
            "beleg" => %{
              "type" => "string",
              "description" => "Das wörtliche Zitat, in dem die Frist genannt wird."
            },
            "kettenplatz_unklar" => %{
              "type" => "string",
              "minLength" => 0,
              "description" => "Optionale Notiz, wenn du unsicher bist."
            }
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ["kettenplatz_unklar"],
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_frist/2
      },
      %{
        name: "anker_dazu",
        beschreibung:
          "Antwort auf eine Rückfrage: Dein Anker kommt NEBEN den bestehenden. An " <>
            "einer Zeile dürfen mehrere Anker hängen — „eine Stunde vergangen, dann " <>
            "ist es kurz nach zwölf“ ist eine Dauer UND ein Zeitpunkt.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "kennung" => %{
              "type" => "string",
              "description" =>
                "Die Kennung aus meiner Rückfrage. Sie gilt für genau einen Aufruf und nur an der Stelle, an der sie entstanden ist."
            },
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" => "Dieselben Zeilen wie im abgelehnten Aufruf."
            },
            "art" => %{
              "type" => "string",
              "enum" => ~w(setz_zeitpunkt setz_spanne),
              "description" => "Die Art des Ankers, den du setzen wolltest."
            },
            "wert" => %{"type" => "string", "description" => "Der Ausdruck, wie gesagt."},
            "welt" => %{
              "type" => "string",
              "enum" => ~w(spielwelt tisch),
              "description" => "„spielwelt“ oder „tisch“, wie bei zeitpunkt."
            },
            "beleg" => %{"type" => "string", "description" => "Das wörtliche Zitat."}
          },
          "required" => ~w(kennung zeilen art wert welt beleg)
        },
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_dazu/2
      },
      %{
        name: "anker_ersetzen",
        beschreibung:
          "Antwort auf eine Rückfrage: Der bestehende Anker wird aus der Kette " <>
            "gelöst, deiner tritt an seine Stelle. Nimm das, wenn der alte falsch " <>
            "ist — nicht, wenn beide stimmen; dafür ist dazu da.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "kennung" => %{
              "type" => "string",
              "description" =>
                "Die Kennung aus meiner Rückfrage. Sie gilt für genau einen Aufruf und nur an der Stelle, an der sie entstanden ist."
            },
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" => "Dieselben Zeilen wie im abgelehnten Aufruf."
            },
            "art" => %{
              "type" => "string",
              "enum" => ~w(setz_zeitpunkt setz_spanne),
              "description" => "Die Art des Ankers, den du setzen wolltest."
            },
            "wert" => %{"type" => "string", "description" => "Der Ausdruck, wie gesagt."},
            "welt" => %{
              "type" => "string",
              "enum" => ~w(spielwelt tisch),
              "description" => "„spielwelt“ oder „tisch“, wie bei zeitpunkt."
            },
            "beleg" => %{"type" => "string", "description" => "Das wörtliche Zitat."}
          },
          "required" => ~w(kennung zeilen art wert welt beleg)
        },
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_ersetzen/2
      },
      %{
        name: "melde_konflikt",
        beschreibung:
          "Trägt einen Widerspruch zu einer abgesegneten Stelle ein. Eine " <>
            "Festlegung, die ein Mensch getroffen hat, überschreibt niemand — auch " <>
            "du nicht. Wenn du triftige Gründe hast, dass sie nicht stimmt, schreib " <>
            "sie hier auf: Ein Mensch sieht sich das an. Nenne, WAS du gefunden " <>
            "hast und WORAUS — ohne das kann niemand entscheiden, ohne deine Arbeit " <>
            "zu wiederholen.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "minItems" => 1,
              "description" =>
                "Die Zeilen, um die es geht — dort, wo die abgesegnete Stelle deiner Ansicht nach nicht stimmt."
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
          "required" => ~w(zeilen befund beleg)
        },
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

  defp w_zeitpunkt(s, f), do: anker_setzen(s, f, :zeitpunkt, nil)
  defp w_spanne(s, f), do: anker_setzen(s, f, :spanne, nil)
  defp w_frist(s, f), do: anker_setzen(s, f, :frist, nil)

  defp w_dazu(s, f), do: anker_setzen(s, f, art_von(f), {:dazu, f["kennung"]})
  defp w_ersetzen(s, f), do: anker_setzen(s, f, art_von(f), {:ersetzen, f["kennung"]})

  defp art_von(%{"art" => "setz_spanne"}), do: :spanne
  defp art_von(_), do: :zeitpunkt

  # **Ein Anker braucht ein Kettenglied** (#1247, 20.09.2026). Seit die Kette
  # leer beginnt, kann eine Zeile eine Uhrzeit tragen, ohne irgendwo zu
  # liegen — der Anker wäre gesetzt, in `lies_kette()` aber unsichtbar, und
  # die Rechnung hätte nichts, worauf sie ihn legen könnte. Das ist die
  # Klasse „gesetzt, aber wirkungslos", die dieses Ticket bei den
  # Verschiebungen schon einmal erzeugt hat. Die Ablehnung nennt den Ausweg,
  # statt nur Nein zu sagen: erst einreihen, dann datieren.
  defp in_der_kette?(s, ids) do
    fehlend = Enum.reject(ids, &Kette.glied_von(s.kette, &1))

    if fehlend == [] do
      :ok
    else
      nrs = for u <- fehlend, z = Enum.find(s.mitschnitt, &(&1.utterance_id == u)), do: z.nr

      {:fehler,
       "#{length(fehlend)} dieser Zeilen liegen in keinem Kettenglied " <>
         "(#{Enum.join(Enum.sort(nrs), ", ")}) — ein Anker dort wäre gesetzt und " <>
         "unsichtbar. Reih sie erst ein (haenge_an_kette), dann setz die Zeit."}
    end
  end

  defp anker_setzen(s, f, art, entscheidung) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f["zeilen"]),
         :ok <- in_der_kette?(s, ids) do
      wunsch = %{
        utterance_ids: ids,
        art: art,
        wert: to_string(f["wert"]),
        welt: to_string(f["welt"]),
        beleg: to_string(f["beleg"]),
        halbtag: to_string(f["halbtag"] || ""),
        tageswechsel: f["tageswechsel"] == true,
        zweifel: to_string(f["kettenplatz_unklar"] || "")
      }

      s = Stand.gelesen(s, zeilen)

      # **Geprüft wird VOR dem Verbrauch der Kennung.** Der erste Wurf löste
      # sie vorher ein — `entscheiden/4` sah dann seine eigene, soeben
      # entwertete Kennung und antwortete „schon eingelöst". Eine gültige
      # Antwort auf eine Rückfrage war damit unmöglich, und zwar ohne jeden
      # Fehler: Jack bekäme eine plausible Ablehnung auf einen korrekten
      # Aufruf und wiederholte ihn (#1211-Klasse). Verbraucht wird die
      # Kennung genau dann, wenn sie getragen hat.
      case Setzen.entscheiden(s, wunsch, entscheidung) do
        {:gesetzt, anker} ->
          anker = Ausdruck.aufloesen(anker, s.kalender)
          s = s |> entscheidung_verbrauchen(entscheidung) |> Stand.setzen(anker)
          {s, {:ok, gesetzt_text(anker, zeilen, s)}}

        {:rueckfrage, r} ->
          {Stand.ausgeben(s, r.guid, %{utterance_ids: ids}), {:ok, r.text}}

        {:verworfen, v} ->
          {s, {:error, v.text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  defp entscheidung_verbrauchen(s, {_art, guid}), do: Stand.verbrauchen(s, guid)
  defp entscheidung_verbrauchen(s, _), do: s

  # **Das Ziel ist optional** (#1247, nach dem Lauf vom 20.09.2026). Bis
  # dahin verlangte `verschieben` eine Zielzeile — und genau daran blieb das
  # Modell hängen: Für Weltgeschichte („Ende 2011 erwachten die Drachen")
  # gibt es keine Zielzeile, das Geschehen liegt vor der ganzen Sitzung. Im
  # Denkstrom stand es wörtlich: „verschieben requires a ziel (target line)
  # … but there's no specific past scene that should be referenced." Es hat
  # daraufhin die Anker gesetzt und die Zeilen stehen lassen — womit die
  # Kette rückwärts lief.
  #
  # Drei Wege stehen jetzt offen, und `Worker.Timeline.Linie.stelle_fuer/3`
  # wählt in dieser Reihenfolge: „anfang" (vor alles), eine Zielzeile, oder
  # die eigene Zeit des Abschnitts.
  defp offene_ids(s, ids), do: Enum.reject(ids, &Kette.glied_von(s.kette, &1))

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
        case Stand.kette(s, &Kette.anhaengen(&1, offene_ids(s, ids))) do
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

  # ─── Helfer ─────────────────────────────────────────────────────────

  defp gesetzt_text(anker, zeilen, s) do
    nummern = zeilen |> Enum.map(& &1.nr) |> Enum.join(", ")

    "#{art_wort(anker.art)} „#{anker.wert}“ an Zeile #{nummern} (#{anker.welt}). " <>
      gelesen_hinweis(anker, s) <> reststand(s)
  end

  # **Was aus dem Ausdruck wurde, steht in der Antwort.** Der Anker gilt so
  # oder so — aber ob er die Linie bewegt, hängt daran, ob der Parser eine
  # Zahl daraus macht. Ohne diesen Satz setzt Jack eine Uhrzeit, bekommt
  # „gesetzt", und sieht erst in `lies_kette()` (wenn überhaupt), dass dort ein
  # Strich steht. Die Prüfung liest das Ergebnis der Auflösung, nicht ein
  # zweites Mal den Parser: Was hier steht, ist genau das, womit gerechnet
  # wird.
  @doc false
  # Nur für Tests: die Formprüfung des Hinweises ohne einen ganzen Lauf.
  def gelesen_hinweis_fuer_test(anker, stand), do: gelesen_hinweis(anker, stand)

  defp gelesen_hinweis(%{art: :zeitpunkt} = a, s) do
    cond do
      is_integer(a[:minute]) ->
        ""

      is_integer(a[:halbtag_minute]) ->
        "Gelesen als #{uhr(a[:halbtag_minute])} oder #{uhr(a[:halbtag_minute] + 720)}; " <>
          "welches von beiden, ergibt sich aus der Reihe der Anker. " <>
          "Steht es im Gespräch, nenn es in halbtag. "

      true ->
        "Als Zeit lesbar ist er nicht#{als(a, s)} — er ordnet, datiert aber nicht. " <>
          vorschlag(a, s)
    end
  end

  defp gelesen_hinweis(%{art: :spanne} = a, s) do
    case a[:minuten] do
      m when is_integer(m) ->
        "Das sind #{m} Minuten. "

      _ ->
        "Als Dauer lesbar ist er nicht#{als(a, s)} — er ordnet, misst aber nicht. " <>
          vorschlag(a, s)
    end
  end

  defp gelesen_hinweis(%{art: :frist} = a, _s) do
    dauer =
      case a[:minuten] do
        m when is_integer(m) -> "Das sind #{m} Minuten. "
        _ -> ""
      end

    dauer <> "Sie verschiebt nichts auf der Linie — sie wartet auf ihr Ende. "
  end

  defp gelesen_hinweis(_a, _s), do: ""

  # **Wenn ein Zusatz das Lesen verhindert, sagt die Antwort, wie es geht.**
  #
  # Am Lauf vom 24.09.2026 gefunden: Jack setzte zehn Anker, keiner ergab
  # eine Minute — er schreibt Erläuterungen in den Wert („2070
  # (Konzernkriege, Fuji zerbricht)", „um 2010 (erste Metamenschen)") oder
  # zwei Ausdrücke mit Schrägstrich („Ende 2011 / am 24. Dezember 2011").
  # Fünf der zehn wären ohne den Klammerzusatz lesbar gewesen, zwei ohne
  # den Schrägstrich.
  #
  # Den bisherigen Satz („er ordnet, datiert aber nicht") hat er zehnmal
  # bekommen und zehnmal übergangen — er benennt das Problem, aber nicht die
  # Handlung. Der Vorschlag nennt den Wert, der funktioniert hätte;
  # **geändert wird nichts von selbst**: Ein stilles Zurechtschneiden machte
  # aus Jacks Angabe eine andere, ohne dass er es erfährt.
  defp vorschlag(a, s) do
    wert = to_string(a[:wert] || "")

    case lesbare_kurzform(wert, a.art, s) do
      kurz when is_binary(kurz) -> "So ginge es: nimm nur den Ausdruck selbst, also „#{kurz}“. "
      nil -> lesarten_hinweis(wert, a.art, s)
    end
  end

  # **„um 7" kann beides sein** (Maintainer, 24.09.2026: „man muss den
  # context auswerten — ‚um 7‘ kann beides sein"). Eine Zahl ohne Einheit ist
  # als Uhrzeit und als Jahreszahl lesbar, und **welche gemeint ist, steht
  # nur im Gespräch** — der Parser sieht den Ausdruck, nicht den Satz. Er
  # rät deshalb nicht, sondern liefert gar nichts; bis hierher erfuhr Jack
  # davon nur „als Zeit lesbar ist er nicht".
  #
  # Den Kontext hat genau einer: Jack. Also fragt die Antwort ihn — und sie
  # fragt konkret, indem sie **beide Lesarten ausprobiert** und nur die
  # nennt, die tatsächlich aufgehen. Das ist keine Bedeutungserkennung
  # (#1109/#1213: zweimal abgeschaltet, zweimal zu Recht), sondern eine
  # Umformung mit anschliessender Prüfung: „7 Uhr" und „im Jahr 7" gehen
  # beide, „70 Uhr" geht nicht, „im Jahr sieben" auch nicht.
  defp lesarten_hinweis(wert, :zeitpunkt = art, s) do
    case kern(wert) do
      nil ->
        ""

      k ->
        uhr = if lesbar?("#{k} Uhr", art, s), do: "#{k} Uhr"
        jahr = if lesbar?("im Jahr #{k}", art, s), do: "im Jahr #{k}"

        cond do
          uhr && jahr ->
            "„#{wert}“ kann beides sein — eine Uhrzeit oder eine Jahreszahl. Du hast den " <>
              "Satz gelesen, ich nicht: Sag es eindeutig, „#{uhr}“ oder „#{jahr}“. "

          uhr ->
            "So ginge es: „#{uhr}“. "

          jahr ->
            "So ginge es: „#{jahr}“. "

          true ->
            ""
        end
    end
  end

  defp lesarten_hinweis(_wert, _art, _s), do: ""

  # Der Kern eines Ausdrucks ist seine letzte Zahl oder sein letztes Wort —
  # „um 7" → „7", „gegen sieben" → „sieben". Mehr braucht es nicht: Was
  # daraus wird, entscheidet die Prüfung, nicht diese Zerlegung.
  defp kern(wert) do
    case Regex.run(~r/([\p{L}\d]+)\s*$/u, String.trim(wert)) do
      [_, k] -> k
      _ -> nil
    end
  end

  @kuerzungen [
    # „2070 (Konzernkriege…)" → „2070"
    {~r/\s*\([^)]*\)\s*$/u, ""},
    # „Ende 2011 / am 24. Dezember 2011" → „Ende 2011"
    {~r/\s*\/.*$/u, ""}
  ]

  defp lesbare_kurzform(wert, art, s) do
    Enum.find_value(@kuerzungen, fn {muster, ersatz} ->
      kurz = wert |> String.replace(muster, ersatz) |> String.trim()

      if kurz != "" and kurz != wert and lesbar?(kurz, art, s), do: kurz
    end)
  end

  defp lesbar?(wert, art, s) do
    a = Ausdruck.aufloesen(%{art: art, wert: wert, utterance_ids: []}, s.kalender)

    is_integer(a[:minute]) or is_integer(a[:tagesminute]) or is_integer(a[:halbtag_minute]) or
      (art == :spanne and is_integer(a[:minuten]))
  end

  defp uhr(m) do
    "#{String.pad_leading(to_string(div(m, 60)), 2, "0")}:" <>
      String.pad_leading(to_string(rem(m, 60)), 2, "0")
  end

  defp als(a, s) do
    case Ausdruck.gelesen_als(a.wert, s.kalender) do
      {:ok, typ} -> " (gelesen als #{typ})"
      :kein_ausdruck -> ""
    end
  end

  defp art_wort(:zeitpunkt), do: "Zeitpunkt"
  defp art_wort(:spanne), do: "Spanne"
  defp art_wort(:frist), do: "Frist"
  defp art_wort(x), do: to_string(x)

  # Jede Antwort eines setzenden Werkzeugs nennt den Reststand — sonst muss
  # Jack ihn sich mit `zahlen()` holen, und das kostet eine Runde je Anker.
  # **Der Reststand nennt die Einordnung mit** — sie ist seit #1247 die
  # zweite Abschlussbedingung, und was in keiner Antwort steht, erfährt das
  # Modell erst durch eine Ablehnung.
  @doc """
  Die Standardzeile am Ende jeder Antwort: wie weit dieser Lauf ist.

  Öffentlich, weil `fertig()` dieselbe Zeile ausgibt — sie steht am Ende
  jeder setzenden Antwort und am Ende des Laufs, und zwei Fassungen davon
  liefen auseinander.
  """
  def reststand(s) do
    z = Stand.zahlen(s)

    offen =
      if z.ohne_einordnung > 0, do: " Noch ohne Einordnung: #{z.ohne_einordnung}.", else: ""

    "Gelesen #{z.gelesen}/#{z.utterances}, Anker #{z.anker}.#{offen}"
  end
end
