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

  Pure Kerne (`distinct_threads/1`, `parse_clustering/1`, `build_map/1`) sind
  ohne LLM testbar; das Clustering ist die I/O-Grenze (`cluster_fn` injizierbar).
  """

  alias Worker.{Intents, Repo}
  alias Worker.LLM
  alias Worker.Schema.Mnesia, as: S

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

  @doc """
  Orchestriert die Strang-Auflösung campaign-weit: distinkte Roh-Labels ALLER
  Sessions clustern, dann Cluster-Map + Arc/Context-Klassifikation (#885) als
  `ThreadRegistryComputed` publishen (KEIN Fakt-Re-Key). `cluster_fn.(labels)`
  liefert `{:ok, %{map: cluster_map, kinds: kinds}}` (default: LLM-Clustering),
  injizierbar für Tests. Keine Labels / Cluster-Fehler → keine Publish (kein
  Cluster ist besser als ein falscher). Returnt `{:ok, cluster_map}`.
  """
  @spec resolve_campaign_threads(
          String.t(),
          ([String.t()] -> {:ok, %{map: map(), kinds: map()}} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def resolve_campaign_threads(campaign_id, cluster_fn \\ &cluster_via_llm/1)
      when is_function(cluster_fn, 1) do
    all_facts = Repo.list_campaign_facts(campaign_id)

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

          Logger.info(
            "resolve_campaign_threads #{campaign_id}: #{map_size(registry)} Label-Mappings " <>
              "(#{registry |> Map.values() |> Enum.uniq() |> length()} Stränge, " <>
              "#{Enum.count(kinds, fn {_, k} -> k == "context" end)} Contexte, " <>
              "#{Enum.count(kinds, fn {_, k} -> k == "rauschen" end)} Rauschen)"
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
    # Klassifikations-Aufgabe → deterministisch (temperature 0), analog #755.
    opts = [
      format: clustering_json_schema(),
      num_ctx: Worker.Settings.get(:ctx_stage2, 8192),
      temperature: 0
    ]

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

  # Konsistent mit Parsing.normalize_thread/1 (Extraktion trimmt) + der
  # EntityRegistry-Normalisierung: lowercase + Whitespace zusammenfassen + trim.
  # So matcht der Reader ein Roh-Label robust gegen den Cluster-Map-Schlüssel.
  defp normalize(s) when is_binary(s) do
    s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp normalize(_), do: ""
end
