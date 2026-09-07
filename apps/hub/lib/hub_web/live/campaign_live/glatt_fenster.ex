defmodule HubWeb.CampaignLive.GlattFenster do
  @moduledoc """
  Issue #1153 (C6, Epic #1146): die Hub-Seite des Text-Fensters aus #1152.

  Der Worker liefert mit `"glatt" => "fenster"` das **Skelett vollständig** und
  die **Texte** nur für die jüngsten Blöcke je Sitzung. Dieses Modul beantwortet
  die zwei Fragen, die daraus entstehen — beide **pur**, ohne Socket:

  - **Welche Texte fehlen für das, was gerade gezeigt wird?** (`fehlende_ids/3`)
  - **Wie viele gefilterte Blöcke haben noch keinen Text?** (`unbetextet_zahl/2`)

  ## Die Reibung, die das Protokoll nicht hatte

  Das **Anzeige**-Fenster gleitet über die *gefilterte* Ansicht (nur Lücken /
  ohne Unbrauchbare / alles), das **Lade**-Fenster des Workers über die
  *ungefilterte* Blockliste. Ein Index in der einen ist kein Index in der
  anderen — deshalb wird hier nicht über Indizes gerechnet, sondern über
  **Block-IDs**: welche der gerade sichtbaren Blöcke tragen keinen Text?

  Das ist zugleich der Grund, warum der Worker seit #1152 eine **ids**-Form
  hat und nicht nur einen Bereich: die Kuratieren-Ansicht wählt ihre Blöcke
  über ein Prädikat, ihre Treffer liegen über die ganze Sitzung verstreut.

  ## Alte Worker

  Ein Worker ohne #1152 liefert jeden Block mit `"text"`. Dann ist
  `fehlende_ids/3` leer, `unbetextet_zahl/2` ist 0, und die Spalte verhält sich
  **exakt wie vorher** — ohne Sonderfall im Aufrufer. Dasselbe gilt für einen
  neuen Worker ohne gesetztes Flag.

  ## Abhängigkeit, die NICHT aus dem Ticket ablesbar war

  Bis C4 (#1151) kommt `smoothed` aus dem **Haupt**-Snapshot, und der ruft
  `smoothed_for_campaign/1` ohne Option (`snapshots.ex:169`). Das Flag hängt
  aber am `campaign_luecken`-Scope. **Ohne C4 erreicht dieser Cut den
  Mount-Fall also gar nicht** — er wirkt nur beim Reload. Erst C4 leitet den
  Mount über den Scope und macht das Fenster für den teuren Fall erreichbar.
  """

  @doc """
  Die Block-IDs, für die ein Text nachgeladen werden muss.

  `sichtbare` sind die Blöcke, die das Anzeige-Fenster gerade zeigt (also nach
  Filter UND nach `window_slice/3`). Zurück kommen die IDs derer, die weder
  einen eigenen Text tragen noch schon nachgeladen wurden.

  **Warum die bereits geladenen mitgeprüft werden:** ohne das fordert jeder
  Re-Render dieselben Texte erneut an — ein Ereignis pro Tastendruck im
  Kurations-Feld, und die Schlange aus #1149 füllt sich mit Wiederholungen.
  """
  @spec fehlende_ids([map()], map()) :: [String.t()]
  def fehlende_ids(sichtbare, geladene_texte) when is_list(sichtbare) do
    for b <- sichtbare,
        id = b["block_id"],
        is_binary(id),
        not betextet?(b),
        not Map.has_key?(geladene_texte, id),
        uniq: true,
        do: id
  end

  @doc """
  Wie viele Blöcke der gefilterten Ansicht tragen noch keinen Text?

  Das ist die Zahl, die der „ältere anzeigen"-Anker braucht. **Sie zählt auf
  der gefilterten Liste**, weil der Anker in der Ansicht steht, die der
  Betrachter gerade sieht — eine Zahl aus der ungefilterten Liste verspräche
  Blöcke, die der aktive Filter gar nicht zeigt.

  Die Lehre aus #883 hängt daran: ein Deckel ohne erreichbaren Rest ist
  Datenverlust. Solange diese Zahl größer als 0 ist, muss der Anker stehen
  bleiben.
  """
  @spec unbetextet_zahl([map()]) :: non_neg_integer()
  def unbetextet_zahl(gefilterte) when is_list(gefilterte),
    do: Enum.count(gefilterte, &(not betextet?(&1)))

  @doc """
  Block + nachgeladener Text. Die EINE Stelle, an der beide zusammenkommen.

  Der nachgeladene Text gewinnt nie über einen vorhandenen — ein Block, der
  seinen Text schon mitbrachte, behält ihn. Das hält den Fall „alter Worker"
  und den Fall „Nachladen kam doppelt" gleich, ohne Sonderweg.
  """
  @spec mit_text(map(), map()) :: map()
  def mit_text(block, geladene_texte) do
    if betextet?(block) do
      block
    else
      case Map.get(geladene_texte, block["block_id"]) do
        %{} = texte -> Map.merge(block, texte)
        _ -> block
      end
    end
  end

  @doc """
  Trägt der Block seinen Text?

  Geprüft wird die **Anwesenheit des Schlüssels**, nicht sein Wahrheitswert:
  `text` darf legitim `nil` sein (ein Block ohne auflösbaren Roh-Text), und
  `text_smoothed` kann leer sein. Ein `Map.get(b, "text")`-Test hielte solche
  Blöcke für unbetextet und forderte sie endlos nach.
  """
  @spec betextet?(map()) :: boolean()
  def betextet?(block), do: Map.has_key?(block, "text")

  @doc """
  Issue #1153: das Ergebnis eines Nachlade-Reads auf den Socket anwenden.

  Liegt hier statt in `campaign_live.ex`: die Datei stand mit den drei
  Ergebnis-Zweigen bei 617 Code-Zeilen und damit über der God-Module-Grenze.
  Der Rumpf gehört ohnehin hierher — die Datei behält den Dispatch, dieses
  Modul die Bedeutung.

  **Best-effort by design.** Schlägt der Read fehl, bleiben die betroffenen
  Blöcke textlos und der „ältere anzeigen"-Anker steht weiter (er zählt die
  unbetexteten). **Kein Voll-Reload als Fallback** — der wäre genau die
  3,3-MB-Spitze, die dieser Cut vermeiden soll. Ein fehlender Text ist ein
  Schönheitsfehler, ein Voll-Reload ein Risiko.
  """
  @spec apply_ergebnis(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def apply_ergebnis(socket, {:ok, {:ok, %{"texte" => texte}}}) when is_map(texte) do
    Phoenix.Component.assign(
      socket,
      :glatt_texte,
      merge_texte(socket.assigns.glatt_texte, texte)
    )
  end

  def apply_ergebnis(socket, anderes) do
    require Logger
    Logger.warning("CampaignLive: Block-Texte nicht nachladbar (#{inspect(anderes)})")
    socket
  end

  @doc """
  Alle Block-IDs, für die JETZT ein Text nachgeladen werden muss — über alle
  Sitzungen, in derselben Sicht, die das Template zeigt.

  Die Sicht wird hier **nachgebaut, nicht geraten**: derselbe Filter
  (`glatt_view_for` + `glatt_blocks`) und dasselbe Fenster (`window_slice`) wie
  im Template. Liefen die beiden auseinander, würde entweder zu viel geladen
  (Last ohne Nutzen) oder zu wenig (leere Blöcke, die nie nachrücken) — und
  beides ohne Fehlermeldung.

  Gedeckelt auf `max`: eine Kampagne mit vielen Sitzungen könnte sonst in
  einem Rutsch Hunderte anfordern und damit genau die Spitze erzeugen, die
  dieser Cut vermeiden soll. Der Rest kommt beim nächsten Auslöser.
  """
  @spec fehlende_aus_ansicht([map()], map(), map(), map(), pos_integer()) :: [String.t()]
  def fehlende_aus_ansicht(smoothed, view_map, windows, geladene, max \\ 200) do
    alias HubWeb.CampaignLive.Components, as: C

    smoothed
    |> List.wrap()
    |> Enum.flat_map(fn sm ->
      view = C.glatt_view_for(view_map, sm)
      gefiltert = C.glatt_blocks(sm, view)
      {sichtbar, _vor, _nach} = C.window_slice(gefiltert, sm["session_id"], windows)
      fehlende_ids(sichtbar, geladene)
    end)
    |> Enum.uniq()
    |> Enum.take(max)
  end

  @doc """
  Die nachgeladenen Texte in den Bestand einsortieren.

  Neue gewinnen bei gleicher ID — ein Block kann nach einer Kuration andere
  Texte tragen als beim ersten Laden.
  """
  @spec merge_texte(map(), map()) :: map()
  def merge_texte(bestand, neue) when is_map(bestand) and is_map(neue),
    do: Map.merge(bestand, neue)

  def merge_texte(bestand, _), do: bestand
end
