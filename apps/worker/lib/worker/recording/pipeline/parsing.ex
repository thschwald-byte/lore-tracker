defmodule Worker.Recording.Pipeline.Parsing do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Parse-/JSON-/
  Sanitize-Schicht — robustes Dekodieren des Extraktions-Outputs (#651),
  source_refs-Auflösung, `<think>`/Code-Fence-Strip, Token-Schätzung/Prompt-
  Guard. Reine Funktionen (stdlib + Jason). Façade + Stages erreichen die
  Publics via import; Test-erreichbare via Façade-defdelegate. Die Chain-Parser
  (Summary/Epos/Chronik + Fabrication-Filter) sind seit #786 entfernt.
  """
  require Logger

  # Issue #976 (Epic #911 Slice 3): der Escape-Wert des `cast_match`-Enums
  # (Stages.facts_json_schema/1) — "keine der bekannten Cast-Figuren passt".
  # Single Source of Truth für Schema-Bau UND Normalisierung (beide Seiten
  # importieren/referenzieren diese Funktion statt eine eigene Kopie zu halten).
  @doc false
  @spec no_cast_match_sentinel() :: String.t()
  def no_cast_match_sentinel, do: "(kein Cast-Treffer)"

  # Issue #307: Kurz-ID-Mapping. Bildet die Lauf-Indizes `u1`…`uN` (im Prompt)
  # auf die echten Utterance-UUIDs ab — dieselbe `Enum.with_index/2`-Reihenfolge
  # wie der Prompt-Builder, daher muss keine Map durch die Pipeline gereicht
  # werden, der Parser rekonstruiert sie aus der Utterance-Liste.
  def utterance_index_map(utterances) do
    utterances
    |> Enum.with_index(1)
    |> Map.new(fn {u, i} -> {"u#{i}", u.id} end)
  end

  # Issue #307: LLM-source_refs auf echte UUIDs auflösen. Dual: erst Kurz-ID
  # über die Index-Map, sonst Passthrough wenn der Ref schon eine valide echte
  # UUID ist (Robustheit + Backward-Compat zu Tests/alten Pfaden). Alles andere
  # — Halluzinationen, Prompt-Platzhalter wie `<utterance-id-3>` (#114-Leak) —
  # fällt raus.
  def resolve_source_refs(refs, index_map, valid_ids) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_short_ref/1)
    |> Enum.map(fn ref ->
      cond do
        Map.has_key?(index_map, ref) -> Map.fetch!(index_map, ref)
        MapSet.member?(valid_ids, ref) -> ref
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def resolve_source_refs(_, _, _), do: []

  # Issue #651 (Wahrheitsbild, Phase A): Parser für den Extraktions-Output.
  # Erwartet `%{"facts" => [%{"claim", "character", "in_game_date", "source_refs"}]}`.
  # Normalisiert jeden Fakt auf das persistierte Shape (id, claim, entity_id,
  # character_alias, in_game_date, source_refs, verified?). source_refs werden
  # via Index-Map auf echte UUIDs aufgelöst (Halluzinationen rausgefiltert).
  #
  # FLAG STATT DROP: ein Fakt mit leeren source_refs wird NICHT verworfen —
  # ob er belegt ist, entscheidet das Phase-B-Verify-Gate. Verworfen wird nur
  # Junk ohne `claim`. `verified?` startet false (Phase B setzt es).
  # `entity_id` = minimal normalisierter Alias (die kanonische alias→entity-
  # Registry ist Phase B); das Feld-Shape steht aber jetzt.
  @doc false
  @spec parse_facts_json(binary() | nil, [map()]) :: {:ok, [map()]} | {:error, atom()}
  def parse_facts_json(raw, utterances) when is_binary(raw) do
    index_map = utterance_index_map(utterances)
    valid_ids = MapSet.new(utterances, & &1.id)

    # Issue #864 (Epic #861 Slice C): Kontext-Einheit → ihre Roh-Utterance-Menge
    # (Blöcke tragen quell_utterance_ids; rohe Utterances fallen auf sich selbst
    # zurück). Input der transform-ENTKOPPELTEN Fakt-Adresse (P1/B1 Runde 5).
    quell_lookup =
      Map.new(utterances, fn u -> {u.id, Map.get(u, :quell_utterance_ids) || [u.id]} end)

    case parse_with_notes_decode(raw) do
      {{:ok, %{"facts" => list}}, _notes} when is_list(list) ->
        facts =
          list
          |> Enum.map(fn f -> normalize_fact(f, index_map, valid_ids, quell_lookup) end)
          |> Enum.reject(&is_nil/1)
          # F2 (festgenagelt): identischer Claim + identische Refs = DERSELBE
          # Fakt → dedupe. NIE ein Suffix (wäre der positionale Pin durch die
          # Hintertür, den die Content-Adresse gerade abschafft).
          |> Enum.uniq_by(& &1["id"])
          # Issue #1068 (E4): Feld-Grounding der Zeitangabe. Läuft HIER, weil
          # hier beides vorliegt — die Fakten und der Chunk, den das Modell
          # tatsächlich gesehen hat.
          |> Enum.map(&grounde_zeitangabe(&1, utterances))

        {:ok, facts}

      {{:ok, _other}, _notes} ->
        {:error, :no_facts_key}

      {:parse_failed, _notes} ->
        {:error, :parse_failed}
    end
  end

  def parse_facts_json(_, _), do: {:error, :parse_failed}

  @doc """
  Claim-Normalisierung für Adresse + Dedup (Issue #864, EINE Quelle): lowercase,
  Nicht-Wort-Zeichen → Space, Whitespace kollabiert. **Invariant** gegen
  Whitespace/Groß-Klein/Satzzeichen; **NICHT invariant** gegen Umformulierung,
  Wortdreher, Synonyme (dokumentierte Nicht-Invarianzen — eine inhaltliche
  Umformulierung IST ein anderer Fakt).
  """
  @spec normalize_claim(term()) :: String.t()
  def normalize_claim(c) when is_binary(c) do
    c |> String.downcase() |> String.replace(~r/\W+/u, " ") |> String.trim()
  end

  def normalize_claim(_), do: ""

  @doc """
  Content-Adresse eines Fakts (Issue #864, P1): hash über die SORTIERTE
  Vereinigung der Roh-Utterance-Mengen seiner source_refs-Blöcke + den
  normalisierten Claim. Hängt an den ROH-Inputs, NICHT an versionsbehafteten
  Block-IDs — Adress-Invariante: keine versionsbehaftete Adresse als Input
  einer anderen (ein Rules-Bump ohne Kompositions-Änderung lässt Fakt-IDs
  stabil → Datum/Thread-Overrides überleben, B1 Runde 5).
  """
  @spec fact_content_id([String.t()], String.t()) :: String.t()
  def fact_content_id(quell_union, claim) when is_list(quell_union) and is_binary(claim) do
    input = Enum.join(Enum.sort(quell_union), ",") <> "|" <> normalize_claim(claim)
    "f_" <> (:crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  @doc """
  Issue #1068 (E4): steht die Zeitangabe eines Fakts WÖRTLICH im Quelltext?

  Ergänzt `"zeit_beleg"` mit einem von drei Werten:

      "woertlich"     der Ausdruck steht so im Text
      "normalisiert"  er steht dort bis auf Gross-/Kleinschreibung und
                      Interpunktion („24. Dezember. 2011" → „24. Dezember 2011")
      "abgeleitet"    er steht nirgends — das Modell hat gerechnet oder geraten

  Dazu `"zeit_beleg_ref"` (bool): ob er in den Blöcken steht, die der Fakt
  ZITIERT — im Gegensatz zum Chunk insgesamt. Steht er im Chunk, aber nicht in
  den Refs, ist das ein **Attributionsfehler**, kein Fabrikationsfehler; die
  beiden Klassen gehören in der Kuration getrennt.

  ## Warum gegen den Chunk und nicht gegen die Refs

  `source_refs` beantwortet „gehört der Ausdruck zu diesem Fakt", nicht „steht
  er im Text". Für die Frage nach Erfindung ist der Chunk die richtige Basis —
  und die vollständige: `resolve_source_refs/3` läuft chunk-lokal, ein Fakt
  kann also nichts referenzieren, was sein Chunk nicht enthielt.

  ## Warum zwei Stufen und kein Ähnlichkeitsmass

  Kalibriert an den 13 Fakten mit Datum aus `free-seattle-bereinigt`
  (worker_prod, 2026-08-19). Die zwei Stufen trennen sie sauber:

      woertlich       4    "2055 bis 2065", "2070", "Mitte der 2060er", "2080"
      normalisiert    2    "24. Dezember 2011"  (im Text: "24. Dezember. 2011")
      abgeleitet      7    "1.1.200", "1.1.2010"x2, "1.1.2014", "17. August 2017", …

  Eine dritte, unscharfe Stufe (n-Gramm-Ähnlichkeit über einer Schwelle) hätte
  in diesem Datensatz **nichts zusätzlich** gefangen — die sieben abgeleiteten
  sind gerechnete Daten aus Formulierungen wie „in den frühen 2000ern", nicht
  Schreibvarianten. Ein Schwellwert, den niemand kalibrieren kann, wäre nur ein
  weiterer Knopf. **Ehrliche Grenze:** 13 Fälle sind eine kleine Stichprobe;
  taucht später eine echte Schreibvariante auf, gehört die Stufe nachgerüstet.

  Der Befund selbst ist die eigentliche Nachricht: **9 von 13 Datumsangaben
  standen nicht wörtlich im Text.** Das Modell rechnet und normalisiert, statt
  abzuschreiben — genau das, was #1068 abstellen will.
  """
  @spec grounde_zeitangabe(map(), [map()]) :: map()
  def grounde_zeitangabe(fact, utterances) when is_map(fact) and is_list(utterances) do
    # `nil_if_blank/1` in `normalize_fact/4` trimmt bereits — der Trim hier
    # macht die Funktion für Direktaufrufe (Tests, künftige Pfade) trotzdem
    # robust: reiner Whitespace ist kein Datum und braucht keinen Beleg.
    # (Ein Guard kann das nicht prüfen, `String.trim/1` ist dort nicht erlaubt.)
    case fact["in_game_date"] do
      a when is_binary(a) and a != "" and not is_nil(a) ->
        if String.trim(a) == "" do
          fact
        else
          belege(fact, a, utterances)
        end

      _ ->
        fact
    end
  end

  def grounde_zeitangabe(fact, _), do: fact

  defp belege(fact, a, utterances) do
    chunk_text = utterances |> Enum.map(&text_von/1) |> Enum.join(" ")

    ref_text =
      utterances
      |> Enum.filter(&(id_von(&1) in (fact["source_refs"] || [])))
      |> Enum.map(&text_von/1)
      |> Enum.join(" ")

    fact
    |> Map.put("zeit_beleg", beleg_stufe(a, chunk_text))
    |> Map.put("zeit_beleg_ref", beleg_stufe(a, ref_text) != "abgeleitet")
  end

  defp text_von(u), do: Map.get(u, :text) || Map.get(u, "text") || ""
  defp id_von(u), do: Map.get(u, :id) || Map.get(u, "id")

  defp beleg_stufe(ausdruck, text) do
    a = String.trim(ausdruck)

    cond do
      a == "" or text == "" -> "abgeleitet"
      String.contains?(String.downcase(text), String.downcase(a)) -> "woertlich"
      String.contains?(entinterpunktiert(text), entinterpunktiert(a)) -> "normalisiert"
      true -> "abgeleitet"
    end
  end

  # Gross-/Kleinschreibung und Interpunktion weg, Whitespace auf ein Leerzeichen.
  # Ziffern und Buchstaben bleiben — „1.1.2010" wird zu „1 1 2010" und trifft
  # damit NICHT auf „in den frühen 2000ern", was richtig ist.
  defp entinterpunktiert(s) do
    s |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()
  end

  defp normalize_fact(f, index_map, valid_ids, quell_lookup) when is_map(f) do
    claim = f |> Map.get("claim") |> trim_or_empty()

    if claim == "" do
      nil
    else
      alias_name = resolve_character_alias(f)
      refs = resolve_source_refs(f["source_refs"], index_map, valid_ids)

      quell_union =
        refs |> Enum.flat_map(&Map.get(quell_lookup, &1, [&1])) |> Enum.uniq()

      %{
        "id" => fact_content_id(quell_union, claim),
        "claim" => claim,
        "entity_id" => normalize_entity_id(alias_name),
        "character_alias" => alias_name,
        "in_game_date" => nil_if_blank(f["in_game_date"]),
        # Issue #724 Slice D: temporale Felder. narration_time Whitelist mit
        # Default "present" (nie crashen bei Modell-Garbage); time_offset nur wenn
        # {value:int, unit:string} valide, sonst nil; precision Whitelist|nil.
        "narration_time" => normalize_narration(f["narration_time"]),
        "time_offset" => normalize_offset(f["time_offset"]),
        "precision" => normalize_precision(f["precision"]),
        # Issue #1068 (E3): `time_anchor` gehört in diese Liste, seit es
        # `Worker.Timeline.Resolver` gibt — und fehlte hier von Anfang an.
        #
        # Der Resolver kennt vier Ankertypen (`absolute`, `session`,
        # `event:<id>`, unknown), und `Worker.Timeline.Graph` hält dafür einen
        # kompletten Apparat: Fuzzy-Match der Referenz gegen die anderen
        # Claims, Kahn-Fixpunkt, Zyklusschutz. Weil das Feld hier fehlte,
        # konnte es aus der Extraktion NIE entstehen: gemessen an
        # `free-seattle-bereinigt` tragen 7 von 225 Fakten ein `time_anchor`,
        # und die stammen ausnahmslos aus der GM-Kuration
        # (`Repo.Artifacts.merge_override/3` forciert `"absolute"`). Die Typen
        # `"session"` und `"event:…"` kamen in echten Daten **null Mal** vor —
        # der Graph war Infrastruktur ohne Producer.
        #
        # Das Feld bleibt vorerst meist leer: der Extraktions-Prompt fragt es
        # nicht ab (das ist E4/#1075). Aber ohne diese Zeile fiele auch die
        # Ausgabe des deterministischen Zeit-Vorlaufs (E5/E7) stumm auf den
        # Boden, weil sie den Blob nie erreichte.
        "time_anchor" => normalize_anchor(f["time_anchor"]),
        # Issue #831 (Epic #829 Slice B): Handlungsbogen-Felder. Diese
        # Rekonstruktion ist die EINZIGE Stelle mit fixer Feldliste — die
        # Republish-Pfade (verify/registry/materializer) sind feldkonservativ
        # (`Map.put`/Jason.encode!). Ohne die zwei Zeilen hier beträten
        # fact_type/threads den Blob NIE. `fact_type` = Whitelist-Enum (Default
        # "ereignis", nie crashen bei Modell-Garbage, Muster normalize_narration).
        # Issue #953: `threads` = Liste getrimmter Kurzlabels (dedupliziert),
        # leere Liste = zu keinem Strang gehörig. Alt-Skalar `thread` wird als
        # 1-elementige Liste gelesen (Migration ohne Regenerate-Zwang).
        "fact_type" => normalize_fact_type(f["fact_type"]),
        "threads" => normalize_threads(f["threads"] || f["thread"]),
        "source_refs" => refs,
        "verified?" => false
      }
    end
  end

  defp normalize_fact(_, _, _, _), do: nil

  # Issue #976 (Epic #911 Slice 3): cast_match gewinnt, wenn's ein echter
  # Treffer ist (nicht blank, nicht der Sentinel) — sonst Fallback auf das
  # Freitext-Feld character (Ist-Zustand). Bewusst KEINE Re-Validierung
  # gegen das Roster hier (würde es durch parse_facts_json/normalize_fact
  # zusätzlich durchreichen müssen); für lokale/GBNF-Backends garantiert das
  # Schema selbst schon einen validen Wert, für Cloud-Backends (kein GBNF-
  # Zwang, #783) bleibt cast_match effektiv Freitext-Vertrauen — identisch
  # zum bisherigen Vertrauensniveau von character, keine Verschlechterung.
  defp resolve_character_alias(f) do
    character = f |> Map.get("character") |> trim_or_empty()
    cast_match = f |> Map.get("cast_match") |> trim_or_empty()

    if cast_match != "" and cast_match != no_cast_match_sentinel() do
      cast_match
    else
      character
    end
  end

  @narration_times ~w(present flashback future unknown)
  defp normalize_narration(t) when is_binary(t) do
    d = String.downcase(String.trim(t))
    if d in @narration_times, do: d, else: "present"
  end

  defp normalize_narration(_), do: "present"

  @precisions ~w(day month season year decade)
  defp normalize_precision(p) when is_binary(p) do
    d = String.downcase(String.trim(p))
    if d in @precisions, do: d, else: nil
  end

  defp normalize_precision(_), do: nil

  # Issue #1068 (E3): Ankertyp, wie `Worker.Timeline.Resolver` ihn erwartet.
  # `"absolute"` und `"session"` als Whitelist, `"event:<ausdruck>"` per Präfix
  # (der Ausdruck ist frei — `Worker.Timeline.Graph` matcht ihn gegen die
  # Claims der übrigen Fakten). Alles andere wird `nil` statt zu crashen,
  # Muster `normalize_narration/1`.
  #
  # `nil` heisst „kein Anker angegeben" und ist nicht dasselbe wie
  # `"unknown"` — der Resolver behandelt beide gleich, aber ein leeres Feld
  # unterscheidet sich für die Kuration von einem ausdrücklichen „weiss nicht".
  @anchors ~w(absolute session unknown)
  defp normalize_anchor(a) when is_binary(a) do
    d = a |> String.trim() |> String.downcase()

    cond do
      d in @anchors -> d
      String.starts_with?(d, "event:") and String.length(d) > 6 -> d
      true -> nil
    end
  end

  defp normalize_anchor(_), do: nil

  # Issue #831: Handlungsbogen-Fakttyp — Whitelist mit Default "ereignis" (nie
  # crashen bei Modell-Garbage, Muster normalize_narration/1). "auflösung"
  # signalisiert dem D1-Reader einen möglichen Strang-Abschluss (Vorschlag,
  # kein Auto-Übergang).
  @fact_types ~w(ereignis zustandsänderung beziehung absicht enthüllung auflösung)
  defp normalize_fact_type(t) when is_binary(t) do
    d = String.downcase(String.trim(t))
    if d in @fact_types, do: d, else: "ereignis"
  end

  defp normalize_fact_type(_), do: "ereignis"

  # Issue #831: rohes Strang-Kurzlabel — getrimmt, Leerstring bleibt Leerstring
  # (= zu keinem wiederkehrenden Strang gehörig). Die ThreadRegistry (#832)
  # clustert diese Roh-Labels später campaign-weit.
  @doc """
  Issue #953: Roh-Thread-Labels eines (gespeicherten) Fakts als Liste. Liest das
  neue `threads`-Array ODER (Bestandsfakt vor #953) den Alt-Skalar `thread` —
  getrimmt, nicht-leer, dedupliziert. Die EINE migrations-taugliche Lese-Stelle
  für alle Reader (registry / nachlese / render_assignments).
  """
  @spec fact_threads(map()) :: [String.t()]
  def fact_threads(f) when is_map(f), do: normalize_threads(f["threads"] || f["thread"])
  def fact_threads(_), do: []

  # Issue #953: Roh-`threads` → Liste getrimmter, nicht-leerer, deduplizierter
  # Kurzlabels. Akzeptiert eine Liste (Neu-Schema), einen Alt-Skalar-String
  # (Bestandsfakten vor #953 → 1-elementige Liste) oder Garbage (→ []).
  defp normalize_threads(list) when is_list(list) do
    list
    |> Enum.map(fn s -> s |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_threads(s) when is_binary(s) do
    case String.trim(s) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp normalize_threads(_), do: []

  # {value:int, unit:string} — nur valide Kombinationen durchlassen, sonst nil
  # (der Resolver behandelt ein vorhandenes-aber-kaputtes Offset konservativ).
  defp normalize_offset(%{"value" => v, "unit" => u}) when is_integer(v) and is_binary(u) do
    %{"value" => v, "unit" => String.downcase(String.trim(u))}
  end

  defp normalize_offset(_), do: nil

  defp trim_or_empty(s) when is_binary(s), do: String.trim(s)
  defp trim_or_empty(_), do: ""

  defp nil_if_blank(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp nil_if_blank(_), do: nil

  # Minimal-Canonicalization des Alias als entity_id-Platzhalter (Phase-B-
  # Registry ersetzt das durch echte Identitäts-Auflösung): lowercase +
  # Whitespace zusammenfassen. Leerer Alias → "".
  defp normalize_entity_id(""), do: ""

  defp normalize_entity_id(alias_name) do
    alias_name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp normalize_short_ref(ref) do
    ref
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim()
  end

  # Issue #307: grobe Token-Schätzung (Deutsch + Kurz-IDs ≈ 3 Bytes/Token,
  # gemessen in docs/Performance.md). Liegt der Prompt über `num_ctx`,
  # trunkiert Ollama den Transkript-ANFANG kommentarlos (behält die jüngsten
  # Token) — wir loggen das wenigstens als Warning, statt unbemerkt ein halbes
  # Transkript zu verarbeiten.
  #
  # Issue #417/#683: die Extraktion chunked, bevor dieser Guard feuert — er
  # bleibt als Diagnose für den Single-Prompt-Pfad.
  def guard_prompt_size(prompt, num_ctx, stage) when is_integer(num_ctx) do
    est = estimate_tokens(prompt)

    if est > num_ctx do
      Logger.warning(
        "Pipeline: #{stage} Prompt ~#{est} tok > num_ctx=#{num_ctx} — " <>
          "Ollama schneidet den Transkript-Anfang still ab."
      )
    end

    :ok
  end

  def guard_prompt_size(_prompt, _num_ctx, _stage), do: :ok

  # Issue #307/#417: gemeinsame grobe Token-Heuristik (≈ 3 Bytes/Token für
  # Deutsch + `[uN]`-Kurz-IDs, gemessen in docs/Performance.md). Genutzt vom
  # Prompt-Größen-Guard UND vom Extraktions-Chunking (chunk_utterances/3).
  def estimate_tokens(text) when is_binary(text), do: div(byte_size(text), 3)

  defp strip_think_blocks(s) do
    Regex.replace(~r/<think>.*?<\/think>/s, s, "")
  end

  defp strip_code_fence(s) do
    case Regex.run(~r/```(?:json)?\s*\n?(.+?)\n?```/s, s) do
      [_, inner] -> inner
      _ -> s
    end
  end

  # Issue #288: zentraler Sanitize-Helper. Wendet die Strip-Stufen
  # nacheinander an und akkumuliert welche tatsächlich gegriffen haben als
  # pipe-getrennter String (`"think_stripped|fence_unwrapped"`). Wenn keine
  # Stufe greift → `"ok"`. `extract_json_blob` zählt bewusst nicht (Last-
  # Resort-Prose-Extract, kein diagnostisches Signal — Issue #288 spec).
  @doc false
  def strip_and_note(raw) when is_binary(raw) do
    {after_think, notes_after_think} =
      case strip_think_blocks(raw) do
        ^raw -> {raw, []}
        stripped -> {stripped, ["think_stripped"]}
      end

    {after_fence, notes_after_fence} =
      case strip_code_fence(after_think) do
        ^after_think -> {after_think, notes_after_think}
        stripped -> {stripped, notes_after_think ++ ["fence_unwrapped"]}
      end

    cleaned = extract_json_blob(after_fence)
    notes_str = if notes_after_fence == [], do: "ok", else: Enum.join(notes_after_fence, "|")

    {cleaned, notes_str}
  end

  def strip_and_note(_), do: {"", "ok"}

  # Issue #288: kombiniert strip+notes mit dem Parse-Outcome. Wenn
  # Jason.decode scheitert wird `format_notes` zu `"parse_failed"`
  # promoviert (überstimmt die strip-Notes, die ohnehin nicht persistiert
  # werden wenn der Parse fehlschlägt).
  defp parse_with_notes_decode(raw) do
    {cleaned, strip_notes} = strip_and_note(raw)

    case Jason.decode(cleaned) do
      {:ok, decoded} -> {{:ok, decoded}, strip_notes}
      {:error, _} -> {:parse_failed, "parse_failed"}
    end
  end

  defp extract_json_blob(s) do
    trimmed = String.trim(s)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        trimmed

      true ->
        case Regex.run(~r/(\{.*\}|\[.*\])/s, trimmed) do
          [_, json] -> json
          _ -> trimmed
        end
    end
  end
end
