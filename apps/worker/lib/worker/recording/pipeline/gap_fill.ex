defmodule Worker.Recording.Pipeline.GapFill do
  @moduledoc """
  Issue #865 (Epic #861 D+E, K2): Verflüssigungs-Vorschlag für Lücken-Blöcke
  (Produktentscheidung 2026-07-16, Free-Seattle-Review: minimale Wort-Füllung
  half auf echtem Tisch-Deutsch kaum — der Vorschlag ist jetzt eine FLÜSSIGE,
  inhaltstreue Neuformulierung des ganzen Blocks). Separates :generiert-
  Artefakt (`LueckenVorschlagGeneriert`), Key = Block-Content-ID; `original`
  ist dabei schlicht der ganze Block-Text → `Smoothing.effective_text/3`
  (String.replace) und das Wire-Format bleiben unverändert. Der Vorschlag
  entsteht für Block-IDs ohne existierenden Vorschlag und ohne Kurations-Override.

  **Issue #924: SYNCHRON zwischen Glättung und Extraktion** (`generate_now/5`) —
  die richtige Reihenfolge ist glätten → Vorschläge → Rest. Der frühere async-
  Pfad extrahierte beim ersten Lauf aus dem Roh-Text (Vorschlag noch nicht da)
  und war an die #865-Gap-Klemme gekoppelt; die Klemme ist mit #917 (Cut 3)
  entfernt, also muss der Vorschlag schon DIESEN Lauf speisen. Läuft INLINE im
  Pipeline-GpuQueue-Job (`smooth_transcript` ist bereits drin) — kein
  geschachteltes `GpuQueue.run` (Deadlock); die GPU-Serialisierung erbt der Lauf.

  LOCAL-only by design (Settings-Kommentar `gapfill_model`): der Vorschlag
  ist best-effort-Komfort; Fehler landen als eigene /admin/errors-Klasse
  `gapfill`, brechen aber nichts. Kein konfiguriertes Modell = Feature aus.
  """

  require Logger

  alias Worker.Intents
  alias Worker.Recording.Pipeline
  alias Worker.Settings

  # Ollama-JSON-Schema (GBNF, #676-Lektion): nur noch `vorschlag` — das
  # `original` setzt der Code selbst auf den ganzen Block-Text (kein Anker-
  # Mismatch mehr möglich; die frühere :original_not_in_block-Klasse entfällt).
  @gapfill_json_schema %{
    "type" => "object",
    "properties" => %{"vorschlag" => %{"type" => "string"}},
    "required" => ["vorschlag"]
  }

  # Mechanischer Fabulier-Deckel: eine inhaltstreue Verflüssigung bewegt sich
  # längenmäßig nahe am Original — außerhalb der Spanne ist es Kürzung auf
  # Stichworte oder Dazudichtung → Fehler statt Vorschlag.
  @laenge_min 0.4
  @laenge_max 2.5

  @doc """
  Issue #924: generiert SYNCHRON die Gap-Fill-Vorschläge für alle Kandidaten-
  Blöcke der Session (`hat_luecke`, kein existierender Vorschlag, kein Kurations-
  Override) und gibt die **gemergte Vorschlags-Map** zurück (`vorschlaege` +
  neu generierte) — direkt für `Smoothing.to_context/3` desselben Laufs nutzbar.
  Läuft INLINE (kein `GpuQueue.run` — der Pipeline-Lauf ist bereits ein
  GpuQueue-Job, Nesting wäre Deadlock). Kein Modell/keine Kandidaten →
  `vorschlaege` unverändert.
  """
  @spec generate_now(String.t(), String.t(), [map()], map(), map()) :: map()
  def generate_now(session_id, campaign_id, blocks, vorschlaege, overrides) do
    candidates =
      Enum.filter(blocks, fn b ->
        b["hat_luecke"] == true and
          not Map.has_key?(vorschlaege, b["id"]) and
          not Map.has_key?(overrides, b["id"])
      end)

    model = Settings.get(:gapfill_model)

    cond do
      candidates == [] ->
        vorschlaege

      not is_binary(model) or model == "" ->
        Logger.info(
          "GapFill: #{length(candidates)} Lücken-Block/Blöcke in session=#{session_id}, " <>
            "aber kein :gapfill_model konfiguriert — Vorschlags-Generierung aus"
        )

        vorschlaege

      true ->
        Logger.info(
          "GapFill: generiere #{length(candidates)} Vorschlag/Vorschläge synchron " <>
            "(session=#{session_id}, modell=#{model}) vor der Extraktion"
        )

        Map.merge(vorschlaege, generate_all(session_id, campaign_id, candidates, model))
    end
  end

  # Best-effort pro Block: ein Fehler (LLM offline, kaputtes JSON, Original
  # nicht im Block) landet in /admin/errors (Klasse "gapfill"), die übrigen
  # Blöcke laufen weiter. Doppel-Publish durch parallele Worker ist harmlos
  # (LWW-Upsert am Materializer). Returns `%{block_id => %{original, vorschlag,
  # modell}}` der erfolgreich generierten (für die sofortige to_context-Nutzung;
  # effective_text matcht auf original/vorschlag).
  defp generate_all(session_id, campaign_id, candidates, model) do
    Enum.reduce(candidates, %{}, fn block, acc ->
      case generate_one(block, model) do
        :skip ->
          Logger.debug("GapFill: Modell fand keine plausible Lücke in block=#{block["id"]}")
          acc

        {:ok, original, vorschlag} ->
          {:ok, _seq} =
            Intents.publish(%{
              "kind" => Shared.Events.luecken_vorschlag_generiert(),
              "session_id" => session_id,
              "campaign_id" => campaign_id,
              "block_id" => block["id"],
              "original" => original,
              "vorschlag" => vorschlag,
              "modell" => model
            })

          Map.put(acc, block["id"], %{
            "original" => original,
            "vorschlag" => vorschlag,
            "modell" => model
          })

        {:error, reason} ->
          Logger.warning(
            "GapFill: Vorschlag für block=#{block["id"]} session=#{session_id} " <>
              "fehlgeschlagen: #{inspect(reason)}"
          )

          Pipeline.publish_pipeline_error(
            campaign_id,
            "gapfill",
            session_id,
            {:gapfill, reason},
            "Gap-Fill-Vorschlag fehlgeschlagen (block #{block["id"]})"
          )

          acc
      end
    end)
  end

  defp generate_one(block, model) do
    text = block["text"]

    # Endpoint explizit :generate — bewusst NICHT an ein Stage-Endpoint-Setting
    # gekoppelt (Gap-Fill ist kein Wahrheitsbild-Stage; #855-Override-Mechanik).
    result =
      Worker.LLM.Local.complete(prompt(text),
        stage: :summary,
        model: model,
        endpoint: :generate,
        format: @gapfill_json_schema,
        temperature: 0.2
      )

    with {:ok, raw} <- result,
         {:ok, %{"vorschlag" => vorschlag}} <- Jason.decode(raw) do
      # original = ganzer Block-Text: effective_text ersetzt den Block komplett.
      validate(text, vorschlag)
    else
      {:ok, other} -> {:error, {:bad_shape, other}}
      {:error, %Jason.DecodeError{}} -> {:error, :parse_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  # Der Vorschlag muss eine echte WORT-Änderung sein (Komma-/Case-Tweaks sind
  # keine Verflüssigung → :skip, Real-Befund Free Seattle) und längenmäßig
  # nahe am Original bleiben (Fabulier-Deckel). Public (@doc false) für Tests.
  @doc false
  def validate(text, vorschlag) do
    cond do
      not is_binary(vorschlag) or String.trim(vorschlag) == "" ->
        {:error, :empty_vorschlag}

      words(vorschlag) == words(text) ->
        :skip

      String.length(vorschlag) < @laenge_min * String.length(text) or
          String.length(vorschlag) > @laenge_max * String.length(text) ->
        {:error, :laengen_drift}

      true ->
        {:ok, text, String.trim(vorschlag)}
    end
  end

  defp words(s), do: s |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  defp prompt(text) do
    """
    Du machst aus einem holprigen Spracherkennungs-Transkript (deutsches
    Rollenspiel am Tisch) einen flüssig lesbaren Text.

    Regeln:
    - Formuliere den Ausschnitt als zusammenhängenden, grammatisch sauberen
      Text um: Satzbau reparieren, Fragmente verbinden, Groß-/Kleinschreibung
      und Zeichensetzung korrigieren, offensichtliche Erkennungsfehler glätten.
    - Bleibe strikt INHALTSTREU: erfinde KEINE neuen Aussagen, Namen, Zahlen
      oder Details. Was unklar ist, bleibt unklar formuliert.
    - Behalte die Ich-/Sprecher-Perspektive und den Tonfall bei.
    - Lass nichts Inhaltliches weg.

    Ausschnitt:
    #{text}

    Antworte als JSON: {"vorschlag": "..."}
    """
  end
end
