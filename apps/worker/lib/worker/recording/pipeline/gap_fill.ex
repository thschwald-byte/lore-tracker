defmodule Worker.Recording.Pipeline.GapFill do
  @moduledoc """
  Issue #865 (Epic #861 D+E, K2): Gemma-Füll-Vorschlag für Lücken-Blöcke —
  separates :generiert-Artefakt (`LueckenVorschlagGeneriert`), Key =
  Block-Content-ID. Die Block-Schicht bleibt rein deterministisch; der
  Vorschlag entsteht **asynchron** (GpuQueue, hinter der laufenden Pipeline)
  und NUR für Block-IDs ohne existierenden Vorschlag und ohne Kurations-
  Override.

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

  # Ollama-JSON-Schema (GBNF): beide Felder required (#676-Lektion). `original`
  # = EXAKTER Substring des Block-Texts, `vorschlag` = dessen gefüllte Ersetzung
  # — so greift `Smoothing.effective_text/3` per String.replace.
  @gapfill_json_schema %{
    "type" => "object",
    "properties" => %{
      "original" => %{"type" => "string"},
      "vorschlag" => %{"type" => "string"}
    },
    "required" => ["original", "vorschlag"]
  }

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
        temperature: 0.0
      )

    with {:ok, raw} <- result,
         {:ok, %{"original" => original, "vorschlag" => vorschlag}} <- Jason.decode(raw) do
      validate(text, original, vorschlag)
    else
      {:ok, other} -> {:error, {:bad_shape, other}}
      {:error, %Jason.DecodeError{}} -> {:error, :parse_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  # Der Vorschlag muss mechanisch anwendbar UND eine echte Änderung sein —
  # sonst produziert effective_text ein stilles No-op oder Müll. original ==
  # vorschlag ist der Prompt-vorgesehene „keine Lücke gefunden"-Ausweg (legitim
  # → :skip, kein Fehler-Log-Spam). Public (@doc false) für die Fehlerpfad-Tests.
  @doc false
  def validate(text, original, vorschlag) do
    cond do
      not is_binary(original) or original == "" -> {:error, :empty_original}
      not is_binary(vorschlag) or vorschlag == "" -> {:error, :empty_vorschlag}
      original == vorschlag -> :skip
      not String.contains?(text, original) -> {:error, :original_not_in_block}
      true -> {:ok, original, vorschlag}
    end
  end

  defp prompt(text) do
    """
    Du korrigierst Spracherkennungs-Fehler in deutschen Rollenspiel-Transkripten.
    Der folgende Transkript-Ausschnitt enthält vermutlich eine kleine Lücke
    (fehlendes Kurzwort, abgeschnittenes Wortende, verschlucktes Funktionswort).

    Regeln:
    - Ergänze NUR das minimal Fehlende (z.B. ein "zu", "der", "nicht").
    - Erfinde KEINEN Inhalt, keine Namen, keine neuen Aussagen.
    - "original" = der EXAKTE, unveränderte Teilsatz aus dem Ausschnitt, in dem
      die Lücke steckt (muss wortwörtlich darin vorkommen).
    - "vorschlag" = derselbe Teilsatz mit der minimalen Ergänzung.
    - Findest du keine plausible Lücke, gib den kürzesten unveränderten
      Teilsatz als original UND vorschlag zurück.

    Ausschnitt:
    #{text}

    Antworte als JSON: {"original": "...", "vorschlag": "..."}
    """
  end
end
