defmodule Worker.Jack.Pipeline do
  @moduledoc """
  Jack in der Pipeline (J4, #1207): was Jack von einer Sitzung zu lesen
  bekommt und wie aus seinem Bestand die Fakten werden, die bisher die
  Extraktion geliefert hat — ein `SessionFactsExtracted` mit `facts` und
  `extraction_saw`, damit alles dahinter (Kuration, Dirty-Weiche,
  Fakt-Overlays, Render) unberührt bleibt.

  **Dieselbe Blockliste wie die Extraktion.** `eingabe/4` und `fakten/2`
  bekommen die Kontextliste, die `Worker.Recording.Pipeline.Stages` an den
  Extraktor gibt: `Smoothing.to_context/3` (wirksamer Text, `unbrauchbar`
  entfernt), danach der OOC-Filter (`kontext/1`). Jacks Blocknummer n ist die
  Position n in genau dieser Liste — nur so zeigt eine Nummer auf die richtige
  Block-ID, und `extraction_saw` beschreibt, was Jack wirklich gesehen hat.
  `Worker.Jack.Abzug` nimmt dagegen den rohen Text aller Blöcke; das taugt für
  Messläufe, nicht für den Betrieb.

  **Übersetzung über den Parser der Pipeline.** `fakten/2` bildet die
  Blocknummern auf Block-IDs ab, lässt verworfene Aussagen weg und schickt den
  Rest durch `Parsing.parse_facts_json/2`. Inhaltsbasierte Fakt-IDs,
  Normalisierung, Zeit-Grounding und Dedup kommen von dort, nicht aus einer
  zweiten Implementierung. Jacks `beleg` und seine internen Felder fallen
  dabei weg — die Feldliste des Parsers ist fest.
  """

  require Logger

  alias Worker.Jack.{Fortsetzung, Gedaechtnis, Melder, Messlauf, Phase, Stand}
  alias Worker.Recording.Pipeline.{Ooc, Parsing, Prompts, Smoothing}

  # Jede Aussage hat Jacks Belegprüfung bestanden — ein zweiter Prüfer
  # (Stufe 3) entfällt (Tom, 11.09.2026). Die Flags braucht, was dahinter
  # liest: Render nimmt nur `verified?`, die Dirty-Weiche rechnet aus
  # `grounded?`/`attributed?`.
  @geprueft %{"grounded?" => true, "attributed?" => true, "verified?" => true}

  @auftrag_dateien %{phase1: "phase1.md", phase2: "phase2.md", folgelauf: "folgelauf.md"}

  @doc """
  Stufe 2 der Pipeline durch Jack: `extract_facts_raw/4` und EIN
  `SessionFactsExtracted` mit `facts` und `extraction_saw`, wie es die
  Extraktion bisher publizierte. `verify_backend: "jack"` und das Modell
  machen die Herkunft sichtbar. Liefert `{:ok, facts}` oder `{:error, grund}`.
  """
  @spec extract_facts([map()], String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def extract_facts(bloecke, session_id, campaign, opts \\ []) do
    with {:ok, facts, saw} <- extract_facts_raw(bloecke, session_id, campaign, opts) do
      {:ok, _} =
        Worker.Intents.publish(%{
          "kind" => Shared.Events.session_facts_extracted(),
          "session_id" => session_id,
          "campaign_id" => campaign.id,
          "facts" => facts,
          "extraction_saw" => saw,
          "verify_backend" => "jack",
          "verify_model" => Worker.Settings.model_for(2, :local)
        })

      {:ok, facts}
    end
  end

  @doc """
  Die Extraktion durch Jack ohne Publish — für die Pipeline
  (`extract_facts/4`) und die Neuableitung nach einer Kuration. `bloecke` ist
  die Kontextliste des Laufs (`Smoothing.to_context/3`); Sprecher, Cast und
  Stränge kommen aus der Kampagne, Modell und Aufträge aus `modell/0` und
  `auftraege/2`. Liefert `{:ok, facts, extraction_saw}` wie
  `Stages.extract_facts_raw/3`.

  `weiter: n` (Tom, 11.09.2026, „noch N Iterationen“): statt Gedächtnis und
  Extraktion n Folgedurchgänge auf dem abgelegten Stand der Sitzung
  (`abgelegter_stand/2`). Die Fakten sind danach der ganze Bestand, alt und
  neu.
  """
  @spec extract_facts_raw([map()], String.t(), map(), keyword()) ::
          {:ok, [map()], %{String.t() => String.t()}} | {:error, term()}
  def extract_facts_raw(bloecke, session_id, campaign, opts \\ []) do
    k = kontext(bloecke)

    with {:ok, modell} <- modell(),
         {:ok, a} <- auftraege(length(k)),
         {:ok, vorher} <- vorher(session_id, k, opts[:weiter]) do
      sprecher = Prompts.resolve_speaker_names(campaign.id)
      cast = Worker.Repo.character_roster_for(campaign.id)
      straenge = campaign.id |> Worker.Repo.Threads.campaign_threads() |> Enum.map(& &1.canonical)

      # Laufband: Gedächtnis, Extraktion und jede Iteration lesen den ganzen
      # Mitschnitt einmal; „noch N Iterationen“ liest ihn N-mal.
      lesevorgaenge = if vorher, do: opts[:weiter], else: 2 + Keyword.get(opts, :iterationen, 1)
      # Die Laufsicht (Tom, 11.09.2026): bekommt das Protokoll direkt und den
      # Stand über den Melder — der Halter kennt nur einen Beobachter.
      sicht = Process.whereis(Worker.Jack.Sicht)

      melder =
        Melder.start(%{session_id: session_id}, length(k) * lesevorgaenge, weiter: sicht)

      lauf_opts =
        Keyword.merge(
          [auftraege: a, modell: modell, stand_beobachter: melder, beobachter: sicht],
          weiter_opts(opts, vorher)
        )

      ergebnis = extrahieren(k, sprecher, cast, straenge, lauf_opts)
      Melder.stopp(melder)

      case ergebnis do
        {:ok, facts, saw, bericht} ->
          Logger.info(
            "jack #{session_id}: #{length(facts)} Fakten, Ende #{inspect(bericht.ende)}, " <>
              "neu je Durchgang #{inspect(Enum.map(bericht.durchgaenge, & &1.neu))}"
          )

          stand_ablegen(session_id, campaign.id, bericht.ablage)
          {:ok, Enum.map(facts, &Map.merge(&1, @geprueft)), saw}

        {:error, {:extraction, _}} = fehler ->
          fehler

        {:error, grund} ->
          {:error, {:extraction, {:jack, grund}}}
      end
    end
  end

  # Jacks Stand nach dem Lauf als Ereignis (Tom, 11.09.2026): so kann „noch N
  # Iterationen“ auf jedem Worker weitermachen. Nur der letzte Stand zählt
  # (LWW im Fold); der Payload reist als Map, kodiert wird im Fold.
  defp stand_ablegen(session_id, campaign_id, ablage) do
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.jack_stand_abgelegt(),
        "session_id" => session_id,
        "campaign_id" => campaign_id,
        "stand" => ablage
      })

    :ok
  end

  defp vorher(_session_id, _kontext, nil), do: {:ok, nil}

  defp vorher(session_id, kontext, n) when is_integer(n) and n > 0,
    do: abgelegter_stand(session_id, kontext)

  defp weiter_opts(opts, nil), do: opts

  defp weiter_opts(opts, ablage),
    do:
      opts |> Keyword.delete(:weiter) |> Keyword.merge(ablage: ablage, iterationen: opts[:weiter])

  @doc """
  Der zuletzt abgelegte Stand einer Sitzung, auf dem „noch N Iterationen“
  aufsetzt. Jacks Blocknummern gelten nur für die Blockliste, auf der er
  gelaufen ist; hat sie sich seitdem geändert (neu geglättet, ein Block
  `unbrauchbar`), zeigten sie auf andere Blöcke. Dann ist das ein Fehler —
  der Ausweg ist der ganze Lauf, nicht ein Bestand mit verrutschten Belegen.
  """
  @spec abgelegter_stand(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def abgelegter_stand(session_id, kontext) do
    ids = Enum.map(kontext, & &1.id)

    case Worker.Repo.jack_stand_for_session(session_id) do
      %{stand: %{"bloecke" => ^ids} = ablage} -> {:ok, ablage}
      %{stand: %{"bloecke" => _}} -> {:error, {:extraction, {:jack, :blockliste_geaendert}}}
      %{stand: _} -> {:error, {:extraction, {:jack, :blockliste_unbekannt}}}
      nil -> {:error, {:extraction, {:jack, :kein_stand}}}
    end
  end

  @doc """
  Die Kontextliste einer Sitzung aus der gespeicherten Glättung, ohne neu zu
  glätten — wie in `Pipeline.Dirty`: wirksamer Text aus Vorschlägen und
  Kurationen, `unbrauchbar` entfernt. Ohne Glättung ein Fehler.
  """
  @spec gespeicherter_kontext(String.t()) :: {:ok, [map()]} | {:error, term()}
  def gespeicherter_kontext(session_id) do
    case Worker.Repo.get_smoothed_blocks(session_id) do
      %{blocks: [_ | _] = blocks} ->
        vorschlaege = Worker.Repo.luecken_vorschlaege_for_session(session_id)
        %{attached: overrides} = Worker.Repo.luecken_overrides_effective(session_id, blocks)
        {:ok, Smoothing.to_context(blocks, vorschlaege, overrides)}

      _ ->
        {:error, {:extraction, {:jack, :keine_glaettung}}}
    end
  end

  @doc """
  Was bisher Stufe 3 (Verify) an Resümee und Epos weitergab, für Jacks
  Fakten: der Bestand der Sitzung, wie er nach Entity- und Strang-Registry
  gespeichert ist. Die Prüfung tragen die Fakten schon (`extract_facts/4`);
  ein zweites Modell urteilt nicht mehr (Tom, 11.09.2026).
  """
  @spec geprueft(String.t()) :: {:ok, [map()]} | {:error, :no_facts}
  def geprueft(session_id) do
    case Worker.Repo.get_session_facts(session_id) do
      %{facts: facts} -> {:ok, facts}
      nil -> {:error, :no_facts}
    end
  end

  @doc """
  Jacks Modell aus den lokalen Stufe-2-Einstellungen: `local_endpoint` und
  `model_stage2_local`, mit dem Sampling der Messläufe
  (`Worker.Jack.Messlauf.modell_reihe_c/1`). Ohne Endpunkt oder Modell ein
  Fehler, wie bei jedem anderen LLM-Schritt — kein stiller Rückfall.
  """
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell do
    endpunkt = Worker.Settings.get(:local_endpoint)
    name = Worker.Settings.model_for(2, :local)

    cond do
      not is_binary(endpunkt) or endpunkt == "" -> {:error, :no_local_endpoint_configured}
      not is_binary(name) or name == "" -> {:error, {:no_model_configured, 2}}
      true -> {:ok, Messlauf.modell_reihe_c(endpunkt: endpunkt, modell_name: name)}
    end
  end

  @doc """
  Jacks Aufträge für eine Sitzung mit `anzahl` Blöcken: die Vorlagen
  `phase1.md`, `phase2.md`, `folgelauf.md` aus `dir` (Default
  `priv/jack/auftraege/`) mit eingesetzten Blockzahlen (`fuellen/2`). Fehlt
  eine Vorlage, ist das ein Fehler.
  """
  @spec auftraege(non_neg_integer(), Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def auftraege(anzahl, dir \\ nil) do
    dir = dir || Application.app_dir(:worker, "priv/jack/auftraege")

    Enum.reduce_while(@auftrag_dateien, {:ok, %{}}, fn {k, datei}, {:ok, acc} ->
      pfad = Path.join(dir, datei)

      case File.read(pfad) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, k, fuellen(text, anzahl))}}
        {:error, _} -> {:halt, {:error, {:auftrag_fehlt, pfad}}}
      end
    end)
  end

  @doc """
  Setzt die Blockzahlen einer Sitzung in eine Vorlage ein:
  `{{letzter_block}}` (die höchste Blocknummer) und `{{anzahl_bloecke}}`.
  """
  @spec fuellen(String.t(), non_neg_integer()) :: String.t()
  def fuellen(text, anzahl) do
    text
    |> String.replace("{{letzter_block}}", Integer.to_string(max(anzahl - 1, 0)))
    |> String.replace("{{anzahl_bloecke}}", Integer.to_string(anzahl))
  end

  @doc """
  Die Extraktion durch Jack für eine Sitzung: Eingabe aus der Kontextliste
  (`eingabe/4`), ein Durchgang (`laufen/2`), Übersetzung in Fakten
  (`fakten/2`). Liefert `{:ok, facts, extraction_saw, bericht}` — `bericht`
  ist `laufen/2` ohne den Stand — oder `{:error, grund}`. Optionen wie
  `laufen/2`; mit `:ablage` (ein Stand aus `ablage/2`) statt dessen
  `weiterlaufen/3`.
  """
  @spec extrahieren([map()], %{String.t() => String.t()}, [String.t()], [String.t()], keyword()) ::
          {:ok, [map()], %{String.t() => String.t()}, map()} | {:error, term()}
  def extrahieren(kontext, sprecher, cast, straenge, opts) do
    with {:ok, e} <- eingabe(kontext, sprecher, cast, straenge),
         {:ok, lauf} <- lauf(e, opts),
         {:ok, facts, saw} <- fakten(Enum.map(lauf.stand.eingetragen, & &1.voll), kontext) do
      {:ok, facts, saw,
       lauf |> Map.delete(:stand) |> Map.put(:ablage, ablage(lauf.stand, kontext))}
    end
  end

  defp lauf(e, opts) do
    case Keyword.fetch(opts, :ablage) do
      {:ok, ablage} -> weiterlaufen(e, ablage, opts)
      :error -> laufen(e, opts)
    end
  end

  @doc """
  Was von Jacks Stand für die nächste Iteration aufgehoben wird (Tom,
  11.09.2026): der Bestand (`aussagen`, wie in `aussagen.jsonl`) und die
  Übergabe (`Fortsetzung.daten/1`: Gedächtnis samt allem, was die Iteration
  notiert hat, Kollisionszähler, Position) — ohne Jacks interne Journale.
  Dazu die Block-IDs der Kontextliste: nur für genau diese Liste gelten Jacks
  Blocknummern (`abgelegter_stand/2`).
  """
  @spec ablage(Stand.t(), [map()]) :: map()
  def ablage(%Stand{} = s, kontext),
    do: %{
      "aussagen" => Enum.map(s.eingetragen, & &1.voll),
      "fortsetzung" => Fortsetzung.daten(s),
      "bloecke" => Enum.map(kontext, & &1.id)
    }

  @doc """
  Ein Durchgang im Betrieb (Tom, 11.09.2026): Gedächtnis (Phase 1),
  Extraktion (Phase 2) und `:iterationen` Folgedurchgänge (Default 1), alles
  im Speicher, ohne Ablage. Ein Folgedurchgang, der nichts Neues bringt,
  beendet das Iterieren (`:gesaettigt`). Der Regellauf gehört ebenfalls in den
  Durchgang, ist aber noch nicht gebaut (#1207).

  Optionen: `:auftraege` (Pflicht, `%{phase1:, phase2:, folgelauf:}`),
  `:modell` (Pflicht), `:iterationen`, `:denken_zurueck`, `:max_runden`,
  `:max_ms`, `:beobachter`. Liefert `{:ok, %{stand:, durchgaenge:, ende:}}`;
  `ende` ist `:fertig`, `:gesaettigt` oder `{:iteration_ohne_abschluss, …}`.
  Endet Phase 1 oder 2 ohne `fertig`, ist das `{:error, …}` — ohne
  abgeschlossene Extraktion gibt es keinen Bestand, der für die Sitzung steht.
  Eine abgebrochene Iteration behält dagegen, was sie eingetragen hat: jede
  Aussage ist einzeln geprüft.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts) do
    a = Keyword.fetch!(opts, :auftraege)
    basis = basis(eingabe)
    phase_opts = phase_opts(opts)

    s1 = Stand.neu(basis ++ [phase: 1])

    auftrag1 =
      String.trim_trailing(a.phase1) <> "\n\nDer Mitschnitt hat die Blöcke 0 bis #{s1.max_block}."

    with {:ok, s1} <- phase(s1, auftrag1, phase_opts, :phase1_ohne_abschluss),
         s2 = Stand.neu(basis ++ [phase: 2, register: s1.register]),
         {:ok, s2} <-
           phase(s2, mit_gedaechtnis(a.phase2, s2), phase_opts, :phase2_ohne_abschluss) do
      erster = %{nr: 1, vorher: 0, bestand: s2.lfd, neu: s2.lfd}
      iterieren(s2, Keyword.get(opts, :iterationen, 1), [erster], folgelauf(a, basis, phase_opts))
    end
  end

  @doc """
  „Noch N Iterationen“ (Tom, 11.09.2026): `:iterationen` Folgedurchgänge auf
  einem abgelegten Stand (`ablage/2`), ohne Gedächtnis und Extraktion neu zu
  fahren — Jack bekommt Bestand, Gedächtnis und Kollisionszähler, wie sie der
  letzte Lauf hinterlassen hat. Optionen und Ergebnis wie `laufen/2`; die
  Durchgänge zählen ab 1 für diesen Aufruf.
  """
  @spec weiterlaufen(map(), map(), keyword()) :: {:ok, map()}
  def weiterlaufen(eingabe, ablage, opts) do
    a = Keyword.fetch!(opts, :auftraege)
    basis = basis(eingabe)

    s =
      Fortsetzung.aus_daten(
        ablage["aussagen"] || [],
        ablage["fortsetzung"] || %{},
        basis ++ [phase: 2]
      )

    iterieren(s, Keyword.get(opts, :iterationen, 1), [], folgelauf(a, basis, phase_opts(opts)))
  end

  defp basis(e), do: [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge]

  defp phase_opts(opts),
    do:
      Keyword.take(opts, [
        :modell,
        :denken_zurueck,
        :max_runden,
        :max_ms,
        :beobachter,
        :stand_beobachter
      ])

  # Ein Folgedurchgang: frischer Stand aus der Übergabe, Auftrag mit Gedächtnis.
  defp folgelauf(a, basis, phase_opts) do
    fn s ->
      naechster = Fortsetzung.naechster(s, basis ++ [phase: 2])
      Phase.laufen(naechster, mit_gedaechtnis(a.folgelauf, naechster), phase_opts)
    end
  end

  defp iterieren(s, 0, durchgaenge, _fahren), do: fertig(s, durchgaenge, :fertig)

  defp iterieren(s, rest, durchgaenge, fahren) do
    {ergebnis, n} = fahren.(s)
    d = %{nr: length(durchgaenge) + 1, vorher: s.lfd, bestand: n.lfd, neu: n.lfd - s.lfd}
    durchgaenge = durchgaenge ++ [d]

    cond do
      not Phase.abgeschlossen?(ergebnis) ->
        fertig(n, durchgaenge, {:iteration_ohne_abschluss, Phase.ende(ergebnis)})

      d.neu <= 0 ->
        fertig(n, durchgaenge, :gesaettigt)

      true ->
        iterieren(n, rest - 1, durchgaenge, fahren)
    end
  end

  defp fertig(s, durchgaenge, ende), do: {:ok, %{stand: s, durchgaenge: durchgaenge, ende: ende}}

  defp phase(s, auftrag, opts, fehler) do
    {ergebnis, s} = Phase.laufen(s, auftrag, opts)

    if Phase.abgeschlossen?(ergebnis),
      do: {:ok, s},
      else: {:error, {fehler, Phase.ende(ergebnis)}}
  end

  defp mit_gedaechtnis(auftrag, s) do
    gedaechtnis = s |> Gedaechtnis.notizen_text() |> String.trim_trailing()
    String.trim_trailing(auftrag) <> "\n\n## Dein Gedächtnis\n\n" <> gedaechtnis
  end

  @doc "Die Kontextliste, die Jack sieht: wie bei der Extraktion ohne OOC-Blöcke."
  @spec kontext([map()]) :: [map()]
  def kontext(bloecke), do: Ooc.filter(bloecke)

  @doc """
  Jacks Eingabe (`%{bloecke:, cast:, straenge:}`, wie `Worker.Jack.Stand.neu/1`
  sie erwartet) aus der Kontextliste. `sprecher` bildet Discord-IDs auf Namen
  ab (`Prompts.resolve_speaker_names/1`). Ein Block ohne Namen ist ein Fehler:
  Jack bekäme sonst eine Discord-ID als Sprecher.
  """
  @spec eingabe([map()], %{String.t() => String.t()}, [String.t()], [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def eingabe(kontext, sprecher, cast, straenge) do
    case kontext
         |> Enum.map(& &1.discord_id)
         |> Enum.uniq()
         |> Enum.reject(&Map.has_key?(sprecher, &1)) do
      [] ->
        {:ok,
         %{
           bloecke:
             Enum.map(kontext, fn b ->
               %{text: b.text || "", sprecher: Map.fetch!(sprecher, b.discord_id), block_id: b.id}
             end),
           cast: ohne_leere(cast),
           straenge: ohne_leere(straenge)
         }}

      ohne ->
        {:error, {:sprecher_ohne_namen, ohne}}
    end
  end

  @doc """
  Aus Jacks Bestand (die Zeilen von `aussagen.jsonl`, also `voll` der
  eingetragenen Aussagen) die Fakten der Pipeline und die Zeit-Adresse
  `extraction_saw`. `kontext` ist dieselbe Liste wie für `eingabe/4`. Ein
  Bestand ohne gültige Aussage ist `{:error, {:extraction, :empty}}`, wie bei
  der Extraktion.
  """
  @spec fakten([map()], [map()]) ::
          {:ok, [map()], %{String.t() => String.t()}} | {:error, term()}
  def fakten(aussagen, kontext) do
    ids = kontext |> Enum.map(& &1.id) |> List.to_tuple()

    liste =
      for %{"nummer" => n} = a <- aussagen, is_integer(n), a["_verworfen"] != true do
        Map.put(a, "source_refs", block_ids(a["source_refs"], ids))
      end

    case Parsing.parse_facts_json(Jason.encode!(%{"facts" => liste}), kontext) do
      {:ok, [_ | _] = facts} -> {:ok, facts, extraction_saw(kontext)}
      {:ok, []} -> {:error, {:extraction, :empty}}
      {:error, grund} -> {:error, {:extraction, grund}}
    end
  end

  @doc """
  Welchen Text Jack je Block gesehen hat (Block-ID → `Smoothing.text_hash/1`)
  — genau wie die Extraktion (`Stages.extract_facts_raw/3`), damit die
  Dirty-Weiche nach einer Kuration dieselbe Adresse vorfindet.
  """
  @spec extraction_saw([map()]) :: %{String.t() => String.t()}
  def extraction_saw(kontext),
    do: Map.new(kontext, fn b -> {b.id, Smoothing.text_hash(b.text || "")} end)

  # Nummern außerhalb der Liste kann Jack nicht belegt haben — die Belegprüfung
  # kennt nur Blöcke der Eingabe; sie fallen still weg wie ein erfundener Ref
  # bei der Extraktion.
  defp block_ids(refs, ids) when is_list(refs) do
    for n <- refs, is_integer(n), n >= 0, n < tuple_size(ids), uniq: true, do: elem(ids, n)
  end

  defp block_ids(_refs, _ids), do: []

  defp ohne_leere(liste), do: liste |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
end
