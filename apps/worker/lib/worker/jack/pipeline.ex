defmodule Worker.Jack.Pipeline do
  @moduledoc """
  Jack in der Pipeline (J4, #1207): was Jack von einer Sitzung zu lesen
  bekommt und wie aus seinem Bestand die Fakten werden, die bisher die
  Extraktion geliefert hat — ein `SessionFactsExtracted` mit `facts` und
  `extraction_saw`, damit alles dahinter (Kuration, Dirty-Weiche,
  Fakt-Overlays, Render) unberührt bleibt.

  **Dieselbe Blockliste wie Kuration und Dirty-Weiche.** `eingabe/4` und
  `fakten/2` bekommen die Kontextliste des Laufs: `Smoothing.to_context/3`
  (wirksamer Text, `unbrauchbar` entfernt), danach der OOC-Filter
  (`kontext/1`). Jacks Blocknummer n ist die
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

  **Einstellungen (Block „Jack: Extract/verify“ in `/settings`).** Modell
  `model_stage2_local` und Endpunkt `local_endpoint` (Stufe 2 ist immer
  lokal), Sampling aus `jack_temperature`, `jack_top_p`,
  `jack_frequency_penalty`, `jack_max_tokens` (`modell/0`), Kontextfenster aus
  `ctx_jack` (`kontext_fenster/0`). Die Defaults sind die Werte der Messreihe C;
  die Messläufe (`Worker.Jack.Messlauf`) lesen keine Einstellungen und bleiben
  dadurch vergleichbar.

  **Laufband.** Jack meldet seine drei Stufen selbst (`Shared.PipelineStufen`:
  `jack_gedaechtnis`, `extract`, `jack_verifikation`) über den Rückruf
  `:melde_stufe` — `(stufe, ereignis)` mit `:beginn`, `{:ende, ergebnis}`
  (`:ok` oder `{:error, grund}`), `{:zaehlung, gesamt, durchgang}` und
  `{:gelesen, block, durchgang}`. Ohne ihn meldet Jack nichts (Neuableitung,
  Messläufe, Tests). Die Pipeline übersetzt ihn in Stufenmeldungen,
  `Fortschritt` und `/admin/errors`
  (`Worker.Recording.Pipeline.stufen_melder/3`). Ein Fehler, der keiner Phase
  gehört — vor dem Lauf oder beim Übersetzen des Bestands —, erscheint als
  Fehlschlag der Extraktion.
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

  # Gesättigt sind zwei Verifikationen in Folge ohne neue Aussage — das
  # Zielverhalten für Prod (Tom, 11.09.2026). Eine allein ist auf kleinen
  # Sitzungen die Regel, nicht das Ende. Höchstens so viele Verifikationen wie
  # im Referenzlauf.
  @ohne_neu_bis_gesaettigt 2
  @verifikationen_deckel 8

  # Die Stufennamen des Laufbands (`Shared.PipelineStufen`).
  @gedaechtnis "jack_gedaechtnis"
  @extraktion "extract"
  @verifikation "jack_verifikation"

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
  `auftraege/2`. Liefert `{:ok, facts, extraction_saw}` — die Form, die die
  Neuableitung (`Worker.Recording.Pipeline.Dirty`) erwartet.

  `weiter: n` (Tom, 11.09.2026, „noch N Iterationen“): statt Gedächtnis und
  Extraktion n Folgedurchgänge auf dem abgelegten Stand der Sitzung
  (`abgelegter_stand/2`). Die Fakten sind danach der ganze Bestand, alt und
  neu. Im Laufband erscheint dann nur die Verifikation.

  `melde_stufe:` — der Rückruf fürs Laufband (Moduledoc). Ein Fehler vor den
  Phasen (Modell, Kontextfenster, Aufträge, abgelegter Stand) wird als
  Fehlschlag der Extraktion gemeldet, wie er zurückkommt.
  """
  @spec extract_facts_raw([map()], String.t(), map(), keyword()) ::
          {:ok, [map()], %{String.t() => String.t()}} | {:error, term()}
  def extract_facts_raw(bloecke, session_id, campaign, opts \\ []) do
    k = kontext(bloecke)

    with {:ok, modell} <- modell(),
         {:ok, fenster} <- kontext_fenster(),
         {:ok, a} <- auftraege(length(k)),
         {:ok, vorher} <- vorher(session_id, k, opts[:weiter]) do
      sprecher = sprecher(campaign.id, k)
      cast = Worker.Repo.character_roster_for(campaign.id)
      straenge = campaign.id |> Worker.Repo.Threads.campaign_threads() |> Enum.map(& &1.canonical)

      # Die Laufsicht (Tom, 11.09.2026): bekommt das Protokoll direkt und den
      # Stand je Phase über den Melder des Laufbands (`gezaehlt/4`).
      lauf_opts =
        Keyword.merge(
          [
            auftraege: a,
            modell: modell,
            kontext_fenster: fenster,
            beobachter: Process.whereis(Worker.Jack.Sicht)
          ],
          weiter_opts(opts, vorher)
        )

      case extrahieren(k, sprecher, cast, straenge, lauf_opts) do
        {:ok, facts, saw, bericht} ->
          Logger.info(
            "jack #{session_id}: #{length(facts)} Fakten, Ende #{inspect(bericht.ende)}, " <>
              "neu je Durchgang #{inspect(Enum.map(bericht.durchgaenge, & &1.neu))}"
          )

          stand_ablegen(session_id, campaign.id, bericht.ablage)
          {:ok, Enum.map(facts, &Map.merge(&1, @geprueft)), saw}

        fehler ->
          markiert(fehler)
      end
    else
      fehler ->
        melde_fehlschlag(opts, fehler)
        fehler
    end
  end

  # Die Form, in der Jacks Fehler die Pipeline verlassen: `{:extraction, …}`
  # bleibt, alles andere wird `{:extraction, {:jack, grund}}`.
  defp markiert({:error, {:extraction, _}} = fehler), do: fehler
  defp markiert({:error, grund}), do: {:error, {:extraction, {:jack, grund}}}

  defp melder(opts), do: Keyword.get(opts, :melde_stufe, fn _stufe, _ereignis -> :ok end)

  # Ein Fehler, der keiner Phase gehört (vor dem Lauf, Sprecher ohne Namen,
  # ein Bestand ohne gültige Aussage): als Fehlschlag der Extraktion, damit er
  # in /admin/errors steht.
  defp melde_fehlschlag(opts, fehler) do
    melde = melder(opts)
    melde.(@extraktion, :beginn)
    melde.(@extraktion, {:ende, fehler})
    :ok
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
  Jacks Modell aus den Einstellungen: `local_endpoint` und
  `model_stage2_local`, gebaut über `Worker.Jack.Messlauf.modell_reihe_c/1`
  mit `jack_temperature` (→ `temperatur`), `jack_max_tokens`
  (→ `max_ausgabe`), `jack_top_p` und `jack_frequency_penalty` (→ `extra`).
  Ungesetzt gelten die Defaults aus `Worker.Settings` — exakt die Werte der
  Reihe C, Jacks Verhalten ändert sich ohne Eingriff also nicht. Ohne Endpunkt
  oder Modell ein Fehler, wie bei jedem anderen LLM-Schritt — kein stiller
  Rückfall.
  """
  @spec modell() :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell, do: modell(Worker.Settings.model_for(2, :local))

  @doc """
  Wie `modell/0`, aber mit einem anderen Modellnamen — Endpunkt, Regler und
  Fehler wie dort. Für den Resümee-Jack (J5, #1209), der Jacks Einstellungen
  teilt und nur das Modell eigens wählen kann
  (`Worker.Jack.Resuemee.Pipeline.modell/0`).
  """
  @spec modell(String.t() | nil) :: {:ok, {module(), keyword()}} | {:error, term()}
  def modell(name) do
    endpunkt = Worker.Settings.get(:local_endpoint)

    cond do
      not is_binary(endpunkt) or endpunkt == "" ->
        {:error, :no_local_endpoint_configured}

      not is_binary(name) or name == "" ->
        {:error, {:no_model_configured, 2}}

      true ->
        {:ok,
         Messlauf.modell_reihe_c(
           endpunkt: endpunkt,
           modell_name: name,
           temperatur: Worker.Settings.get(:jack_temperature),
           max_ausgabe: Worker.Settings.get(:jack_max_tokens),
           extra: %{
             "top_p" => Worker.Settings.get(:jack_top_p),
             "frequency_penalty" => Worker.Settings.get(:jack_frequency_penalty)
           }
         )}
    end
  end

  @doc """
  Jacks Kontextfenster aus `ctx_jack` (Default 98 304, wie in den
  Messläufen), für `Worker.Jack.Phase` (`:kontext_fenster`). Es steuert nur
  Jacks eigene Kompaktierung — das Fenster des Servers setzt der Client nicht
  (`Worker.Agent.Modell.Ollama`), beide müssen zueinander passen. Ein Wert
  unter `Worker.Jack.Phase.mindestfenster/0` (oder keine ganze Zahl) ist
  `{:error, {:ctx_jack_ungueltig, wert, mindestens}}` — vor dem Lauf und
  sichtbar in `/admin/errors`, statt dass die Laufzeit mitten im Start mit
  `ArgumentError` abbricht.
  """
  @spec kontext_fenster() :: {:ok, pos_integer()} | {:error, term()}
  def kontext_fenster do
    mindestens = Phase.mindestfenster()

    case Worker.Settings.get(:ctx_jack) do
      n when is_integer(n) and n >= mindestens -> {:ok, n}
      anderes -> {:error, {:ctx_jack_ungueltig, anderes, mindestens}}
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
  `weiterlaufen/3`. Fehler bei der Eingabe oder beim Übersetzen gehen mit
  `:melde_stufe` als Fehlschlag der Extraktion ans Laufband; die der Phasen
  meldet `laufen/2`.
  """
  @spec extrahieren([map()], %{String.t() => String.t()}, [String.t()], [String.t()], keyword()) ::
          {:ok, [map()], %{String.t() => String.t()}, map()} | {:error, term()}
  def extrahieren(kontext, sprecher, cast, straenge, opts) do
    case eingabe(kontext, sprecher, cast, straenge) do
      {:ok, e} ->
        mit_eingabe(e, kontext, opts)

      fehler ->
        melde_fehlschlag(opts, markiert(fehler))
        fehler
    end
  end

  defp mit_eingabe(e, kontext, opts) do
    with {:ok, lauf} <- lauf(e, opts) do
      case fakten(Enum.map(lauf.stand.eingetragen, & &1.voll), kontext) do
        {:ok, facts, saw} ->
          {:ok, facts, saw,
           lauf |> Map.delete(:stand) |> Map.put(:ablage, ablage(lauf.stand, kontext))}

        fehler ->
          melde_fehlschlag(opts, fehler)
          fehler
      end
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
  Extraktion (Phase 2) und Verifikationen (Folgedurchgänge) bis zur Sättigung —
  zwei in Folge ohne neue Aussage (`:gesaettigt`) —, höchstens `:iterationen`
  (Default 8, der Deckel des Referenzlaufs; erreicht: `:fertig`). Alles im
  Speicher, ohne Ablage. Der Regellauf gehört ebenfalls in den Durchgang, ist
  aber noch nicht gebaut (#1207).

  Optionen: `:auftraege` (Pflicht, `%{phase1:, phase2:, folgelauf:}`),
  `:modell` (Pflicht), `:kontext_fenster` (an jede Phase, siehe
  `Worker.Jack.Phase`; im Betrieb aus `kontext_fenster/0`), `:iterationen`,
  `:denken_zurueck`, `:max_runden`, `:max_ms`, `:beobachter`, `:melde_stufe`
  (Moduledoc). Liefert `{:ok, %{stand:, durchgaenge:, ende:}}`;
  `ende` ist `:fertig`, `:gesaettigt` oder `{:iteration_ohne_abschluss, …}`.
  Endet Phase 1 oder 2 ohne `fertig`, ist das `{:error, …}` — ohne
  abgeschlossene Extraktion gibt es keinen Bestand, der für die Sitzung steht.
  Eine abgebrochene Iteration behält dagegen, was sie eingetragen hat: jede
  Aussage ist einzeln geprüft. Im Laufband ist sie ein Fehlschlag der
  Verifikation, der Lauf geht weiter.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts) do
    a = Keyword.fetch!(opts, :auftraege)
    basis = basis(eingabe)
    phase_opts = phase_opts(opts)
    melde = melder(opts)

    s1 = Stand.neu(basis ++ [phase: 1])

    auftrag1 =
      String.trim_trailing(a.phase1) <> "\n\nDer Mitschnitt hat die Blöcke 0 bis #{s1.max_block}."

    with {:ok, s1} <-
           phase(s1, auftrag1, phase_opts, {melde, @gedaechtnis}, :phase1_ohne_abschluss),
         s2 = Stand.neu(basis ++ [phase: 2, register: s1.register]),
         {:ok, s2} <-
           phase(
             s2,
             mit_gedaechtnis(a.phase2, s2),
             phase_opts,
             {melde, @extraktion},
             :phase2_ohne_abschluss
           ) do
      erster = %{nr: 1, vorher: 0, bestand: s2.lfd, neu: s2.lfd}
      max = Keyword.get(opts, :iterationen, @verifikationen_deckel)
      verifizieren(s2, max, [erster], folgelauf(a, basis, phase_opts, melde), melde)
    end
  end

  @doc """
  „Noch N Iterationen“ (Tom, 11.09.2026): `:iterationen` Folgedurchgänge auf
  einem abgelegten Stand (`ablage/2`), ohne Gedächtnis und Extraktion neu zu
  fahren — Jack bekommt Bestand, Gedächtnis und Kollisionszähler, wie sie der
  letzte Lauf hinterlassen hat. Optionen und Ergebnis wie `laufen/2`;
  `:iterationen` ist eine Obergrenze, gesättigt ist der Aufruf nach zwei
  Verifikationen in Folge ohne Neues. Die Durchgänge zählen ab 1 für diesen
  Aufruf.
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

    melde = melder(opts)

    verifizieren(
      s,
      Keyword.get(opts, :iterationen, 1),
      [],
      folgelauf(a, basis, phase_opts(opts), melde),
      melde
    )
  end

  defp basis(e), do: [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge]

  # Ohne `:stand_beobachter`: den setzt je Phase der Melder (`gezaehlt/4`).
  defp phase_opts(opts),
    do:
      Keyword.take(opts, [
        :modell,
        :kontext_fenster,
        :denken_zurueck,
        :max_runden,
        :max_ms,
        :beobachter
      ])

  # Ein Folgedurchgang: frischer Stand aus der Übergabe, Auftrag mit Gedächtnis.
  # `nr` ist der wievielte Verifikationsdurchgang dieses Aufrufs — fürs Band.
  defp folgelauf(a, basis, phase_opts, melde) do
    fn s, nr ->
      naechster = Fortsetzung.naechster(s, basis ++ [phase: 2])

      gezaehlt(
        naechster,
        mit_gedaechtnis(a.folgelauf, naechster),
        phase_opts,
        {melde, @verifikation, nr}
      )
    end
  end

  # Die Verifikationen sind EINE Stufe des Laufbands; jeder Durchgang zählt
  # seine Blöcke neu (`folgelauf/4`). Ohne Iteration läuft sie nicht und
  # bleibt im Band offen. Eine abgebrochene Verifikation ist ein Fehlschlag
  # dieser Stufe, aber keiner des Laufs: der Bestand bis dahin gilt.
  defp verifizieren(s, max, durchgaenge, fahren, _melde) when max == 0,
    do: iterieren(s, 0, durchgaenge, fahren)

  defp verifizieren(s, max, durchgaenge, fahren, melde) do
    melde.(@verifikation, :beginn)
    {:ok, bericht} = ergebnis = iterieren(s, max, durchgaenge, fahren)

    ende =
      case bericht.ende do
        {:iteration_ohne_abschluss, _} = abbruch -> markiert({:error, abbruch})
        _gesaettigt_oder_fertig -> :ok
      end

    melde.(@verifikation, {:ende, ende})
    ergebnis
  end

  # `ohne_neu`: wie viele Verifikationen dieses Aufrufs zuletzt in Folge nichts
  # Neues brachten; ein Fund setzt ihn zurück. `nr`: die wievielte
  # Verifikation dieses Aufrufs, ab 1.
  defp iterieren(s, rest, durchgaenge, fahren, ohne_neu \\ 0, nr \\ 1)

  defp iterieren(s, 0, durchgaenge, _fahren, _ohne_neu, _nr), do: fertig(s, durchgaenge, :fertig)

  defp iterieren(s, rest, durchgaenge, fahren, ohne_neu, nr) do
    {ergebnis, n} = fahren.(s, nr)
    d = %{nr: length(durchgaenge) + 1, vorher: s.lfd, bestand: n.lfd, neu: n.lfd - s.lfd}
    durchgaenge = durchgaenge ++ [d]
    ohne_neu = if d.neu <= 0, do: ohne_neu + 1, else: 0

    cond do
      not Phase.abgeschlossen?(ergebnis) ->
        fertig(n, durchgaenge, {:iteration_ohne_abschluss, Phase.ende(ergebnis)})

      ohne_neu >= @ohne_neu_bis_gesaettigt ->
        fertig(n, durchgaenge, :gesaettigt)

      true ->
        iterieren(n, rest - 1, durchgaenge, fahren, ohne_neu, nr + 1)
    end
  end

  defp fertig(s, durchgaenge, ende), do: {:ok, %{stand: s, durchgaenge: durchgaenge, ende: ende}}

  # Gedächtnis und Extraktion: je eine Phase, je eine Stufe des Laufbands.
  defp phase(s, auftrag, opts, {melde, stufe}, fehler) do
    melde.(stufe, :beginn)
    {ergebnis, s} = gezaehlt(s, auftrag, opts, {melde, stufe, nil})

    if Phase.abgeschlossen?(ergebnis) do
      melde.(stufe, {:ende, :ok})
      {:ok, s}
    else
      fehlschlag = {:error, {fehler, Phase.ende(ergebnis)}}
      melde.(stufe, {:ende, markiert(fehlschlag)})
      fehlschlag
    end
  end

  # Eine Phase mit eigenem Melder fürs Laufband (`Worker.Jack.Melder`): er
  # zählt nur die Blöcke, die diese Phase liest, und reicht jeden Stand an die
  # Laufsicht weiter. Warum je Phase einer, steht dort.
  defp gezaehlt(s, auftrag, phase_opts, {melde, stufe, nr}) do
    melder = Melder.start(melde, stufe, s.max_block + 1, nr, weiter: phase_opts[:beobachter])
    ergebnis = Phase.laufen(s, auftrag, Keyword.put(phase_opts, :stand_beobachter, melder))
    Melder.stopp(melder)
    ergebnis
  end

  defp mit_gedaechtnis(auftrag, s) do
    gedaechtnis = s |> Gedaechtnis.notizen_text() |> String.trim_trailing()
    String.trim_trailing(auftrag) <> "\n\n## Dein Gedächtnis\n\n" <> gedaechtnis
  end

  @doc "Die Kontextliste, die Jack sieht: wie bei der Extraktion ohne OOC-Blöcke."
  @spec kontext([map()]) :: [map()]
  def kontext(bloecke), do: Ooc.filter(bloecke)

  @doc """
  Die Namen der Sprecher einer Kontextliste: Figur oder Mitglied der Kampagne
  (`Prompts.resolve_speaker_names/1`), sonst der Anzeigename des Nutzers, sonst
  eine neutrale Bezeichnung (`namen_ergaenzen/3`). Gebraucht wird der zweite
  Schritt, sobald jemand spricht, der kein Mitglied (mehr) ist — ein
  ausgetretenes Mitglied bleibt im Mitschnitt. Die alte Extraktion setzte dann
  die Discord-ID ein; Jack bekommt nie eine.
  """
  @spec sprecher(String.t(), [map()]) :: %{String.t() => String.t()}
  def sprecher(campaign_id, kontext) do
    namen_ergaenzen(Prompts.resolve_speaker_names(campaign_id), kontext, fn did ->
      case Worker.Repo.get_user(did) do
        %{display_name: name} -> name
        nil -> nil
      end
    end)
  end

  @doc """
  Ergänzt `namen` um jeden Sprecher der Kontextliste, der keinen Namen hat —
  fehlend, leer oder nur seine Discord-ID: `Repo.fetch_users/1` liefert für
  ein Mitglied ohne Nutzerzeile die Discord-ID als Anzeigenamen, und die kam
  sonst als „Name“ bei Jack an. Erst über `nachschlagen` (Discord-ID → Name
  oder `nil`), sonst als „Sprecher ohne Namen N“, in der Reihenfolge des
  ersten Auftretens. Die Ersatzbezeichnung wird laut geloggt.
  """
  @spec namen_ergaenzen(map(), [map()], (String.t() -> String.t() | nil)) :: map()
  def namen_ergaenzen(namen, kontext, nachschlagen) do
    kontext
    |> Enum.map(& &1.discord_id)
    |> Enum.uniq()
    |> Enum.filter(&kein_name?(Map.get(namen, &1), &1))
    |> Enum.reduce({namen, 1}, fn did, {acc, n} ->
      name = nachschlagen.(did)

      case kein_name?(name, did) do
        false ->
          {Map.put(acc, did, name), n}

        true ->
          Logger.warning("jack: Sprecher #{did} ohne Namen — heißt „Sprecher ohne Namen #{n}“")
          {Map.put(acc, did, "Sprecher ohne Namen #{n}"), n + 1}
      end
    end)
    |> elem(0)
  end

  defp kein_name?(name, did), do: not is_binary(name) or name in ["", did]

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
  — die Zeit-Adresse, gegen die die Dirty-Weiche nach einer Kuration prüft.
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
