defmodule Worker.Recording.Pipeline.GapFill do
  @moduledoc """
  Issue #865 (Epic #861 D+E, K2): Verflüssigungs-Vorschlag für Lücken-Blöcke
  (Produktentscheidung 2026-07-16, Free-Seattle-Review: minimale Wort-Füllung
  half auf echtem Tisch-Deutsch kaum — der Vorschlag ist jetzt eine FLÜSSIGE,
  inhaltstreue Neuformulierung des ganzen Blocks). Separates :generiert-
  Artefakt (`LueckenVorschlagGeneriert`), Key = Block-Content-ID; `original`
  ist dabei schlicht der ganze Block-Text → `Smoothing.effective_text/3`
  (String.replace) und das Wire-Format bleiben unverändert. Der Vorschlag
  entsteht **asynchron** (GpuQueue, hinter der laufenden Pipeline) und NUR
  für Block-IDs ohne existierenden Vorschlag und ohne Kurations-Override.

  Explizite Nicht-Kante (Plan Runde 5): das Eintreffen eines Vorschlags
  triggert NIE eine Re-Extraktion — Fakten bleiben durch die ANY-Klemme
  fail-closed geklemmt, bis ein Mensch kuratiert.

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
  Enqueued EINEN GpuQueue-Job für alle Kandidaten-Blöcke der Session:
  `hat_luecke`, kein existierender Vorschlag, kein Kurations-Override.
  Läuft nur aus der elected Pipeline heraus (erbt die Author-Worker-Election).
  Returns `:enqueued | :no_model | :no_candidates`.
  """
  @spec maybe_enqueue(String.t(), String.t(), [map()], map(), map()) ::
          :enqueued | :no_model | :no_candidates
  def maybe_enqueue(session_id, campaign_id, blocks, vorschlaege, overrides) do
    candidates =
      Enum.filter(blocks, fn b ->
        b["hat_luecke"] == true and
          not Map.has_key?(vorschlaege, b["id"]) and
          not Map.has_key?(overrides, b["id"])
      end)

    model = Settings.get(:gapfill_model)

    cond do
      candidates == [] ->
        :no_candidates

      not is_binary(model) or model == "" ->
        Logger.info(
          "GapFill: #{length(candidates)} Lücken-Block/Blöcke in session=#{session_id}, " <>
            "aber kein :gapfill_model konfiguriert — Vorschlags-Generierung aus " <>
            "(Klemme hält die Fakten trotzdem fail-closed)"
        )

        :no_model

      true ->
        Worker.GpuQueue.enqueue(
          fn -> generate_all(session_id, campaign_id, candidates, model) end,
          label: "gapfill:#{session_id}"
        )

        :enqueued
    end
  end

  # Best-effort pro Block: ein Fehler (LLM offline, kaputtes JSON, Original
  # nicht im Block) landet in /admin/errors (Klasse "gapfill"), die übrigen
  # Blöcke laufen weiter. Doppel-Publish durch parallele Worker ist harmlos
  # (LWW-Upsert am Materializer).
  defp generate_all(session_id, campaign_id, candidates, model) do
    Enum.each(candidates, fn block ->
      case generate_one(block, model) do
        :skip ->
          Logger.debug("GapFill: Modell fand keine plausible Lücke in block=#{block["id"]}")

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
