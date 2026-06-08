defmodule Worker.Recording.Pipeline.EntityRegistry do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): die campaign-weite alias→entity-Registry.

  Die Extraktion (#664) setzt `entity_id` minimal = normalisierter `character_alias`
  — pro Oberflächenform eine eigene „Entität". Diese Registry **merged Gestalten**:
  „König", „Graf von Kramm", „Wilhelm von Ormstein", „der König", „maskiert" →
  EINE kanonische `entity_id`. Erst damit wird aus per-Session-Fakt-Listen ein
  echtes Wahrheitsbild (Campaign-Epos + „alle Events mit dem König"-Sichten).

  Resolver = ein LLM-Clustering-Schritt über die distinkten Aliase der Campaign.
  Der Effekt (kanonische `entity_id`) wird in die Fakten zurückgeschrieben
  (SessionFactsExtracted-Overwrite) — keine eigene Registry-Tabelle nötig.

  Pure Kerne (`distinct_aliases/1`, `parse_clustering/1`, `apply_registry/2`)
  sind ohne LLM testbar; das Clustering selbst ist die I/O-Grenze. NOCH NICHT
  verdrahtet (Phase C). Die Attributions-Verify-Achse baut auf dieser
  Registry auf (Folge-Arbeit).
  """

  alias Worker.{Intents, Repo}
  alias Worker.LLM

  require Logger

  @doc "Distinkte, nicht-leere `character_alias`-Oberflächenformen aus den Fakten."
  @spec distinct_aliases([map()]) :: [String.t()]
  def distinct_aliases(facts) when is_list(facts) do
    facts
    |> Enum.map(fn f -> f |> Map.get("character_alias", "") |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Re-keyt `entity_id` jedes Fakts über die Registry (`normalisierter_alias →
  kanonische entity_id`). Alias nicht in der Registry → der Fakt behält seine
  bestehende `entity_id` (Extraktions-Default). PURE, behält alle Fakten.
  """
  @spec apply_registry([map()], %{optional(String.t()) => String.t()}) :: [map()]
  def apply_registry(facts, registry) when is_list(facts) and is_map(registry) do
    Enum.map(facts, fn fact ->
      key = fact |> Map.get("character_alias", "") |> normalize()

      case Map.get(registry, key) do
        nil -> fact
        canonical -> Map.put(fact, "entity_id", canonical)
      end
    end)
  end

  @doc """
  Parst den Clustering-Output (`%{"entities" => [%{"canonical", "aliases"}]}`)
  zur Registry-Map `%{normalisierter_alias => normalisierte kanonische entity_id}`.
  Die kanonische Form selbst mappt auf sich (idempotent). Junk-Cluster (ohne
  canonical) werden übersprungen.
  """
  @spec parse_clustering(binary() | nil) :: {:ok, map()} | {:error, atom()}
  def parse_clustering(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"entities" => entities}} when is_list(entities) ->
        {:ok, build_map(entities)}

      {:ok, _} ->
        {:error, :no_entities_key}

      {:error, _} ->
        {:error, :parse_failed}
    end
  end

  def parse_clustering(_), do: {:error, :parse_failed}

  defp build_map(entities) do
    Enum.reduce(entities, %{}, fn entity, acc ->
      canonical = entity |> Map.get("canonical", "") |> to_string() |> String.trim()

      if canonical == "" do
        acc
      else
        canonical_id = normalize(canonical)
        aliases = [canonical | List.wrap(Map.get(entity, "aliases"))]

        Enum.reduce(aliases, acc, fn a, m ->
          case normalize(a) do
            "" -> m
            key -> Map.put(m, key, canonical_id)
          end
        end)
      end
    end)
  end

  @doc """
  Baut + wendet die Registry an: distinkte Aliase → `cluster_fn` → Registry-Map →
  `apply_registry`. `cluster_fn.(aliases)` liefert `{:ok, registry}` (default:
  LLM-Clustering). Injizierbar für Tests ohne LLM. Keine Aliase / Cluster-Fehler
  → Fakten unverändert (kein Merge ist besser als ein falscher).
  """
  @spec resolve([map()], ([String.t()] -> {:ok, map()} | {:error, term()})) :: [map()]
  def resolve(facts, cluster_fn \\ &cluster_via_llm/1) when is_function(cluster_fn, 1) do
    case distinct_aliases(facts) do
      [] ->
        facts

      aliases ->
        case cluster_fn.(aliases) do
          {:ok, registry} when map_size(registry) > 0 -> apply_registry(facts, registry)
          _ -> facts
        end
    end
  end

  # ─── LLM-Clustering (I/O-Grenze) ─────────────────────────────────────

  @doc false
  def cluster_via_llm(aliases) when is_list(aliases) do
    prompt = build_clustering_prompt(aliases)
    opts = [format: clustering_json_schema(), num_ctx: Worker.Settings.get(:ctx_stage2, 8192)]

    with {:ok, raw} <- LLM.complete(:summary, prompt, opts),
         {:ok, registry} <- parse_clustering(raw) do
      {:ok, registry}
    end
  end

  @doc false
  def build_clustering_prompt(aliases) do
    list = aliases |> Enum.with_index(1) |> Enum.map_join("\n", fn {a, i} -> "#{i}. #{a}" end)

    """
    Unten stehen Figuren-Bezeichnungen aus einer Rollenspiel-Kampagne. Manche
    bezeichnen DIESELBE Figur in verschiedenen Gestalten/Schreibweisen (z.B. ein
    Titel, ein Eigenname und eine Verkleidung derselben Person).

    Gruppiere die Bezeichnungen zu Entitäten. Pro Entität: eine `canonical`-Form
    (die klarste Bezeichnung) + die Liste ihrer `aliases` (alle zugehörigen
    Bezeichnungen aus der Liste, inkl. der canonical-Form selbst).

    Regeln:
    - Fasse NUR zusammen, was eindeutig dieselbe Figur ist. Im Zweifel getrennt
      lassen (lieber zwei Entitäten als eine falsche Verschmelzung).
    - Erfinde keine Bezeichnungen, die nicht in der Liste stehen.

    Bezeichnungen:
    #{list}
    """
  end

  defp clustering_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "entities" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "canonical" => %{"type" => "string"},
              "aliases" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["canonical", "aliases"]
          }
        }
      },
      "required" => ["entities"]
    }
  end

  @doc """
  Orchestriert die Entitäts-Auflösung campaign-weit: distinkte Aliase ALLER
  Sessions clustern, dann pro Session die Fakten re-keyen + via
  SessionFactsExtracted zurückschreiben. NOCH NICHT in die Pipeline verdrahtet.
  """
  @spec resolve_campaign_entities(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_campaign_entities(campaign_id) do
    all_facts = Repo.list_campaign_facts(campaign_id)

    case distinct_aliases(all_facts) do
      [] ->
        {:ok, %{}}

      aliases ->
        with {:ok, registry} when map_size(registry) > 0 <- cluster_via_llm(aliases) do
          rekey_and_republish(campaign_id, registry)
          Logger.info("resolve_campaign_entities #{campaign_id}: #{map_size(registry)} Alias-Mappings")
          {:ok, registry}
        else
          {:ok, _empty} -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Pro Session die persistierten Fakten re-keyen + zurückschreiben (Set-Semantik).
  defp rekey_and_republish(campaign_id, registry) do
    campaign_id
    |> Repo.list_sessions()
    |> Enum.each(fn session ->
      case Repo.get_session_facts(session.id) do
        %{facts: facts} when facts != [] ->
          Intents.publish(%{
            "kind" => Shared.Events.session_facts_extracted(),
            "session_id" => session.id,
            "campaign_id" => campaign_id,
            "facts" => apply_registry(facts, registry)
          })

        _ ->
          :ok
      end
    end)
  end

  # Konsistent mit Parsing.normalize_entity_id/1 (Extraktion): lowercase +
  # Whitespace zusammenfassen + trim.
  defp normalize(s) when is_binary(s) do
    s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp normalize(_), do: ""
end
