defmodule Worker.Jack.Chronik.Abschluss do
  @moduledoc """
  `fertig` des Chronik-Jack, je Lauf (J7, #1211). Die Mechanik ist die des
  Resümee-Jack (`Worker.Jack.Resuemee.Abschluss.mit_regeln/3`: Ablehnung mit
  den offenen Punkten, Zahlenabgleich, der dritte Versuch mit falschen Zahlen
  geht durch und die Abweichung steht im Journal), die Regeln sind eigen.

  ## Gepflichtet ist die BEWERTUNG, nicht die Zuordnung

  **Jeder Fakt muss angeschaut und entschieden sein** — entweder liegt er in
  einem Eintrag, oder er steht begründet unter NICHT_ZEITLEISTE. Was dabei
  herauskommt, ist frei: Landen alle unter NICHT_ZEITLEISTE, ist das ein
  gültiges Ergebnis (Maintainer, 18.09.2026: „es darf keine pflicht geben —
  pflicht ist das sie bewertet werden — also jedes ding anschauen — und wenn
  alle NICHT_ZEITLEISTE sind — dann ist das ok").

  **Das gilt für ALLE Fakten, auch für Zustände.** Die frühere Regel nahm
  Fakten mit `fact_type: "zustand"` von der Prüfung aus; an echten Daten war
  das die Mehrheit (85 von 112 an seattleV5 S1), und damit entschied ein
  Extraktions-Etikett darüber, was die Zeitleiste überhaupt sehen darf —
  laufzeit-ungegated, von niemandem geprüft, und Jack hat es selbst mehrfach
  angezweifelt. Jetzt sieht er jeden Fakt und entscheidet; das Etikett ist
  ein Hinweis, kein Filter.

  Warum die Bewertungspflicht überhaupt: „gebündelt" und „verschluckt" sehen
  im Ergebnis gleich aus — zwanzig Einträge statt 544 sind das Ziel, zwanzig
  Einträge mit der Hälfte der Fakten darin wären ein Verlust. Ein Fakt, den
  niemand angeschaut hat, ist der Unterschied. Die Ablehnung nennt die
  unbewerteten beim Namen (Muster `stationen_ohne_satz` aus J5), damit Jack
  sie entscheiden kann, statt zu suchen.

  Offen ist ein Lauf ausserdem, solange **die Chronik leer ist** — ein Lauf
  ohne einen einzigen Eintrag ist kein Ergebnis.

  **Kein eigener Eintrag für einen dauerhaften Zustand** — das ist der
  Befund aus #1119 (49 von 70 Einträgen einer Sitzung waren Zustände), und er
  bleibt eine Regel über die Flughöhe, nicht über die Bewertung: Ein Zustand
  darf in einer Phase aufgehen, wenn er sie erklärt, und unter
  NICHT_ZEITLEISTE, wenn er nirgends hingehört. Beides ist eine Entscheidung
  und zählt als Bewertung.

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

  alias Worker.Jack.Chronik.{Durchsicht, Entwurf, Notizen}
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
      # „Nichts notiert" heisst nichts BEWERTET — nicht „keine Phase". Stellt
      # Jack alle Fakten begründet unter NICHT_ZEITLEISTE, ist der Überblick
      # fertig, auch ohne eine einzige Phase (Maintainer, 18.09.2026: „wenn
      # alle NICHT_ZEITLEISTE sind — dann ist das ok"). Eine Sitzung, die nur
      # am Tisch stattfand, hat keine Chronik, und das ist eine Aussage.
      Notizen.gruppen(s) == [] and Notizen.ausgeschlossen(s) == [] ->
        [
          "Du hast noch nichts notiert. Trag mit notiz() ein, welche Abschnitte der " <>
            "Handlung du siehst (PHASEN) — ein ganzer Auftrag von der Annahme bis zur " <>
            "Abrechnung ist EINE Phase. Was in keine Zeitleiste gehört, kommt mit " <>
            "Begründung unter NICHT_ZEITLEISTE."
        ]

      offen != [] ->
        [
          "Diese #{length(offen)} Fakten hast du noch nicht bewertet: #{liste(offen)}. " <>
            "Jeder Fakt braucht eine Entscheidung — aber keine bestimmte: Nimm ihn in die " <>
            "Gruppe auf, zu der er gehört (denselben Schlüssel erneut schreiben ersetzt " <>
            "den Eintrag), leg die fehlende Gruppe an, oder stell ihn mit Begründung " <>
            "unter NICHT_ZEITLEISTE. Auch „gehört nicht in die Zeitleiste\" ist eine " <>
            "Bewertung. offen() zeigt sie mit ihrer Aussage."
        ]

      true ->
        []
    end
  end

  def hindernisse(%Stand{} = s) do
    offen = offene(s)

    cond do
      # Eine leere Chronik ist nur dann kein Ergebnis, wenn auch nichts
      # bewertet wurde. Stehen alle Fakten begründet unter NICHT_ZEITLEISTE,
      # bleibt die Chronik zu Recht leer (Maintainer, 18.09.2026).
      s.eintraege == [] and Notizen.ausgeschlossen(s) == [] ->
        [
          "Die Chronik hat noch keinen Eintrag. Lege mit chronik_eintrag() die " <>
            "Abschnitte der Handlung an — ein ganzer Auftrag von der Annahme bis zur " <>
            "Abrechnung ist EIN Eintrag. Was in keine Zeitleiste gehört, kommt mit " <>
            "notiz() unter NICHT_ZEITLEISTE."
        ]

      offen != [] ->
        [
          "Diese #{length(offen)} Fakten hast du noch nicht bewertet: #{liste(kurz(s, offen))}. " <>
            "Jeder Fakt braucht eine Entscheidung — aber keine bestimmte: Nimm ihn in die " <>
            "Phase auf, zu der er gehört (eintrag_ergaenzen), lege die fehlende Phase an, " <>
            "oder stell ihn mit notiz() und Begründung unter NICHT_ZEITLEISTE. Auch " <>
            "„gehört nicht in die Zeitleiste\" ist eine Bewertung. offen() zeigt sie mit " <>
            "ihrer Aussage."
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
    do: Entwurf.offene_fakten(s.eintraege, alle_fakten(s) -- Notizen.ausgeschlossen(s))

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
    for id <- alle_fakten(s), not MapSet.member?(behandelt, id), do: id
  end

  @doc "Die echten IDs aller Fakten — die Menge, die bewertet werden muss."
  @spec alle_fakten(Stand.t()) :: [String.t()]
  def alle_fakten(%Stand{fakten: fakten}), do: Enum.map(fakten, & &1.fakt_id)

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
    bekannt = MapSet.new(alle_fakten(s))
    for id <- Notizen.ausgeschlossen(s), MapSet.member?(bekannt, id), do: id
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
    %{
      "gruppen" => length(Notizen.gruppen(s)),
      "fakten_zugeordnet" => length(Notizen.gruppiert(s))
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
    zu_bewerten = alle_fakten(s) -- ausserhalb(s)

    %{
      "eintraege" => length(s.eintraege),
      "fakten_zugeordnet" => length(zu_bewerten) - length(offene(s))
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

  @doc """
  Das Werkzeug `zahlen` — die Zähler des Laufs, damit Jack sie nicht selbst
  zählen muss.

  **Warum** (Maintainer, 18.09.2026: „jack zählt ständig verschiedene sachen —
  könnten wir ihm dafür tools geben?"): `fertig` verlangt Zahlen als Quittung,
  und Jack hat sie in **jedem** der drei Läufe falsch gezählt — 108 statt 27
  bewertete Fakten, 9 statt 8 Gruppen, dazu die Durchsicht. Jede Fehlzahl
  kostet eine Runde, und in einem Fall schickte sie ihn ins Nachzählen von
  112 Fakten.

  **Was das für den Zahlenabgleich bedeutet, ehrlich gesagt:** Er ist damit
  keine Selbstprüfung mehr, sondern eine Bestätigung — Jack kann die Zahlen
  ablesen. Das ist gewollt: Geprüft wird inhaltlich über die **Hindernisse**
  (welcher Fakt ist unbewertet, welcher Eintrag noch nicht durchgesehen), und
  die sind deterministisch. Der Abgleich hat in drei Läufen keinen einzigen
  inhaltlichen Fehler gefunden, aber vier Runden gekostet.
  """
  @spec zahlen_werkzeug(Stand.t()) :: map()
  def zahlen_werkzeug(%Stand{lauf: lauf}) do
    %{
      name: "zahlen",
      beschreibung:
        "Nennt die Zähler dieses Laufs — genau die, die fertig() als Quittung verlangt, " <>
          "und dazu den Zusammenhang. Lies sie hier ab, statt selbst zu zählen: " <>
          case lauf do
            :ueberblick ->
              "gruppen (Phasen und Schlüsselszenen zusammen) und fakten_zugeordnet."

            :durchsicht ->
              "bestaetigt und ersetzt."

            _ ->
              "eintraege und fakten_zugeordnet."
          end,
      parameter: %{"type" => "object", "properties" => %{}},
      wiederholung: :bis_aenderung,
      ausfuehren: fn s, _p -> {s, {:ok, zahlen_text(s)}} end
    }
  end

  @doc "Die Zähler eines Laufs als Antwort, mit den Zahlen von `fertig` obenan."
  @spec zahlen_text(Stand.t()) :: map()
  def zahlen_text(%Stand{lauf: :ueberblick} = s) do
    {phasen, szenen} = Enum.split_with(Notizen.gruppen(s), &(&1.abschnitt == "PHASEN"))

    Worker.Jack.Antwort.geordnet([
      {"fuer_fertig", ist_ueberblick(s)},
      {"phasen", length(phasen)},
      {"schluesselszenen", length(szenen)},
      {"fakten_gesamt", length(s.fakten)},
      {"fakten_ausserhalb", length(ausserhalb(s))},
      {"fakten_unbewertet", length(offene(s))},
      {"gelesen", MapSet.size(s.gelesen)}
    ])
  end

  def zahlen_text(%Stand{lauf: :durchsicht} = s) do
    Worker.Jack.Antwort.geordnet([
      {"fuer_fertig", Durchsicht.zaehler(s)},
      {"durchgang", Durchsicht.durchgang(s)},
      {"eintraege", length(s.eintraege)},
      {"noch_offen", Durchsicht.offen(s)}
    ])
  end

  def zahlen_text(%Stand{} = s) do
    {phasen, szenen} = Enum.split_with(s.eintraege, &(&1.wichtigkeit == "phase"))

    Worker.Jack.Antwort.geordnet([
      {"fuer_fertig", ist_schreiben(s)},
      {"phasen", length(phasen)},
      {"schluesselszenen", length(szenen)},
      {"fakten_gesamt", length(s.fakten)},
      {"fakten_ausserhalb", length(ausserhalb(s))},
      {"fakten_unbewertet", length(offene(s))}
    ])
  end

  @doc "Das Werkzeug `fertig` für einen Stand, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{lauf: :durchsicht} = s) do
    [
      zahlen_werkzeug(s),
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

  def werkzeuge(%Stand{lauf: :ueberblick} = s) do
    [
      zahlen_werkzeug(s),
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

  def werkzeuge(%Stand{} = s) do
    [
      zahlen_werkzeug(s),
      %{
        name: "fertig",
        beschreibung:
          "Meldet die Chronik als geschrieben — der EINZIGE gültige Abschluss. Ein Satz in " <>
            "der letzten Nachricht zählt nicht. Das Werkzeug rechnet nach und LEHNT AB, " <>
            "solange ein Fakt unbewertet ist; in der Ablehnung stehen sie beim Namen. " <>
            "Bewertet heisst: in einem Eintrag ODER begründet unter NICHT_ZEITLEISTE. " <>
            "Erwartete Zahlen: eintraege (Einträge der Chronik) und " <>
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
        |> Map.put("offen_geblieben", %{
          "type" => "string",
          # `minLength: 0` wie beim Resümee-Jack: Blieb nichts offen, ist die
          # leere Angabe die wahre. Ohne das lehnte das strenge Schema sie ab
          # („mindestens 1 Zeichen, erhalten 0"), und Jack musste sich etwas
          # ausdenken — eine Runde für nichts (18.09.2026 im Lauf gesehen).
          "minLength" => 0,
          "description" => "was offen geblieben ist — in Worten; leer, wenn nichts offen ist"
        }),
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
      hindernisse: hindernisse_durchsicht(s),
      zahlen: @zahlen_durchsicht,
      ist: Durchsicht.zaehler(s),
      weg: fn stand -> "Durchgang #{Durchsicht.durchgang(stand)}" end,
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

  @doc """
  Die offenen Punkte der Durchsicht: Einträge, die im laufenden Durchgang
  weder bestätigt noch ersetzt sind.

  **Eigene Funktion, nicht die des Resümee-Jack** — dessen
  `hindernisse/2` liest `s.durchsicht.absaetze`, was es hier nicht gibt; der
  Abschluss war damit unerreichbar (s. `Worker.Jack.Chronik.Durchsicht.offen/1`).
  """
  @spec hindernisse_durchsicht(Stand.t()) :: [String.t()]
  def hindernisse_durchsicht(%Stand{} = s) do
    case Durchsicht.offen(s) do
      [] ->
        []

      offen ->
        [
          "In Durchgang #{Durchsicht.durchgang(s)} sind diese Einträge noch offen: " <>
            "#{Enum.join(offen, ", ")}. Leg jeden mit durchsicht(nummer) vor und bestätige " <>
            "oder ersetze ihn."
        ]
    end
  end

  defp liste(ids) when length(ids) <= 12, do: Enum.join(ids, ", ")

  defp liste(ids),
    do: (ids |> Enum.take(12) |> Enum.join(", ")) <> " und #{length(ids) - 12} weitere"
end
