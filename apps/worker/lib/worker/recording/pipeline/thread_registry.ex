defmodule Worker.Recording.Pipeline.ThreadRegistry do
  @moduledoc """
  Issue #832 (Epic #829 Slice C): die campaign-weite Handlungsbogen-Cluster-Map.

  Die Extraktion (#831) setzt pro Fakt ein rohes `thread`-Label — je nach Modell
  fragmentiert (derselbe Strang unter „der Skandal in Böhmen" / „der Coup-Plan" /
  „der Brief"). Diese Registry clustert die distinkten Roh-Labels einer Kampagne
  zu **kanonischen Strängen** und persistiert die Map als **Whole-Snapshot-
  Artefakt** (`ThreadRegistryComputed` → `worker_thread_registry`, 1 Row/Kampagne).
  Seit #885 klassifiziert das Clustering jeden Kanon-Strang zusätzlich als
  `"arc"` (auflösbarer Handlungsbogen) oder `"context"` (zeitloses Weltwissen —
  schließt nie ab), seit #901 (Epic #900) zusätzlich als `"rauschen"`
  (Meta-/Tisch-/Werkzeug-Gerede, das nicht in der Spielwelt stattfindet — fällt
  aus den inhaltlichen Sichten); die Klassifikation reist als `kinds`-Map im
  selben Snapshot.

  **Bewusster Unterschied zur `EntityRegistry`:** die re-keyt `entity_id` in den
  Fakt-Blob zurück (zweiter Schreibpfad, N-Session-Republish). Die ThreadRegistry
  tut das NICHT — die Fakten behalten ihr Roh-`thread`-Label, der Reader
  (`campaign_threads/1`, #833) wendet die Cluster-Map zur Lesezeit an. Vorteile:
  kein zweiter Fakt-Schreibpfad, Re-Cluster = 1-Row-Write, und die Whole-Snapshot-
  Semantik macht LWW-per-Kampagne partial-payload-frei (Voll-Ersatz, kein Merge).

  Läuft im `resolve`-Schritt von `run_wahrheitsbild` (single-worker-gated,
  best-effort — ein Cluster-Fehler lässt die Roh-Labels unverändert, wie #714
  bei den Entitäten; sichtbar in `/admin/errors` wie #820).

  **Seit #842 inkrementell, nicht mehr bei jedem Pipeline-Lauf voll neu:**
  `resolve_campaign_threads/2` clustert nur die Roh-Labels, die seit dem
  letzten Lauf neu dazugekommen sind, gegen die bestehenden Kanon-Stränge als
  Kontext — bestehende Kanon-Texte werden dabei nie verändert (schützt die
  `worker_thread_overrides`-Kuration vor Verwaisen im Normalfall). Der frühere
  Vollpfad (jeden Lauf alle Roh-Labels der Kampagne neu clustern) lebt als
  `full_recluster_campaign_threads/2` weiter — ein seltener, expliziter,
  GM-getriggerter Vorgang (Fäden-Panel-Button „Fäden neu clustern"), bei dem
  sich Kanon-Texte ändern KÖNNEN (bekanntes Restrisiko für
  `worker_thread_overrides`, s. `full_recluster_campaign_threads/2`-Doku).

  Pure Kerne (`distinct_threads/1`, `parse_clustering/1`, `build_map/1`,
  `new_raw_labels/2`, `merge_incremental_result/4`, …) sind ohne LLM testbar;
  das Clustering ist die I/O-Grenze (`cluster_fn` injizierbar).
  """

  alias Worker.{Intents, Repo}
  alias Worker.LLM
  alias Worker.Schema.Mnesia, as: S

  import Worker.Recording.Pipeline.Parsing, only: [guard_prompt_size: 3]

  require Logger

  @doc "Distinkte, nicht-leere `thread`-Roh-Labels aus den Fakten."
  @spec distinct_threads([map()]) :: [String.t()]
  def distinct_threads(facts) when is_list(facts) do
    facts
    |> Enum.map(fn f -> f |> Map.get("thread", "") |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Parst den Clustering-Output (`%{"threads" => [%{"canonical", "labels", "kind"}]}`)
  zu `%{map: cluster_map, kinds: kinds}` — `map` ist die Cluster-Map
  `%{normalisiertes_roh_label => kanonisches Anzeige-Label}` (Anders als bei der
  EntityRegistry bleibt der WERT die **menschenlesbare** canonical-Form; nur der
  Schlüssel wird normalisiert), `kinds` die Klassifikation
  `%{normalisiertes_canonical => "arc" | "context" | "rauschen"}` (Issues
  #885/#901). Fehlendes/unbekanntes `kind` fällt auf `"arc"` (fail-safe =
  bisheriges Verhalten: der Strang bleibt im Fäden-Panel sichtbar, statt still
  in ein Themen-/Rauschen-Register zu verschwinden). Junk-Cluster (ohne
  canonical) werden übersprungen.
  """
  # Reasons bewusst distinkt von EntityRegistry (`:parse_failed`/`:no_entities_key`)
  # — sonst würde ein Thread-Clustering-Fehler in `/admin/errors` als
  # „entity_registry_*" fehl-klassifiziert (classify_pipeline_error sieht nur das
  # Atom, nicht den resolve-Schritt).
  @spec parse_clustering(binary() | nil) ::
          {:ok, %{map: map(), kinds: map()}} | {:error, atom()}
  def parse_clustering(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"threads" => threads}} when is_list(threads) ->
        {:ok, build_map(threads)}

      {:ok, _} ->
        {:error, :no_threads_key}

      {:error, _} ->
        {:error, :thread_parse_failed}
    end
  end

  def parse_clustering(_), do: {:error, :thread_parse_failed}

  @doc false
  def build_map(threads) when is_list(threads) do
    Enum.reduce(threads, %{map: %{}, kinds: %{}}, fn thread, acc ->
      canonical = thread |> Map.get("canonical", "") |> to_string() |> String.trim()

      if canonical == "" do
        acc
      else
        labels = [canonical | List.wrap(Map.get(thread, "labels"))]

        map =
          Enum.reduce(labels, acc.map, fn l, m ->
            case normalize(l) do
              "" -> m
              key -> Map.put(m, key, canonical)
            end
          end)

        # #901: echte Drei-Wege-Whitelist — der frühere Binär-Kollaps
        # (alles ≠ "context" → "arc") würde ein LLM-"rauschen" still schlucken.
        kind =
          case Map.get(thread, "kind") do
            k when k in ["context", "rauschen"] -> k
            _ -> "arc"
          end

        %{acc | map: map, kinds: Map.put(acc.kinds, normalize(canonical), kind)}
      end
    end)
  end

  # ─── #842: inkrementelle Hilfsfunktionen (pure, ohne LLM testbar) ───────

  @doc """
  Roh-Labels aus `all_raw_labels`, deren Normalform noch KEIN Key der
  persistierten `cluster_map` ist — der Diff, der das inkrementelle
  Clustering überhaupt erst klein hält. Kein separates Watermark-Tracking:
  die persistierte Map kodiert selbst, welche Roh-Labels bereits geclustert
  wurden.
  """
  @spec new_raw_labels([String.t()], map()) :: [String.t()]
  def new_raw_labels(all_raw_labels, persisted_map)
      when is_list(all_raw_labels) and is_map(persisted_map) do
    Enum.reject(all_raw_labels, &Map.has_key?(persisted_map, normalize(&1)))
  end

  @doc """
  Distinkte, ROHE gespeicherte Kanon-Texte der persistierten Map — bewusst
  NICHT der `rename`-Override-Anzeigetext (der wird erst zur Lesezeit
  angewandt, `Worker.Repo.Threads.build_thread/9`). Würde die Registry hier
  den Anzeigetext als Anker verwenden, würde sie den rename-Override selbst
  duplizieren/umgehen.
  """
  @spec existing_anchors(map()) :: [String.t()]
  def existing_anchors(persisted_map) when is_map(persisted_map) do
    persisted_map |> Map.values() |> Enum.uniq()
  end

  @doc """
  Deckelt die Anker-Liste auf `n` Einträge für den Prompt — größte Cluster
  (# Roh-Labels) zuerst, Tie-Break alphabetisch nach Kanon-Text. Der
  Tie-Break ist bewusst deterministisch: er hält den Index-Vertrag zwischen
  Prompt und Parse auch bei Größen-Gleichstand stabil. Rangierung nach
  Cluster-Größe statt „zuletzt aktiv" — billiger (kein zusätzlicher
  `campaign_threads/1`-Read nötig). Herausfallende Anker sind für neue
  Labels unsichtbar bis zum nächsten Voll-Re-Cluster.
  """
  @spec cap_anchors([String.t()], map(), pos_integer()) :: [String.t()]
  def cap_anchors(anchors, persisted_map, n)
      when is_list(anchors) and is_map(persisted_map) and is_integer(n) do
    sizes = persisted_map |> Map.values() |> Enum.frequencies()

    anchors
    |> Enum.sort_by(&{-Map.get(sizes, &1, 0), &1})
    |> Enum.take(n)
  end

  # 1-basierter Index in `anchors` -> {:ok, kanonischer Text} | :new.
  # Out-of-range/kein Integer degradiert kontrolliert zu :new (neue Gruppe)
  # statt zu crashen oder still falsch zuzuordnen.
  defp resolve_anchor_target(idx, anchors) when is_integer(idx) and idx >= 1 do
    case Enum.at(anchors, idx - 1) do
      nil -> :new
      canonical -> {:ok, canonical}
    end
  end

  defp resolve_anchor_target(_idx, _anchors), do: :new

  @doc """
  Mischt frisch geclusterte Gruppen (aus dem inkrementellen LLM-Call, Form
  wie `build_map/1`s Input + `anchor_index`) in die bestehende
  Cluster-Map/Kinds. `anchors` ist die (ggf. gecappte) im Prompt gezeigte
  Liste — nur zur Index-Auflösung bei `anchor_index > 0`.

  **Kollisions-Guard**: eine neue Gruppe (`anchor_index` löst zu `:new` auf)
  wird gegen ALLE bestehenden Kanon-Texte aus `existing_map` geprüft (nicht
  nur die gezeigten/gecappten Anker!) — matcht `canonical` normalisiert
  einen bestehenden Kanon, wird die Gruppe wie ein Anker-Treffer behandelt
  (Attach, Text/Kind unangetastet). Ohne diesen Guard könnte ein vom Cap
  ausgeblendeter oder vom Modell trotz Anweisung neu formulierter
  Kanon-Text einen Schatten-Strang samt Kind-Flip erzeugen.

  **Within-Batch-Dedupe**: neue Gruppen (nicht nur `anchor_index == 0`,
  sondern alles was zu `:new` auflöst) mit normalisiert gleichem `canonical`
  werden VOR dem Merge vereinigt — defensive Absicherung, falls das Modell
  trotz Gruppen-Vertrag zwei separate Einträge für denselben neuen Strang
  liefert. Fängt exakte (post-normalize) Text-Duplikate, keine echten
  Synonyme (das ist der Job des Modells beim Gruppieren selbst, s. Prompt).

  Bei Anker-Treffer werden Text UND `kind` des bestehenden Strangs NIE aus
  der Response übernommen — nur die `labels` werden zugeordnet.
  """
  @spec merge_incremental_result(map(), map(), [map()], [String.t()]) ::
          %{map: map(), kinds: map()}
  def merge_incremental_result(existing_map, existing_kinds, groups, anchors)
      when is_map(existing_map) and is_map(existing_kinds) and is_list(groups) and
             is_list(anchors) do
    existing_norm_to_canonical =
      existing_map |> Map.values() |> Enum.uniq() |> Map.new(&{normalize(&1), &1})

    groups
    |> dedupe_new_groups(anchors)
    |> Enum.reduce(%{map: existing_map, kinds: existing_kinds}, fn group, acc ->
      apply_group(group, acc, anchors, existing_norm_to_canonical)
    end)
  end

  defp dedupe_new_groups(groups, anchors) do
    {news, attached} =
      Enum.split_with(groups, fn g ->
        resolve_anchor_target(Map.get(g, "anchor_index"), anchors) == :new
      end)

    merged_news =
      news
      |> Enum.group_by(fn g -> normalize(to_string(Map.get(g, "canonical", ""))) end)
      |> Enum.map(fn {_norm, [first | rest]} ->
        extra_labels = Enum.flat_map(rest, &List.wrap(Map.get(&1, "labels")))
        Map.update(first, "labels", extra_labels, &(List.wrap(&1) ++ extra_labels))
      end)

    merged_news ++ attached
  end

  defp apply_group(group, acc, anchors, existing_norm_to_canonical) do
    idx = Map.get(group, "anchor_index")
    labels = group |> Map.get("labels", []) |> List.wrap()

    case resolve_anchor_target(idx, anchors) do
      {:ok, canonical} ->
        attach(acc, canonical, labels)

      :new ->
        canonical = group |> Map.get("canonical", "") |> to_string() |> String.trim()
        apply_new_group(acc, canonical, labels, Map.get(group, "kind"), existing_norm_to_canonical)
    end
  end

  defp apply_new_group(acc, "", _labels, _kind, _existing), do: acc

  defp apply_new_group(acc, canonical, labels, kind, existing_norm_to_canonical) do
    case Map.get(existing_norm_to_canonical, normalize(canonical)) do
      nil ->
        validated_kind = if kind in ["context", "rauschen"], do: kind, else: "arc"

        acc
        |> attach(canonical, [canonical | labels])
        |> put_in([:kinds, normalize(canonical)], validated_kind)

      existing_canonical ->
        # Kollisions-Guard (s. moduledoc merge_incremental_result/4): schon
        # bekannt (auch außerhalb der gecappten Anker) -> Attach, kein
        # Kind-Flip.
        attach(acc, existing_canonical, labels)
    end
  end

  defp attach(acc, canonical, labels) do
    map =
      Enum.reduce(labels, acc.map, fn l, m ->
        case normalize(l) do
          "" -> m
          key -> Map.put(m, key, canonical)
        end
      end)

    %{acc | map: map}
  end

  @doc """
  #842: automatischer, inkrementeller Pfad (läuft im `resolve`-Schritt jedes
  Pipeline-Laufs). Clustert NUR die Roh-Labels, die seit dem letzten Lauf neu
  dazugekommen sind (`new_raw_labels/2`), gegen die (gecappten) bestehenden
  Kanon-Stränge als Kontext — NICHT die ganze Kampagne neu. Kein neues
  Watermark-Tracking: die persistierte Map selbst kodiert, was schon bekannt
  ist. Keine neuen Labels seit dem letzten Lauf → kein LLM-Call, nur
  `birth_arcs/1` (idempotent, Selbstheilung für einen ggf. unterbrochenen
  Vorlauf). `cluster_fn.(new_labels, anchors)` liefert `{:ok, [group]}`
  (default: `cluster_incremental_via_llm/2`), injizierbar für Tests.

  Für den seltenen, expliziten Voll-Re-Cluster siehe
  `full_recluster_campaign_threads/2`.
  """
  @spec resolve_campaign_threads(
          String.t(),
          ([String.t()], [String.t()] -> {:ok, [map()]} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def resolve_campaign_threads(campaign_id, cluster_fn \\ &cluster_incremental_via_llm/2)
      when is_function(cluster_fn, 2) do
    all_facts = Repo.list_campaign_facts(campaign_id)

    case distinct_threads(all_facts) do
      [] ->
        {:ok, %{}}

      all_labels ->
        existing_map = Repo.get_thread_registry(campaign_id)
        existing_kinds = Repo.get_thread_kinds(campaign_id)

        case new_raw_labels(all_labels, existing_map) do
          [] ->
            # Nichts Neues seit dem letzten Lauf — kein LLM-Call. birth_arcs
            # bleibt idempotent/best-effort für Selbstheilung nach einem
            # unterbrochenen Vorlauf (Race zweier Worker, s. Design H).
            birth_arcs(campaign_id)
            {:ok, existing_map}

          new_labels ->
            anchor_cap = Worker.Settings.get(:thread_cluster_anchor_cap, 200)
            anchors = existing_map |> existing_anchors() |> cap_anchors(existing_map, anchor_cap)

            with {:ok, groups} <- cluster_fn.(new_labels, anchors) do
              merged = merge_incremental_result(existing_map, existing_kinds, groups, anchors)
              publish_registry(campaign_id, merged.map, merged.kinds)
              birth_arcs(campaign_id)

              Logger.info(
                "resolve_campaign_threads #{campaign_id}: #{length(new_labels)} neue Roh-Labels " <>
                  "(von #{length(all_labels)} gesamt), #{map_size(merged.map)} Label-Mappings " <>
                  "(#{merged.map |> Map.values() |> Enum.uniq() |> length()} Stränge)"
              )

              {:ok, merged.map}
            end
        end
    end
  end

  @doc """
  Voll-Re-Cluster (#842: manueller, seltener Pfad — siehe `resolve_campaign_threads/2`
  für den automatischen inkrementellen Pfad). Orchestriert die Strang-
  Auflösung campaign-weit: distinkte Roh-Labels ALLER Sessions clustern,
  dann Cluster-Map + Arc/Context-Klassifikation (#885) als
  `ThreadRegistryComputed` publishen (KEIN Fakt-Re-Key). `cluster_fn.(labels)`
  liefert `{:ok, %{map: cluster_map, kinds: kinds}}` (default: LLM-Clustering),
  injizierbar für Tests. Keine Labels / Cluster-Fehler → keine Publish (kein
  Cluster ist besser als ein falscher). Returnt `{:ok, cluster_map}`.

  ACHTUNG: kanonische Namen können sich hierbei ändern (das Modell wählt bei
  jedem Voll-Lauf neu) — bestehende `worker_thread_overrides`-Einträge
  (rename/merge/resolve/dismiss/mark_*), die auf den alten Text keyen, können
  dadurch verwaisen (#842 Design I, bekanntes Restrisiko, nicht in diesem
  PR migriert).
  """
  @spec full_recluster_campaign_threads(
          String.t(),
          ([String.t()] -> {:ok, %{map: map(), kinds: map()}} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def full_recluster_campaign_threads(campaign_id, cluster_fn \\ &cluster_via_llm/1)
      when is_function(cluster_fn, 1) do
    all_facts = Repo.list_campaign_facts(campaign_id)
    # #842 Design E: Kanon-Text-Diff für Observability — VOR dem Cluster-Call
    # erfassen, welche Kanon-Texte heute gelten, damit sich nach dem Publish
    # zählen lässt, wie viele davon verschwunden (umbenannt/verschmolzen)
    # sind. Reine Sichtbarkeit für den GM, kein Blocker.
    old_canonicals = campaign_id |> Repo.get_thread_registry() |> existing_anchors() |> MapSet.new()

    case distinct_threads(all_facts) do
      [] ->
        {:ok, %{}}

      labels ->
        with {:ok, %{map: registry, kinds: kinds}} when map_size(registry) > 0 <-
               cluster_fn.(labels) do
          publish_registry(campaign_id, registry, kinds)
          # #903 (Epic #900 S2): Arc-Geburt auf der FRISCHEN Map — der
          # Local-First-Apply von publish_registry macht sie sofort lesbar,
          # campaign_threads/1 liefert dieselbe effektive Kind-Logik
          # (inkl. mark_arc-Override) wie der Reader. Best-effort wie der
          # ganze resolve-Schritt.
          birth_arcs(campaign_id)

          new_canonicals = registry |> Map.values() |> Enum.uniq() |> MapSet.new()
          vanished = MapSet.difference(old_canonicals, new_canonicals) |> MapSet.size()

          Logger.info(
            "full_recluster_campaign_threads #{campaign_id}: #{map_size(registry)} Label-Mappings " <>
              "(#{MapSet.size(new_canonicals)} Stränge, " <>
              "#{Enum.count(kinds, fn {_, k} -> k == "context" end)} Contexte, " <>
              "#{Enum.count(kinds, fn {_, k} -> k == "rauschen" end)} Rauschen) — " <>
              "#{vanished} von #{MapSet.size(old_canonicals)} vorherigen Kanon-Texten verschwunden " <>
              "(potenziell verwaiste worker_thread_overrides, #842 Design I)"
          )

          {:ok, registry}
        else
          {:ok, %{map: _empty}} -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp publish_registry(campaign_id, registry, kinds) do
    Intents.publish(%{
      "kind" => Shared.Events.thread_registry_computed(),
      "campaign_id" => campaign_id,
      "cluster_map" => registry,
      "kinds" => kinds
    })
  end

  # ─── Arc-Geburt (Epic #900 S2, Issue #903) ───────────────────────────

  @doc false
  # Für jeden arc-kind-Strang OHNE paarenden Arc ein ArcCreated emittieren.
  # Pairing (S2-minimal): normalisierte Roh-Label-Menge des Strangs schneidet
  # die Seed-Labels eines bestehenden Arcs (≥1 Treffer) — der Guard ist
  # zugleich der Duplikat-Schutz gegen Seed-Drift zwischen Läufen. Verwaiste
  # Arcs / Merge-Review sind S3. Public für die Tests (LLM-entkoppelt).
  def birth_arcs(campaign_id) do
    existing_seeds =
      Repo.transaction(fn -> :mnesia.index_read(S.arcs(), campaign_id, :campaign_id) end)
      |> Enum.map(fn {_t, _id, _cid, seeds, _d, _ak, _ag, _aw, _lk, _mi} ->
        seeds |> List.wrap() |> MapSet.new()
      end)

    campaign_id
    |> Repo.campaign_threads()
    |> Enum.filter(&(&1.kind == "arc"))
    |> Enum.each(fn t ->
      labels = thread_raw_labels(t)

      paired? =
        Enum.any?(existing_seeds, fn seeds -> Enum.any?(labels, &MapSet.member?(seeds, &1)) end)

      if labels != [] and not paired? do
        Intents.publish(%{
          "kind" => Shared.Events.arc_created(),
          "arc_id" => arc_content_id(campaign_id, labels),
          "campaign_id" => campaign_id,
          # Deterministischer :generiert-Draft (kein LLM in S2); die
          # kuratierte Leitfrage (LeitfrageSet) überstimmt ihn am Reader.
          "leitfrage_draft" => "Wie löst sich „#{t.canonical}“ auf?",
          "seed_raw_labels" => labels
        })
      end
    end)

    :ok
  end

  @doc false
  # Content-adressierte Arc-ID: campaign_id + sortierte normalisierte
  # Seed-Labels (Cross-Campaign-disambiguiert — gleiche Labels in zwei
  # Kampagnen sind zwei Arcs; #900-Plan Fund A3). sha256/16-hex wie die
  # Block-IDs der Glättung (#862-Hausrezept).
  def arc_content_id(campaign_id, sorted_labels) when is_list(sorted_labels) do
    input = campaign_id <> ":" <> Enum.join(sorted_labels, ",")

    "arc_" <>
      (:crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  # Normalisierte, sortierte Roh-Labels der Fakten des Strangs — dieselbe
  # Normalisierung wie Overrides/Reader (Worker.ThreadOverride.normalize/1,
  # single-sourced gegen Pairing-Drift).
  defp thread_raw_labels(t) do
    t.facts
    |> Enum.map(fn f -> f |> Map.get("thread", "") |> Worker.ThreadOverride.normalize() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ─── LLM-Clustering (I/O-Grenze) ─────────────────────────────────────

  @doc false
  def cluster_via_llm(labels) when is_list(labels) do
    prompt = build_clustering_prompt(labels)
    num_ctx = Worker.Settings.get(:ctx_stage2, 8192)
    # #842: einzige Ausnahme vom "Vollpfad unangetastet"-Grundsatz — sonst
    # bleibt exakt der Pfad, der heute unbegrenzt wächst und jetzt per Button
    # auf noch größere Label-Mengen anwendbar ist, ohne jede Warnung.
    guard_prompt_size(prompt, num_ctx, "thread_clustering_full")
    # Klassifikations-Aufgabe → deterministisch (temperature 0), analog #755.
    opts = [format: clustering_json_schema(), num_ctx: num_ctx, temperature: 0]

    with {:ok, raw} <- LLM.complete(:summary, prompt, opts),
         {:ok, registry} <- parse_clustering(raw) do
      {:ok, registry}
    end
  end

  @doc false
  def build_clustering_prompt(labels) do
    list = labels |> Enum.with_index(1) |> Enum.map_join("\n", fn {l, i} -> "#{i}. #{l}" end)

    """
    Unten stehen Kurz-Labels für Handlungsstränge aus einer Rollenspiel-Kampagne.
    Verschiedene Labels bezeichnen oft DENSELBEN übergreifenden Erzählstrang
    (z.B. „die Fotografie", „der Skandal" und „Auftrag des Königs" meinen einen
    Strang), weil sie aus verschiedenen Sessions/Fakten stammen.

    Gruppiere die Labels zu Handlungssträngen. Pro Strang: eine `canonical`-Form
    (das klarste, sprechendste Label) + die Liste seiner `labels` (alle
    zugehörigen Labels aus der Liste, inkl. der canonical-Form selbst) + ein
    `kind`:
    - `"arc"` — ein Handlungsbogen: etwas öffnet sich, entwickelt sich und kann
      irgendwann abgeschlossen werden (ein Auftrag, ein Konflikt, ein Plan).
    - `"context"` — zeitloses Welt- oder Figurenwissen, das nie „abgeschlossen"
      wird, sondern nur wächst (Weltgeschichte, Regeln der Welt,
      Charakterbeschreibung, Schauplatz-Hintergrund).
    - `"rauschen"` — Meta-/Tisch-/Werkzeug-Gerede, das gar nicht in der
      Spielwelt stattfindet: Gespräche über Aufnahme/Software/Technik-Tests
      oder Organisatorisches am Tisch (z.B. „das Protokoll", „die Testdaten
      sammeln", „das neue Feature").

    Regeln:
    - Fasse NUR zusammen, was eindeutig denselben Strang meint. Im Zweifel
      getrennt lassen (lieber zwei Stränge als eine falsche Verschmelzung).
    - Erfinde keine Labels, die nicht in der Liste stehen.
    - Die canonical-Form MUSS eines der gelisteten Labels sein (nicht neu
      erfinden).
    - `kind`: im Zweifel `"arc"` (ein fälschlich als Context oder Rauschen
      einsortierter Bogen würde aus der Fäden-Übersicht verschwinden).
      `"rauschen"` NUR, wenn das Label eindeutig Tisch-Meta statt Spielwelt
      ist — Spielwelt-Wissen ist `"context"`, nie `"rauschen"`.

    Labels:
    #{list}
    """
  end

  defp clustering_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "threads" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "canonical" => %{"type" => "string"},
              "labels" => %{"type" => "array", "items" => %{"type" => "string"}},
              "kind" => %{"type" => "string", "enum" => ["arc", "context", "rauschen"]}
            },
            # `kind` required (#676-Lektion: optionale Schema-Felder werden von
            # GBNF-Modellen schlicht weggelassen).
            "required" => ["canonical", "labels", "kind"]
          }
        }
      },
      "required" => ["threads"]
    }
  end

  # ─── #842: inkrementelles LLM-Clustering (I/O-Grenze) ───────────────

  @doc """
  Clustert NUR `new_labels` (statt der ganzen Kampagne), mit den bestehenden
  Kanon-Strängen (`anchors`) als Zuordnungs-Kontext. Antwortform ist
  bewusst identisch zu `cluster_via_llm/1` (`threads: [{canonical, labels,
  kind}]`) plus `anchor_index` — das Modell gruppiert die neuen Labels
  zuerst untereinander (löst die "ein Eintrag pro Label"-Ambiguität), dann
  entscheidet es PRO GRUPPE, ob sie zu einem bestehenden Strang gehört.
  """
  @spec cluster_incremental_via_llm([String.t()], [String.t()]) ::
          {:ok, [map()]} | {:error, atom()}
  def cluster_incremental_via_llm(new_labels, anchors)
      when is_list(new_labels) and is_list(anchors) do
    prompt = build_incremental_prompt(new_labels, anchors)
    num_ctx = Worker.Settings.get(:ctx_stage2, 8192)
    guard_prompt_size(prompt, num_ctx, "thread_clustering_incremental")

    opts = [format: incremental_clustering_json_schema(), num_ctx: num_ctx, temperature: 0]

    with {:ok, raw} <- LLM.complete(:summary, prompt, opts),
         {:ok, groups} <- parse_incremental_clustering(raw, new_labels) do
      {:ok, groups}
    end
  end

  @doc false
  def build_incremental_prompt(new_labels, anchors) do
    new_list =
      new_labels |> Enum.with_index(1) |> Enum.map_join("\n", fn {l, i} -> "#{i}. #{l}" end)

    anchor_section =
      if anchors == [] do
        "(noch keine bestehenden Stränge — alles ist neu.)"
      else
        anchors |> Enum.with_index(1) |> Enum.map_join("\n", fn {a, i} -> "#{i}. #{a}" end)
      end

    """
    Unten stehen NEUE Kurz-Labels für Handlungsstränge aus einer laufenden
    Rollenspiel-Kampagne, plus eine Liste BEREITS BEKANNTER Stränge dieser
    Kampagne.

    Gruppiere zuerst die neuen Labels untereinander zu Handlungssträngen (wie
    gewohnt: nur eindeutig Zusammengehöriges, im Zweifel getrennt lassen).
    Prüfe für jede so entstandene Gruppe dann, ob sie zu einem der BEREITS
    BEKANNTEN Stränge gehört (z.B. neue Details zu einem laufenden Auftrag) —
    wenn ja, gib die Nummer dieses bekannten Strangs als `anchor_index` an
    (dann werden `canonical`/`kind` ignoriert, der bekannte Strang behält
    seinen Namen). Gehört die Gruppe zu KEINEM bekannten Strang, ist sie neu:
    `anchor_index: 0` + eigene `canonical`-Form + `kind`.

    Pro Gruppe: `anchor_index` (0 = neuer Strang, sonst Nummer aus der
    Bekannt-Liste) + `canonical` (nur bei neuem Strang relevant — dann MUSS
    sie eines der zugehörigen neuen Labels sein) + `labels` (alle
    zugehörigen NEUEN Labels aus der obigen Liste) + `kind`:
    - `"arc"` — ein Handlungsbogen: etwas öffnet sich, entwickelt sich und
      kann irgendwann abgeschlossen werden (ein Auftrag, ein Konflikt, ein
      Plan).
    - `"context"` — zeitloses Welt- oder Figurenwissen, das nie
      „abgeschlossen" wird, sondern nur wächst (Weltgeschichte, Regeln der
      Welt, Charakterbeschreibung, Schauplatz-Hintergrund).
    - `"rauschen"` — Meta-/Tisch-/Werkzeug-Gerede, das gar nicht in der
      Spielwelt stattfindet: Gespräche über Aufnahme/Software/Technik-Tests
      oder Organisatorisches am Tisch (z.B. „das Protokoll", „die Testdaten
      sammeln", „das neue Feature").

    Regeln:
    - Fasse NUR zusammen, was eindeutig denselben Strang meint. Im Zweifel
      getrennt lassen (lieber zwei Stränge als eine falsche Verschmelzung).
    - Erfinde keine Labels, die nicht in der NEUE-Labels-Liste stehen.
    - Bei `anchor_index > 0`: `canonical` MUSS trotzdem gefüllt sein (z.B.
      mit dem Namen des bekannten Strangs) — wird aber ignoriert, der
      bekannte Name bleibt unverändert.
    - `kind`: im Zweifel `"arc"` (ein fälschlich als Context oder Rauschen
      einsortierter Bogen würde aus der Fäden-Übersicht verschwinden).
      `"rauschen"` NUR, wenn das Label eindeutig Tisch-Meta statt Spielwelt
      ist — Spielwelt-Wissen ist `"context"`, nie `"rauschen"`.

    Bereits bekannte Stränge dieser Kampagne:
    #{anchor_section}

    Neue Labels:
    #{new_list}
    """
  end

  defp incremental_clustering_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "threads" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "anchor_index" => %{"type" => "integer"},
              "canonical" => %{"type" => "string"},
              "labels" => %{"type" => "array", "items" => %{"type" => "string"}},
              "kind" => %{"type" => "string", "enum" => ["arc", "context", "rauschen"]}
            },
            # #676-Lektion: ALLE vier Felder required — auch wenn
            # canonical/kind bei anchor_index > 0 semantisch irrelevant sind
            # (werden nie übernommen, s. merge_incremental_result/4). NICHT
            # "aufräumen": ein optionales Feld lässt ein GBNF-Modell sonst
            # manchmal einfach weg.
            "required" => ["anchor_index", "canonical", "labels", "kind"]
          }
        }
      },
      "required" => ["threads"]
    }
  end

  @doc """
  Parst den inkrementellen Clustering-Output analog `parse_clustering/1`,
  zusätzlich gegen `new_labels` gehärtet: Labels, die eine Gruppe zurückgibt,
  aber die NICHT tatsächlich angefragt wurden (Halluzination), werden
  gefiltert. Gruppen, die danach keine echten Labels mehr haben (alles
  halluziniert), werden verworfen — sonst könnte eine rein erfundene neue
  Gruppe einen Phantom-Strang erzeugen (nur sich selbst als Label). Fehler-
  Atome bewusst distinkt von `parse_clustering/1`s Atomen (sonst verschmilzt
  `/admin/errors` beide Klassen).
  """
  @spec parse_incremental_clustering(binary() | nil, [String.t()]) ::
          {:ok, [map()]} | {:error, atom()}
  def parse_incremental_clustering(raw, new_labels)
      when is_binary(raw) and is_list(new_labels) do
    allowed = MapSet.new(new_labels)

    case Jason.decode(raw) do
      {:ok, %{"threads" => groups}} when is_list(groups) ->
        {:ok, filter_hallucinated_labels(groups, allowed)}

      {:ok, _} ->
        {:error, :no_incremental_threads_key}

      {:error, _} ->
        {:error, :incremental_thread_parse_failed}
    end
  end

  def parse_incremental_clustering(_raw, _new_labels),
    do: {:error, :incremental_thread_parse_failed}

  defp filter_hallucinated_labels(groups, allowed) do
    groups
    |> Enum.map(fn g ->
      labels =
        g |> Map.get("labels", []) |> List.wrap() |> Enum.filter(&MapSet.member?(allowed, &1))

      Map.put(g, "labels", labels)
    end)
    |> Enum.reject(fn g -> g["labels"] == [] end)
  end

  # #842: EINE Quelle für die Normalisierung — vorher gab es dieselbe
  # lowercase+Whitespace-Kollaps+trim-Logik dreifach identisch dupliziert
  # (hier, Worker.ThreadOverride.normalize/1, inline in
  # Worker.Repo.Threads.canonical_thread/2). Delegation statt eigener Body
  # macht "Diff-Vergleich, Map-Keys und Read-Lookup nutzen dieselbe
  # Schlüsselfunktion" strukturell garantiert statt zufällig konsistent.
  defp normalize(s), do: Worker.ThreadOverride.normalize(s)
end
