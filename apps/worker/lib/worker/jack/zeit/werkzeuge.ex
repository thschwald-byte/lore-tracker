defmodule Worker.Jack.Zeit.Werkzeuge do
  @moduledoc """
  #1247 (Z2): die Werkzeuge des Zeit-Jack, je Lauf.

      :gedaechtnis   nur lesen. Den Ablauf verstehen, nichts setzen.
      :einsortieren  die Utterances einordnen: Anker, Spannen, Verschiebungen,
                     oder begründet aus der Kette lösen.
      :pruefen       dieselben Werkzeuge, anderer Gegenstand: die entstandene
                     Linie lesen und geraderücken.

  **Die Regeln stehen in den Werkzeugen, nicht im Auftrag** — wie beim
  Chronik-Jack (#1211). Ein Auftrag wird einmal gelesen und nach einer
  Kompaktierung vergessen; eine Werkzeugbeschreibung steht bei jedem Aufruf
  da, und was das Werkzeug ablehnt, kann das Modell nicht übersehen.

  **Jede Antwort rechnet nach und nennt Zahlen.** Kein „geht nicht" ohne
  Grund und ohne Ausweg: Beim Chronik-Jack kostete eine Ablehnung, die ihre
  gezählte Zahl verschwieg, 28 von 51 Runden.

  ## Adressiert wird über die Zeilennummer des Mitschnitts

  Eine Zeile ist eine **Utterance** — nicht ein Block. Die Nummer ist Jacks
  Zeigefinger im Gespräch; gespeichert wird die Utterance-ID, und nur die
  überlebt ein Re-Smoothing. Mehrere Zeilen ergeben eine Menge: eine Szene,
  ein Gespräch, eine Passage.
  """

  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam
  alias Worker.Jack.Zeit.{Abschluss, Lesen, Notizen, Setzen, Stand}
  alias Worker.Timeline.Ausdruck

  # `hilfe` steht hier NICHT: `Gemeinsam.aus/3` stellt es jedem Lauf von
  # selbst voran (Maintainer, 18.09.2026 — die Beschreibungen tragen die
  # Regeln und stehen nur einmal im Gespräch; nach einer Kompaktierung ist
  # der Wortlaut weg).
  @lesend ~w(mitschnitt linie offen zahlen)
  # Nur der Gedächtnis-Lauf notiert: Er SETZT nichts, und sein Ergebnis ist
  # genau diese Notiz — ohne sie wäre er wirkungslos (Befund des zweiten
  # echten Laufs, 19.09.2026). Die beiden anderen Läufe legen ihr Ergebnis in
  # Ankern ab.
  #
  # **Alle drei Läufe lesen die ÄUSSERUNGEN** (Maintainer, 19.09.2026: „wir
  # stellen den jacklauf ganz auf die utts um — also auch datensammeln aus
  # utts, werkzeug für fakten weg"). Der Gedächtnis-Lauf las bis dahin die
  # Fakten; die sind eine andere Schicht mit anderer Körnung (418 gegen 2168),
  # sie kommen aus allen Sitzungen der Kampagne, und ihre Reihenfolge ist
  # nicht die des Gesprächs — das Modell rätselte darüber mehrfach. Jetzt ist
  # es Jacks eigenes Muster: Phase 1 und Phase 2 lesen denselben Mitschnitt,
  # die eine versteht ihn, die andere ordnet ein.
  @notierend ~w(notiz notizen_lesen)
  @setzend ~w(zeitpunkt spanne frist verschieben loesen ingame dazu ersetzen konflikt zweifel)

  @doc """
  Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Liste.

  Der **Gedächtnis-Lauf setzt nichts** — er versteht den Ablauf, gegen den
  die beiden anderen lesen. Seine Notizen bekommt er mit dem Lauf selbst
  (noch nicht gebaut).
  """
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :gedaechtnis}), do: @lesend ++ @notierend ++ ["fertig"]
  def namen(%Stand{}), do: @lesend ++ @setzend ++ ["fertig"]

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Worker.Agent.Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end

  @doc false
  def definitionen(%Stand{} = s) do
    Lesen.werkzeuge(s) ++ Notizen.werkzeuge() ++ setzen_werkzeuge() ++ abschluss_werkzeuge(s.lauf)
  end

  # ─── Setzen ─────────────────────────────────────────────────────────

  defp setzen_werkzeuge do
    [
      %{
        name: "zeitpunkt",
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
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Die Zeilennummern, an denen der Zeitpunkt hängt — eine, mehrere oder eine ganze Szene."},
            "wert" => %{"type" => "string",
              "description" => "Der Ausdruck, WIE er gesagt wurde: „drei viertel elf“, „am 15. November“, „kurz nach zwölf“. Wortformen bleiben Wortformen — nicht in Ziffern umschreiben, nicht umrechnen."},
            "welt" => %{"type" => "string", "enum" => ~w(spielwelt tisch),
              "description" => "„spielwelt“, wenn die Zeit in der erzählten Welt gilt; „tisch“, wenn sie den Abend meint (Pause, Restzeit, wann wir aufhören). Steht es nicht da: nicht raten, sondern zweifel() nehmen."},
            "beleg" => %{"type" => "string",
              "description" => "Das wörtliche Zitat aus der Zeile, in dem die Zeit vorkommt."},
            "halbtag" => %{"type" => "string", "enum" => ~w(vormittag nachmittag unklar),
              "description" => "Nur wenn BELEGT — steht im selben Satz eine Tageszeit („nachts um halb zwei“, „morgens um zehn“). Sonst weglassen: Ich löse den Halbtag aus der Reihe der Anker auf."},
            "zweifel" => %{"type" => "string", "minLength" => 0,
              "description" => "Optionale Notiz, wenn du den Anker setzt, aber unsicher bist. Der Anker gilt und trägt deinen Vorbehalt mit."}
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ~w(halbtag zweifel),
        wiederholung: :zaehlt,
        ausfuehren: &w_zeitpunkt/2
      },
      %{
        name: "spanne",
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
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Die Zeilen, an denen die Dauer hängt. Verrechnet wird sie an der HÖCHSTEN dieser Nummern — dort ist die Zeit bereits vergangen."},
            "wert" => %{"type" => "string",
              "description" => "Die Dauer, wie sie gesagt wurde: „zwei Stunden“, „eine halbe Stunde später“, „vier oder fünf Minuten“."},
            "welt" => %{"type" => "string", "enum" => ~w(spielwelt tisch),
              "description" => "Wie bei zeitpunkt: Vergeht die Zeit in der erzählten Welt oder am Tisch?"},
            "beleg" => %{"type" => "string",
              "description" => "Das wörtliche Zitat, in dem die Dauer genannt wird."},
            "tageswechsel" => %{"type" => "boolean",
              "description" => "true, wenn die Spanne über eine NACHT führt („es vergeht eine Nacht“, „am nächsten Morgen“). Dann zählt nicht die Stundenzahl, sondern der Morgen danach — den rechne ich."},
            "zweifel" => %{"type" => "string", "minLength" => 0,
              "description" => "Optionale Notiz, wenn die Spanne gilt, du aber unsicher bist."}
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ~w(tageswechsel zweifel),
        wiederholung: :zaehlt,
        ausfuehren: &w_spanne/2
      },
      %{
        name: "frist",
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
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Die Zeilen, an denen die angekündigte Dauer genannt wird. Die Linie bewegt sich dadurch NICHT."},
            "wert" => %{"type" => "string",
              "description" => "Die angekündigte Dauer, wie gesagt: „noch eine Woche“, „in zwei Stunden“, „bis Freitag“."},
            "welt" => %{"type" => "string", "enum" => ~w(spielwelt tisch),
              "description" => "Wie bei zeitpunkt: Gilt die Frist in der erzählten Welt oder am Tisch?"},
            "beleg" => %{"type" => "string",
              "description" => "Das wörtliche Zitat, in dem die Frist genannt wird."},
            "zweifel" => %{"type" => "string", "minLength" => 0,
              "description" => "Optionale Notiz, wenn du unsicher bist."}
          },
          "required" => ~w(zeilen wert welt beleg)
        },
        optional: ["zweifel"],
        wiederholung: :zaehlt,
        ausfuehren: &w_frist/2
      },
      %{
        name: "verschieben",
        beschreibung:
          "Holt Zeilen aus der Erzählreihenfolge heraus und setzt sie vor oder " <>
            "hinter eine andere Zeile. Dafür ist dieses Werkzeug da: Ein Rückblick " <>
            "liegt in der VERGANGENHEIT, auch wenn er mitten in der Sitzung erzählt " <>
            "wird; eine Ankündigung liegt in der Zukunft. Alles, was du NICHT " <>
            "verschiebst, steht an seiner Erzählposition — das ist der Normalfall " <>
            "und kostet dich nichts. VERSCHIEBEN BRAUCHT EINEN BELEG im Text " <>
            "(„letztes Mal“, „damals“, „das war, bevor“); ohne einen bleibt die " <>
            "Zeile, wo sie ist. Der häufigste Fall ist der SITZUNGSANFANG: Fast " <>
            "jede Sitzung beginnt damit, dass die Runde erzählt, was beim letzten " <>
            "Mal geschah — Dutzende Zeilen, die dorthin gehören, wo sie geschahen.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Die Zeilen, die an eine andere Stelle gehören — der Rückblick, die Ankündigung."},
            "richtung" => %{"type" => "string", "enum" => ~w(vor nach),
              "description" => "„vor“ = die Zeilen liegen zeitlich VOR der Zielzeile (Rückblick), „nach“ = danach (Ankündigung)."},
            "ziel" => %{"type" => "integer",
              "description" => "Die Zeilennummer, vor oder hinter die es gehört."},
            "beleg" => %{"type" => "string",
              "description" => "Das wörtliche Zitat, aus dem hervorgeht, dass die Stelle zeitlich nicht hierher gehört („letztes Mal“, „damals“, „das war, bevor“). Ohne Beleg im Text bleibt die Zeile stehen — die Erzählreihenfolge ist der Normalfall."}
          },
          "required" => ~w(zeilen richtung ziel beleg)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_verschieben/2
      },
      %{
        name: "loesen",
        beschreibung:
          "Nimmt Zeilen aus der Kette: Sie liegen dann nicht mehr auf der Linie und " <>
            "werden nie interpoliert. **Das ist zugleich die Einordnung " <>
            "„Tischgespräch“** — du brauchst kein zweites Werkzeug dafür. " <>
            "Dafür: Tischgespräch, Regelfrage, " <>
            "Würfelergebnis, Pausenabsprache — und generische Wirkdauern („eine " <>
            "Stunde hat man Zeit“), die sagen, wie lange etwas dauert, aber nicht, " <>
            "wann es geschieht. Das ist eine " <>
            "vollwertige Entscheidung, kein Notausgang — was nicht auf die Linie " <>
            "gehört, dort zu lassen wäre schlechter.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für zusammenhängende Abschnitte lieber von/bis."},
            "von" => %{"type" => "integer", "description" => "Erste Zeile des Abschnitts (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile des Abschnitts (mit von)."},
            "grund" => %{"type" => "string",
              "description" => "In deinen Worten, kurz: warum das nicht auf die Linie gehört („Regelfrage“, „Pausenabsprache“, „Smalltalk über Fußball“)."}
          },
          "required" => ["grund"]
        },
        optional: ~w(zeilen von bis),
        wiederholung: :zaehlt,
        ausfuehren: &w_loesen/2
      },
      %{
        name: "ingame",
        beschreibung:
          "Sagt: Diese Zeilen gehören zur erzählten Welt — sie bleiben auf der " <>
            "Linie. Das ist keine Zeitangabe und kein Anker, sondern die Antwort " <>
            "auf die Frage, ob hier gespielt oder am Tisch geredet wird. " <>
            "JEDE Zeile braucht eine solche Antwort, bevor du fertig bist: " <>
            "entweder ingame(), oder loesen() für Tischgespräch, oder zweifel(), " <>
            "wenn du es nicht entscheiden kannst. Was niemand einordnet, wird " <>
            "trotzdem interpoliert und bekommt eine Spielzeit, die es nicht gibt. " <>
            "Nimm grosse Abschnitte auf einmal — von/bis ist dafür da.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für zusammenhängende Abschnitte lieber von/bis."},
            "von" => %{"type" => "integer", "description" => "Erste Zeile des Abschnitts (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile des Abschnitts (mit von)."}
          },
          "required" => []
        },
        optional: ~w(zeilen von bis),
        wiederholung: :zaehlt,
        ausfuehren: &w_ingame/2
      },
      %{
        name: "dazu",
        beschreibung:
          "Antwort auf eine Rückfrage: Dein Anker kommt NEBEN den bestehenden. An " <>
            "einer Zeile dürfen mehrere Anker hängen — „eine Stunde vergangen, dann " <>
            "ist es kurz nach zwölf“ ist eine Dauer UND ein Zeitpunkt.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "kennung" => %{"type" => "string",
              "description" => "Die Kennung aus meiner Rückfrage. Sie gilt für genau einen Aufruf und nur an der Stelle, an der sie entstanden ist."},
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Dieselben Zeilen wie im abgelehnten Aufruf."},
            "art" => %{"type" => "string", "enum" => ~w(zeitpunkt spanne),
              "description" => "Die Art des Ankers, den du setzen wolltest."},
            "wert" => %{"type" => "string", "description" => "Der Ausdruck, wie gesagt."},
            "welt" => %{"type" => "string", "enum" => ~w(spielwelt tisch),
              "description" => "„spielwelt“ oder „tisch“, wie bei zeitpunkt."},
            "beleg" => %{"type" => "string", "description" => "Das wörtliche Zitat."}
          },
          "required" => ~w(kennung zeilen art wert welt beleg)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_dazu/2
      },
      %{
        name: "ersetzen",
        beschreibung:
          "Antwort auf eine Rückfrage: Der bestehende Anker wird aus der Kette " <>
            "gelöst, deiner tritt an seine Stelle. Nimm das, wenn der alte falsch " <>
            "ist — nicht, wenn beide stimmen; dafür ist dazu da.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "kennung" => %{"type" => "string",
              "description" => "Die Kennung aus meiner Rückfrage. Sie gilt für genau einen Aufruf und nur an der Stelle, an der sie entstanden ist."},
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Dieselben Zeilen wie im abgelehnten Aufruf."},
            "art" => %{"type" => "string", "enum" => ~w(zeitpunkt spanne),
              "description" => "Die Art des Ankers, den du setzen wolltest."},
            "wert" => %{"type" => "string", "description" => "Der Ausdruck, wie gesagt."},
            "welt" => %{"type" => "string", "enum" => ~w(spielwelt tisch),
              "description" => "„spielwelt“ oder „tisch“, wie bei zeitpunkt."},
            "beleg" => %{"type" => "string", "description" => "Das wörtliche Zitat."}
          },
          "required" => ~w(kennung zeilen art wert welt beleg)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_ersetzen/2
      },
      %{
        name: "konflikt",
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
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1,
              "description" => "Die Zeilen, um die es geht — dort, wo die abgesegnete Stelle deiner Ansicht nach nicht stimmt."},
            "befund" => %{"type" => "string",
              "description" => "WAS du gefunden hast: der Widerspruch in einem Satz, so dass ein Mensch entscheiden kann, ohne deine Arbeit zu wiederholen."},
            "beleg" => %{"type" => "string",
              "description" => "WORAUS: das wörtliche Zitat, auf das sich dein Befund stützt."}
          },
          "required" => ~w(zeilen befund beleg)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_konflikt/2
      },
      %{
        name: "zweifel",
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
            "zeilen" => %{"type" => "array", "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für zusammenhängende Abschnitte lieber von/bis."},
            "von" => %{"type" => "integer", "description" => "Erste Zeile des Abschnitts (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile des Abschnitts (mit von)."},
            "text" => %{"type" => "string",
              "description" => "Was du nicht entscheiden kannst — beides gehört hierher: „Welt oder Tisch?“ und „ingame, aber die Zeit ist unklar“."}
          },
          "required" => ["text"]
        },
        optional: ~w(zeilen von bis),
        wiederholung: :zaehlt,
        ausfuehren: &w_zweifel/2
      }
    ]
  end

  # ─── Abschluss ──────────────────────────────────────────────────────



  # **Der Gedächtnis-Lauf hat einen anderen Abschluss, und das muss in der
  # Beschreibung stehen** (Befund des zweiten echten Laufs): Die gemeinsame
  # Fassung sprach von Zeilen, die zugeordnet sein müssen. Das Modell hielt
  # inne — „fertig() requires that every row of the transcript has been
  # assigned… but this run is about facts, not about the transcript" — kam
  # zur richtigen Antwort und verlor eine Runde. Dieselbe Klasse wie die
  # geteilten Werkzeugbeschreibungen beim Chronik-Jack (#1211).
  defp abschluss_werkzeuge(:gedaechtnis) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Schliesst den Lauf ab. Geht, wenn du JEDE Zeile gelesen hast — nicht, " <>
            "wenn du jede notiert hast: Notiert wird, was der nächste Lauf " <>
            "braucht, und das ist viel weniger. Was noch fehlt, sagt dir diese " <>
            "Antwort mit Zahlen, und offen() sagt es dir vorher.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: &w_fertig/2
      }
    ]
  end

  defp abschluss_werkzeuge(_lauf) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Schliesst den Lauf ab. Dafür muss JEDE Zeile zweierlei haben: eine " <>
            "EINORDNUNG (ingame / loesen / zweifel — gespielt, Tisch oder unklar) " <>
            "und einen Platz in der Reihe. Und alles, was du als Tischgespräch " <>
            "eingeordnet hast, muss mit loesen() aus der Kette heraus sein: Was " <>
            "auf der Linie liegt, bekommt eine Spielzeit, auch wenn es keine " <>
            "hat. Zum Platz in der Reihe: Sie " <>
            "steht in der Reihe — das tut sie durch die Erzählreihenfolge, solange " <>
            "du sie nicht anfasst — oder sie ist gelöst. Dazu musst du jede Zeile " <>
            "GELESEN haben: „nicht angefasst“ heisst „die Erzählreihenfolge stimmt " <>
            "hier“, und das ist eine Aussage über die Welt, die du nur treffen " <>
            "kannst, wenn du die Zeile gesehen hast. Was fehlt, sagt dir diese " <>
            "Antwort mit Zahlen.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: &w_fertig/2
      }
    ]
  end

  # ─── Ausführung ─────────────────────────────────────────────────────

  defp w_zeitpunkt(s, f), do: anker_setzen(s, f, :zeitpunkt, nil)
  defp w_spanne(s, f), do: anker_setzen(s, f, :spanne, nil)
  defp w_frist(s, f), do: anker_setzen(s, f, :frist, nil)

  defp w_dazu(s, f), do: anker_setzen(s, f, art_von(f), {:dazu, f["kennung"]})
  defp w_ersetzen(s, f), do: anker_setzen(s, f, art_von(f), {:ersetzen, f["kennung"]})

  defp art_von(%{"art" => "spanne"}), do: :spanne
  defp art_von(_), do: :zeitpunkt

  defp anker_setzen(s, f, art, entscheidung) do
    with {:ok, ids, zeilen} <- aufloesen(s, f["zeilen"]) do
      wunsch = %{
        utterance_ids: ids,
        art: art,
        wert: to_string(f["wert"]),
        welt: to_string(f["welt"]),
        beleg: to_string(f["beleg"]),
        halbtag: to_string(f["halbtag"] || ""),
        tageswechsel: f["tageswechsel"] == true,
        zweifel: to_string(f["zweifel"] || "")
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

  defp w_verschieben(s, f) do
    with {:ok, ids, zeilen} <- aufloesen(s, f["zeilen"]),
         {:ok, [ziel], _} <- aufloesen(s, [f["ziel"]]) do
      anker =
        Setzen.bauen(%{
          utterance_ids: ids,
          art: :ordnung,
          wert: to_string(f["richtung"]),
          welt: "spielwelt",
          beleg: to_string(f["beleg"])
        })
        |> Map.put(:ziel, ziel)
        |> Map.put(:richtung, if(f["richtung"] == "nach", do: :nach, else: :vor))

      s = Stand.gelesen(s, zeilen) |> Stand.setzen(anker)

      {s,
       {:ok,
        "Verschoben: #{length(ids)} Zeile(n) #{f["richtung"]} Zeile #{f["ziel"]}. " <>
          reststand(s)}}
    else
      {:fehler, text} -> {s, {:error, text}}
      _ -> {s, {:error, "Das Ziel gibt es nicht. Nenn eine Zeilennummer aus dem Mitschnitt."}}
    end
  end

  defp w_loesen(s, f) do
    with {:ok, ids, zeilen} <- aufloesen(s, f) do
      anker =
        Setzen.bauen(%{
          utterance_ids: ids,
          art: :geloest,
          wert: to_string(f["grund"]),
          welt: "tisch",
          beleg: ""
        })

      s = s |> Stand.gelesen(zeilen) |> Stand.einordnen(zeilen, :tisch) |> Stand.setzen(anker)

      {s,
       {:ok,
        "#{length(ids)} Zeile(n) aus der Kette gelöst: #{f["grund"]}. Sie liegen nicht " <>
          "mehr auf der Linie und werden nie interpoliert. " <> reststand(s)}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  defp w_ingame(s, f) do
    with {:ok, _ids, zeilen} <- aufloesen(s, f) do
      s = s |> Stand.gelesen(zeilen) |> Stand.einordnen(zeilen, :ingame)
      z = Stand.zahlen(s)

      {s,
       {:ok,
        "#{length(zeilen)} Zeile(n) als Spielwelt eingeordnet — sie bleiben auf der " <>
          "Linie. Eingeordnet #{z.eingeordnet}/#{z.utterances}."}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  defp w_konflikt(s, f) do
    with {:ok, ids, zeilen} <- aufloesen(s, f["zeilen"]) do
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
    with {:ok, ids, zeilen} <- aufloesen(s, f) do
      anker =
        Setzen.bauen(%{
          utterance_ids: ids,
          art: :zweifel,
          wert: "",
          welt: "",
          beleg: "",
          zweifel: to_string(f["text"])
        })

      s =
        s |> Stand.gelesen(zeilen) |> Stand.einordnen(zeilen, :unklar) |> Stand.setzen(anker)

      {s, {:ok, "Zweifel festgehalten — nichts gesetzt, #{length(ids)} Zeile(n) als " <>
                  "unklar vermerkt. " <> reststand(s)}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  # **`:halt` beendet den Lauf, `:error` lehnt ab** — und beides ist tragend.
  # Der erste Wurf lieferte hier wie überall einen blanken String: Der Lauf
  # hätte auch bei sonst fehlerfreier Arbeit NIE geendet, weil
  # `Worker.Jack.Resuemee.Lauf` auf `%{ende: :halt}` prüft. Er wäre in den
  # Rundendeckel gelaufen, nach Stunden, mit vollständiger Arbeit und ohne
  # Ergebnis.
  defp w_fertig(s, _f) do
    case Abschluss.hindernisse(s) do
      [] ->
        {s, {:halt, "Abgeschlossen. " <> reststand(s)}}

      hindernisse ->
        {s,
         {:error, "Noch nicht fertig:\n" <> Enum.map_join(hindernisse, "\n", &("- " <> &1))}}
    end
  end

  # ─── Helfer ─────────────────────────────────────────────────────────

  # Zeilennummern → Utterance-IDs. Eine unbekannte Nummer ist ein Fehler mit
  # Grund, kein stilles Weglassen: Sonst hinge der Anker an weniger Zeilen,
  # als Jack meinte, und niemand merkte es.
  # **Ein Bereich statt einer Liste** (#1247): Bei 2168 Zeilen, die alle
  # eingeordnet werden müssen, wäre `zeilen: [1, 2, …, 80]` je Aufruf eine
  # Zumutung — und die Wiederholungssperre zählte jeden mit. `von`/`bis`
  # nimmt denselben Abschnitt in zwei Zahlen.
  defp aufloesen(%Stand{} = s, %{} = f) do
    aufloesen(s, nummern_aus(f))
  end

  defp aufloesen(%Stand{mitschnitt: m}, nummern) do
    gewaehlt = for nr <- List.wrap(nummern), z = Enum.find(m, &(&1.nr == nr)), do: z

    fehlend = List.wrap(nummern) -- Enum.map(gewaehlt, & &1.nr)

    cond do
      gewaehlt == [] ->
        {:fehler, "Keine dieser Zeilennummern gibt es. Der Mitschnitt hat #{length(m)} Zeilen."}

      fehlend != [] ->
        {:fehler,
         "Diese Zeilennummern gibt es nicht: #{Enum.join(fehlend, ", ")}. Nichts " <>
           "eingetragen — nenn nur Nummern aus dem Mitschnitt."}

      true ->
        {:ok, Enum.map(gewaehlt, & &1.utterance_id), gewaehlt}
    end
  end

  # `zeilen` und `von`/`bis` ergänzen sich; beides leer ist ein Fehler, den
  # `aufloesen/2` mit seiner eigenen Meldung abfängt.
  defp nummern_aus(f) do
    aus_liste = List.wrap(f["zeilen"])

    aus_bereich =
      case {f["von"], f["bis"]} do
        {von, bis} when is_integer(von) and is_integer(bis) and von <= bis -> Enum.to_list(von..bis)
        {von, nil} when is_integer(von) -> [von]
        _ -> []
      end

    (aus_liste ++ aus_bereich) |> Enum.uniq() |> Enum.sort()
  end

  defp gesetzt_text(anker, zeilen, s) do
    nummern = zeilen |> Enum.map(& &1.nr) |> Enum.join(", ")

    "#{art_wort(anker.art)} „#{anker.wert}“ an Zeile #{nummern} (#{anker.welt}). " <>
      gelesen_hinweis(anker, s) <> reststand(s)
  end

  # **Was aus dem Ausdruck wurde, steht in der Antwort.** Der Anker gilt so
  # oder so — aber ob er die Linie bewegt, hängt daran, ob der Parser eine
  # Zahl daraus macht. Ohne diesen Satz setzt Jack eine Uhrzeit, bekommt
  # „gesetzt", und sieht erst in `linie()` (wenn überhaupt), dass dort ein
  # Strich steht. Die Prüfung liest das Ergebnis der Auflösung, nicht ein
  # zweites Mal den Parser: Was hier steht, ist genau das, womit gerechnet
  # wird.
  defp gelesen_hinweis(%{art: :zeitpunkt} = a, s) do
    cond do
      is_integer(a[:minute]) ->
        ""

      is_integer(a[:halbtag_minute]) ->
        "Gelesen als #{uhr(a[:halbtag_minute])} oder #{uhr(a[:halbtag_minute] + 720)}; " <>
          "welches von beiden, ergibt sich aus der Reihe der Anker. " <>
          "Steht es im Gespräch, nenn es in halbtag. "

      true ->
        "Als Zeit lesbar ist er nicht#{als(a, s)} — er ordnet, datiert aber nicht. "
    end
  end

  defp gelesen_hinweis(%{art: :spanne} = a, s) do
    case a[:minuten] do
      m when is_integer(m) -> "Das sind #{m} Minuten. "
      _ -> "Als Dauer lesbar ist er nicht#{als(a, s)} — er ordnet, misst aber nicht. "
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
  defp reststand(s) do
    z = Stand.zahlen(s)

    offen =
      if z.ohne_einordnung > 0, do: " Noch ohne Einordnung: #{z.ohne_einordnung}.", else: ""

    "Gelesen #{z.gelesen}/#{z.utterances}, Anker #{z.anker}.#{offen}"
  end
end
