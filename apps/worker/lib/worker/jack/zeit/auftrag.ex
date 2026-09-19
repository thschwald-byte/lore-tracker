defmodule Worker.Jack.Zeit.Auftrag do
  @moduledoc """
  #1247 (Z2): die Aufträge des Zeit-Jack — eine Vorlage je Lauf.

      :gedaechtnis   zeit_gedaechtnis.md   die Fakten lesen, nichts setzen
      :einsortieren  zeit_einsortieren.md  den Mitschnitt einordnen
      :pruefen       zeit_pruefen.md       die entstandene Linie prüfen

  **Im Auftrag steht, was über den einzelnen Aufruf hinausgeht** — die
  Flughöhe, das Verfahren, die Befunde aus der handgelesenen Referenz. Was
  bei jedem einzelnen Setzen gilt (Welt-Frage, Rauschen, Uhrzeit-Formen),
  steht in den **Werkzeugbeschreibungen**: Ein Auftrag wird einmal gelesen
  und ist nach einer Kompaktierung weg, eine Beschreibung steht bei jedem
  Aufruf da (#1211).

  **Die gemessene Sitzung kommt nie ins Repo** (Tom, 11.09.2026). Die
  Beispiele in den Vorlagen sind entweder erfunden oder so weit abgelöst,
  dass sie keinen Eigennamen der echten Runde tragen;
  `auftragsvorlagen_test.exs` hält eine Liste ihrer Begriffe heraus.
  """

  alias Worker.Jack.Resuemee.Lauf
  alias Worker.Jack.Zeit.Stand

  @vorlagen %{
    gedaechtnis: "zeit_gedaechtnis.md",
    einsortieren: "zeit_einsortieren.md",
    pruefen: "zeit_pruefen.md"
  }

  @doc """
  Der Auftrag für einen Lauf, mit gefüllten Platzhaltern.

  **Eine unbekannte Laufart wirft, statt auf eine Vorlage zurückzufallen.**
  Der Auffangzweig wäre genau die Klasse, die am 18.09.2026 die
  Chronik-Abschnitte still durch die des Resümees ersetzt hat: Der Lauf
  läuft, das Modell liest einen Auftrag für eine andere Arbeit, und niemand
  sieht es.
  """
  @spec fuer(Stand.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:auftrag_fehlt, String.t()}}
  def fuer(%Stand{lauf: lauf} = s, kampagne, dir \\ nil) do
    with {:ok, datei} <- vorlage_name(lauf),
         {:ok, text} <- Lauf.vorlage(datei, dir) do
      {:ok, Lauf.einsetzen(text, werte(s, kampagne))}
    end
  end

  defp vorlage_name(lauf) do
    case Map.fetch(@vorlagen, lauf) do
      {:ok, datei} ->
        {:ok, datei}

      :error ->
        raise ArgumentError,
              "Worker.Jack.Zeit.Auftrag kennt die Laufart #{inspect(lauf)} nicht. " <>
                "Wer einen Lauf ergänzt, ergänzt seine Vorlage — ein Rückfall auf " <>
                "eine fremde liesse das Modell die falsche Arbeit tun, ohne Fehler."
    end
  end

  defp werte(%Stand{} = s, kampagne) do
    z = Stand.zahlen(s)

    %{
      "kampagne" => kampagne,
      "anzahl_zeilen" => to_string(z.utterances),
      "letzte_zeile" => to_string(max(z.utterances, 1))
    }
  end
end
