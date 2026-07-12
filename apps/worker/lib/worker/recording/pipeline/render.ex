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

  alias Worker.LLM
  alias Worker.LLM.Faithfulness

  @doc """
  Rendert verifizierte, datierte Fakten zu Chronik-kompatiblen Timeline-
  Einträgen — deterministisch, kein LLM.

  **Erwartet Fakten, die bereits durch `Worker.Timeline.Graph.resolve/3`
  gelaufen sind** (Issue #724 Slice E): sie tragen `"in_game_day"` (Integer
  Tageszähler | nil), `"precision"` (String) und `"display"` (formatierter
  String) zusätzlich zum rohen `"in_game_date"`.

  - **Nur verifizierte Fakten** (`verified? == true`) — Phase-B-Vertrag.
  - **Nur datierte Fakten** — ein aufgelöster Tageszähler ODER ein nicht-leeres
    rohes `in_game_date` (der Sort-Fallback der Chronik greift für Letzteres via
    Familie 1, #650). Undatierte gehen ins Resümee, nicht hierher.
  - Ein aufgelöster Fakt (`in_game_day` integer) nutzt den formatierten
    `display`-String als Anzeige; ein nicht auflösbarer behält seinen rohen
    `in_game_date`-String (z.B. „Tag 5") — dieser sortiert am Read-Path über
    `derive_chronik_sort_tuple` weiter (kein Datenverlust, nur keine globale
    Chronologie).

  Eintrag-Shape: `%{in_game_date, in_game_day, precision, label, summary,
  source_refs, session_id, character}`.
  """
  @spec timeline([map()]) :: [map()]
  def timeline(facts) when is_list(facts) do
    facts
    |> Enum.filter(&renderable?/1)
    |> Enum.map(&to_entry/1)
  end

  defp renderable?(f) when is_map(f), do: verified?(f) and dated?(f)
  defp renderable?(_), do: false

  defp verified?(f), do: Map.get(f, "verified?") == true

  # Datiert = aufgelöster Tageszähler ODER nicht-leeres rohes in_game_date.
  defp dated?(f) do
    is_integer(f["in_game_day"]) or
      (is_binary(f["in_game_date"]) and String.trim(f["in_game_date"]) != "")
  end

  defp to_entry(f) do
    {display, day, precision} =
      case f["in_game_day"] do
        d when is_integer(d) -> {f["display"], d, f["precision"]}
        # Nicht aufgelöst → rohen String behalten, kein Tageszähler.
        _ -> {f["in_game_date"], nil, nil}
      end

    %{
      in_game_date: display,
      in_game_day: day,
      precision: precision,
      # Label = die Figur (falls vorhanden) — kompakter Anker im Zeitstrahl;
      # der eigentliche Inhalt ist der Claim als summary.
      label: Map.get(f, "character_alias") || "",
      summary: f["claim"],
      source_refs: Map.get(f, "source_refs") || [],
      session_id: Map.get(f, "session_id"),
      character: Map.get(f, "character_alias") || ""
    }
  end

  # ─── Epos-Kapitel-Kopf (Issue #752, deterministisch) ─────────────────

  @doc """
  Issue #752: deterministischer Kapitel-Kopf für das per-Session-Epos-Kapitel —
  die EINZIGE Kontinuität zwischen Kapiteln kommt aus Daten, nie aus dem LLM
  (Poisoning-Entscheidung, #651-Kommentar 2026-07-08).

  `entries` ist der `timeline/1`-Output der Session. Nur Einträge mit
  aufgelöstem Integer-Tageszähler speisen die Tag-Range; Sessions ohne
  datierte Fakten bekommen den nackten Kopf (keine „Tag ?–?"-Leichen).
  PURE — kein LLM, kein Mnesia.
  """
  @spec chapter_header(map(), [map()]) :: String.t()
  def chapter_header(session, entries) when is_list(entries) do
    base = "## Kapitel #{session.number}"

    days =
      entries
      |> Enum.map(& &1.in_game_day)
      |> Enum.filter(&is_integer/1)

    case days do
      [] ->
        base

      list ->
        {min_d, max_d} = Enum.min_max(list)
        if min_d == max_d, do: "#{base} — Tag #{min_d}", else: "#{base} — Tag #{min_d}–#{max_d}"
    end
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
        opts = render_opts()

        case LLM.complete(:summary, prompt, opts) do
          {:ok, md} when is_binary(md) ->
            {:ok, gate_rendered(String.trim(md), fact_claims(verified))}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  #755: die LLM-Optionen der Prosa-Renders (R_n + Ep_n). Erben die Stage-2-
  Sampling-Knöpfe (temperature/top_p/repeat_penalty) — vorher liefen die
  Renders auf der Modell-Default-Temperatur, an allen Settings vorbei.
  `num_predict` bewusst NICHT (Prosa terminiert selbst; das Stage-2-Cap ist
  für 3-6-Satz-Resümees dimensioniert und würde ein Kapitel abschneiden —
  analog zur Extraktions-Begründung in stages.ex).

  #783: `:render_model` erlaubt ein anderes Modell für die Prosa-Renders als
  den Extraktor (analog `:judge_model` im Verify) — nil/leer = Stage-2-Modell.
  PURE bis auf Settings-Reads.
  """
  @spec render_opts() :: keyword()
  def render_opts do
    ([num_ctx: Worker.Settings.get(:ctx_stage2, 8192)] ++
       Keyword.delete(Worker.Recording.Pipeline.Prompts.sampling_opts(2), :num_predict))
    |> LLM.put_model_override(Worker.Settings.get(:render_model))
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
    pseudo_utts =
      fact_claims |> Enum.with_index(1) |> Enum.map(fn {c, i} -> %{id: "fact-#{i}", text: c} end)

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
      who =
        case Map.get(f, "character_alias") do
          a when is_binary(a) and a != "" -> "[#{a}] "
          _ -> ""
        end

      "#{i}. #{who}#{f["claim"]}"
    end)
  end
end
