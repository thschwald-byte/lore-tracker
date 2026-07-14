defmodule Worker.Recording.Pipeline.ThreadRegistry do
  @moduledoc """
  Issue #832 (Epic #829 Slice C): die campaign-weite Handlungsbogen-Cluster-Map.

  Die Extraktion (#831) setzt pro Fakt ein rohes `thread`-Label — je nach Modell
  fragmentiert (derselbe Strang unter „der Skandal in Böhmen" / „der Coup-Plan" /
  „der Brief"). Diese Registry clustert die distinkten Roh-Labels einer Kampagne
  zu **kanonischen Strängen** und persistiert die Map als **Whole-Snapshot-
  Artefakt** (`ThreadRegistryComputed` → `worker_thread_registry`, 1 Row/Kampagne).

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
  Parst den Clustering-Output (`%{"threads" => [%{"canonical", "labels"}]}`) zur
  Cluster-Map `%{normalisiertes_roh_label => kanonisches Anzeige-Label}`. Anders
  als bei der EntityRegistry bleibt der WERT die **menschenlesbare** canonical-
  Form (der Reader zeigt sie an); nur der Schlüssel wird normalisiert (robustes
  Matching der Roh-Labels). Junk-Cluster (ohne canonical) werden übersprungen.
  """
  # Reasons bewusst distinkt von EntityRegistry (`:parse_failed`/`:no_entities_key`)
  # — sonst würde ein Thread-Clustering-Fehler in `/admin/errors` als
  # „entity_registry_*" fehl-klassifiziert (classify_pipeline_error sieht nur das
  # Atom, nicht den resolve-Schritt).
  @spec parse_clustering(binary() | nil) :: {:ok, map()} | {:error, atom()}
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
    Enum.reduce(threads, %{}, fn thread, acc ->
      canonical = thread |> Map.get("canonical", "") |> to_string() |> String.trim()

      if canonical == "" do
        acc
      else
        labels = [canonical | List.wrap(Map.get(thread, "labels"))]

        Enum.reduce(labels, acc, fn l, m ->
          case normalize(l) do
            "" -> m
            key -> Map.put(m, key, canonical)
          end
        end)
      end
    end)
  end

  @doc """
  Orchestriert die Strang-Auflösung campaign-weit: distinkte Roh-Labels ALLER
  Sessions clustern, dann die volle Cluster-Map als `ThreadRegistryComputed`
  publishen (KEIN Fakt-Re-Key). `cluster_fn.(labels)` liefert `{:ok, map}`
  (default: LLM-Clustering), injizierbar für Tests. Keine Labels / Cluster-Fehler
  → keine Publish (kein Cluster ist besser als ein falscher).
  """
  @spec resolve_campaign_threads(String.t(), ([String.t()] -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def resolve_campaign_threads(campaign_id, cluster_fn \\ &cluster_via_llm/1)
      when is_function(cluster_fn, 1) do
    all_facts = Repo.list_campaign_facts(campaign_id)

    case distinct_threads(all_facts) do
      [] ->
        {:ok, %{}}

      labels ->
        with {:ok, registry} when map_size(registry) > 0 <- cluster_fn.(labels) do
          publish_registry(campaign_id, registry)

          Logger.info(
            "resolve_campaign_threads #{campaign_id}: #{map_size(registry)} Label-Mappings " <>
              "(#{registry |> Map.values() |> Enum.uniq() |> length()} Stränge)"
          )

          {:ok, registry}
        else
          {:ok, _empty} -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp publish_registry(campaign_id, registry) do
    Intents.publish(%{
      "kind" => Shared.Events.thread_registry_computed(),
      "campaign_id" => campaign_id,
      "cluster_map" => registry
    })
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
    zugehörigen Labels aus der Liste, inkl. der canonical-Form selbst).

    Regeln:
    - Fasse NUR zusammen, was eindeutig denselben Strang meint. Im Zweifel
      getrennt lassen (lieber zwei Stränge als eine falsche Verschmelzung).
    - Erfinde keine Labels, die nicht in der Liste stehen.
    - Die canonical-Form MUSS eines der gelisteten Labels sein (nicht neu
      erfinden).

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
              "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["canonical", "labels"]
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
