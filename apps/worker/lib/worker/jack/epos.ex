defmodule Worker.Jack.Epos do
  @moduledoc """
  Jack schreibt das Epos-Kapitel einer Sitzung (J6, #1210, Epic #1195) — die
  Ablaufsteuerung. **Priorität ist ein guter, schön zu lesender Text**,
  deutlich stärker nach der Stilvorgabe aus „Stil setzen“ (Grundton,
  Epos-Ton, Überschrift der Epos-Spalte) als beim Resümee, mit mehr
  erzählerischer Freiheit. „Handlung treu, Erzählweise frei“ bleibt: Figuren,
  Orte, Ereignisse und Ausgänge kommen aus den Fakten.

  Gebaut in Schritten (#1210, Kommentar 1): **E1 Überblick** (hier), E2
  Schreiben (Sätze mit Fakten, `farbe`, Mindestlänge, höchstens 30 % ohne
  Beleg), E3 Durchsicht, E4 Einbau in die Pipeline (Stufe `render_epos`,
  Laufband, `epos_jack_model`, Ereignisse, das Längenfeld in „Stil setzen“),
  E5 Test auf der Teststage.

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
  den Abschnitten des Epos (FORM, SZENEN, ABWEICHUNG, OFFEN). Lauf 1 und 2
  lesen alle früheren Daten (E0-Lesebasis, #1210 Kommentar 4).

  **Was geteilt ist.** Der Epos-Jack nutzt die Teile des Resümee-Jack, die
  nicht einschränken: den Stand (mit `art: :epos`), die Lesebasis (Lesen,
  Suche, Bisher, Mitschnitte), den Halter, die Laufmechanik
  (`Worker.Jack.Resuemee.Lauf`), die Mechanik von `notiz` und `fertig`
  (`Worker.Jack.Resuemee.Notizen.eintragen/3`,
  `Worker.Jack.Resuemee.Abschluss.mit_regeln/3`), die Werkzeug-Hülle
  (`Worker.Jack.Resuemee.Werkzeuge.aus/3`), den Rückruf der Kompaktierung und
  die Spanne der Blocknummern (`Worker.Jack.Resuemee.Weg.spanne/2`). Wo ein
  gemeinsames Modul dem Modell etwas über „das Resümee“ sagt, richtet es sich
  nach `art`; für den Resümee-Jack bleibt es byte-gleich. Eigen sind Eingabe,
  Notiz-Abschnitte, Abschluss-Regeln, Vorlage, Zusammenfassung und diese
  Ablaufsteuerung. **Die gemeinsamen Teile in einen neutralen Namensraum zu
  verschieben ist ein eigener Schritt** — hier bewusst nicht getan, damit E1
  keine Umbenennung quer durch den Resümee-Jack und seine Tests braucht.

  **Wie beim Resümee-Jack:** dasselbe Modell und Kontextfenster (bis E4
  `Worker.Jack.Pipeline.modell/0`), dieselbe Kompaktierung mit einem
  Arbeitsstand aus den Werkzeugen (`Worker.Jack.Epos.Zusammenfassung`),
  derselbe Systemprompt, dasselbe Nachhaken, der Auftrag angeheftet. Ein
  `:stand_beobachter` bekommt das Abbild mit `"jack" => "epos"`
  (`Worker.Jack.Epos.Notizen.abbild/1`), als `{:jack_resuemee_stand, abbild}`
  — die Nachricht des gemeinsamen Halters. **Ehrliche Grenze:** die Laufsicht
  kennt noch keine Epos-Ansicht und setzt auf jede solche Nachricht
  `"jack" => "resuemee"` (`Worker.Jack.Sicht`); eine eigene Ansicht kommt mit
  dem Einbau (E4).

  Der Auftrag kommt aus `priv/jack/auftraege/epos_ueberblick.md` (`auftrag/2`).
  """

  alias Worker.Jack.Epos.{Eingabe, Notizen, Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.{Lauf, Stand}

  @vorlage_ueberblick "epos_ueberblick.md"

  @doc """
  Der Überblick für eine Sitzung aus dem Repo: `Worker.Jack.Epos.Eingabe.aus_repo/1`,
  dann `laufen_ueberblick/2` mit denselben Optionen.
  """
  @spec ueberblick(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ueberblick(session_id, opts \\ []) do
    with {:ok, e} <- Eingabe.aus_repo(session_id), do: laufen_ueberblick(e, opts)
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

  defp jack do
    %{
      werkzeuge: &Werkzeuge.fuer/1,
      zusammenfassung: &Zusammenfassung.fuer/1,
      abbild: &Notizen.abbild/1
    }
  end

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
  Setzt die Angaben einer Sitzung in die Vorlage ein, in einem Durchgang
  (`Worker.Jack.Resuemee.Lauf.einsetzen/2`): `{{ueberschrift}}` (ohne Angabe
  „Epos“), `{{sitzung}}`, `{{anzahl_fakten}}`, `{{letzter_block}}`,
  `{{fruehere}}` (ein Satz über die früheren Sitzungen), `{{mindest_woerter}}`
  (`Shared.EposLaenge.wirksam/1`), `{{ton}}` (Grundton und Epos-Ton,
  `Worker.Jack.Resuemee.Stand.ton/2`), `{{anzahl_stationen}}` (Stationen im
  Weg aus dem Resümee) und `{{weg}}` (ein Satz dazu; ohne Weg, dass Jack ihn
  selbst aufstellt). Unbekannte Platzhalter bleiben stehen.
  """
  @spec fuellen(String.t(), map()) :: String.t()
  def fuellen(text, eingabe) do
    fruehere = eingabe |> Map.get(:fruehere, []) |> Enum.map(& &1.nummer)
    stationen = length(Map.get(eingabe, :resuemee_weg) || [])
    mindest = Shared.EposLaenge.wirksam(Map.get(eingabe, :mindest_woerter))

    Lauf.einsetzen(text, %{
      "ueberschrift" => Map.get(eingabe, :ueberschrift) || "Epos",
      "sitzung" => to_string(eingabe.sitzung.nummer),
      "anzahl_fakten" => Integer.to_string(length(eingabe.fakten)),
      "letzter_block" => Integer.to_string(max(length(Map.get(eingabe, :bloecke, [])) - 1, 0)),
      "fruehere" => Lauf.fruehere_text(fruehere),
      "mindest_woerter" => Integer.to_string(mindest),
      "ton" => Stand.ton(Map.get(eingabe, :flavor), :epos),
      "anzahl_stationen" => Integer.to_string(stationen),
      "weg" => weg_satz(stationen)
    })
  end

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
