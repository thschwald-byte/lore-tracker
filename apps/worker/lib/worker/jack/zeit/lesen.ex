defmodule Worker.Jack.Zeit.Lesen do
  @moduledoc """
  #1247 (Z2): die lesenden Werkzeuge des Zeit-Jack.

  **`lies_kette()` zeigt das ERGEBNIS, nicht die Eingaben** — und das ist der
  Gegensatz zur Extraktion, wo Jack den Bestand bewusst nicht sieht
  (`Worker.Jack.Tor`). Hier muss er ihn sehen: Ein einzelner Anker kann für
  sich richtig sein und die Reihe trotzdem falsch, und das ist nur am
  gerechneten Ergebnis zu erkennen (Maintainer, 19.09.2026: „im unterschied
  zur extraction das timejack die ergebnisse anschauen").

  **`lies_sprechlinie()` zählt mit, was es ausgibt.** Die Buchführung ist Teil des
  Lesens, nicht ein zweiter Schritt, den jemand vergessen kann — `fertig()`
  hängt daran.
  """

  alias Worker.Jack.Zeit.{Abschluss, Mitschnitt, Stand}
  alias Worker.Timeline.{Calendar, Kette, Linie}

  @minuten_pro_tag 1440

  @fenster 80

  @doc false
  def werkzeuge(%Stand{} = s) do
    [
      %{
        name: "lies_sprechlinie",
        beschreibung:
          "Zeigt den Mitschnitt ab einer Zeile. Eine Zeile ist eine ÄUSSERUNG — " <>
            "mehrere gehören oft zu einem Block, dann steht der geglättete Text " <>
            "einmal darüber. Zeilen mit [ooc] hat die Glättung aussortiert; sie " <>
            "zählen trotzdem und wollen zugeordnet werden. Lies in Portionen und " <>
            "arbeite dich durch: Was du nicht gelesen hast, kannst du nicht " <>
            "einordnen, und fertig() lässt dich damit nicht durch.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "ab" => %{"type" => "integer", "description" => "Erste Zeilennummer des Ausschnitts."},
            "anzahl" => %{
              "type" => "integer",
              "description" =>
                "Wie viele Zeilen (Standard und Höchstwert #{@fenster}). Ein Abschnitt darf kleiner sein, wenn ein Szenenwechsel es nahelegt."
            }
          },
          "required" => ["ab"]
        },
        optional: ["anzahl"],
        wiederholung: :zaehlt,
        aendert_bestand: true,
        ausfuehren: &w_mitschnitt/2
      },
      %{
        name: "lies_kette",
        beschreibung:
          "Zeigt die LINIE, wie sie gerade gerechnet wird — nicht deine Eingaben: " <>
            "wo eine Zeile liegt, wo Spannen greifen, was gelöst wurde, und welche " <>
            "Widersprüche die Rechnung findet. Jede Zeit sagt, woher sie kommt: " <>
            "„belegt“ wurde gesagt und gilt — wie grob der Ausdruck auch war " <>
            "(„auf 3 Jahre genau“ heisst nicht unsicher, sondern ungenau). " <>
            "„gerechnet (70%)“ ist zwischen zwei Belegen geraten; die Zahl sagt, " <>
            "wie eng die beiden beieinander liegen. „fortgeschrieben“ hat keinen " <>
            "Beleg nach oben und ist nur ein Anhalt — kein Grund, an den Ankern " <>
            "zu zweifeln. Und welche " <>
            "Widersprüche die Rechnung findet. Nutz das, um dein Ergebnis zu " <>
            "prüfen: Ein einzelner Anker kann für sich richtig sein und die Reihe " <>
            "trotzdem falsch. Die Befunde kommen in Portionen: Du siehst die, " <>
            "die du noch nicht angesehen hast — ruf lies_kette() erneut, bis keine " <>
            "weiteren mehr gemeldet werden.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "ab" => %{
              "type" => "integer",
              "description" =>
                "Erste ZEILENNUMMER des Ausschnitts — dieselbe Nummerierung wie im Mitschnitt. Gelöste Zeilen erscheinen nicht; gezeigt wird ab der nächsten, die noch auf der Linie liegt. Ohne Angabe von vorn."
            },
            "anzahl" => %{
              "type" => "integer",
              "description" => "Wie viele Zeilen der Linie gezeigt werden."
            }
          },
          "required" => []
        },
        optional: ["ab", "anzahl"],
        wiederholung: :bis_aenderung,
        wiederholung_merkmal: fn %Stand{} = st, _args -> gesehene_befunde(st) end,
        ausfuehren: &w_linie/2
      },
      %{
        name: "offen",
        beschreibung: offen_text(s.lauf),
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_offen/2
      },
      %{
        name: "zahlen",
        beschreibung:
          "Der Stand dieses Laufs in Zahlen: gelesene und eingeordnete Zeilen, " <>
            "Anker nach Art, Gelöstes, Konflikte. Die Zählung ist meine, nicht " <>
            "deine — nimm sie, " <>
            "statt selbst nachzuzählen.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_zahlen/2
      }
    ]
  end

  # **`offen()` nennt, wogegen DIESER Lauf geprüft wird** — die Antwort tut
  # es ohnehin (`Abschluss.hindernisse/1` hat eine eigene Klausel je Lauf),
  # aber wer die Beschreibung liest, soll nicht erst einen Aufruf brauchen,
  # um das zu erfahren.
  defp offen_text(:pruefen),
    do:
      "Nennt, was fertig() noch im Weg steht — in diesem Lauf sind das die " <>
        "BEFUNDE der Rechnung, die du noch nicht angesehen hast, dazu " <>
        "Tischgespräch auf der Linie und Verschiebungen ohne auflösbares Ziel. " <>
        "Lesen und Einordnen stehen schon; danach wird hier nicht mehr gefragt. " <>
        "Frag das, statt zu raten — es ist billiger als ein abgelehntes fertig()."

  defp offen_text(:gedaechtnis),
    do:
      "Nennt, was fertig() noch im Weg steht — in diesem Lauf die ungelesenen " <>
        "Zeilen, als Bereiche („1–60, 501–899“). Frag das, statt zu raten."

  defp offen_text(_lauf),
    do:
      "Nennt, was fertig() noch im Weg steht: ungelesene Zeilen, Zeilen ohne " <>
        "Einordnung, Tischgespräch das noch auf der Linie liegt, " <>
        "Verschiebungen ohne auflösbares Ziel — jeweils als Bereiche " <>
        "(„1–60, 501–899“). Frag das, statt zu raten — es ist billiger als " <>
        "ein abgelehntes fertig()."

  defp w_mitschnitt(%Stand{} = s, f) do
    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || @fenster, @fenster)

    zeilen = s.mitschnitt |> Enum.drop(ab - 1) |> Enum.take(anzahl)

    case zeilen do
      [] ->
        {s,
         {:ok,
          "Ab Zeile #{ab} gibt es nichts mehr — der Mitschnitt hat #{length(s.mitschnitt)} Zeilen."}}

      _ ->
        s = Stand.gelesen(s, zeilen)
        letzte = List.last(zeilen).nr
        z = Stand.zahlen(s)

        {s,
         {:ok,
          Mitschnitt.als_text(zeilen) <>
            "\n\n(Zeile #{ab}–#{letzte} von #{z.utterances}; gelesen #{z.gelesen}, " <>
            "offen #{z.offen}.#{einordnungs_hinweis(s, z)})"}}
    end
  end

  # **Die Erinnerung gehört in die Antwort, die er ohnehin liest.**
  # Im Lauf vom 19.09.2026 las der Einsortier-Lauf Hunderte Zeilen und
  # ordnete keine einzige ein — er dachte die Einordnung sogar aus („lines
  # 1–41: loesen, table talk") und rief sie nicht auf. Der Reststand mit
  # „noch ohne Einordnung" hing nur an den SETZENDEN Werkzeugen, also genau
  # an denen, die er nicht benutzte.
  @sammel_grenze 300

  defp einordnungs_hinweis(%Stand{lauf: :gedaechtnis}, _z), do: ""
  defp einordnungs_hinweis(_s, %{ohne_einordnung: 0}), do: ""

  defp einordnungs_hinweis(_s, %{ohne_einordnung: n}) when n > @sammel_grenze do
    " Noch ohne Einordnung: #{n} — das ist viel. Ordne das Gelesene ein, " <>
      "bevor du weiterliest: setz_kettenplatz(von,bis) für die Welt, loesche_kettenplatz(von,bis,grund) " <>
      "für Tischgespräch. Ein Abschnitt ist EIN Aufruf."
  end

  defp einordnungs_hinweis(_s, %{ohne_einordnung: n}),
    do: " Noch ohne Einordnung: #{n}."

  defp w_linie(%Stand{} = s, f) do
    linie = Linie.aus_kette(s.kette, Map.values(s.anker), stellen(s))

    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || 40, 40)

    # **Über den ganzen Baum, nicht nur die Wurzeln** (#1247): Ein Unterglied
    # ist ein Glied, und was Jack nicht sieht, kann er nicht prüfen. Die
    # Vorordnung ist die Lesereihenfolge; die Tiefe steht als Einrückung
    # davor, damit der Zusammenhang sichtbar ist, ohne ihn zu benennen.
    # **Fremde Glieder gehören immer dazu** (#1247, 25.09.2026, am Lauf
    # gefunden). Der Filter vergleicht die höchste ZEILENNUMMER eines Gliedes
    # mit `ab` — und `max_nr/2` liefert 0, wenn keine seiner Äußerungen im
    # eigenen Mitschnitt steht. Für ein Glied aus einer anderen Sitzung ist
    # das immer so, es fiel damit aus `lies_kette()` heraus.
    #
    # Jack hat es selbst benannt: „Ich sehe nur Glieder 15-34, aber die
    # Befunde beziehen sich auf frühere Glieder 1-14 aus S1, die ich noch
    # nicht gesehen habe." Er konnte die Befunde nicht prüfen, weil ihre
    # Glieder unsichtbar waren — die Kette lag vollständig im Stand, die
    # Anzeige zeigte nur die eigene Hälfte.
    #
    # `ab` ist eine Nummer der EIGENEN Sitzung; auf ein fremdes Glied lässt
    # sie sich nicht anwenden, also gilt es unabhängig davon.
    glieder =
      s.kette
      |> Kette.flach()
      |> Enum.with_index(1)
      |> Enum.filter(fn {{g, _tiefe}, _platz} -> fremd?(g, s) or max_nr(g, s) >= ab end)
      |> Enum.take(anzahl)

    zeigen = befunde_zum_zeigen(s, linie)
    s = Stand.gesehen(s, Enum.map(zeigen, & &1.id))

    {s, {:ok, ketten_text(s, linie, glieder, ab, zeigen, length(linie.befunde))}}
  end

  # Die Spanne eines Gliedes nennt den ganzen Unterbaum: Wer „Zeilen 10–90"
  # liest, sieht den Kontext, den das Glied umspannt — die eigenen Zeilen
  # allein wären bei einem Glied mit Kindern eine Teilangabe.
  defp nummern(glied, %Stand{mitschnitt: m}) do
    for u <- Kette.alle_utts(glied), z = Enum.find(m, &(&1.utterance_id == u)), do: z.nr
  end

  # Ein Glied aus einer anderen Sitzung: keine seiner Äußerungen steht im
  # eigenen Mitschnitt. Es ist lesbar und veränderbar (erweitern, versetzen),
  # nur nicht über Zeilennummern adressierbar — deshalb auch nicht filterbar.
  defp fremd?(glied, %Stand{} = s), do: nummern(glied, s) == []

  defp max_nr(glied, %Stand{} = s) do
    case nummern(glied, s) do
      [] -> 0
      nrs -> Enum.max(nrs)
    end
  end

  defp spanne_wort(glied, %Stand{} = s) do
    case glied |> nummern(s) |> Enum.sort() do
      # **„andere Sitzung" statt „—"** (#1247, 25.09.2026): Ein Strich sagt
      # nicht, WARUM keine Nummern dastehen, und Jack hielt fremde Glieder
      # daraufhin für fehlerhaft. Er darf sie anfassen (erweitern, versetzen)
      # — nur nicht über Zeilennummern, denn die gelten für seine Sitzung.
      [] -> "andere Sitzung"
      [n] -> "#{n}"
      liste -> "#{List.first(liste)}–#{List.last(liste)}"
    end
  end

  # **Ein Befund nennt seine Stelle** (#1247, 25.09.2026, am laufenden Lauf
  # gefunden). Vorher stand nur `text` da; die Adresse trug der Befund bereits
  # (`stellen`, s. `Worker.Timeline.Befunde.mit_stellen/2`) und wurde hier
  # weggeworfen. Jack konnte keinen der sechs Befunde einem Anker zuordnen,
  # hat es aus den Zahlen zurückzurechnen versucht und dabei dreissig Mal
  # denselben Absatz geschrieben.
  #
  # Genannt wird, was für ihn eine Adresse IST: die Zeilennummer seines
  # Mitschnitts, und dazu der gesetzte Ausdruck — nicht die `anker_id`, die
  # für ihn ein Hash ist. Eine Stelle aus einer anderen Sitzung heisst
  # „andere Sitzung", wie bei den Gliedern: Sie ist über Zeilennummern nicht
  # ansprechbar, und ein Strich sagte nicht, warum.
  defp befund_zeile(befund, %Stand{} = s) do
    case stellen_wort(Map.get(befund, :stellen) || [], s) do
      "" -> befund.text
      wo -> "#{wo}: #{befund.text}"
    end
  end

  defp stellen_wort(stellen, %Stand{} = s) do
    stellen
    |> Enum.map(&stelle_wort(&1, s))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp stelle_wort(%{utterance_ids: utts} = stelle, %Stand{mitschnitt: m}) do
    nrs = for u <- utts, z = Enum.find(m, &(&1.utterance_id == u)), do: z.nr

    ort =
      case Enum.sort(nrs) do
        [] -> "andere Sitzung"
        [n] -> "Zeile #{n}"
        liste -> "Zeilen #{List.first(liste)}–#{List.last(liste)}"
      end

    case Map.get(stelle, :wert) do
      w when is_binary(w) and w != "" -> "#{ort} („#{w}“)"
      _ -> ort
    end
  end

  defp stelle_wort(_, _), do: ""

  @befund_deckel 15

  @doc false
  def befunde_zum_zeigen(%Stand{} = s, linie) do
    case Enum.reject(linie.befunde, &MapSet.member?(s.gesehen, &1.id)) do
      [] -> Enum.take(linie.befunde, @befund_deckel)
      offen -> Enum.take(offen, @befund_deckel)
    end
  end

  @doc false
  def gesehene_befunde(%Stand{} = s), do: MapSet.size(s.gesehen)

  defp w_offen(%Stand{} = s, _f) do
    case Abschluss.hindernisse(s) do
      [] -> {s, {:ok, "Nichts steht im Weg — fertig() geht."}}
      h -> {s, {:ok, Enum.map_join(h, "\n", &("- " <> &1))}}
    end
  end

  defp w_zahlen(%Stand{} = s, _f) do
    z = Stand.zahlen(s)

    {s,
     {:ok,
      "Lauf: #{z.lauf}\nZeilen: #{z.utterances}, gelesen #{z.gelesen}, " <>
        "eingeordnet #{z.eingeordnet}, ohne Einordnung #{z.ohne_einordnung}\n" <>
        "Anker: #{z.anker} (Zeitpunkte #{z.zeitpunkte}, Spannen #{z.spannen}, " <>
        "Verschiebungen #{z.verschiebungen})\nGelöst: #{z.geloest}, Konflikte: #{z.konflikte}"}}
  end

  # Die Grundordnung dieses Laufs: der Mitschnitt in seiner Reihenfolge. Die
  # Sitzungsnummer ist hier überall dieselbe — die Linie über die ganze
  # Kampagne baut `Worker.Repo.Zeit`, nicht der Lauf.
  defp stellen(%Stand{mitschnitt: m}) do
    Enum.map(m, &%{utterance_id: &1.utterance_id, session_nr: 1, pos: &1.nr})
  end

  # **Die Kette zeigt Refs, keinen Text** (Maintainer, 20.09.2026:
  # „lies_kette liefert doch die ref — mit der ref kann es sich doch jack
  # holen?"). Sie ist eine Folge von Verweisen auf Äußerungen; wer den
  # Wortlaut braucht, holt ihn mit `lies_sprechlinie(ab: n)`. Vorher trug
  # jede Zeile 60 Zeichen Text mit — dieselbe Auskunft wie das
  # Nachbarwerkzeug, nur abgeschnitten, und die zwei Achsen sahen dadurch
  # gleich aus.
  #
  # **Zwei Spalten, weil es zwei Achsen sind:** der PLATZ in der Kette und
  # die ZEILE in der Sprechlinie. Erst daran ist zu sehen, ob eine
  # Versetzung gewirkt hat — mit nur einer Spalte war die Kette bloss die
  # Reihenfolge der Ausgabe.
  # **Die Kette zeigt GLIEDER, nicht Zeilen** (#1247). Ein Glied ist eine
  # Zeiteinheit aus einer oder mehreren Äußerungen; eine Sitzung mit 2168
  # Zeilen hat vielleicht achtzig davon, und die kann ein Modell
  # überblicken. Den Wortlaut holt es mit `lies_sprechlinie(ab: n)` —
  # deshalb steht hier kein Text (Maintainer, 20.09.2026: „lies_kette
  # liefert doch die ref — mit der ref kann es sich doch jack holen?").
  defp ketten_text(s, linie, glieder, ab, zeigen, gesamt) do
    zeilen =
      Enum.map_join(glieder, "\n", fn {{g, tiefe}, platz} ->
        zeit = zeit_des_gliedes(g, linie, s)
        name = if g[:grund] in [nil, ""], do: "", else: "  #{g.grund}"
        einzug = String.duplicate("  ", tiefe)
        an = if tiefe > 0, do: "↳ ", else: ""

        "Glied #{String.pad_leading(to_string(platz), 4)}  #{einzug}#{an}" <>
          "Zeilen #{String.pad_trailing(spanne_wort(g, s), 12)} #{zeit}#{name}"
      end)

    offen_danach = gesamt - MapSet.size(s.gesehen)

    befunde =
      case zeigen do
        [] ->
          ""

        b ->
          rest =
            cond do
              offen_danach > 0 -> "\n(#{offen_danach} weitere — ruf lies_kette() noch einmal.)"
              gesamt > length(b) -> "\n(#{gesamt} Befunde insgesamt, alle angesehen.)"
              true -> ""
            end

          "\n\nBefunde:\n" <> Enum.map_join(b, "\n", &("- " <> befund_zeile(&1, s))) <> rest
      end

    z = Stand.zahlen(s)

    # **Die Klammer sagt, was die Kampagne ist und was deine Sitzung**
    # (Maintainer, 25.09.2026: „lies_kette() muss über die ganze Kampagne
    # gehen"). Sie mischte drei kampagnenweite Zahlen mit einer eigenen, ohne
    # Kennzeichnung — und Jack hat in zwei Läufen darüber gerätselt, welche
    # seine ist: „1978 lines were outside — hmm, ‚41 Glieder, 6235 Zeilen
    # drin, 1978 draussen'. Wait, total lines across all se…". Er arbeitet an
    # 3.385 Zeilen und bekam Zahlen über 8.213.
    #
    # `unentschieden` bleibt die eigene Zahl, weil sie es sein MUSS: Jack
    # entscheidet nur die Zeilen seiner Sitzung. Sie steht jetzt nur nicht
    # mehr in derselben Aufzählung wie die kampagnenweiten.
    stand =
      "\n(Kampagne: #{z.glieder} Glieder, #{z.in_der_kette} Zeilen drin, " <>
        "#{z.draussen} draussen. Deine Sitzung: #{z.utterances} Zeilen, " <>
        "#{z.unentschieden} unentschieden.)"

    kopf =
      case glieder do
        [] when z.glieder == 0 ->
          "Die Kette ist noch LEER. Reih ein, was zur erzählten Welt gehört " <>
            "(haenge_an_kette), und nimm heraus, was nicht hineingehört " <>
            "(nicht_in_die_kette)."

        [] ->
          "Ab Zeile #{ab} liegt kein Glied mehr in der Kette."

        _ ->
          "Die Kette ab Zeile #{ab}. GLIED ist die Stelle in der zeitlichen " <>
            "Reihenfolge, ZEILEN die Stelle in der Sprechlinie — laufen sie " <>
            "auseinander, ist dort versetzt worden. Den Wortlaut holst du mit " <>
            "lies_sprechlinie(ab: <Zeile>).\n"
      end

    kopf <> zeilen <> stand <> befunde
  end

  # Die Zeit eines Gliedes ist die seiner ersten Äußerung — ein Glied ist
  # eine Zeiteinheit, seine Zeilen teilen sie.
  defp zeit_des_gliedes(glied, linie, s) do
    case Enum.find_value(glied.utts, &linie.nach_utterance[&1]) do
      nil -> "ohne Zeit"
      e -> zeit(e, s.kalender)
    end
  end

  defp zeit(%{minute: nil}, _cal), do: "—        "

  defp zeit(%{minute: m, herkunft: :belegt} = e, cal),
    do: "#{uhr(m, cal)} belegt#{genauigkeit(e.aufloesung)}"

  defp zeit(%{minute: m, herkunft: :fortgeschrieben}, cal), do: "#{uhr(m, cal)} fortgeschrieben"
  defp zeit(%{minute: m} = e, cal), do: "#{uhr(m, cal)} gerechnet (#{e.gewissheit}%)"

  # Wie fein der Ausdruck war — nur bei belegten Zeiten, und nur wenn es
  # gröber als eine Stunde ist: „22:45 belegt" braucht keinen Zusatz,
  # „Ende 2011 belegt" schon.
  defp genauigkeit(nil), do: ""
  defp genauigkeit(u) when u <= 60, do: ""
  defp genauigkeit(u) when u < @minuten_pro_tag, do: " (auf #{div(u, 60)} h genau)"

  defp genauigkeit(u) when u < 60 * @minuten_pro_tag,
    do: " (auf #{div(u, @minuten_pro_tag)} Tage genau)"

  defp genauigkeit(u), do: " (auf #{Float.round(u / (365 * @minuten_pro_tag), 1)} Jahre genau)"

  # **Ein Tageszähler ist für niemanden lesbar** — das ist die #1092-Lehre, und
  # der erste Wurf hat sie hier wiederholt: Für das Jahr 2000 stand in der
  # Linie `T+730000 00:00`. Das Modell konnte die Zahl nicht deuten, riet
  # („the timestamps seem to be in seconds, so T+730000 would be roughly 202
  # hours") und schloss daraus, die Anker seien falsch gemessen. Eine falsch
  # verstandene Zahl ist schlechter als keine Angabe.
  #
  # Gezeigt wird deshalb das DATUM, sobald der Zähler über den ersten Tag
  # hinausgeht, und die Uhrzeit nur dort, wo sie etwas aussagt. Ohne Kalender
  # bleibt es beim relativen `T+n` — dann ist die Linie ohnehin relativ, und
  # ein erfundenes Datum wäre schlimmer.
  defp uhr(m, cal) do
    tag = Integer.floor_div(m, @minuten_pro_tag)
    rest = Integer.mod(m, @minuten_pro_tag)
    h = rest |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    min = rest |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    cond do
      tag == 0 -> "#{h}:#{min}"
      is_nil(cal) -> "T+#{tag} #{h}:#{min}"
      true -> "#{Calendar.format(cal, tag, :day)} #{h}:#{min}"
    end
  end
end
