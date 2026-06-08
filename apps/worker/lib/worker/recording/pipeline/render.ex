defmodule Worker.Recording.Pipeline.Render do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase B): die Geschwister-Render-Schicht. Resümee,
  Timeline und Epos rendern aus den **verifizierten** Fakten (statt aus der Prosa
  der jeweils anderen Stufe) — das bricht das Halluzinations-Laundering der
  Prosa-Kette.

  Enthält:
  - **DETERMINISTISCHE Timeline** (`timeline/1`) — kein LLM. Datierte,
    verifizierte Fakten chronologisch sortiert → reproduzierbarer Zeitstrahl
    (beendet die #650/#75-Verdreh-Klasse).
  - **Prosa-Render** (`render_summary/1`, `render_epos/1`) — Resümee/Epos aus den
    verifizierten Fakten, mit **context-faithful Prompt** (nur diese Fakten, kein
    neuer Claim) + **Render-Gating**: der gerenderte Text wird gegen das Fakt-Set
    re-verifiziert (`gate_rendered/3`) — behauptet die Prosa etwas, das auf keinen
    Fakt zurückführbar ist (Bindegewebe-Claim / Re-Inversion), wird es geflaggt.
    Damit ist die Verify-Abdeckung an BEIDEN Generativschritten geschlossen
    (Extraktion + Render), nicht nur an der Extraktion.
  """

  alias Worker.Repo
  alias Worker.LLM
  alias Worker.LLM.Faithfulness

  @doc """
  Rendert die datierten, verifizierten Fakten zu chronologischen Timeline-
  Einträgen — deterministisch, kein LLM.

  - **Nur verifizierte Fakten** (`verified? == true`) speisen den Render
    (Phase-B-Vertrag: Unverifiziertes geht nicht in den Output, nur ins
    Claims-UI). Flag-statt-Drop heißt: die unverifizierten bleiben in der
    Fakt-Tabelle, fließen aber hier nicht ein.
  - **Nur datierte Fakten** (`in_game_date` gesetzt) — die Timeline ist der
    Zeitstrahl; undatierte Fakten gehören ins Resümee/Epos, nicht hierher.
  - Sortiert über `Repo.derive_chronik_sort_tuple/1` (dieselbe Familie-Logik
    wie die Chronik, #135/#650). `Enum.sort_by` ist stabil → bei gleichem
    Datum bleibt die Eingabe-Reihenfolge (z.B. session.number-Vorsortierung aus
    `Repo.list_campaign_facts/1`) als Tie-Break erhalten.

  Eintrag-Shape (Chronik-kompatibel für den späteren Cutover):
  `%{in_game_date, label, summary, source_refs, session_id, character}`.
  """
  @spec timeline([map()]) :: [map()]
  def timeline(facts) when is_list(facts) do
    facts
    |> Enum.filter(&renderable?/1)
    |> Enum.sort_by(fn f -> Repo.derive_chronik_sort_tuple(f["in_game_date"]) end)
    |> Enum.map(&to_entry/1)
  end

  defp renderable?(f) when is_map(f), do: verified?(f) and dated?(f)
  defp renderable?(_), do: false

  defp verified?(f), do: Map.get(f, "verified?") == true

  defp dated?(f) do
    case Map.get(f, "in_game_date") do
      d when is_binary(d) -> String.trim(d) != ""
      _ -> false
    end
  end

  defp to_entry(f) do
    %{
      in_game_date: f["in_game_date"],
      # Label = die Figur (falls vorhanden) — kompakter Anker im Zeitstrahl;
      # der eigentliche Inhalt ist der Claim als summary.
      label: Map.get(f, "character_alias") || "",
      summary: f["claim"],
      source_refs: Map.get(f, "source_refs") || [],
      session_id: Map.get(f, "session_id"),
      character: Map.get(f, "character_alias") || ""
    }
  end

  # ─── Prosa-Render (Resümee / Epos aus verifizierten Fakten) ──────────

  @doc """
  Rendert die verifizierten Fakten zu einem Resümee (LLM) + gatet das Ergebnis
  gegen das Fakt-Set. Gibt `%{md, flagged, clean?}` zurück: `flagged` sind
  gerenderte Claims, die auf KEINEN Fakt zurückführbar sind (Bindegewebe / Re-
  Inversion). `{:error, reason}` wenn die Generierung scheitert.
  """
  @spec render_summary([map()]) :: {:ok, map()} | {:error, term()}
  def render_summary(facts), do: render_with_gate(facts, &summary_prompt/1)

  @doc "Wie `render_summary/1`, aber Epos (literarische Ebene, Handlung an die Fakten gebunden)."
  @spec render_epos([map()]) :: {:ok, map()} | {:error, term()}
  def render_epos(facts), do: render_with_gate(facts, &epos_prompt/1)

  defp render_with_gate(facts, prompt_fn) do
    verified = Enum.filter(facts, &(Map.get(&1, "verified?") == true))

    cond do
      verified == [] ->
        {:error, :no_verified_facts}

      true ->
        prompt = prompt_fn.(verified)
        opts = [num_ctx: Worker.Settings.get(:ctx_stage2, 8192)]

        case LLM.complete(:summary, prompt, opts) do
          {:ok, md} when is_binary(md) ->
            {:ok, gate_rendered(String.trim(md), fact_claims(verified))}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Render-Gating: zerlegt den gerenderten Text in Claims und prüft pro Claim, ob
  er auf das Fakt-Set zurückführbar ist (`trace_fn`, default NLI). Nicht-führbare
  Claims sind `flagged` (die Prosa hat etwas hinzugedichtet / re-invertiert).
  PURE gegeben `trace_fn` — injizierbar für Tests ohne NLI.
  """
  @spec gate_rendered(String.t(), [String.t()], (String.t(), [String.t()] -> boolean())) :: map()
  def gate_rendered(rendered_md, fact_claims, trace_fn \\ &__MODULE__.traces_to_facts?/2)
      when is_binary(rendered_md) and is_list(fact_claims) and is_function(trace_fn, 2) do
    claims = Faithfulness.split_claims(rendered_md)
    {traceable, flagged} = Enum.split_with(claims, fn c -> trace_fn.(c, fact_claims) == true end)

    %{md: rendered_md, traceable: traceable, flagged: flagged, clean?: flagged == []}
  end

  @doc false
  # Default-Trace: ein gerenderter Claim ist führbar, wenn das Fakt-Set ihn
  # entailt (NLI gegen die Fakten als Premise). NLI-Fehler → false (konservativ:
  # nicht-verifizierbar = geflaggt, nicht still durchgewunken).
  def traces_to_facts?(rendered_claim, fact_claims) do
    pseudo_utts = fact_claims |> Enum.with_index(1) |> Enum.map(fn {c, i} -> %{id: "fact-#{i}", text: c} end)

    case Faithfulness.score(rendered_claim, pseudo_utts) do
      {:ok, %{score: s}} -> s >= 1.0
      _ -> false
    end
  end

  defp fact_claims(facts), do: Enum.map(facts, &(&1["claim"] || ""))

  @doc false
  def summary_prompt(facts) do
    """
    Verdichte die folgenden GESICHERTEN FAKTEN zu einem zusammenhängenden Resümee
    auf Deutsch (3-6 Sätze).

    STRENG (context-faithful): Verwende AUSSCHLIESSLICH die Fakten unten. Füge
    KEINEN neuen Claim, keine Figur, kein Ereignis hinzu, das nicht in den Fakten
    steht. Keine Deutung, keine Ausschmückung über die Fakten hinaus. Wenn die
    Fakten dünn sind, schreibe weniger.

    Fakten:
    #{numbered_facts(facts)}
    """
  end

  @doc false
  def epos_prompt(facts) do
    """
    Erzähle die folgenden GESICHERTEN FAKTEN als zusammenhängende, atmosphärische
    Geschichte auf Deutsch.

    Handlung treu, Erzählweise frei: Das WIE (Stimmung, Schauplätze, Erzählstimme)
    darfst du ausmalen — das WAS ist bindend. Verwende NUR Figuren, Orte,
    Ereignisse und Ausgänge aus den Fakten unten. Erfinde KEINE neuen Plot-Fakten,
    keine zusätzlichen benannten Figuren, keine Wendungen, die nicht in den Fakten
    stehen.

    Fakten:
    #{numbered_facts(facts)}
    """
  end

  defp numbered_facts(facts) do
    facts
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {f, i} ->
      who = case Map.get(f, "character_alias") do
        a when is_binary(a) and a != "" -> "[#{a}] "
        _ -> ""
      end

      "#{i}. #{who}#{f["claim"]}"
    end)
  end
end
