defmodule Worker.Jack.Chronik.Abschluss do
  @moduledoc """
  `fertig` des Chronik-Jack, je Lauf (J7, #1211). Die Mechanik ist die des
  Resümee-Jack (`Worker.Jack.Resuemee.Abschluss.mit_regeln/3`: Ablehnung mit
  den offenen Punkten, Zahlenabgleich, der dritte Versuch mit falschen Zahlen
  geht durch und die Abweichung steht im Journal), die Regeln sind eigen.

  ## Offen ist das Schreiben, solange

    * **ein ereignisförmiger Fakt in keinem Eintrag liegt.** Das ist die
      zentrale Regel dieses Laufs, und sie ist die Antwort auf die Frage, an
      der eine gebündelte Chronik scheitern kann: „gebündelt" und
      „verschluckt" sehen im Ergebnis gleich aus — zwanzig Einträge statt
      544 sind das Ziel, zwanzig Einträge mit der Hälfte der Fakten darin
      wären ein Verlust. Die Ablehnung nennt die offenen Fakten beim Namen
      (Muster `stationen_ohne_satz` aus J5), damit Jack sie zuordnen kann,
      statt zu suchen.
    * **die Chronik leer ist.** Ein Lauf ohne einen einzigen Eintrag ist
      kein Ergebnis.

  **Zustände zählen nicht mit** — sie werden nicht verlangt. Ein Fakt mit
  `fact_type: "zustand"` ist Weltwissen ohne Zeitpunkt („X ist
  Steuerberater", „das Gebäude hat neun Stockwerke"); als **eigener Eintrag**
  hätte er in einer Zeitleiste nichts zu suchen, das ist der Befund aus #1119
  (49 von 70 Einträgen einer Sitzung waren Zustände). **In** einer Phase ist
  er dagegen oft am richtigen Platz, weil er sie erklärt — Jack entscheidet
  das, der Abschluss erzwingt es nicht.

  Die Formulierung war bis zum 18.09.2026 schärfer („gehört nicht in den
  Zeitstrahl"), und der Maintainer hat sie zu Recht als grenzwertig benannt:
  Ein Zustand hat meist einen Anfang, und das Etikett kommt aus der
  Extraktion, die laufzeit-ungegated ist — ein falsch gelabeltes Geschehen
  fiele damit still heraus. Deshalb ist die Regel jetzt eine über
  **Einträge**, nicht über Zugehörigkeit.

  ## Was hier NICHT geprüft wird

  **Ob ein Einschnitt in einer Phase verschluckt wurde.** Der Maintainer hat
  das ausdrücklich als Anweisung an Jack bestimmt, nicht als Prüfung im Code:
  Der Fakt-Typ `zustandsänderung` ist zu fein (jede Verletzung, jede
  geöffnete Tür trägt ihn), und ein Wortabgleich auf Todesfälle wäre das
  Verfahren, das in #1109 abgeschaltet wurde, weil ein einzelner Falschtreffer
  zur bindenden Aussage wird. Die Regel steht im Auftrag, mit Beispielen.

  **Die Reihenfolge.** Ein Zyklus in den Bezügen ist ein Befund für die
  Durchsicht (`Worker.Jack.Chronik.Ordnung`), kein Grund, den Abschluss zu
  verweigern — Jack soll ihn auflösen, wenn er den ganzen Graphen sieht,
  nicht beim einzelnen Aufruf.
  """

  alias Worker.Jack.Chronik.{Entwurf, Notizen}
  alias Worker.Jack.Resuemee.Abschluss, as: Mechanik
  alias Worker.Jack.Resuemee.Stand

  @zahlen_ueberblick ~w(gruppen fakten_zugeordnet)
  @zahlen_schreiben ~w(eintraege fakten_zugeordnet)
  @zahlen_durchsicht ~w(bestaetigt ersetzt)

  @doc """
  Die offenen Punkte des Schreibens: ereignisförmige Fakten ohne Eintrag und
  die leere Chronik.
  """
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{lauf: :ueberblick} = s) do
    offen = kurz(s, offene_geschehen(s))

    cond do
      Notizen.gruppen(s) == [] ->
        [
          "Du hast noch keinen Abschnitt notiert. Trag mit notiz() unter PHASEN ein, " <>
            "welche Abschnitte der Handlung du siehst — ein ganzer Auftrag von der Annahme " <>
            "bis zur Abrechnung ist EINE Phase."
        ]

      offen != [] ->
        [
          "Diese #{length(offen)} Fakten liegen in keiner Gruppe: #{liste(offen)}. " <>
            "Jedes Geschehen muss vertreten sein — das heisst nicht, dass es eine eigene " <>
            "Phase bekommt: Nimm es in die Phase auf, zu der es gehört (denselben " <>
            "Schlüssel erneut schreiben ersetzt den Eintrag), oder leg die fehlende Phase " <>
            "an. Dauerhafte Zustände stehen nicht in dieser Liste — sie werden nicht " <>
            "verlangt; in eine Phase dürfen sie, wenn sie zu ihr beitragen."
        ]

      true ->
        []
    end
  end

  def hindernisse(%Stand{} = s) do
    offen = offene(s)

    cond do
      s.eintraege == [] ->
        [
          "Die Chronik hat noch keinen Eintrag. Lege mit chronik_eintrag() die " <>
            "Abschnitte der Handlung an — ein ganzer Auftrag von der Annahme bis zur " <>
            "Abrechnung ist EIN Eintrag."
        ]

      offen != [] ->
        [
          "Diese #{length(offen)} Fakten liegen in keinem Eintrag: #{liste(kurz(s, offen))}. " <>
            "Jedes Geschehen muss vertreten sein — das heisst nicht, dass es einen " <>
            "eigenen Eintrag bekommt: Nimm es in die Phase auf, zu der es gehört " <>
            "(eintrag_ergaenzen), oder lege die fehlende Phase an. Dauerhafte " <>
            "Zustände stehen nicht in dieser Liste — sie werden nicht verlangt; in eine " <>
            "Phase dürfen sie, wenn sie zu ihr beitragen."
        ]

      true ->
        []
    end
  end

  @doc """
  Die offenen Geschehen des Laufs, in dem der Stand steht — die EINE Stelle,
  die weiss, wogegen geprüft wird: im **Überblick** gegen die Notizen (dort
  gibt es keine Einträge), beim **Schreiben** und in der **Verfeinerung**
  gegen die Einträge. Begründet Ausgeschlossenes zählt nie mit.

  Beide Verwechslungen sind schon passiert: der Überblick prüfte gegen
  Einträge und konnte nie abschliessen, und der Reststand an den
  Schreib-Werkzeugen prüfte gegen Notizen und nannte den eben eingetragenen
  Fakt als offen (beides 18.09.2026).
  """
  @spec offene(Stand.t()) :: [String.t()]
  def offene(%Stand{lauf: :ueberblick} = s), do: offene_geschehen(s)

  def offene(%Stand{} = s),
    do: Entwurf.offene_fakten(s.eintraege, ereignisse(s) -- ausserhalb(s))

  @doc """
  Die ereignisförmigen Fakten, die im Überblick in keiner Gruppe liegen.
  Dieselbe Grundmenge wie beim Schreiben (`ereignisse/1`), nur gegen die
  Notizen statt gegen die Einträge geprüft — im Überblick gibt es noch keine
  Einträge, und genau diese Verwechslung liess `fertig()` dort bis #1211
  ausnahmslos ablehnen.
  """
  @spec offene_geschehen(Stand.t()) :: [String.t()]
  def offene_geschehen(%Stand{} = s) do
    behandelt = MapSet.new(Notizen.gruppiert(s) ++ Notizen.ausgeschlossen(s))
    for id <- ereignisse(s), not MapSet.member?(behandelt, id), do: id
  end

  @doc """
  Die ereignisförmigen Fakten — alles ausser `zustand`. Öffentlich, weil die
  Trichter-Messung (#1111) dieselbe Grundmenge braucht: Was hier nicht
  drinsteht, kann auch nicht verschluckt werden.
  """
  @spec ereignisse(Stand.t()) :: [String.t()]
  def ereignisse(%Stand{fakten: fakten}),
    do: for(f <- fakten, Map.get(f, :typ) != "zustand", do: f.fakt_id)

  @doc """
  Die ereignisförmigen Fakten, die Jack begründet aus der Zeitleiste
  herausgehalten hat (Notiz-Abschnitt NICHT_ZEITLEISTE) — echte IDs. Sie
  gelten als behandelt, ohne ein Eintrag zu sein, und der Trichter zählt sie
  getrennt: „bewusst draussen" ist etwas anderes als „verschluckt".
  """
  @spec ausserhalb(Stand.t()) :: [String.t()]
  def ausserhalb(%Stand{} = s) do
    ereignisse = MapSet.new(ereignisse(s))
    for id <- Notizen.ausgeschlossen(s), MapSet.member?(ereignisse, id), do: id
  end

  @doc "Die Zahlen, die `fertig` im Überblick verlangt."
  @spec zahlen_ueberblick() :: [String.t()]
  def zahlen_ueberblick, do: @zahlen_ueberblick

  @doc """
  Die Ist-Zahlen des Überblicks für den Abgleich: wie viele Gruppen stehen,
  und wie viele Geschehen in ihnen aufgehen.
  """
  @spec ist_ueberblick(Stand.t()) :: map()
  def ist_ueberblick(%Stand{} = s) do
    ereignisse = ereignisse(s)

    %{
      "gruppen" => length(Notizen.gruppen(s)),
      "fakten_zugeordnet" => length(ereignisse) - length(offene_geschehen(s))
    }
  end

  @doc "Die Zahlen, die `fertig` im Schreiben verlangt."
  @spec zahlen_schreiben() :: [String.t()]
  def zahlen_schreiben, do: @zahlen_schreiben

  @doc "Die Zahlen, die `fertig` in der Durchsicht verlangt."
  @spec zahlen_durchsicht() :: [String.t()]
  def zahlen_durchsicht, do: @zahlen_durchsicht

  @doc """
  Die Ist-Zahlen des Schreibens für den Abgleich: wie viele Einträge stehen,
  und wie viele ereignisförmige Fakten in ihnen aufgehen.
  """
  @spec ist_schreiben(Stand.t()) :: map()
  def ist_schreiben(%Stand{} = s) do
    ereignisse = ereignisse(s) -- ausserhalb(s)
    offen = offene(s)

    %{
      "eintraege" => length(s.eintraege),
      "fakten_zugeordnet" => length(ereignisse) - length(offen)
    }
  end

  @doc """
  Die Messzeile des Trichters (#1111): was hineinging, was herauskam, und wo
  der Rest blieb. Ohne sie ist „gebündelt" von „verschluckt" nicht zu
  unterscheiden — genau der Zustand, in dem wochenlang „16 → 175 Einträge"
  als belegter Erfolg in der Doku stand, während die Wirkung null war.
  """
  @spec trichter(Stand.t()) :: map()
  def trichter(%Stand{} = s) do
    ereignisse = ereignisse(s)
    ausserhalb = ausserhalb(s)
    offen = Entwurf.offene_fakten(s.eintraege, ereignisse -- ausserhalb)
    {phasen, szenen} = Enum.split_with(s.eintraege, &(&1.wichtigkeit == "phase"))

    ordnung =
      case Entwurf.ordnen(s.eintraege) do
        {:ok, %{verwaist: v}} -> %{"zyklen" => 0, "verwaiste_bezuege" => length(v)}
        {:zyklus, ids} -> %{"zyklen" => length(ids), "verwaiste_bezuege" => 0}
      end

    Map.merge(
      %{
        "fakten_gesamt" => length(s.fakten),
        "fakten_ereignis" => length(ereignisse),
        "fakten_zustand" => length(s.fakten) - length(ereignisse),
        "fakten_ohne_eintrag" => length(offen),
        "fakten_ausserhalb" => length(ausserhalb),
        "eintraege" => length(s.eintraege),
        "phasen" => length(phasen),
        "schluesselszenen" => length(szenen),
        "bestand_vorher" => length(s.chronik)
      },
      ordnung
    )
  end

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{lauf: :durchsicht}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet die Durchsicht als abgeschlossen — der EINZIGE gültige Abschluss. Ein " <>
            "Satz in der letzten Nachricht zählt nicht. Das Werkzeug LEHNT AB, solange im " <>
            "laufenden Durchgang ein Eintrag weder bestätigt noch ersetzt ist; in der " <>
            "Ablehnung steht, welche. Erwartete Zahlen: bestaetigt und ersetzt, über alle " <>
            "Durchgänge. Deine Zahlen und die Buchhaltung werden verglichen.",
        parameter: schema(@zahlen_durchsicht),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  def werkzeuge(%Stand{lauf: :ueberblick}) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Meldet den Überblick als abgeschlossen — der EINZIGE gültige Abschluss. Ein Satz " <>
            "in der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange ein Geschehen in keiner Gruppe liegt; in der Ablehnung stehen die " <>
            "Fakten beim Namen. Dauerhafte Zustände zählen nicht mit — sie gehören nicht in " <>
            "den Zeitstrahl. Erwartete Zahlen: gruppen (deine Phasen und Schlüsselszenen " <>
            "zusammen) und fakten_zugeordnet (Geschehen, die in einer Gruppe aufgehen). " <>
            "Deine Zahlen und die Buchhaltung werden verglichen.",
        parameter: schema(@zahlen_ueberblick),
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
          "Meldet die Chronik als geschrieben — der EINZIGE gültige Abschluss. Ein Satz in " <>
            "der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange ein Geschehen in keinem Eintrag liegt; in der Ablehnung stehen die " <>
            "Fakten beim Namen. Dauerhafte Zustände zählen nicht mit — sie werden nicht " <>
            "verlangt. Erwartete Zahlen: eintraege (Einträge der Chronik) und " <>
            "fakten_zugeordnet (Geschehen, die in einem Eintrag aufgehen). Deine Zahlen " <>
            "und die Buchhaltung werden verglichen.",
        parameter: schema(@zahlen_schreiben),
        wiederholung: :frei,
        ausfuehren: &fertig/2
      }
    ]
  end

  @doc "Die Parameter von `fertig`: die Zahlen des Laufs und `offen_geblieben`."
  @spec schema([String.t()]) :: map()
  def schema(zahlen) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(zahlen, &{&1, %{"type" => "integer"}})
        |> Map.put("offen_geblieben", %{"type" => "string"}),
      "required" => zahlen ++ ["offen_geblieben"]
    }
  end

  @doc """
  `fertig` selbst: die Regeln dieses Laufs an die geteilte Mechanik
  (`Worker.Jack.Resuemee.Abschluss.mit_regeln/3`).
  """
  @spec fertig(Stand.t(), map()) :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}
  def fertig(%Stand{lauf: :durchsicht} = s, p) do
    Mechanik.mit_regeln(s, p, %{
      hindernisse: Worker.Jack.Resuemee.Abschluss.hindernisse(s, p),
      zahlen: @zahlen_durchsicht,
      ist: %{},
      weg: fn _ -> nil end,
      abschluss: fn stand, eintrag -> {stand, eintrag} end
    })
  end

  def fertig(%Stand{lauf: :ueberblick} = s, p) do
    Mechanik.mit_regeln(s, p, %{
      hindernisse: hindernisse(s),
      zahlen: @zahlen_ueberblick,
      ist: ist_ueberblick(s),
      weg: fn stand -> "#{length(Notizen.gruppen(stand))} Gruppen" end,
      abschluss: fn stand, eintrag -> {stand, eintrag} end
    })
  end

  def fertig(%Stand{} = s, p) do
    Mechanik.mit_regeln(s, p, %{
      hindernisse: hindernisse(s),
      zahlen: @zahlen_schreiben,
      ist: ist_schreiben(s),
      weg: fn stand -> "#{length(stand.eintraege)} Einträge" end,
      abschluss: fn stand, eintrag ->
        # Issue #1111: der Trichter kommt ins Journal — ohne ihn ist
        # „gebündelt" von „verschluckt" nicht zu unterscheiden.
        {stand, Map.put(eintrag, "trichter", trichter(stand))}
      end
    })
  end

  # Echte IDs zurück in die kurzen, die fakten() dem Modell zeigt.
  defp kurz(%Stand{fakten: fakten}, echte) do
    karte = Map.new(fakten, &{&1.fakt_id, &1.id})
    Enum.map(echte, &Map.get(karte, &1, &1))
  end

  defp liste(ids) when length(ids) <= 12, do: Enum.join(ids, ", ")

  defp liste(ids),
    do: (ids |> Enum.take(12) |> Enum.join(", ")) <> " und #{length(ids) - 12} weitere"
end
