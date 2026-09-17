defmodule Worker.Jack.Chronik.Eingabe do
  @moduledoc """
  Was der Chronik-Jack zu lesen bekommt (J7, #1211) — und worin er sich von
  allen anderen Jacks unterscheidet: **er sieht die ganze Kampagne.**

  Resümee (#1209) und Epos (#1210) lesen nichts aus späteren Sitzungen; ihr
  Gegenstand ist eine Sitzung, und ein Blick nach vorn wäre ein Blick in die
  Zukunft. Die Chronik ist kampagnenweit — ein Eintrag aus einer späteren
  Sitzung steht ohnehin im selben Zeitstrahl, und ohne ihn ließe sich eine
  Einordnung gar nicht prüfen. Bezüge über Sitzungsgrenzen sind ausdrücklich
  erlaubt („zwei Tage nach der Flucht“); sie verwaisen nicht, weil die
  Verfeinerung die Einträge anderer Sitzungen nicht wegwirft.

  Deshalb liegen in `fakten` **alle** geprüften Fakten der Kampagne, nicht
  die einer Sitzung, und in `chronik` der vollständige Bestand mit der
  Angabe, was der Spielleiter kuratiert hat.

  ## Die beiden Betriebsarten

  `betriebsart/1` entscheidet: **leere Chronik → voller Lauf** (Überblick,
  Schreiben, Durchsicht), **bestehende Chronik → Verfeinerung**. Das gilt
  kampagnenweit, nicht je Sitzung: Sitzung 5 einer Kampagne mit Einträgen aus
  S1–S4 ist immer eine Verfeinerung.

  **Eine halb entstandene Chronik zählt als vorhanden.** Bricht der erste Lauf
  nach der Hälfte ab, ist der nächste eine Verfeinerung — gewollt, weil nichts
  weggeworfen wird, aber im Laufband erkennbar (die Stufe heisst dann anders).

  ## Was die kurzen IDs bedeuten

  Wie bei den anderen Jacks bekommt jeder Fakt eine kurze, lesbare ID
  (`S3-F12` — Sitzung 3, zwölfter Fakt). Sie ist eine **Position im
  Bestand**, keine dauerhafte Adresse: Wird neu extrahiert, zeigt dieselbe
  kurze ID auf einen anderen Fakt. Für die Chronik zählt das doppelt, weil
  ihre Einträge über Läufe hinweg bestehen bleiben — deshalb speichert der
  Eintrag die **echten** Fakt-IDs, und die kurze Form existiert nur im
  Gespräch mit dem Modell.
  """

  alias Worker.Jack.Resuemee.Eingabe, as: Basis

  @doc """
  Die Eingabe für eine Sitzung. Die Lesebasis kommt aus dem Resümee-Jack
  (dieselben Werkzeuge), erweitert um die Fakten **aller** Sitzungen und den
  Chronik-Bestand.
  """
  @spec aus_repo(String.t()) :: {:ok, map()} | {:error, term()}
  def aus_repo(session_id) do
    with {:ok, basis} <- Basis.aus_repo(session_id),
         {:ok, campaign} <- kampagne(session_id) do
      {:ok, zusaetze(basis, campaign)}
    end
  end

  @doc """
  Die Lesebasis mit dem, was nur die Chronik braucht. Pur, damit ein Test sie
  ohne Repo bauen kann.
  """
  @spec zusaetze(map(), map()) :: map()
  def zusaetze(basis, campaign) do
    bestand = bestand(campaign.id)

    basis
    |> Map.delete(:max_woerter)
    |> Map.merge(%{
      art: :chronik,
      kampagne: Map.get(campaign, :name) || campaign.id,
      ueberschrift: ueberschrift(campaign),
      # Alle Fakten der Kampagne, nicht die einer Sitzung — der Unterschied
      # zu allen anderen Jacks (Moduledoc).
      fakten: alle_fakten(basis),
      chronik: bestand,
      eintraege: aus_bestand(bestand),
      betriebsart: betriebsart(bestand)
    })
  end

  @doc """
  `:aufbau`, solange die Chronik der Kampagne leer ist — sonst
  `:verfeinerung`. Öffentlich, weil die Pipeline daran die Stufen wählt und
  ein Test es ohne Repo prüfen können soll.
  """
  @spec betriebsart([map()]) :: :aufbau | :verfeinerung
  def betriebsart([]), do: :aufbau
  def betriebsart(_), do: :verfeinerung

  @doc """
  Die Fakten aller Sitzungen, in der Form der Lesebasis. Die Reihenfolge ist
  die der Sitzungen — der Chronik-Jack liest von vorn nach hinten, wie die
  Kampagne gespielt wurde.
  """
  @spec alle_fakten(map()) :: [map()]
  def alle_fakten(basis) do
    frueher = Enum.flat_map(Map.get(basis, :fruehere, []), &Map.get(&1, :fakten, []))
    frueher ++ Map.get(basis, :fakten, [])
  end

  @doc """
  Der Chronik-Bestand einer Kampagne in der Gestalt, die
  `Worker.Jack.Chronik.Entwurf` erwartet — mit `kuratiert?` aus dem Overlay.

  **Ein Eintrag ohne `rang` behält seine Reihenfolge nicht**, er hat nie eine
  gehabt: Einträge aus dem alten, deterministischen Pfad sind nach Tag und
  Quell-Position sortiert. Sie kommen als `isoliert` an, und Jack ordnet sie
  ein, wenn er sie anfasst. Das ist ehrlicher, als aus der Lesereihenfolge
  eine Behauptung über Bezüge zu machen.
  """
  @spec aus_bestand([map()]) :: [map()]
  def aus_bestand(bestand) do
    Enum.map(bestand, fn e ->
      %{
        id: e.id,
        titel: e.label || "",
        text: e.markdown_body || e.summary || "",
        fakt_ids: e[:fakt_ids] || [],
        wichtigkeit: e[:wichtigkeit] || "phase",
        zeit_bezug: e[:zeit_bezug] || %{"art" => "isoliert"},
        kuratiert?: kuratiert?(e),
        kuratierter_text: if(kuratiert?(e), do: e.markdown_body, else: nil),
        neu?: false
      }
    end)
  end

  # `rebuild_available?` heisst: es gibt eine kuratierte Fassung, die die
  # generierte überstimmt (#914). Das ist die verlässliche Anzeige dafür, dass
  # der Spielleiter Hand angelegt hat — ein eigenes Feld dafür gibt es nicht.
  defp kuratiert?(e), do: Map.get(e, :rebuild_available?, false) == true

  defp bestand(campaign_id), do: Worker.Repo.list_chronik_entries(campaign_id)

  defp kampagne(session_id) do
    with %{campaign_id: cid} <- Worker.Repo.get_session(session_id),
         %{} = c <- Worker.Repo.get_campaign(cid) do
      {:ok, c}
    else
      _ -> {:error, :keine_kampagne}
    end
  end

  defp ueberschrift(campaign) do
    case Worker.Recording.Pipeline.Prompts.stage_heading(campaign, "chronik") do
      n when is_binary(n) -> if String.trim(n) == "", do: "Chronik", else: String.trim(n)
      _ -> "Chronik"
    end
  end
end
