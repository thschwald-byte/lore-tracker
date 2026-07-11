defmodule Worker.Recording.Transcribe.Confidence do
  @moduledoc """
  Issue #791: reine Value-Transformer aus `Worker.Recording.Transcribe`
  ausgelagert (God-Module-Split #544, `Worker.Repo`-#719-Muster). Kein I/O,
  keine externen Prozesse — nur Segment-Dedup, Whisper-Halluzinations-Filter
  und Per-Token-Confidence-Aggregation.

  `Worker.Recording.Transcribe` behält eine `defdelegate`-Fassade, die
  Call-Sites (Probelauf, BenchReader, PromptBuilder, Tests) bleiben
  `Transcribe.<fn>` — nur die Implementierung wohnt jetzt hier.
  """

  require Logger

  # Whisper neigt zu Wiederholungen auf stillen/rauschigen Passagen (klassische
  # Halluzination). Schmeißt aufeinanderfolgende Segmente raus, deren
  # normalisierter Text identisch ist. Konservativ — keine Levenshtein-Fuzzy,
  # damit echte Wiederholungen wie „Ja. Ja." (zwei Sätze) erhalten bleiben,
  # während eine wiederholte Identität in Folge gedroppt wird.
  # Public weil per Test reflexiv aufgerufen.
  def dedupe_consecutive(segments) do
    {acc, _last_norm} =
      Enum.reduce(segments, {[], nil}, fn seg, {kept, last_norm} ->
        norm = seg |> Map.get("text", "") |> normalize_for_dedupe()

        cond do
          norm == "" -> {kept, last_norm}
          norm == last_norm -> {kept, last_norm}
          true -> {[seg | kept], norm}
        end
      end)

    Enum.reverse(acc)
  end

  defp normalize_for_dedupe(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Bekannte Whisper-Halluzinations-Strings die auf Stille, Hintergrundmusik
  # oder sehr leisen Passagen entstehen. Public für Tests.
  @hallucination_patterns [
    ~r/^\[BLANK_AUDIO\]$/i,
    ~r/^\[Stille\]$/i,
    ~r/^\[ *Stille *\]$/i,
    ~r/^\[Musik\]$/i,
    ~r/^\[ *Musik *\]$/i,
    ~r/^\(Musik\)$/i,
    ~r/^Danke fürs Zuschauen\.?$/i,
    ~r/^Vielen Dank\.?$/i,
    ~r/^Vielen Dank fürs? Zuschauen\.?$/i,
    ~r/^Tschüss\.?$/i,
    ~r/^Auf Wiedersehen\.?$/i,
    ~r/^Bis zum nächsten Mal\.?$/i,
    ~r/^Bis bald\.?$/i,
    ~r/^Untertitel(?:ung)? (?:von|des|im Auftrag) .+$/i,
    ~r/^Abonniert? (?:jetzt|den Kanal)\.?$/i,
    ~r/^\[.*?Applaus.*?\]$/i,
    ~r/^\[.*?Gelächter.*?\]$/i,
    ~r/^www\.\S+$/i,
    # YouTube/streaming outros
    ~r/^Thanks? for watching\.?$/i,
    ~r/^Subscribe to .+$/i,
    ~r/^Like and subscribe\.?$/i,
    ~r/^(?:Please )?like,? (?:and )?subscribe\.?$/i,
    # Music/sound indicators
    ~r/^♪.+♪$/u,
    ~r/^\[Music\]$/i,
    ~r/^\[Applause\]$/i,
    ~r/^\[Laughter\]$/i,
    ~r/^\(.+(?:Musik|Lachen|Applaus|Laughter|Applause|music).+\)$/i,
    # German formality outros (häufig bei Stille + deutsch)
    ~r/^Vielen Dank für (?:Ihre?|Ihre? )?Aufmerksamkeit\.?$/i,
    ~r/^Danke schön\.?$/i,
    ~r/^Herzlichen Dank\.?$/i,
    # Signaturzeile-Artefakt
    ~r/^Gez\.\s+\S+/,
    # Transcript-Boilerplate
    ~r/^Untertitel (?:von|der|des) /i,
    ~r/^Untertitelung (?:von|der|des) /i,
    ~r/^Übersetzt von /i,
    # Chunk-boundary artifacts (häufig bei Stille + whisper.cpp 1s-chunks)
    ~r/^\.\.\.$/,
    ~r/^\.{4,}$/,
    # Issue #234: Onomatopoeia-Emphasis-Marker `*...*` (z.B. `*Squeaky*`,
    # `*räuspert sich*`). Whisper produziert das selten in legitimen
    # Outputs — wenn doch, ist's fast immer aus dem Initial-Prompt
    # reprojiziert (Self-Vergiftung).
    ~r/^\*[^*]+\*\.?$/u
  ]

  def filter_hallucinations(segments) do
    Enum.reject(segments, fn seg ->
      text = seg |> Map.get("text", "") |> String.trim()
      hallucination?(text)
    end)
  end

  # Public so PromptBuilder kann symmetrisch denselben Filter beim
  # Prompt-Build anwenden (Issue #234: Self-Vergiftung via Rolling-Context).
  @spec hallucination?(String.t()) :: boolean
  def hallucination?(text) when is_binary(text) do
    trimmed = String.trim(text)
    Enum.any?(@hallucination_patterns, &Regex.match?(&1, trimmed))
  end

  def hallucination?(_), do: false

  @doc """
  Issue #376/#381: aggregiert Per-Token-Probabilities (`tokens[].p` aus
  `-ojf`) zu Segment-Confidence-Map:

      %{"mean_p" => f, "min_p" => f, "low_token_fraction" => f, "token_count" => n}

  Special-Tokens (`[_BEG_]`, `[_TT_*]`, EOT etc.) haben in Whisper p≈1.0 und
  würden den Mean künstlich anheben — sie werden anhand der Token-ID
  rausgefiltert. Cut bei 50257 gilt für das multilinguale Whisper-Vokab
  (Lore-Tracker-Default); `.en`-Modelle hätten den Cut bei 50256, irrelevant
  hier.

  Tokens ohne `p`-Key (oder `p: nil`) werden verworfen, **nicht** auf 0.0
  gezwungen — sonst zöge ein einzelner JSON-Hiccup den ganzen Segment-Mean
  auf 0.

  Issue #381: zusätzlich wird `low_token_fraction` = Anteil der Tokens mit
  `p < threshold` (default 0.5, pro Worker via
  `Worker.Settings.put(:confidence_low_token_threshold, …)` tunbar) und
  `token_count` (n, gefiltert) mitgeschrieben. Das ist die längen-
  normalisierte Größe, gegen die das Hub-UI gated — `min_p` allein hat
  Längen-Bias (sinkt mit N, lange Utts über-flaggen).

  **Caveat kurzes Ende:** bei sehr kleinem `token_count` (n<8) ist die
  Fraction grob und über-sensitiv für Clip-Rand-Tokens. Hub-UI flagged
  dann konservativer (Tooltip-Hinweis).

  **Eingefrorenes Aggregat:** der Threshold-Lookup passiert HIER zur
  Transkriptionszeit. Späteres Drehen von `:confidence_low_token_threshold`
  wirkt nur auf neu-transkribierte Utterances, nicht rückwirkend.
  """
  @spec aggregate_token_confidence([map()] | any()) :: map() | nil
  def aggregate_token_confidence(tokens) when is_list(tokens) do
    threshold = Worker.Settings.get(:confidence_low_token_threshold, 0.5)

    real =
      tokens
      |> Enum.filter(fn t -> is_map(t) and is_integer(t["id"]) and t["id"] < 50_257 end)
      |> Enum.map(& &1["p"])
      |> Enum.filter(&is_number/1)

    case real do
      [] ->
        nil

      ps ->
        n = length(ps)
        low_count = Enum.count(ps, &(&1 < threshold))

        %{
          "mean_p" => Float.round(Enum.sum(ps) / n, 4),
          "min_p" => Float.round(Enum.min(ps), 4),
          "low_token_fraction" => Float.round(low_count / n, 3),
          "token_count" => n
        }
    end
  end

  def aggregate_token_confidence(_), do: nil

  @doc """
  Issue #376: normalisiert Confidence-Werte aus Seed/Probelauf/Manual-Pfaden
  auf das einheitliche Map-Format `%{"mean_p" => f, "min_p" => f}`. So
  crasht später kein `confidence["min_p"]` an einem Float-Altwert.

  - `nil` → `nil` (keine Messung verfügbar).
  - Zahl → Map mit gleichem Wert für mean + min.
  - Bereits Map → idempotent.
  - Sonst (unbekannter Typ): Warning + `nil`, damit der Pipeline-Flow
    nicht crasht.
  """
  @spec to_confidence_map(any()) :: map() | nil
  def to_confidence_map(nil), do: nil
  def to_confidence_map(%{"mean_p" => _, "min_p" => _} = m), do: m

  def to_confidence_map(n) when is_number(n) do
    f = n * 1.0
    # Issue #381: token_count: 0 ist der Marker "kein echtes Aggregat".
    # Hub-Side asr_uncertain?/1 nutzt das im Primary-Guard, damit
    # Platzhalter (Seed/Probelauf/Manual) niemals den Fraction-Pfad triggern.
    %{"mean_p" => f, "min_p" => f, "low_token_fraction" => 0.0, "token_count" => 0}
  end

  def to_confidence_map(other) do
    Logger.warning("to_confidence_map/1: unexpected #{inspect(other)} — using nil")
    nil
  end
end
