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
  - **Prosa-Render** (`render_arc_progression/5`) — die Bogen-Progressionen
    aus den verifizierten Fakten, mit **context-faithful Prompt** (nur diese
    Fakten, kein neuer Claim). Das Resümee schreibt seit J5 (#1209, B4) der
    Resümee-Jack (`Worker.Jack.Resuemee.Pipeline`), das Epos-Kapitel seit J6
    (#1210, E4) der Epos-Jack (`Worker.Jack.Epos.Pipeline`);
    `render_summary/2` und `render_epos/2` sind entfernt. Übrig sind
    `summary_prompt/2` und `epos_prompt/2` — die früheren Prompts, die nur
    noch die Stil-Vorschau eines zurückgerollten Hubs abfragt
    (`Worker.HubClient.Rpc.on_preview/2`).
  - **Kapitelkopf** (`chapter_header/3`) — deterministisch (#752), auch für
    das Kapitel des Epos-Jack.

    #1124: das frühere **Render-Gating** (NLI-Rückführung jedes erzeugten Satzes
    auf das Fakt-Set) ist ersatzlos entfallen. Die Verify-Abdeckung endet damit
    an der Extraktion; was die Prosa daraus macht, wird nicht mehr geprüft.
    Grund: beim Epos maß das Gate das Falsche — der Prompt erlaubt Ausschmückung
    ausdrücklich, geflaggt wurden zwei Drittel eines Kapitels —, beim Resümee
    überwiegend seinen eigenen Claim-Splitter. Offene Frage dazu: #1125.
  """

  alias Worker.LLM

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
  @spec timeline([map()], %{optional(String.t()) => non_neg_integer()}) :: [map()]
  def timeline(facts, block_pos \\ %{}) when is_list(facts) and is_map(block_pos) do
    facts
    |> Enum.filter(&renderable?/1)
    |> Enum.map(&to_entry(&1, block_pos))
  end

  defp renderable?(f) when is_map(f), do: verified?(f) and dated?(f)
  defp renderable?(_), do: false

  defp verified?(f), do: Map.get(f, "verified?") == true

  # Datiert = aufgelöster Tageszähler ODER nicht-leeres rohes in_game_date.
  defp dated?(f) do
    is_integer(f["in_game_day"]) or
      (is_binary(f["in_game_date"]) and String.trim(f["in_game_date"]) != "")
  end

  # Issue #1092: die FRÜHESTE Quell-Position des Eintrags — ein Fakt kann
  # mehrere Blöcke zitieren, und der Zeitpunkt, an dem er im Gespräch zu
  # entstehen beginnt, ist der erste davon. `nil`, wenn keine Referenz
  # zuzuordnen ist (Seeds, Alt-Sessions ohne Glättung) — der Reader sortiert
  # solche Einträge ans Ende ihres Tages.
  @doc false
  @spec earliest_source_pos([String.t()], map()) :: non_neg_integer() | nil
  def earliest_source_pos(refs, block_pos) when is_list(refs) and is_map(block_pos) do
    refs
    |> Enum.map(&Map.get(block_pos, &1))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> nil
      list -> Enum.min(list)
    end
  end

  def earliest_source_pos(_, _), do: nil

  defp to_entry(f, block_pos) do
    {display, day, precision} =
      case f["in_game_day"] do
        d when is_integer(d) -> {f["display"], d, f["precision"]}
        # Nicht aufgelöst → rohen String behalten, kein Tageszähler.
        _ -> {f["in_game_date"], nil, nil}
      end

    refs = Map.get(f, "source_refs") || []

    %{
      in_game_date: display,
      in_game_day: day,
      precision: precision,
      # Label = die Figur (falls vorhanden) — kompakter Anker im Zeitstrahl;
      # der eigentliche Inhalt ist der Claim als summary.
      label: Map.get(f, "character_alias") || "",
      summary: f["claim"],
      source_refs: refs,
      session_id: Map.get(f, "session_id"),
      character: Map.get(f, "character_alias") || "",
      source_pos: earliest_source_pos(refs, block_pos)
    }
  end

  # ─── Epos-Kapitel-Kopf (Issue #752, deterministisch) ─────────────────

  @doc """
  Issue #752: deterministischer Kapitel-Kopf für das per-Session-Epos-Kapitel —
  die EINZIGE Kontinuität zwischen Kapiteln kommt aus Daten, nie aus dem LLM
  (Poisoning-Entscheidung, #651-Kommentar 2026-07-08).

  `entries` ist der `timeline/2`-Output der Session. Nur Einträge mit
  aufgelöstem Integer-Tageszähler speisen die Tag-Range; Sessions ohne
  datierte Fakten bekommen den nackten Kopf (keine „Tag ?–?"-Leichen).
  PURE — kein LLM, kein Mnesia.

  **Issue #1092: der Kopf zeigt ein DATUM, keinen Zähler.** `in_game_day` ist
  ein Tageszähler seit der Kalender-Epoche; roh ausgegeben entstanden real in
  Prod Köpfe wie `## Kapitel 1 — Tag 734372–759565` (das sind der 24.12.2011
  und der 1.1.2081 — 69 Jahre, dargestellt als zwei siebenstellige Zahlen).
  Für einen Leser ist das keine Zeitangabe, sondern eine Seriennummer.

  Ohne Kalender (`nil`) bleibt es beim nackten Kopf statt beim Zähler: eine
  falsch verstandene Zahl ist schlechter als keine Angabe.
  """
  @spec chapter_header(map(), [map()], Worker.Timeline.Calendar.t() | nil) :: String.t()
  def chapter_header(session, entries, calendar \\ nil) when is_list(entries) do
    base = "## Kapitel #{session.number}"

    days =
      entries
      # `Map.get`, nicht `&1.in_game_day`: ein Eintrag OHNE Tag ist seit #1211
      # der Normalfall („lieber keine Angabe als eine gerechnete"), und wer das
      # Feld weglässt, darf den Kapitelkopf nicht umbringen.
      |> Enum.map(&Map.get(&1, :in_game_day))
      |> Enum.filter(&is_integer/1)

    case {days, calendar} do
      {[], _} ->
        base

      {_, nil} ->
        base

      {list, cal} ->
        {min_d, max_d} = Enum.min_max(list)
        precision = coarsest_precision(entries)
        von = Worker.Timeline.Calendar.format(cal, min_d, precision)
        bis = Worker.Timeline.Calendar.format(cal, max_d, precision)

        if von == bis, do: "#{base} — #{von}", else: "#{base} — #{von}–#{bis}"
    end
  end

  # Issue #1092: die GRÖBSTE Präzision der beteiligten Einträge gewinnt — der
  # Kopf spannt über alle, er darf nicht genauer aussehen als sein ungenauester
  # Bestandteil. Ohne Angabe `:day` (die Auflösungs-Granularität), wie in
  # `Resolver.effective_precision/2`.
  defp coarsest_precision(entries) do
    entries
    |> Enum.map(& &1[:precision])
    |> Enum.map(&Worker.Timeline.Resolver.to_precision/1)
    |> Enum.reject(&(&1 == :unknown))
    |> case do
      [] -> :day
      list -> Enum.max_by(list, &Worker.Timeline.Resolver.precision_rank/1)
    end
  end

  # ─── Prosa-Render (Bogen-Progressionen aus verifizierten Fakten) ─────

  @doc """
  Issue #838: EIN (Bogen × Session)-Eintrag der Prosa-Progression.
  `new_facts` füttert den Prompt (Session-Delta ODER volle Historie im
  Backfill-Fall, s. `Prompts.build_arc_progression_prompt/4`) — `gate_facts`
  füttert NUR das Gate (immer die VOLLE Arc-Fakt-Historie, unabhängig vom
  Prompt-Input): der neue Eintrag knüpft an den vorherigen an und kann sich
  implizit auf ältere, etablierte Aussagen beziehen — ein Gate nur gegen das
  Prompt-Delta würde das systematisch als "nicht führbar" flaggen (#838-Plan
  Nutzt Stage 4 (Resümee) — kein eigener Stage-Slot in v1 (Design G).
  `complete_fn` injizierbar (Muster `ThreadRegistry.cluster_fn` #842) — Tests
  brauchen keinen echten/gemockten LLM-HTTP-Call.

  #1124: der frühere `gate_facts`-Parameter und die Gate-Injektion sind mit dem
  Render-Gate entfallen.
  """
  @spec render_arc_progression(
          String.t(),
          map() | nil,
          [map()],
          map(),
          (atom(), String.t(), keyword() -> {:ok, String.t()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def render_arc_progression(
        canonical,
        prior_entry,
        new_facts,
        campaign \\ %{},
        complete_fn \\ &LLM.complete/3
      ) do
    prompt =
      Worker.Recording.Pipeline.Prompts.build_arc_progression_prompt(
        canonical,
        prior_entry,
        new_facts,
        campaign
      )

    opts = render_opts()

    with :ok <- check_prompt_size(prompt, opts[:num_ctx], stage_backend(:render)),
         {:ok, md} when is_binary(md) <- complete_fn.(:render, prompt, opts) do
      {:ok, %{md: String.trim(md)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # #889/#909: fail-loud Prompt-Größen-Guard — NUR fürs Local-Backend: Ollama
  # trunkiert still bei prompt_tokens > num_ctx (das Modell sieht einen
  # abgerissenen Nummern-Schwanz und antwortet mit einer Assistenten-
  # Entschuldigung, die als Resümee persistiert würde — der #889-Real-Befund).
  # Cloud-Backends ignorieren num_ctx komplett (CloudHelper reicht es nicht
  # durch) und failen bei Oversize laut beim Provider (http_error-Klasse).
  # Schätzung = Parsing.estimate_tokens (÷3 Bytes); die Varianz der Heuristik
  # ist die benannte Grenze — bewusst KEINE Pseudo-Marge, Ollamas
  # Trunkierungsbedingung ist genau prompt > num_ctx.
  def check_prompt_size(prompt, num_ctx, backend) when is_binary(prompt) do
    est = Worker.Recording.Pipeline.Parsing.estimate_tokens(prompt)

    if backend == :local and is_integer(num_ctx) and est > num_ctx,
      do: {:error, {:prompt_too_large, est, num_ctx}},
      else: :ok
  end

  # Dieselbe Default-Auflösung wie LLM.complete (Settings.get(…, :local)).
  defp stage_backend(:render), do: Worker.Settings.get(:backend_stage4, :local)

  @doc """
  #755: die LLM-Optionen des Resümee-Renders (R_n). Erben die Stage-4-
  Sampling-Knöpfe (temperature/top_p/repeat_penalty) — vorher liefen die
  Renders auf der Modell-Default-Temperatur, an allen Settings vorbei.
  `num_predict` bewusst NICHT (Prosa terminiert selbst; das Stage-Cap ist
  für 3-6-Satz-Resümees dimensioniert und würde ein Kapitel abschneiden —
  analog zur Extraktions-Begründung in stages.ex).

  #783 Phase 2: Render-Resümee hat sein eigenes Backend + Modell (Stage 4,
  via backend_stage4 + model_stage4_<backend>) — kein separater Override
  mehr (render_model/put_model_override sind entfernt). PURE bis auf
  Settings-Reads.
  """
  @spec render_opts() :: keyword()
  def render_opts do
    # #755 Reopen: num_predict_stage4 als optionale Notbremse (nil = aus,
    # Prosa terminiert selbst — der frühere Zustand ohne jeden Deckel bleibt
    # der Default; ein degeneriertes Reasoning-Modell ist damit aber kappbar).
    [num_ctx: Worker.Settings.get(:ctx_stage4, 8192)] ++
      Worker.Recording.Pipeline.Prompts.sampling_opts(4) ++
      Worker.Recording.Pipeline.Prompts.num_predict_opt(4)
  end

  # #787: die Prompt-Bodies leben in der Prompt-Bau-Schicht (Prompts) — EIN
  # Builder für Pipeline UND Stil-Editor-Vorschau (byte-genau). Die Wrapper
  # bleiben als Test-erreichbare Publics. J5 (#1209, B4) und J6 (#1210, E4):
  # Resümee- und Epos-Prompt speisen keine Pipeline mehr — nur noch die
  # Vorschau eines zurückgerollten Hubs.
  @doc false
  def summary_prompt(facts, campaign \\ %{}),
    do: Worker.Recording.Pipeline.Prompts.build_summary_render_prompt(facts, campaign)

  @doc false
  def epos_prompt(facts, campaign \\ %{}),
    do: Worker.Recording.Pipeline.Prompts.build_epos_render_prompt(facts, campaign)
end
