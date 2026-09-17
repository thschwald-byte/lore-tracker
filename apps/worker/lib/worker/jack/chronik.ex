defmodule Worker.Jack.Chronik do
  @moduledoc """
  Der Chronik-Jack (J7, #1211, Epic #1195): er schreibt die Zeitleiste der
  Kampagne — gebündelte Phasen statt Einzelereignisse, Reihenfolge statt
  geratener Tage.

  ## Zwei Betriebsarten, und die zweite ist der Normalfall

  **Ist die Chronik leer, läuft der volle Aufbau**: Überblick (die Fakten der
  Kampagne sichten und in Abschnitte teilen), Schreiben, Durchsicht. Das
  passiert genau einmal je Kampagne.

  **Sobald eine Chronik existiert, läuft nur noch die Verfeinerung** — ein
  Lauf, der liest, ergänzt und einordnet. Auch bei jedem weiteren Lauf
  derselben Sitzung, bei „neu generieren" und beim Replay. Das ist der
  Unterschied zu Resümee (#1209) und Epos (#1210), die jedes Mal von vorn
  schreiben: Die Chronik wächst, sie wird nicht ersetzt.

  **Eine halb entstandene Chronik zählt als vorhanden.** Bricht der erste Lauf
  nach der Hälfte ab, ist der nächste eine Verfeinerung. Das ist gewollt —
  nichts wird weggeworfen — und im Laufband erkennbar, weil die Stufe anders
  heisst.

  Die Durchsicht gehört zum Aufbau. Bei der Verfeinerung wäre sie ein zweiter
  Modelldurchgang über eine Chronik, die zu weiten Teilen schon dasteht und
  beim Aufbau bereits durchgesehen wurde.

  ## Geleert wird nie

  Der alte Pfad schrieb `ChronikClearedForSession` und danach alle Einträge
  der Sitzung neu. Das passt nicht mehr: Eine Phase gehört keiner Sitzung, und
  die Verfeinerung ergänzt, statt zu ersetzen. Das Ereignis bleibt lesbar,
  damit Bestand und Replay gültig bleiben — geschrieben wird es nicht mehr.
  """

  require Logger

  alias Worker.Jack.Chronik.{Abschluss, Lesen, Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.{Lauf, Melder, Stand}

  @stufe_ueberblick "chronik_ueberblick"
  @stufe_schreiben "timeline"
  @stufe_durchsicht "chronik_durchsicht"

  @vorlage_ueberblick "chronik_ueberblick.md"
  @vorlage_schreiben "chronik_schreiben.md"
  @vorlage_durchsicht "chronik_durchsicht.md"
  @vorlage_verfeinerung "chronik_verfeinerung.md"

  @doc """
  Fährt den Chronik-Jack auf einer Eingabe
  (`Worker.Jack.Chronik.Eingabe.aus_repo/1`). Welche Läufe das sind,
  entscheidet die Betriebsart (Moduledoc).

  Liefert `{:ok, %{eintraege:, betriebsart:, trichter:, …}}` oder
  `{:error, grund}`.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts \\ []) do
    opts = Keyword.delete(opts, :auftrag)
    melde = Keyword.get(opts, :melde_stufe) || fn _stufe, _ereignis -> :ok end
    opts = Keyword.delete(opts, :melde_stufe)

    case Map.get(eingabe, :betriebsart, :aufbau) do
      :verfeinerung -> verfeinern(eingabe, melde, opts)
      _ -> aufbauen(eingabe, melde, opts)
    end
  end

  defp aufbauen(eingabe, melde, opts) do
    with {:ok, u} <-
           Melder.gemeldet(@stufe_ueberblick, melde, opts, &laufen_ueberblick(eingabe, &1)),
         ablage = Stand.ablage(u.stand),
         {:ok, s} <-
           Melder.gemeldet(@stufe_schreiben, melde, opts, &laufen_schreiben(eingabe, ablage, &1)) do
      {:ok, durchsehen(%{ueberblick: u, schreiben: s}, eingabe, ablage, melde, opts)}
    end
  end

  defp verfeinern(eingabe, melde, opts) do
    lauf = &laufen_verfeinerung(eingabe, &1)

    with {:ok, v} <- Melder.gemeldet(@stufe_schreiben, melde, opts, lauf) do
      {:ok, ergebnis(%{schreiben: v}, :verfeinerung)}
    end
  end

  defp durchsehen(r, eingabe, ablage, melde, opts) do
    if Keyword.get(opts, :durchsicht, true) do
      lauf = &laufen_durchsicht(eingabe, ablage, r.schreiben.stand.eintraege, &1)

      case Melder.gemeldet(@stufe_durchsicht, melde, opts, lauf, :chronik_durchsicht) do
        {:ok, d} ->
          ergebnis(Map.put(r, :durchsicht, d), :aufbau)

        {:error, grund} = fehler ->
          Logger.warning(
            "Chronik-Jack: Durchsicht gescheitert, es gilt die Chronik aus dem " <>
              "Schreiben: #{inspect(grund, limit: 20)}"
          )

          ergebnis(Map.put(r, :durchsicht, fehler), :aufbau)
      end
    else
      ergebnis(Map.put(r, :durchsicht, :uebersprungen), :aufbau)
    end
  end

  @doc """
  Was aus den Läufen herauskommt, JSON-fähig: die Einträge des letzten
  gelungenen Laufs, die Betriebsart und der Trichter (#1111).
  """
  @spec ergebnis(map(), atom()) :: map()
  def ergebnis(r, betriebsart) do
    letzter = letzter_stand(r)

    %{
      eintraege: letzter.eintraege,
      betriebsart: betriebsart,
      trichter: Abschluss.trichter(letzter),
      rangfolge: rangfolge(letzter.eintraege),
      notizen: notizen(r)
    }
  end

  defp letzter_stand(%{durchsicht: %{stand: s}}), do: s
  defp letzter_stand(%{schreiben: %{stand: s}}), do: s

  defp notizen(%{ueberblick: %{stand: s}}), do: Stand.ablage(s)["notizen"]
  defp notizen(_), do: nil

  # Die Reihenfolge als Liste von IDs. Ein Zyklus ist hier kein Fehler mehr —
  # die Durchsicht hatte ihre Gelegenheit; jetzt zählt, dass die Einträge
  # gespeichert werden. Sie bekommen dann keinen Rang und sortieren nach dem
  # alten Schlüssel.
  defp rangfolge(eintraege) do
    case Lesen.rangfolge(eintraege) do
      {:ok, ids} ->
        ids

      {:zyklus, ids} ->
        Logger.warning(
          "Chronik-Jack: die Bezüge bilden einen Kreis (#{Enum.join(ids, ", ")}) — die " <>
            "Einträge werden ohne Rang gespeichert und sortieren nach Tag und Position."
        )

        []
    end
  end

  # ─── Die einzelnen Läufe ────────────────────────────────────────────

  @doc "Fährt den Überblick (nur im Aufbau)."
  @spec laufen_ueberblick(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_ueberblick(eingabe, opts \\ []) do
    Lauf.starten(
      eingabe,
      opts,
      fn -> stand(eingabe, :ueberblick) end,
      fn -> auftrag(@vorlage_ueberblick, eingabe, nil) end,
      :chronik_ueberblick_ohne_abschluss,
      jack()
    )
  end

  @doc "Fährt das Schreiben mit den Notizen des Überblicks."
  @spec laufen_schreiben(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_schreiben(eingabe, ablage, opts \\ []) do
    Lauf.starten(
      eingabe,
      opts,
      fn -> %{stand(eingabe, :schreiben) | notizen: notizen_aus(ablage)} end,
      fn -> auftrag(@vorlage_schreiben, eingabe, ablage) end,
      :chronik_schreiben_ohne_abschluss,
      jack()
    )
  end

  @doc """
  Fährt die Verfeinerung — der Normalbetrieb. Kein Überblick davor: Jack
  liest den Bestand mit `chronik()` und arbeitet ein, was dazugekommen ist.
  """
  @spec laufen_verfeinerung(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen_verfeinerung(eingabe, opts \\ []) do
    Lauf.starten(
      eingabe,
      opts,
      fn -> stand(eingabe, :schreiben) end,
      fn -> auftrag(@vorlage_verfeinerung, eingabe, nil) end,
      :chronik_verfeinerung_ohne_abschluss,
      jack()
    )
  end

  @doc "Fährt die Durchsicht über die geschriebenen Einträge."
  @spec laufen_durchsicht(map(), map() | nil, [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def laufen_durchsicht(eingabe, ablage, eintraege, opts \\ []) do
    Lauf.starten(
      eingabe,
      opts,
      fn ->
        %{stand(eingabe, :durchsicht) | eintraege: eintraege, notizen: notizen_aus(ablage)}
      end,
      fn -> auftrag(@vorlage_durchsicht, eingabe, nil, eintraege) end,
      :chronik_durchsicht_ohne_abschluss,
      jack()
    )
  end

  # Der Stand eines Laufs: wie beim Resümee-Jack, dazu die Einträge aus dem
  # Bestand — ohne sie könnte die Verfeinerung nichts fortschreiben.
  defp stand(eingabe, lauf) do
    %{Stand.neu(eingabe) | lauf: lauf, eintraege: Map.get(eingabe, :eintraege, [])}
  end

  defp notizen_aus(nil), do: []

  defp notizen_aus(ablage) do
    leer = %{sitzung: %{id: nil, nummer: nil, name: nil}}
    Stand.fuer_schreiben(leer, ablage).notizen
  rescue
    _ -> []
  end

  defp jack,
    do: %{werkzeuge: &Werkzeuge.fuer/1, zusammenfassung: &Zusammenfassung.fuer/1}

  # ─── Aufträge ───────────────────────────────────────────────────────

  @doc "Der Auftrag eines Laufs aus seiner Vorlage, gefüllt."
  @spec auftrag(String.t(), map(), map() | nil, [map()]) :: {:ok, String.t()} | {:error, term()}
  def auftrag(vorlage, eingabe, ablage, eintraege \\ [], dir \\ nil) do
    with {:ok, text} <- Lauf.vorlage(vorlage, dir) do
      {:ok, fuellen(text, eingabe, ablage, eintraege)}
    end
  end

  @doc "Die Platzhalter einer Vorlage füllen. Pur."
  @spec fuellen(String.t(), map(), map() | nil, [map()]) :: String.t()
  def fuellen(text, eingabe, ablage, eintraege \\ []) do
    fakten = Map.get(eingabe, :fakten, [])

    text
    |> String.replace("{{kampagne}}", to_string(Map.get(eingabe, :kampagne, "")))
    |> String.replace("{{anzahl_fakten}}", to_string(length(fakten)))
    |> String.replace("{{sitzung}}", to_string(get_in(eingabe, [:sitzung, :nummer]) || ""))
    |> String.replace("{{notizen}}", notizen_text(ablage))
    |> String.replace("{{chronik}}", chronik_text(eingabe, eintraege))
  end

  defp notizen_text(nil), do: "(keine Notizen)"

  defp notizen_text(ablage) do
    case ablage["notizen"] do
      liste when is_list(liste) and liste != [] ->
        Enum.map_join(liste, "\n", fn n ->
          "- **#{n["schluessel"]}** (#{n["abschnitt"]}): #{n["zeile"]}"
        end)

      _ ->
        "(keine Notizen)"
    end
  end

  defp chronik_text(eingabe, []),
    do: Lesen.text(%Stand{art: :chronik, eintraege: Map.get(eingabe, :eintraege, [])})

  defp chronik_text(_eingabe, eintraege),
    do: Lesen.text(%Stand{art: :chronik, eintraege: eintraege})
end
