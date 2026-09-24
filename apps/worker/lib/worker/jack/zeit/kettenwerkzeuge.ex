defmodule Worker.Jack.Zeit.Kettenwerkzeuge do
  @moduledoc """
  #1247: die Werkzeuge, mit denen Jack die **Kette** baut — die zeitliche
  Reihenfolge des Geschehens.

  Geschnitten aus `Worker.Jack.Zeit.Anker`, als dort mit den fünf
  Ketten-Operationen die God-Module-Grenze fiel. Der Schnitt folgt der
  Zweiteilung der Arbeit, die der Auftrag ohnehin vorgibt: **erst
  einreihen, dann datieren.** Hier liegt das Einreihen, dort das Datieren.

      haenge_an_kette         ein neues Glied AUF den Zeitstrahl
      unterhaenge_kettenglied ein neues Glied AN ein bestehendes Glied
      erweitere_kettenglied   ein bestehendes Glied wächst, bleibt wo es ist
      versetze_kettenglied    vor/nach ein Geschwisterglied, oder an den Anfang
      loesche_kettenglied     Glied raus, seine Zeilen sind wieder offen
      nicht_in_die_kette      Tischgespräch — kommt nie hinein

  ## Bäume auf dem Zeitstrahl

  Maintainer, 20.09.2026: „ein glied hängt entweder am zeitstrahl oder an
  einem glied" — und „die glieder die an einem glied hängen sind wieder eine
  kette". Daraus folgt die Gestalt der Werkzeuge: `haenge_an_kette` und
  `unterhaenge_kettenglied` sind **dasselbe Werkzeug auf zwei Ebenen**,
  `versetzen` und `löschen` gelten auf beiden unverändert, und `vor`/`nach`
  meinen immer die Geschwister — nie den Sprung in eine andere Ebene.

  **Jack adressiert ein Glied über eine seiner Zeilennummern.** Die Kennung
  (`g_<hash>`) ist seine Adresse im Code, nicht im Gespräch: Ein Modell
  kann sie nicht tippen, und sie ändert sich, sobald das Glied anders
  geschnitten wird. Eine Zeilennummer hat es ohnehin vor sich.

  Die Rechnung dahinter steht in `Worker.Timeline.Kette` — pur, ohne
  Werkzeug-Belange; hier liegt nur, was das Modell davon sieht.
  """

  alias Worker.Jack.Zeit.{Mitschnitt, Stand}
  alias Worker.Timeline.Kette

  @doc "Die sechs Ketten-Werkzeuge."
  def werkzeuge do
    [
      %{
        name: "versetze_kettenglied",
        beschreibung:
          "Setzt ein bestehendes Glied an eine andere Stelle der Kette. Dafür " <>
            "ist dieses Werkzeug da: Ein Rückblick liegt in der VERGANGENHEIT, " <>
            "auch wenn er mitten in der Sitzung erzählt wird; eine Ankündigung " <>
            "liegt in der Zukunft. " <>
            "glied: eine Zeile, die in dem Glied liegt, das wandern soll. " <>
            "Drei Ziele: vor eine Zeile (das Glied, in dem sie liegt), nach " <>
            "einer Zeile, oder anfang für vor die ganze Kette — letzteres ist " <>
            "der Fall für Weltgeschichte, die vor allem anderen liegt. " <>
            "VERSETZEN BRAUCHT EINEN BELEG im Text („letztes Mal“, „damals“, " <>
            "„das war, bevor“); ohne einen bleibt das Glied, wo es ist. Der " <>
            "häufigste Fall ist der SITZUNGSANFANG: Fast jede Sitzung beginnt " <>
            "damit, dass die Runde erzählt, was beim letzten Mal geschah.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "glied" => %{
              "type" => "integer",
              "description" => "Eine Zeile aus dem Glied, das versetzt werden soll."
            },
            "vor" => %{
              "type" => "integer",
              "description" => "Eine Zeile; das Glied kommt VOR das Glied, in dem sie liegt."
            },
            "nach" => %{
              "type" => "integer",
              "description" => "Eine Zeile; das Glied kommt HINTER das Glied, in dem sie liegt."
            },
            "anfang" => %{
              "type" => "boolean",
              "description" => "true setzt das Glied vor die ganze Kette."
            },
            "beleg" => %{
              "type" => "string",
              "description" =>
                "Das wörtliche Zitat, aus dem hervorgeht, dass die Stelle zeitlich nicht hierher gehört."
            }
          },
          "required" => ~w(glied beleg)
        },
        optional: ~w(vor nach anfang),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_versetze_kettenglied/2
      },
      %{
        name: "loesche_kettenglied",
        beschreibung:
          "Nimmt ein Glied aus der Kette heraus. Seine Zeilen sind danach wieder " <>
            "OFFEN — nicht draussen: Herausnehmen ist kein Urteil über den Inhalt, " <>
            "sondern die Rücknahme einer Einreihung. Dafür: ein Glied, das du " <>
            "falsch geschnitten hast und neu bilden willst. " <>
            "Für Tischgespräch ist nicht_in_die_kette() das richtige Werkzeug — " <>
            "es entscheidet, statt die Zeilen wieder offen zu lassen. " <>
            "glied: eine Zeile, die in dem Glied liegt.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "glied" => %{
              "type" => "integer",
              "description" => "Eine Zeile aus dem Glied, das herausgenommen werden soll."
            }
          },
          "required" => ["glied"]
        },
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_loesche_kettenglied/2
      },
      %{
        name: "haenge_an_kette",
        beschreibung:
          "Bildet aus Zeilen EIN Kettenglied und hängt es an die Kette. Das ist " <>
            "die Hauptarbeit dieses Laufs: Die Kette beginnt LEER, und jede Zeile, " <>
            "die zur erzählten Welt gehört, muss bewusst hinein. " <>
            "EIN GLIED IST EINE ZEITEINHEIT, nicht eine Zeile: Eine Szene — " <>
            "Ankunft, Verhandlung, Rückzug — ist ein Glied, auch wenn vierzig " <>
            "Zeilen dazugehören. Nimm grosse Abschnitte (von/bis); eine Kette aus " <>
            "zweitausend Einzelgliedern kannst du nicht mehr lesen, eine aus " <>
            "achtzig schon. " <>
            "ABER: ZWEI ZEITEN SIND ZWEI GLIEDER. Kommen in einem Abschnitt zwei " <>
            "verschiedene Zeitpunkte der Spielwelt vor (etwa „die Plage der frühen " <>
            "2000er“ und „2011 erwachten die Drachen“), mach zwei Glieder daraus — " <>
            "auch wenn derselbe Sprecher ohne Pause durchredet. Ein Glied trägt " <>
            "genau EINE Zeit; alles Weitere darin wird unsichtbar. " <>
            "Die Kette ist die Zeitleiste der SPIELWELT: Weltgeschichte gehört " <>
            "hinein, auch wenn sie nie jemand gespielt hat — und an ihren Platz, " <>
            "nicht an den Sitzungsanfang, wo sie erzählt wurde. " <>
            "Ohne Angabe kommt das Glied ans ENDE der Kette — das ist der " <>
            "Normalfall, wenn du den Mitschnitt der Reihe nach durchgehst. Gehört " <>
            "der Abschnitt woanders hin (ein Rückblick), nenn vor/nach mit einer " <>
            "Zeile aus dem Zielglied, oder anfang für vor die ganze Kette. " <>
            "Was NICHT hineingehört, kommt mit nicht_in_die_kette() heraus — " <>
            "Tischgespräch bekommt sonst eine Spielzeit, die es nicht hat. " <>
            "NICHTS DAVON IST ENDGÜLTIG: Ein Glied lässt sich versetzen, " <>
            "erweitern, herausnehmen und neu schneiden, und eine Zeile, die du " <>
            "neu einreihst, verlässt ihr altes Glied von selbst. Trag also ein, " <>
            "was du vor dir hast, statt erst die perfekte Gliederung zu suchen — " <>
            "was du nur denkst, ist nach der nächsten Zusammenfassung deines " <>
            "Gedächtnisses weg.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" =>
                "Einzelne Zeilennummern. Für zusammenhängende Abschnitte lieber von/bis."
            },
            "von" => %{"type" => "integer", "description" => "Erste Zeile des Glieds (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile des Glieds (mit von)."},
            "vor" => %{
              "type" => "integer",
              "description" => "OPTIONAL: eine Zeile aus dem Glied, VOR das dieses gehört."
            },
            "nach" => %{
              "type" => "integer",
              "description" => "OPTIONAL: eine Zeile aus dem Glied, HINTER das dieses gehört."
            },
            "anfang" => %{
              "type" => "boolean",
              "description" =>
                "OPTIONAL: true setzt das Glied vor die ganze Kette — für alles, was vor allem anderen liegt (Weltgeschichte)."
            },
            "grund" => %{
              "type" => "string",
              "description" => "OPTIONAL: ein kurzer Name für die Szene, in deinen Worten."
            }
          },
          "required" => []
        },
        optional: ~w(zeilen von bis vor nach anfang grund),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_haenge_an_kette/2
      },
      %{
        name: "unterhaenge_kettenglied",
        beschreibung:
          "Hängt ein NEUES Glied an ein bestehendes — als Teil davon. Dafür " <>
            "ist das da: Ein Glied ist ein zusammenhängender Zusammenhang, und " <>
            "ein grosser besteht aus kleineren. „Der Überfall“ bekommt so „der " <>
            "Hinterhalt“ und „die Flucht“; sie stehen IN ihm, nicht daneben auf " <>
            "dem Zeitstrahl. " <>
            "glied: eine Zeile aus dem Glied, in das das neue hineingehört. " <>
            "DIE GLIEDER AN EINEM GLIED SIND WIEDER EINE KETTE: ohne Angabe " <>
            "kommt das neue hinten dazu, vor/nach nennen eine Zeile aus einem " <>
            "seiner Geschwister, anfang setzt es davor. " <>
            "Nimm das nur, wenn der Zusammenhang wirklich verschachtelt ist — " <>
            "eine Szene nach der anderen gehört mit haenge_an_kette auf den " <>
            "Zeitstrahl, nicht ineinander.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "glied" => %{
              "type" => "integer",
              "description" => "Eine Zeile aus dem Glied, an das das neue gehängt wird."
            },
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für Abschnitte lieber von/bis."
            },
            "von" => %{
              "type" => "integer",
              "description" => "Erste Zeile des neuen Glieds (mit bis)."
            },
            "bis" => %{
              "type" => "integer",
              "description" => "Letzte Zeile des neuen Glieds (mit von)."
            },
            "vor" => %{
              "type" => "integer",
              "description" =>
                "OPTIONAL: eine Zeile aus einem Geschwisterglied, VOR das dieses gehört."
            },
            "nach" => %{
              "type" => "integer",
              "description" =>
                "OPTIONAL: eine Zeile aus einem Geschwisterglied, HINTER das dieses gehört."
            },
            "anfang" => %{
              "type" => "boolean",
              "description" =>
                "OPTIONAL: true setzt das neue Glied an den Anfang seiner Geschwister."
            },
            "grund" => %{
              "type" => "string",
              "description" => "OPTIONAL: ein kurzer Name für diesen Teil, in deinen Worten."
            }
          },
          "required" => ["glied"]
        },
        optional: ~w(zeilen von bis vor nach anfang grund),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_unterhaenge_kettenglied/2
      },
      %{
        name: "erweitere_kettenglied",
        beschreibung:
          "Hängt Zeilen an ein BESTEHENDES Glied — das Glied wächst und bleibt, " <>
            "wo es ist. Das ist etwas anderes als haenge_an_kette(): Dort entsteht " <>
            "ein NEUES Glied und landet am Ende der Kette. Wenn du merkst, dass " <>
            "eine Szene schon früher anfing („ach, das begann bei 98“), ist das " <>
            "hier das richtige Werkzeug. " <>
            "glied: eine Zeile, die schon in dem Glied liegt. " <>
            "DIE ZEILEN EINES GLIEDES SIND SELBST EINE KETTE: vor/nach nennen " <>
            "eine Zeile IM Glied, ohne Angabe wird hinten angehängt.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "glied" => %{
              "type" => "integer",
              "description" => "Eine Zeile, die bereits in dem Glied liegt, das wachsen soll."
            },
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für Abschnitte lieber von/bis."
            },
            "von" => %{"type" => "integer", "description" => "Erste Zeile (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile (mit von)."},
            "vor" => %{
              "type" => "integer",
              "description" => "OPTIONAL: eine Zeile IM Glied, vor die das Neue gehört."
            },
            "nach" => %{
              "type" => "integer",
              "description" => "OPTIONAL: eine Zeile IM Glied, hinter die das Neue gehört."
            },
            "anfang" => %{
              "type" => "boolean",
              "description" => "OPTIONAL: true setzt das Neue an den Anfang des Gliedes."
            }
          },
          "required" => ["glied"]
        },
        optional: ~w(zeilen von bis vor nach anfang),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_erweitere_kettenglied/2
      },
      %{
        name: "nicht_in_die_kette",
        beschreibung:
          "Erklärt Zeilen für DRAUSSEN: Tischgespräch, Regelfrage, Würfelergebnis, " <>
            "Pausenabsprache, Smalltalk über die reale Welt — und generische " <>
            "Wirkdauern („eine Stunde hat man Zeit“), die sagen, wie lange etwas " <>
            "dauert, aber nicht, wann es geschieht. Sie kommen nie in die Kette " <>
            "und werden nie datiert. " <>
            "Das ist eine vollwertige Entscheidung, kein Notausgang: Jede Zeile " <>
            "braucht eine — entweder in ein Glied oder hier heraus. Was niemand " <>
            "entschieden hat, zählt als offen, und fertig() fragt danach. " <>
            "Auch das ist umkehrbar: haenge_an_kette() holt eine Zeile aus dem " <>
            "Draussen zurück, wenn sie doch zur Spielwelt gehört.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "zeilen" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" => "Einzelne Zeilennummern. Für Abschnitte lieber von/bis."
            },
            "von" => %{"type" => "integer", "description" => "Erste Zeile (mit bis)."},
            "bis" => %{"type" => "integer", "description" => "Letzte Zeile (mit von)."},
            "grund" => %{
              "type" => "string",
              "description" => "In deinen Worten, kurz: warum das nicht in die Kette gehört."
            }
          },
          "required" => ["grund"]
        },
        optional: ~w(zeilen von bis),
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_nicht_in_die_kette/2
      }
    ]
  end

  # ─── Ausführung ─────────────────────────────────────────────────────

  defp w_versetze_kettenglied(s, f) do
    with {:ok, [utt], zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, [f["glied"]]),
         {:ok, glied} <- glied_bei(s, utt),
         {:ok, wohin, wort} <- versetz_ziel(s, f) do
      s = Stand.gelesen(s, zeilen)

      case Stand.kette(s, &Kette.versetzen(&1, glied.id, wohin)) do
        {:ok, s, _} ->
          {s, {:ok, "Glied #{glied_wort(glied, s)} #{wort}. " <> kettenstand(s)}}

        {:fehler, text} ->
          {s, {:error, text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
      _ -> {s, {:error, "Die Zeile in glied liegt in keinem Kettenglied."}}
    end
  end

  defp versetz_ziel(s, f) do
    cond do
      f["anfang"] == true ->
        {:ok, :anfang, "an den Anfang der Kette gesetzt"}

      is_integer(f["vor"]) ->
        ziel_glied(s, f["vor"], :vor)

      is_integer(f["nach"]) ->
        ziel_glied(s, f["nach"], :nach)

      true ->
        {:fehler,
         "Sag wohin: vor eine Zeile, nach eine Zeile, oder anfang für vor die " <>
           "ganze Kette."}
    end
  end

  defp ziel_glied(s, nr, richtung) do
    with {:ok, [utt], _} <- Mitschnitt.aufloesen(s.mitschnitt, [nr]),
         {:ok, ziel} <- glied_bei(s, utt) do
      wort = if richtung == :vor, do: "vor", else: "hinter"
      {:ok, {richtung, ziel.id}, "#{wort} das Glied bei Zeile #{nr} gesetzt"}
    else
      _ ->
        {:fehler,
         "Zeile #{nr} liegt in keinem Kettenglied — nenn eine, die schon " <>
           "eingereiht ist."}
    end
  end

  defp w_loesche_kettenglied(s, f) do
    with {:ok, [utt], zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, [f["glied"]]),
         {:ok, glied} <- glied_bei(s, utt) do
      wort = glied_wort(glied, s)
      s = Stand.gelesen(s, zeilen)

      case Stand.kette(s, &Kette.loeschen(&1, glied.id)) do
        {:ok, s, _} ->
          {s,
           {:ok,
            "Glied #{wort} aus der Kette genommen — seine Zeilen sind wieder " <>
              "offen. " <> kettenstand(s)}}

        {:fehler, text} ->
          {s, {:error, text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
      _ -> {s, {:error, "Die Zeile in glied liegt in keinem Kettenglied."}}
    end
  end

  defp w_haenge_an_kette(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f),
         {:ok, opts} <- kette_opts(s, f) do
      s = Stand.gelesen(s, zeilen)

      case Stand.kette(s, &Kette.anhaengen(&1, ids, opts)) do
        {:ok, s, glied} ->
          s = Stand.einordnen(s, zeilen, :ingame)
          {s, {:ok, "Glied #{glied_wort(glied, s)} angelegt. " <> kettenstand(s)}}

        {:fehler, text} ->
          {s, {:error, text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  defp w_unterhaenge_kettenglied(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f),
         {:ok, [eltern_utt], _} <- Mitschnitt.aufloesen(s.mitschnitt, [f["glied"]]),
         {:ok, eltern} <- glied_bei(s, eltern_utt),
         {:ok, opts} <- kette_opts(s, f) do
      s = Stand.gelesen(s, zeilen)

      case Stand.kette(s, &Kette.unterhaengen(&1, eltern.id, ids, opts)) do
        {:ok, s, glied} ->
          s = Stand.einordnen(s, zeilen, :ingame)

          {s,
           {:ok,
            "Glied #{glied_wort(glied, s)} an #{glied_wort(eltern, s)} gehängt. " <>
              kettenstand(s)}}

        {:fehler, text} ->
          {s, {:error, text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
      _ -> {s, {:error, "Die Zeile in glied liegt in keinem Kettenglied."}}
    end
  end

  defp w_erweitere_kettenglied(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f),
         {:ok, [glied_utt], _} <- Mitschnitt.aufloesen(s.mitschnitt, [f["glied"]]),
         {:ok, glied} <- glied_bei(s, glied_utt),
         {:ok, opts} <- innere_opts(s, f) do
      s = Stand.gelesen(s, zeilen)

      case Stand.kette(s, &Kette.erweitern(&1, glied.id, ids, opts)) do
        {:ok, s, groesser} ->
          s = Stand.einordnen(s, zeilen, :ingame)

          {s,
           {:ok,
            "Glied auf #{length(groesser.utts)} Zeile(n) erweitert: " <>
              "#{glied_wort(groesser, s)}. " <> kettenstand(s)}}

        {:fehler, text} ->
          {s, {:error, text}}
      end
    else
      {:fehler, text} -> {s, {:error, text}}
      _ -> {s, {:error, "Die Zeile in glied liegt in keinem Kettenglied."}}
    end
  end

  defp w_nicht_in_die_kette(s, f) do
    with {:ok, ids, zeilen} <- Mitschnitt.aufloesen(s.mitschnitt, f) do
      s = Stand.gelesen(s, zeilen)
      {:ok, s, _} = Stand.kette(s, &Kette.draussen(&1, ids, to_string(f["grund"])))
      s = Stand.einordnen(s, zeilen, :tisch)

      {s, {:ok, "#{length(ids)} Zeile(n) bleiben draussen. " <> kettenstand(s)}}
    else
      {:fehler, text} -> {s, {:error, text}}
    end
  end

  # Positionsangaben der KETTE: vor/nach nennen eine Zeile, die in einem
  # Glied liegt — das Glied ist gemeint, nicht die Zeile.

  defp kette_opts(s, f) do
    cond do
      f["anfang"] == true ->
        {:ok, [anfang: true, grund: f["grund"]]}

      is_integer(f["vor"]) ->
        mit_zielglied(s, f["vor"], :vor, f["grund"])

      is_integer(f["nach"]) ->
        mit_zielglied(s, f["nach"], :nach, f["grund"])

      true ->
        {:ok, [grund: f["grund"]]}
    end
  end

  defp mit_zielglied(s, nr, richtung, grund) do
    with {:ok, [utt], _} <- Mitschnitt.aufloesen(s.mitschnitt, [nr]),
         {:ok, glied} <- glied_bei(s, utt) do
      {:ok, [{richtung, glied.id}, {:grund, grund}]}
    else
      _ ->
        {:fehler,
         "Zeile #{nr} liegt in keinem Kettenglied — nenn eine Zeile, die schon " <>
           "eingereiht ist, oder lass vor/nach weg."}
    end
  end

  # Positionsangaben INNERHALB eines Gliedes: vor/nach nennen eine Zeile.

  defp innere_opts(s, f) do
    cond do
      f["anfang"] == true -> {:ok, [anfang: true]}
      is_integer(f["vor"]) -> innere_pos(s, f["vor"], :vor)
      is_integer(f["nach"]) -> innere_pos(s, f["nach"], :nach)
      true -> {:ok, []}
    end
  end

  defp innere_pos(s, nr, richtung) do
    case Mitschnitt.aufloesen(s.mitschnitt, [nr]) do
      {:ok, [utt], _} -> {:ok, [{richtung, utt}]}
      andere -> andere
    end
  end

  # Nur die, die noch nirgends liegen — wer schon in einem Glied ist, soll
  # durch einen Zweifel nicht daraus gerissen werden.

  defp glied_bei(s, utterance_id) do
    case Kette.glied_von(s.kette, utterance_id) do
      nil -> {:fehler, "Diese Zeile liegt in keinem Kettenglied."}
      g -> {:ok, g}
    end
  end

  # Ein Glied benennt sich über seine Zeilenspanne — die Kennung ist für
  # Jack keine Adresse, er zeigt über Zeilennummern darauf.

  defp glied_wort(glied, s) do
    nrs =
      for u <- Kette.alle_utts(glied),
          z = Enum.find(s.mitschnitt, &(&1.utterance_id == u)),
          do: z.nr

    case nrs do
      [] -> "(leer)"
      [n] -> "Zeile #{n}"
      liste -> "Zeilen #{Enum.min(liste)}–#{Enum.max(liste)}"
    end
  end

  @doc "Der Stand der Kette in einem Satz — dieselbe Zeile in jeder Antwort."
  def kettenstand(s) do
    z = Stand.zahlen(s)

    "Kette: #{z.glieder} Glied(er), #{z.in_der_kette} Zeile(n) drin, " <>
      "#{z.draussen} draussen, #{z.unentschieden} noch unentschieden."
  end
end
