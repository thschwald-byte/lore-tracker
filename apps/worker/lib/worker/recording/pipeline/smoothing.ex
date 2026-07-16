defmodule Worker.Recording.Pipeline.Smoothing do
  @moduledoc """
  Stage 1.1 — deterministische Transkript-Glättung (Issue #862, Epic #861 Slice A).

  Fasst rohe ASR-Utterances VOR der Fakt-Extraktion zu Sprecher-Blöcken zusammen
  und entfernt ASR-Artefakte — **rein programmatisch, kein LLM** (der Gemma-
  Lücken-FÜLLVORSCHLAG ist ein separates, gepinntes Artefakt in Slice D+E; die
  Glättung selbst bleibt deterministisch: gleiche Utterances + gleiche Regeln →
  gleiche Blöcke).

  ## Regeln (die Transformation)

  1. **Sprecher-Merge**: konsekutive Utterances desselben Sprechers mit
     Zeit-Gap ≤ `merge_gap_seconds` werden EIN Block. Eine **OOC-Utterance
     bricht den Merge-Run** — ein Narrationsblock absorbiert nie einen
     Würfel-Turn (beide Fehlerrichtungen zu: Narration verschwindet nicht,
     OOC überlebt nicht als IC). Verworfene OOC-Utterances sind auditierbar
     (`ooc_verworfen` im Ergebnis — unterscheidbar „war OOC" vs. „Smoother
     hat's verloren").
  2. **Stotter-Dedup**: unmittelbare Wort-Wiederholung („Wir Wir" → „Wir",
     case-insensitiv, erste Form gewinnt).
  3. **Füllwort-Strip**: Tokens aus `@fillers` fliegen raus. Ein Block, dessen
     Text danach LEER ist, wird **verworfen** (nie ein leerer
     source_ref-Ziel-Block — das wäre ein Grounding-Bug).
  4. **⚠-Propagation**: `asr_unsicher` = mindestens eine Mitglieds-Utterance
     ist ASR-unsicher (low_token_fraction-Signal, #381).
  5. **`quell_utterance_ids`** = die Utterance-Menge **VOR** dem Strippen
     (Input-basiert; eine komplett gestrippte „äh"-Utterance bleibt Mitglied —
     die Block-ID hängt an den Inputs, nicht am Strip-Ergebnis).

  ## Content-Adresse (K1)

      block_id = "b_" <> hash(Enum.sort(quell_utterance_ids) ++ [rules_version])

  **Content-Adresse = Inputs + Transformations-Version.** `rules_version/0` wird
  zur COMPILE-Zeit aus den Regeldaten abgeleitet (Füllwortliste, OOC-Regex-
  Fingerprint, Dedup-/Merge-Semantik-Tags) — ein vergessener Hand-Bump ist
  strukturell unmöglich. Eine Regeländerung invalidiert Block-IDs ehrlich;
  Kurations-Overrides überleben via Read-Zeit-Re-Attach (Slice D+E, über die
  gesnapshottete Utterance-Menge). `merge_gap_seconds` steht NICHT in der
  Version: eine Gap-Änderung ändert die Komposition → `quell_utterance_ids`
  → die ID ändert sich von selbst.

  Die `@dedup_rules_tag`/`@merge_semantics_tag`-Integer decken ALGORITHMISCHE
  Änderungen (Code, nicht Daten) — bei Semantik-Änderung an `dedup_stutter/1`
  bzw. der Merge-Schleife von Hand hochzählen; der Golden-Test pinnt die
  resultierende Version und rotet bei jeder Regel-Drift sichtbar.

  ## Lücken-Erkennung (`detect_luecke`, deterministisch — E2)

  ASR-Signal-Regeln (KEIN Modell):
  - `low_token_fraction >= 0.30` (bei `token_count > 0`) — Häufung wackliger Tokens
  - `min_p < 0.15` (bei `token_count > 0`) — ein extrem unsicherer Token
  - Block-Text endet auf ein **hängendes Funktionswort** (`@hanging_words`,
    z.B. „…zurück zu") oder Ellipse — abgebrochenes Syntagma.

  **Benannte Grenze (False Negative, F4):** grammatische Lücken bei hoher
  Wort-ASR-Konfidenz — der Ur-Fall „Wir kommen mal zurück so unserem…"
  (fehlendes „zu", jedes Wort einzeln konfident) — werden von Signal-Regeln
  NICHT gefangen; der Text geht dann mit `konfidenz: "hoch"` ungeklemmt in die
  Extraktion (kein Schaden durch Erfindung, aber unerkannt roh). Fixture-belegt.

  ## `effective_text/3` — DIE eine Text-Funktion (B1 Runde 4)

  Präzedenz: Kurations-Override (Text-Snapshot) > offener Gap-Fill-Vorschlag >
  Smoothed-Text. ALLE Pipeline-Stufen (Extraktions-Prompt, Grounding, Verify,
  Render) nutzen diese Funktion — sonst hat jede Stufe ihre private Wahrheit.
  Ein Pipeline-Lauf resolved EINMAL und reicht den Wert durch (`extraction_saw`,
  Slice C); Live-Auflösung ist ausschließlich Sache der Dirty-Weiche (Slice F).
  `unbrauchbar`-Overrides liefern den Smoothed-Text (sie segnen keinen anderen
  Text ab) — die Extraktions-Oberfläche schließt solche Blöcke separat aus (F5).

  Rein + ohne Mnesia/LLM unit-testbar. Verdrahtung in die Pipeline: Slice C.
  """

  alias Worker.Recording.Pipeline.Ooc

  # ── Regeldaten (Bestandteil der abgeleiteten rules_version) ───────────────

  # Bewusst konservative Füllwort-Liste: nur eindeutige Verzögerungslaute.
  # KEIN „eh"/„halt"/„also" — die sind auch reguläre deutsche Wörter; ein zu
  # aggressiver Strip verlöre Inhalt (dieselbe Konservativitäts-Linie wie Ooc).
  @fillers ~w(äh ähm ehm öhm mhm hm hmm hee)

  # Algorithmus-Tags: von Hand hochzählen, wenn sich die SEMANTIK von
  # dedup_stutter/1 bzw. der Merge-Schleife ändert (Daten-Änderungen an
  # @fillers/OOC-Regexes fließen automatisch ein).
  @dedup_rules_tag 1
  @merge_semantics_tag 1

  # Hängende Funktionswörter für die Abbruch-Erkennung (detect_luecke Regel 3).
  # Ändert NUR das hat_luecke-Flag, nie Text/Komposition → bewusst NICHT in der
  # rules_version (Block-IDs bleiben stabil, Kurationen unberührt).
  @hanging_words ~w(der die das den dem des ein eine einem einen einer und oder
                    aber so zu mit von für auf in an bei nach vor über unter
                    durch um als wie)

  # Schwellen der Lücken-/Unsicherheits-Signale (#381-Confidence-Map).
  @luecke_fraction_threshold 0.30
  @luecke_min_p_threshold 0.15
  @uncertain_fraction_threshold 0.20

  @default_merge_gap_seconds 8

  @doc """
  Die aus den Regeldaten abgeleitete Transformations-Version (Compile-Zeit-
  Bestandteile) + OOC-Fingerprint (Laufzeit-Call, aber konstant pro Build).
  phash2 ist über Maschinen/OTP-Releases portabel-stabil.
  """
  @spec rules_version() :: non_neg_integer()
  def rules_version do
    :erlang.phash2({@fillers, Ooc.fingerprint(), @dedup_rules_tag, @merge_semantics_tag})
  end

  @doc """
  Glättet eine chronologisch sortierte Utterance-Liste (Atom-Key-Maps aus
  `Repo.list_utterances/2`) zu Blöcken.

  Opts: `:merge_gap_seconds` (Default #{@default_merge_gap_seconds} — der Wert
  kommt in Slice C aus der Campaign-Konfiguration, Class A).

  Returns `%{blocks: [block], ooc_verworfen: [utterance_id], rules_version: v,
  merge_gap_seconds: gap}` — snapshot-fertig für `TranscriptSmoothed` (Slice B).
  Blöcke sind String-Key-Maps (Event-Payload-Welt).
  """
  @spec smooth([map()], keyword()) :: %{
          blocks: [map()],
          ooc_verworfen: [String.t()],
          rules_version: non_neg_integer(),
          merge_gap_seconds: non_neg_integer()
        }
  def smooth(utterances, opts \\ []) when is_list(utterances) do
    gap = Keyword.get(opts, :merge_gap_seconds, @default_merge_gap_seconds)

    {runs, ooc_ids} = merge_runs(utterances, gap)

    blocks =
      runs
      |> Enum.map(&build_block/1)
      # Nur-Füllwort-Blöcke: nach dem Strip leerer Text → verwerfen, nie als
      # leeres source_ref-Ziel stehen lassen.
      |> Enum.reject(&(&1["text"] == ""))

    %{
      blocks: blocks,
      ooc_verworfen: ooc_ids,
      rules_version: rules_version(),
      merge_gap_seconds: gap
    }
  end

  @doc """
  Content-Adresse eines Blocks aus seiner Utterance-Menge: sortiert (Reihenfolge-
  unabhängig) + rules_version. SHA256-basiert (kollisionsfest, portabel), 16 Hex.
  """
  @spec block_id([String.t()]) :: String.t()
  def block_id(quell_utterance_ids) when is_list(quell_utterance_ids) do
    input =
      Enum.join(Enum.sort(quell_utterance_ids), ",") <> ":" <> Integer.to_string(rules_version())

    "b_" <> (:crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  @doc """
  DIE eine Text-Funktion (siehe Moduldoc). `vorschlag`/`override` sind die
  String-Key-Maps aus Slice D+E (oder nil).
  """
  @spec effective_text(map(), map() | nil, map() | nil) :: String.t()
  def effective_text(block, vorschlag, override)

  def effective_text(block, _vorschlag, %{"status" => st, "bestaetigter_text" => text})
      when st in ["bestaetigt", "manuell_korrigiert", "original_bestaetigt"] and is_binary(text) do
    _ = block
    text
  end

  # unbrauchbar segnet keinen Text ab → Smoothed-Text; Ausschluss aus der
  # Extraktions-Oberfläche passiert separat (F5, Slice D+E).
  def effective_text(block, vorschlag, %{"status" => "unbrauchbar"}),
    do: effective_text(block, vorschlag, nil)

  def effective_text(block, %{"original" => orig, "vorschlag" => fill}, nil)
      when is_binary(orig) and is_binary(fill) and orig != "" do
    String.replace(Map.fetch!(block, "text"), orig, fill, global: false)
  end

  def effective_text(block, _vorschlag, _override), do: Map.fetch!(block, "text")

  @doc """
  Stabiler Hash eines effektiven Block-Texts — die ZEIT-ADRESSE (`extraction_saw`,
  Slice C): der Extraktions-Snapshot hält fest, welchen Text er pro Block sah;
  die Dirty-Weiche (Slice F) vergleicht dagegen. SHA256, 16 Hex (portabel).
  """
  @spec text_hash(String.t()) :: String.t()
  def text_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc """
  Adapter Block → utterance-förmige Kontext-Map (Slice C, Vollumstellung E1):
  `%{id, discord_id, text, quell_utterance_ids}` mit BEREITS aufgelöstem
  `effective_text` (Einmal-Resolve pro Lauf, B2 — alle Stufen desselben Laufs
  arbeiten auf diesem Wert, nie auf effective_text(now)). Damit konsumieren
  Prompt-Renderer (`[uN]`-Index), Chunking, `resolve_source_refs` und
  `restrict_to_refs` Blöcke unverändert — `source_refs` werden Block-IDs.
  `vorschlaege`/`overrides`: Maps block_id → Artefakt (Slice D+E; bis dahin leer).
  """
  @spec to_context([map()], map(), map()) :: [map()]
  def to_context(blocks, vorschlaege \\ %{}, overrides \\ %{}) when is_list(blocks) do
    Enum.map(blocks, fn b ->
      id = Map.fetch!(b, "id")

      %{
        id: id,
        discord_id: b["speaker_discord_id"],
        text: effective_text(b, Map.get(vorschlaege, id), Map.get(overrides, id)),
        quell_utterance_ids: b["quell_utterance_ids"] || []
      }
    end)
  end

  # ── Merge-Schleife ─────────────────────────────────────────────────────────

  # Läuft chronologisch; sammelt Runs gleicher Sprecher innerhalb des Gaps.
  # OOC bricht den aktuellen Run (verhindert Absorption in beide Richtungen).
  # Utterances ohne discord_id mergen NIE (nil ist kein Sprecher — defensiv
  # jede ihr eigener Block statt fremde Turns zu verschmelzen).
  defp merge_runs(utterances, gap) do
    {runs_rev, current, ooc_rev} =
      Enum.reduce(utterances, {[], nil, []}, fn u, {runs, cur, ooc} ->
        cond do
          Ooc.ooc?(u_text(u)) ->
            {close(cur, runs), nil, [u_id(u) | ooc]}

          cur != nil and mergeable?(cur, u, gap) ->
            {runs, %{cur | utts: [u | cur.utts], last: u}, ooc}

          true ->
            {close(cur, runs), %{speaker: u_speaker(u), utts: [u], last: u}, ooc}
        end
      end)

    {Enum.reverse(close(current, runs_rev)), Enum.reverse(ooc_rev)}
  end

  defp close(nil, runs), do: runs
  defp close(cur, runs), do: [%{cur | utts: Enum.reverse(cur.utts)} | runs]

  defp mergeable?(cur, u, gap) do
    speaker = u_speaker(u)
    speaker != nil and speaker == cur.speaker and within_gap?(cur.last, u, gap)
  end

  defp within_gap?(prev, next, gap) do
    with %DateTime{} = t1 <- u_ts(prev),
         %DateTime{} = t2 <- u_ts(next) do
      DateTime.diff(t2, t1, :second) <= gap
    else
      # Nicht vergleichbare Timestamps → defensiv NICHT mergen.
      _ -> false
    end
  end

  # ── Block-Bau ──────────────────────────────────────────────────────────────

  defp build_block(%{speaker: speaker, utts: utts}) do
    # B1b: Mitgliedschaft ist INPUT-basiert (vor dem Strip) — die ID hängt an
    # den Inputs, nicht am Strip-Ergebnis.
    ids = Enum.map(utts, &u_id/1)

    text =
      utts
      |> Enum.map_join(" ", &u_text/1)
      |> dedup_stutter()
      |> strip_fillers()

    %{
      "id" => block_id(ids),
      "speaker_discord_id" => speaker,
      "text" => text,
      "quell_utterance_ids" => ids,
      "asr_unsicher" => Enum.any?(utts, &uncertain?/1),
      "hat_luecke" => detect_luecke(utts, text),
      "konfidenz" => if(detect_luecke(utts, text), do: "niedrig", else: "hoch")
    }
  end

  @doc """
  Unmittelbare Wort-Wiederholung kollabieren („Wir Wir kommen" → „Wir kommen").
  Case-insensitiver Vergleich, die ERSTE Form gewinnt. PURE.
  """
  @spec dedup_stutter(String.t()) :: String.t()
  def dedup_stutter(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [prev | _] ->
          if String.downcase(word) == String.downcase(strip_trailing_punct(prev)) or
               String.downcase(strip_trailing_punct(word)) == String.downcase(prev),
             do: acc,
             else: [word | acc]

        [] ->
          [word | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.join(" ")
  end

  @doc "Füllwort-Tokens entfernen (Vergleich case-insensitiv, satzzeichen-tolerant). PURE."
  @spec strip_fillers(String.t()) :: String.t()
  def strip_fillers(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(fn word ->
      String.downcase(strip_trailing_punct(word)) in @fillers
    end)
    |> Enum.join(" ")
  end

  defp strip_trailing_punct(word),
    do: String.trim(word, ",") |> String.trim(".") |> String.trim("…")

  # ── Signale ────────────────────────────────────────────────────────────────

  # ⚠-ASR-Unsicherheit (#381-Primärsignal, wie hub-seitig asr_uncertain?).
  defp uncertain?(u) do
    case u_conf(u) do
      %{"low_token_fraction" => f, "token_count" => n}
      when is_number(f) and is_integer(n) and n > 0 ->
        f > @uncertain_fraction_threshold

      _ ->
        false
    end
  end

  @doc """
  Deterministische Lücken-Erkennung (Regeln siehe Moduldoc; benannte
  False-Negative-Grenze: grammatische Lücken bei hoher Wort-Konfidenz).
  """
  @spec detect_luecke([map()], String.t()) :: boolean()
  def detect_luecke(utts, block_text) when is_list(utts) and is_binary(block_text) do
    Enum.any?(utts, &confidence_gap_signal?/1) or hanging_end?(block_text)
  end

  defp confidence_gap_signal?(u) do
    case u_conf(u) do
      %{"low_token_fraction" => f, "token_count" => n}
      when is_number(f) and is_integer(n) and n > 0 and f >= @luecke_fraction_threshold ->
        true

      %{"min_p" => p, "token_count" => n}
      when is_number(p) and is_integer(n) and n > 0 and p < @luecke_min_p_threshold ->
        true

      _ ->
        false
    end
  end

  defp hanging_end?(""), do: false

  defp hanging_end?(text) do
    if String.ends_with?(text, "…") or String.ends_with?(text, "--") do
      true
    else
      last = text |> String.split(~r/\s+/u, trim: true) |> List.last()
      last != nil and String.downcase(String.trim(last, ".")) in @hanging_words
    end
  end

  # ── Utterance-Zugriff (Atom- ODER String-Keys, wie restrict_to_refs) ──────

  defp u_id(u), do: Map.get(u, :id) || Map.get(u, "id")
  defp u_text(u), do: Map.get(u, :text) || Map.get(u, "text") || ""
  defp u_speaker(u), do: Map.get(u, :discord_id) || Map.get(u, "discord_id")
  defp u_conf(u), do: Map.get(u, :confidence) || Map.get(u, "confidence")
  defp u_ts(u), do: Map.get(u, :timestamp) || Map.get(u, "timestamp")
end
