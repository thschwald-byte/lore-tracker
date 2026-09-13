defmodule Worker.Jack.Epos do
  @moduledoc """
  Jack schreibt das Epos-Kapitel einer Sitzung (J6, #1210, Epic #1195) — die
  Ablaufsteuerung. **Priorität ist ein guter, schön zu lesender Text**,
  deutlich stärker nach der Stilvorgabe aus „Stil setzen“ (Grundton,
  Epos-Ton, Überschrift der Epos-Spalte) als beim Resümee, mit mehr
  erzählerischer Freiheit. „Handlung treu, Erzählweise frei“ bleibt: Figuren,
  Orte, Ereignisse und Ausgänge kommen aus den Fakten.

  Gebaut in Schritten (#1210, Kommentar 1): E1 Überblick, E2 Schreiben,
  E3 Durchsicht (alle drei hier), **E4 Einbau in die Pipeline**
  (`Worker.Jack.Epos.Pipeline`: an der Stelle der früheren Stufe
  `render_epos`, drei Laufband-Stufen, `epos_jack_model`,
  `JackEposStandAbgelegt`), E5 Test auf der Teststage.

  **Lauf 1, Überblick** (`laufen_ueberblick/2`, `ueberblick/2`): Jack liest
  zuerst den Stil, dann alle Fakten der Sitzung, prüft den **Weg aus dem
  Resümee** (`resuemee()`, `Worker.Jack.Epos.Weg`) gegen die Fakten und stellt
  seine **eigenen SZENEN** auf — ohne Obergrenze für ihre Zahl (Maintainer,
  13.09.2026). Notiert wird unter FORM (Form aus der Überschrift,
  Erzählhaltung aus dem Epos-Ton), SZENEN, ABWEICHUNG (warum eine Station
  anders erzählt oder weggelassen wird) und OFFEN (`Worker.Jack.Epos.Notizen`).
  `fertig` schließt erst ab, wenn alle Fakten gelesen sind, FORM und SZENEN
  stehen und jede Station des Wegs in einer Szene oder unter ABWEICHUNG steht
  (`Worker.Jack.Epos.Abschluss`). Was Lauf 2 davon bekommt, ist
  `Worker.Jack.Resuemee.Stand.ablage/1` — dieselbe Form wie beim Resümee, mit
  den Abschnitten des Epos.

  **Lauf 2, Schreiben** (`laufen_schreiben/3`): ein frischer Lauf ohne
  Erinnerung an den Überblick. Jack bekommt **zuerst den Stil** — Überschrift,
  Grundton, Epos-Ton und seine FORM-Notiz —, dann seine Szenen (SZENEN,
  ABWEICHUNG, OFFEN), dann die Aufgabe, und **erzählt das Kapitel frei**,
  Absatz für Absatz (`Worker.Jack.Epos.Entwurf`). Maintainer, 13.09.2026: der
  Epos-Jack schreibt frei — keine Prüfung je Satz, keine Fakten je Satz, keine
  Markierungen, keine Länge des Kapitels, keine Pflicht, jede Szene zu
  erzählen. Ein Absatz nennt optional die Szene, die er erzählt; über sie
  führt der Weg zu den Fakten (`Worker.Jack.Epos.Ergebnis.quellen/1`, für die
  Quellen im Einbau). `fertig` lehnt nur ein Kapitel ohne Absatz ab und
  gleicht die Zahl der Absätze ab. Heraus kommt das Kapitel als Markdown
  (`Worker.Jack.Epos.Ergebnis.markdown/1`) — **ohne Kapitelkopf**: Nummer und
  Datum bleiben deterministisch in der Pipeline (#752); sie setzt den Kopf
  davor (`Worker.Jack.Epos.Pipeline.kopf/3`).

  **Lauf 3, Durchsicht** (`laufen_durchsicht/4`): wieder ein frischer Lauf.
  Jack bekommt den Stil samt FORM, seine Szenen und sein Kapitel und liest es
  Absatz für Absatz (`Worker.Jack.Epos.Durchsicht`). Anders als beim Resümee
  ist die Durchsicht **auch stilistisch beauftragt** (Maintainer,
  13.09.2026): Lesefluss, Rhythmus, Wiederholungen, Ton nach der FORM,
  Übergänge zwischen den Szenen, Anschluss an das vorige Kapitel — dazu grobe
  Schnitzer gegen die Fakten. Jede Ersetzung braucht einen Grund, ein
  gelungener Absatz bleibt; Hinweise auf großgeschriebene Wörter ohne
  Fundstelle (`Worker.Jack.Epos.Hinweise`) sind ein Fingerzeig, nie eine
  Ablehnung.

  Alle drei Läufe lesen alle früheren Daten (E0-Lesebasis, #1210
  Kommentar 4). `laufen/2` fährt sie nacheinander auf derselben Eingabe,
  `kapitel/2` dasselbe für eine Sitzung aus dem Repo. **Scheitert die
  Durchsicht, gilt das Kapitel aus dem Schreiben** — sie darf das Kapitel
  nicht verhindern.

  **Was geteilt ist.** Der Epos-Jack nutzt die Teile des Resümee-Jack, die
  nicht einschränken: den Stand (mit `art: :epos`), die Lesebasis (Lesen,
  Suche, Bisher, Mitschnitte), den Halter, die Laufmechanik
  (`Worker.Jack.Resuemee.Lauf`), die Mechanik von `notiz` und `fertig`
  (`Worker.Jack.Resuemee.Notizen.eintragen/3`,
  `Worker.Jack.Resuemee.Abschluss.mit_regeln/3`), die Werkzeug-Hülle
  (`Worker.Jack.Resuemee.Werkzeuge.aus/3`), den Rückruf der Kompaktierung, die
  Spanne der Blocknummern (`Worker.Jack.Resuemee.Weg.spanne/2`) und das
  Markdown eines Absatzes (`Worker.Jack.Resuemee.Ergebnis.absatz_markdown/2`).
  Wo ein gemeinsames Modul dem Modell etwas über „das Resümee“ sagt, richtet
  es sich nach `art`; für den Resümee-Jack bleibt es byte-gleich. Eigen sind
  Eingabe, Notiz-Abschnitte, Abschluss-Regeln, der Entwurf aus freien
  Absätzen, das Ergebnis, die Vorlagen, die Zusammenfassung und diese
  Ablaufsteuerung. **Die gemeinsamen Teile in einen neutralen Namensraum zu
  verschieben ist ein eigener Schritt.**

  **Wie beim Resümee-Jack:** dieselben Einstellungen wie Jack (Endpunkt,
  Regler, Kontextfenster; ohne `:modell` hier `Worker.Jack.Pipeline.modell/0`,
  in der Pipeline das eigens wählbare `epos_jack_model`,
  `Worker.Jack.Epos.Pipeline.modell/0`), dieselbe Kompaktierung mit einem
  Arbeitsstand aus den Werkzeugen (`Worker.Jack.Epos.Zusammenfassung`),
  derselbe Systemprompt, dasselbe Nachhaken, der Auftrag angeheftet. Ein
  `:stand_beobachter` bekommt das Abbild mit `"jack" => "epos"`
  (`Worker.Jack.Epos.Notizen.abbild/1`), als `{:jack_resuemee_stand, abbild}`
  — die Nachricht des gemeinsamen Halters. Die Laufsicht (`Worker.Jack.Sicht`)
  zeigt die Läufe an dieser Marke in einer eigenen Ansicht, der Melder des
  Laufbands zählt aus demselben Abbild (`:melde_stufe`, `laufen/2`).

  Die Aufträge kommen aus `priv/jack/auftraege/epos_ueberblick.md`
  (`auftrag/2`), `epos_schreiben.md` (`auftrag_schreiben/3`) und
  `epos_durchsicht.md` (`auftrag_durchsicht/4`).
  """

  require Logger

  alias Worker.Jack.Epos.{Durchsicht, Eingabe, Entwurf, Ergebnis, Notizen, Werkzeuge}
  alias Worker.Jack.Epos.Zusammenfassung
  alias Worker.Jack.Resuemee.{Lauf, Melder, Stand}

  # Die Stufennamen des Laufbands (`Shared.PipelineStufen`). Das Schreiben
  # heißt „render_epos“, weil `/admin/errors` und die Spalten-Anzeige daran
  # hängen.
  @stufe_ueberblick "epos_ueberblick"
  @stufe_schreiben "render_epos"
  @stufe_durchsicht "epos_durchsicht"

  @vorlage_ueberblick "epos_ueberblick.md"
  @vorlage_schreiben "epos_schreiben.md"
  @vorlage_durchsicht "epos_durchsicht.md"
  @keine_form "Aus dem Überblick liegt keine FORM vor. Leite die Form des Kapitels aus der " <>
                "Überschrift und seine Erzählhaltung aus dem Ton ab."
  @keine_szenen "(Aus dem Überblick liegen keine Szenen vor. Erzähl den Weg der Gruppe durch " <>
                  "die Sitzung, wie die Fakten ihn zeigen.)"

  @doc """
  Der Überblick für eine Sitzung aus dem Repo: `Worker.Jack.Epos.Eingabe.aus_repo/1`,
  dann `laufen_ueberblick/2` mit denselben Optionen.
  """
  @spec ueberblick(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ueberblick(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen_ueberblick(e, opts)
  end

  @doc """
  Überblick, Schreiben und Durchsicht für eine Sitzung aus dem Repo:
  `Worker.Jack.Epos.Eingabe.aus_repo/1` einmal, dann `laufen/2` mit denselben
  Optionen.
  """
  @spec kapitel(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def kapitel(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen(e, opts)
  end

  @doc """
  Überblick, Schreiben und Durchsicht nacheinander auf derselben Eingabe:
  Schreiben und Durchsicht bekommen die Ablage des Überblicks
  (`Worker.Jack.Resuemee.Stand.ablage/1`), die Durchsicht dazu das Kapitel
  des Schreibens. Optionen wie `laufen_ueberblick/2`, für alle Läufe
  dieselben; `:auftrag` gilt hier nicht (ein Text kann nicht alle Aufträge
  sein). `durchsicht: false` überspringt die Durchsicht.

  Liefert `{:ok, %{ueberblick:, schreiben:, durchsicht:, markdown:}}` oder den
  Fehler von Überblick bzw. Schreiben. `durchsicht` ist das Ergebnis von
  `laufen_durchsicht/4`, `:uebersprungen` oder `{:error, grund}`: **eine
  gescheiterte Durchsicht lässt das Ganze nicht scheitern** — dann ist
  `markdown` das Kapitel aus dem Schreiben, und der Fehler steht im Log und im
  Ergebnis. `Worker.Jack.Epos.Ergebnis` auf `durchsicht.stand` liefert das
  Kapitel nach der Durchsicht, auf `schreiben.stand` das aus dem Schreiben.

  `melde_stufe:` — der Rückruf fürs Laufband (`(stufe, ereignis)`, dieselbe
  Form wie beim Resümee-Jack, `Worker.Jack.Resuemee.laufen/2`): jeder Lauf ist
  eine Stufe (`epos_ueberblick`, `render_epos`, `epos_durchsicht`), gemeldet
  über `Worker.Jack.Resuemee.Melder.gemeldet/5`. Eine gescheiterte Durchsicht
  geht als `{:error, {:epos_durchsicht, grund}}` ans Band (eigene Klasse
  `epos_durchsicht_gescheitert`). Ohne ihn meldet der Lauf nichts; ein
  `:stand_beobachter` bekommt jeden Stand über den Melder des Laufs.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts \\ []) do
    opts = Keyword.delete(opts, :auftrag)
    melde = Keyword.get(opts, :melde_stufe) || fn _stufe, _ereignis -> :ok end
    opts = Keyword.delete(opts, :melde_stufe)

    with {:ok, u} <-
           Melder.gemeldet(@stufe_ueberblick, melde, opts, &laufen_ueberblick(eingabe, &1)),
         ablage = Stand.ablage(u.stand),
         {:ok, s} <-
           Melder.gemeldet(@stufe_schreiben, melde, opts, &laufen_schreiben(eingabe, ablage, &1)) do
      {:ok, durchsehen(%{ueberblick: u, schreiben: s}, eingabe, ablage, melde, opts)}
    end
  end

  defp durchsehen(r, eingabe, ablage, melde, opts) do
    if Keyword.get(opts, :durchsicht, true) do
      lauf = &laufen_durchsicht(eingabe, ablage, r.schreiben.stand.entwurf, &1)

      case Melder.gemeldet(@stufe_durchsicht, melde, opts, lauf, :epos_durchsicht) do
        {:ok, d} ->
          Map.merge(r, %{durchsicht: d, markdown: d.markdown})

        {:error, grund} = fehler ->
          Logger.warning(
            "Epos-Jack: Durchsicht von Sitzung #{eingabe.sitzung.nummer} gescheitert, es gilt " <>
              "das Kapitel aus dem Schreiben: #{inspect(grund, limit: 20)}"
          )

          Map.merge(r, %{durchsicht: fehler, markdown: r.schreiben.markdown})
      end
    else
      Map.merge(r, %{durchsicht: :uebersprungen, markdown: r.schreiben.markdown})
    end
  end

  @doc """
  Fährt den Überblick auf einer Eingabe (`Worker.Jack.Epos.Eingabe`; die Art
  wird auf `:epos` gesetzt). Optionen wie `Worker.Jack.Resuemee.laufen_ueberblick/2`
  (`:modell`, `:kontext_fenster`, `:auftrag`, `:denken_zurueck`,
  `:max_runden`, `:max_ms`, `:beobachter`, `:stand_beobachter`, `:protokoll`,
  `:bei_stopp`); ohne `:auftrag` gilt `auftrag/2`.

  Liefert `{:ok, %{stand:, runden:, ms:}}`, wenn Jack mit `fertig`
  abschloss; sonst `{:error, {:epos_ueberblick_ohne_abschluss, ende}}`. Ohne
  Fakten `{:error, :keine_fakten}`. Die Ablage für das Schreiben ist
  `Worker.Jack.Resuemee.Stand.ablage(stand)`.
  """
  @spec laufen_ueberblick(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_ueberblick(eingabe, opts \\ []) do
    eingabe = Map.put(eingabe, :art, :epos)

    Lauf.starten(
      eingabe,
      opts,
      fn -> Stand.neu(eingabe) end,
      fn -> auftrag(eingabe) end,
      :epos_ueberblick_ohne_abschluss,
      jack()
    )
  end

  @doc """
  Fährt das Schreiben auf einer Eingabe, mit der Ablage des Überblicks als
  Notizen. Ein frischer Lauf: neuer Halter, `lauf: :schreiben`, nichts
  gelesen (`Worker.Jack.Resuemee.Stand.fuer_schreiben/2`, die Art wird auf
  `:epos` gesetzt). Optionen wie `laufen_ueberblick/2`; ohne `:auftrag` gilt
  `auftrag_schreiben/3`.

  Liefert `{:ok, %{stand:, runden:, ms:, markdown:}}`, wenn Jack mit
  `fertig` abschloss; sonst `{:error, {:epos_schreiben_ohne_abschluss, ende}}`.
  Ohne Fakten `{:error, :keine_fakten}`.
  """
  @spec laufen_schreiben(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_schreiben(eingabe, ablage, opts \\ []) do
    eingabe = Map.put(eingabe, :art, :epos)

    with {:ok, r} <-
           Lauf.starten(
             eingabe,
             opts,
             fn -> Stand.fuer_schreiben(eingabe, ablage) end,
             fn -> auftrag_schreiben(eingabe, ablage) end,
             :epos_schreiben_ohne_abschluss,
             jack()
           ) do
      {:ok, Map.put(r, :markdown, Ergebnis.markdown(r.stand))}
    end
  end

  @doc """
  Fährt die Durchsicht auf einer Eingabe, mit der Ablage des Überblicks und
  dem Kapitel aus dem Schreiben (`s.entwurf` des Schreib-Stands, oder als
  JSON — `Worker.Jack.Epos.Entwurf.entwurf_aus/1`). Ein frischer Lauf: neuer
  Halter, `lauf: :durchsicht` (`Worker.Jack.Epos.Durchsicht.stand/3`, die Art
  wird auf `:epos` gesetzt). Optionen wie `laufen_ueberblick/2`; ohne
  `:auftrag` gilt `auftrag_durchsicht/4`.

  Liefert `{:ok, %{stand:, runden:, ms:, markdown:}}` — `markdown` ist das
  Kapitel nach der Durchsicht —, wenn Jack mit `fertig` abschloss; sonst
  `{:error, {:epos_durchsicht_ohne_abschluss, ende}}`. Ohne Fakten
  `{:error, :keine_fakten}`, ohne Absatz im Kapitel `{:error, :entwurf_leer}`.
  """
  @spec laufen_durchsicht(map(), map() | nil, [map()] | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def laufen_durchsicht(eingabe, ablage, entwurf, opts \\ []) do
    eingabe = Map.put(eingabe, :art, :epos)

    with :ok <- Lauf.fakten_da(eingabe),
         :ok <- entwurf_da(entwurf),
         {:ok, r} <-
           Lauf.starten(
             eingabe,
             opts,
             fn -> Durchsicht.stand(eingabe, ablage, entwurf) end,
             fn -> auftrag_durchsicht(eingabe, ablage, entwurf) end,
             :epos_durchsicht_ohne_abschluss,
             jack()
           ) do
      {:ok, Map.put(r, :markdown, Ergebnis.markdown(r.stand))}
    end
  end

  defp entwurf_da(entwurf) do
    if Entwurf.entwurf_aus(entwurf) == [], do: {:error, :entwurf_leer}, else: :ok
  end

  defp jack do
    %{
      werkzeuge: &Werkzeuge.fuer/1,
      zusammenfassung: &Zusammenfassung.fuer/1,
      abbild: &Notizen.abbild/1
    }
  end

  # ─── Aufträge ─────────────────────────────────────────────────────────

  @doc """
  Der Auftrag des Überblicks: die Vorlage `epos_ueberblick.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen/2`. Fehlt sie, ist
  das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag(map(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def auftrag(eingabe, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_ueberblick, dir), do: {:ok, fuellen(text, eingabe)}
  end

  @doc """
  Der Auftrag des Schreibens: die Vorlage `epos_schreiben.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen_schreiben/3`. Fehlt
  sie, ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag_schreiben(map(), map() | nil, Path.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def auftrag_schreiben(eingabe, ablage, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_schreiben, dir),
         do: {:ok, fuellen_schreiben(text, eingabe, ablage)}
  end

  @doc """
  Der Auftrag der Durchsicht: die Vorlage `epos_durchsicht.md` aus `dir`
  (Default `priv/jack/auftraege/`), gefüllt mit `fuellen_durchsicht/4`. Fehlt
  sie, ist das `{:error, {:auftrag_fehlt, pfad}}`.
  """
  @spec auftrag_durchsicht(map(), map() | nil, [map()] | nil, Path.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def auftrag_durchsicht(eingabe, ablage, entwurf, dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(@vorlage_durchsicht, dir),
         do: {:ok, fuellen_durchsicht(text, eingabe, ablage, entwurf)}
  end

  @doc """
  Setzt die Angaben einer Sitzung in die Vorlage ein, in einem Durchgang
  (`Worker.Jack.Resuemee.Lauf.einsetzen/2`): `{{ueberschrift}}` (ohne Angabe
  „Epos“), `{{sitzung}}`, `{{anzahl_fakten}}`, `{{letzter_block}}`,
  `{{fruehere}}` (ein Satz über die früheren Sitzungen), `{{ton}}` (Grundton
  und Epos-Ton, `Worker.Jack.Resuemee.Stand.ton/2`), `{{anzahl_stationen}}`
  (Stationen im Weg aus dem Resümee) und `{{weg}}` (ein Satz dazu; ohne Weg,
  dass Jack ihn selbst aufstellt). Unbekannte Platzhalter bleiben stehen.
  """
  @spec fuellen(String.t(), map()) :: String.t()
  def fuellen(text, eingabe) do
    stationen = length(Map.get(eingabe, :resuemee_weg) || [])

    Lauf.einsetzen(
      text,
      Map.merge(grundwerte(eingabe), %{
        "anzahl_stationen" => Integer.to_string(stationen),
        "weg" => weg_satz(stationen)
      })
    )
  end

  @doc """
  Wie `fuellen/2` ohne den Weg, dazu `{{form}}` (die FORM-Notiz aus der
  Ablage des Überblicks; ohne sie ein Satz, woraus Jack sie ableitet),
  `{{notizen}}` (SZENEN, ABWEICHUNG und OFFEN als Text, Abschnitte als `###`
  — die FORM steht schon beim Stil), `{{szenen}}` (ein Satz über die Zahl der
  Szenen) und `{{max_absatz_woerter}}` (`Worker.Jack.Epos.Entwurf.max_woerter/0`).
  """
  @spec fuellen_schreiben(String.t(), map(), map() | nil) :: String.t()
  def fuellen_schreiben(text, eingabe, ablage),
    do: Lauf.einsetzen(text, schreibwerte(eingabe, ablage))

  @doc """
  Wie `fuellen_schreiben/3`, dazu `{{entwurf}}` (das Kapitel aus dem
  Schreiben, wie `entwurf()` es zeigt: der Stand vorn, dann je Absatz Nummer,
  Titel, Wortzahl, Szene und Text), `{{anzahl_absaetze}}` und
  `{{max_durchgaenge}}` (`Worker.Jack.Resuemee.Durchsicht.max_durchgaenge/0`).
  """
  @spec fuellen_durchsicht(String.t(), map(), map() | nil, [map()] | nil) :: String.t()
  def fuellen_durchsicht(text, eingabe, ablage, entwurf) do
    s = Durchsicht.stand(eingabe, ablage, entwurf)

    werte =
      eingabe
      |> schreibwerte(ablage)
      |> Map.merge(%{
        "entwurf" => Entwurf.entwurf_text(s),
        "anzahl_absaetze" => Integer.to_string(length(s.entwurf)),
        "max_durchgaenge" => Integer.to_string(Worker.Jack.Resuemee.Durchsicht.max_durchgaenge())
      })

    Lauf.einsetzen(text, werte)
  end

  defp schreibwerte(eingabe, ablage) do
    s = Stand.fuer_schreiben(Map.put(eingabe, :art, :epos), ablage)

    notizen =
      case String.trim(
             Worker.Jack.Resuemee.Notizen.text_aus(ablage, "### ", ~w(SZENEN ABWEICHUNG OFFEN))
           ) do
        "" -> @keine_szenen
        t -> t
      end

    Map.merge(grundwerte(eingabe), %{
      "form" => form_text(Stand.form(s)),
      "notizen" => notizen,
      "szenen" => szenen_satz(length(Stand.abschnitt(s, "SZENEN"))),
      "max_absatz_woerter" => Integer.to_string(Entwurf.max_woerter())
    })
  end

  defp grundwerte(eingabe) do
    fruehere = eingabe |> Map.get(:fruehere, []) |> Enum.map(& &1.nummer)

    %{
      "ueberschrift" => Map.get(eingabe, :ueberschrift) || "Epos",
      "sitzung" => to_string(eingabe.sitzung.nummer),
      "anzahl_fakten" => Integer.to_string(length(eingabe.fakten)),
      "letzter_block" => Integer.to_string(max(length(Map.get(eingabe, :bloecke, [])) - 1, 0)),
      "fruehere" => Lauf.fruehere_text(fruehere),
      "ton" => Stand.ton(Map.get(eingabe, :flavor), :epos)
    }
  end

  defp form_text(%{zeile: z}), do: z
  defp form_text(nil), do: @keine_form

  defp szenen_satz(0), do: "Im Überblick hast du keine Szene aufgestellt."
  defp szenen_satz(1), do: "Im Überblick hast du eine Szene aufgestellt."
  defp szenen_satz(n), do: "Im Überblick hast du #{n} Szenen aufgestellt."

  defp weg_satz(0),
    do:
      "Zu dieser Sitzung liegt kein Weg aus dem Resümee vor. Du stellst den Weg der Gruppe " <>
        "selbst auf: in deinen SZENEN, vom Anfang bis zum Ende der Sitzung."

  defp weg_satz(1),
    do:
      "Das Resümee dieser Sitzung hält den Weg der Gruppe in einer Station fest; " <>
        "`resuemee()` zeigt ihn dir zusammen mit dem Text des Resümees."

  defp weg_satz(n),
    do:
      "Das Resümee dieser Sitzung hält den Weg der Gruppe in #{n} Stationen fest; " <>
        "`resuemee()` zeigt ihn dir zusammen mit dem Text des Resümees."
end
