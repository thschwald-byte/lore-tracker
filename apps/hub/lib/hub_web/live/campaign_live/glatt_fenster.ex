defmodule HubWeb.CampaignLive.GlattFenster do
  @moduledoc """
  Issue #1153 (C6, Epic #1146): die Hub-Seite des Text-Fensters aus #1152.

  Der Worker liefert mit `"glatt" => "fenster"` das **Skelett vollständig** und
  die **Texte** nur für die jüngsten Blöcke je Sitzung. Dieses Modul beantwortet
  die zwei Fragen, die daraus entstehen — beide **pur**, ohne Socket:

  - **Welche Texte fehlen für das, was gerade gezeigt wird?** (`fehlende_ids/2`)
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
  `fehlende_ids/2` leer, `unbetextet_zahl/2` ist 0, und die Spalte verhält sich
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

  **Und sie zählt das schon Nachgeladene mit ab** — dieselbe Regel wie
  `fehlende_ids/2`. Der erste Wurf zählte nur `betextet?/1` auf dem rohen
  Skelett; nachgeladene Texte liegen aber in `glatt_texte` und **nie** im
  Skelett. Die Zahl blieb dadurch nach jedem erfolgreichen Nachladen stehen,
  und der Anker verschwand nie (an seattleV4 S3: „426 noch ohne Text" beim
  Mount und 426, wenn alles geladen ist).

  Die Lehre aus #883 hängt daran: ein Deckel ohne erreichbaren Rest ist
  Datenverlust. Solange diese Zahl größer als 0 ist, muss der Anker stehen
  bleiben.
  """
  @spec unbetextet_zahl([map()], map()) :: non_neg_integer()
  def unbetextet_zahl(gefilterte, geladene_texte) when is_list(gefilterte),
    do: Enum.count(gefilterte, &offen?(&1, geladene_texte))

  defp offen?(block, geladene_texte),
    do: not betextet?(block) and not Map.has_key?(geladene_texte, block["block_id"])

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

  ## EIN Ergebnis, EIN assign, EIN Render (#1181)

  Der Task (`lade_texte/2`) hat bereits alle Reads gemacht. Hier wird nur
  noch quittiert und einmal zugewiesen. **Dieser Zweig stößt keinen weiteren
  Read an** — die C6-Kette tat das und renderte die Spalte pro Runde. Ein
  Quelltext-Wächter hält das fest. (Dass die Kette NICHT der Mount-Killer
  war, ist gemessen — s. `lade_texte/2`; der Zweig bleibt trotzdem einfach.)

  ## Warum die Quittung nötig ist

  `quittiere/3` trägt jede **beantwortete** Anforderung ein, auch die IDs, auf
  die der Worker nichts geliefert hat (als `%{}`). Ohne das fordert die
  nächste Betrachter-Aktion dieselben unbekannten IDs erneut an (etwa nach
  einem Re-Smoothing mit neuen Block-IDs) — bei jedem Fensterschritt ein
  nutzloser Read. Die IDs eines **gescheiterten** Reads werden dagegen NICHT
  quittiert: ein Timeout ist kein „gibt es nicht".
  """
  @spec apply_ergebnis(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def apply_ergebnis(socket, {:ok, {quittierbar, texte, fehler}})
      when is_list(quittierbar) and is_map(texte) do
    if fehler != nil do
      require Logger
      Logger.warning("CampaignLive: Block-Texte nur teilweise nachladbar (#{inspect(fehler)})")
    end

    # Issue #1169/#1181: Marke nach dem EINEN Render — mit #1181 gibt es nur
    # noch eines. Die Nachricht wird erst nach dem Render verarbeitet, die
    # Zeile misst also den LiveView-Heap DANACH: die Vorher/Nachher-Zahl.
    send(self(), {:voll_read_rendered, "campaign_luecken_slice"})

    Phoenix.Component.assign(
      socket,
      :glatt_texte,
      quittiere(socket.assigns.glatt_texte, quittierbar, texte)
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
  # Issue #1181: so viele IDs gehen in EINEN Slice-Read. Der Wert deckelt die
  # Nutzlast einer Antwort, nicht mehr die Zahl der Runden — die laufen jetzt
  # alle im selben Task (`lade_texte/2`).
  @max_pro_read 200
  def max_pro_read, do: @max_pro_read

  @spec fehlende_aus_ansicht([map()], map(), map(), map(), pos_integer() | :alle) :: [String.t()]
  def fehlende_aus_ansicht(smoothed, view_map, windows, geladene, max \\ @max_pro_read) do
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
    |> deckeln(max)
  end

  defp deckeln(ids, :alle), do: ids
  defp deckeln(ids, max) when is_integer(max), do: Enum.take(ids, max)

  @doc """
  Issue #1181: ALLE fehlenden Texte in EINEM Task holen — Read für Read, bis
  die Liste leer ist — und als EIN Ergebnis zurückgeben.

  Der Vorgänger (C6, #1153) kettete in der LiveView: jede Antwort ein
  `assign`, jedes `assign` ein Render der Geglättet-Spalte (600 Blöcke, bis
  zu 1200 Wort-Diffs) — an seattleV4 **vier Renders in unter einer Sekunde**
  statt einem. Das war der Verdacht für die Mount-Kills auf Release 398
  (07.09.2026). **Gemessen war es nicht die Ursache**: die Slice-Renders
  laufen bei konstantem LiveView-Heap, der Kill kommt in der
  `campaign_luecken`-Phase davor (Tabelle in #1181). Ein Render statt vier
  bleibt richtig — es ist Hygiene, kein Fix.

  Hier läuft die Schleife im Task: die Reads und ihr Garbage leben im
  Task-Prozess und sterben mit ihm; die LiveView bekommt genau eine Antwort
  und rendert genau einmal. `lese` ist der Read als Funktion (Liste von IDs
  → Reader-Antwort), damit die Schleife ohne Reader testbar ist.

  **Fehler mitten in der Schleife brechen ab, verwerfen aber nichts:** was
  vorher ankam, wird übernommen und quittiert; die IDs des gescheiterten
  Reads und alles dahinter bleiben **unquittiert**, damit die nächste
  Betrachter-Aktion sie erneut anfordert — ein Timeout der #1149-Schlange
  darf kein dauerhaftes „nicht holbar" hinterlassen. Rückgabe deshalb ein
  Tripel `{quittierbar, texte, fehler | nil}`.
  """
  @spec lade_texte([String.t()], ([String.t()] -> term())) :: {[String.t()], map(), term() | nil}
  def lade_texte(ids, lese) when is_list(ids) and is_function(lese, 1) do
    ids
    |> Enum.chunk_every(@max_pro_read)
    |> Enum.reduce_while({[], %{}, nil}, fn chunk, {quittierbar, texte, nil} ->
      case lese.(chunk) do
        {:ok, %{"texte" => neue}} when is_map(neue) ->
          {:cont, {quittierbar ++ chunk, Map.merge(texte, neue), nil}}

        anderes ->
          {:halt, {quittierbar, texte, anderes}}
      end
    end)
  end

  @doc """
  Angeforderte IDs quittieren: gelieferte Texte übernehmen, **unbeantwortete
  als `%{}` vermerken**.

  Der leere Eintrag ist kein Text, sondern eine Notiz „danach wurde gefragt,
  es kam nichts". `mit_text/2` lässt den Block dadurch unverändert
  (`Map.merge(block, %{})`), `fehlende_ids/2` fragt ihn nicht erneut an — das
  ist der Abbruch der Kette in `apply_ergebnis/2`.
  """
  @spec quittiere(map(), [String.t()], map()) :: map()
  def quittiere(bestand, angefordert, texte) when is_map(bestand) and is_map(texte) do
    unbeantwortet =
      for id <- angefordert, is_binary(id), not Map.has_key?(texte, id), into: %{}, do: {id, %{}}

    bestand |> Map.merge(unbeantwortet) |> Map.merge(texte)
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
