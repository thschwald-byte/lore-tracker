defmodule Worker.Recording.Pipeline.Prompts do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Prompt-Bau-
  Schicht — Summary-/Epos-/Chronik-Prompts (+ Map-Reduce-Partials/Retry), Flavor-/
  Heading-Direktiven, Stil-Vorschau. Reine Bau-Funktionen (Strings); ruft nur
  `Worker.Repo` (Vorschau-Sampling) + stdlib. Die Pipeline-Façade importiert dies
  für die Stage-Bodies; Test-erreichbare Publics hält die Façade als defdelegate.
  """
  alias Worker.Repo

  def build_summary_retry_prompt(original_prompt, faulty_output) do
    """
    #{original_prompt}

    --- Vorheriger Versuch (fehlerhaft) ---
    #{faulty_output}

    --- Anweisung ---
    Kein valides JSON. Korrigiere. Antworte ausschließlich mit dem korrigierten JSON.
    """
  end

  def build_partial_summary_prompt(utterances, speaker_names, flavors, heading) do
    transcript = render_transcript(utterances, speaker_names)

    """
    #{heading}#{flavor_preamble(flavors, "summary")}Dies ist EIN ABSCHNITT einer längeren Spielsitzung. Fasse NUR diesen
    Abschnitt zu einem dichten Teil-Resümee auf Deutsch zusammen — so knapp wie
    möglich, aber alle Handlungsschritte dieses Abschnitts. Überspringe
    Out-of-Game-Smalltalk (Pizza, Pausen, Regelfragen).

    `source_refs` ist die Liste der `u…`-Marker (in eckigen Klammern unten),
    auf denen das Teil-Resümee fußt. Verwende nur Marker aus dem Abschnitt.

    Abschnitt:
    #{transcript}

    #{fact_fidelity_block("Abschnitt")}
    """
  end

  def build_reduce_prompt(partials, flavors, heading) do
    joined =
      partials
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {md, i} -> "Teil #{i}:\n#{md}" end)

    """
    #{heading}#{flavor_preamble(flavors, "summary")}Unten stehen Teil-Resümees EINER Spielsitzung, in zeitlicher Reihenfolge.
    Fasse sie zu EINEM kohärenten Gesamt-Resümee auf Deutsch zusammen
    (3-6 Sätze). Keine Wiederholungen, keine neuen Fakten, kein Smalltalk.

    `source_refs` darf leer bleiben.

    Teil-Resümees:
    #{joined}

    FAKTENTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Verwende NUR Figuren, Orte und Ereignisse aus den Teil-Resümees oben.
    - Erfinde nichts dazu; wenn das Material dünn ist, schreibe weniger.
    """
  end

  def render_transcript(utterances, speaker_names) do
    utterances
    |> Enum.with_index(1)
    |> Enum.map(fn {u, i} ->
      "[u#{i}] #{Map.get(speaker_names, u.discord_id, u.discord_id)}: #{u.text}"
    end)
    |> Enum.join("\n")
  end

  # Issue #417: gerenderte Einzelzeile für die Chunk-Token-Schätzung. Der echte
  # Index variiert pro Position — fürs Budget irrelevant (~3 Token), daher
  # konstanter `[u]`-Marker.
  def transcript_line(u, speaker_names) do
    "[u] #{Map.get(speaker_names, u.discord_id, u.discord_id)}: #{u.text}"
  end

  def build_summary_prompt(utterances, speaker_names, flavors, heading) do
    transcript = render_transcript(utterances, speaker_names)

    """
    #{heading}#{flavor_preamble(flavors, "summary")}Verdichte das folgende Transkript zu einem Resümee auf Deutsch
    (3-6 Sätze). Überspringe Out-of-Game-Smalltalk (Pizza, Pausen,
    Regelfragen).

    `source_refs` ist die Liste der `u…`-Marker (in eckigen Klammern unten),
    auf denen das Resümee fußt. Verwende nur Marker aus dem Transkript; nimm
    die 3-8 wichtigsten Quellen, nicht alle.

    Transkript:
    #{transcript}

    #{fact_fidelity_block("Transkript")}
    """
  end

  # Issue #651 (Wahrheitsbild, Phase A): der Extraktions-Prompt — der EINE
  # gegatete Generativschritt. Quell-erhaltend: atomare, im Transkript belegte
  # Fakten (KEINE Prosa-Paraphrase), je mit Pflicht-source_refs (`u…`-Marker)
  # und der aus dem KONTEXT aufgelösten Figur (der SL spricht mehrere NPCs — die
  # Figur lebt im Text, nicht im Sprecher-Feld). Resümee/Epos/Timeline rendern
  # später als Geschwister aus diesen Fakten.
  def build_facts_extraction_prompt(utterances, speaker_names, flavors, heading) do
    transcript = render_transcript(utterances, speaker_names)

    """
    #{heading}#{flavor_preamble(flavors, "summary")}Extrahiere aus dem folgenden Spielsitzungs-Transkript die FAKTEN — atomare,
    im Text belegte Aussagen über Figuren, Orte und Ereignisse. KEINE Prosa,
    KEINE Zusammenfassung, KEINE Ausschmückung: nur die nackten Fakten, je einer
    pro Eintrag, in der Reihenfolge des Geschehens.

    Pro Fakt:
    - `claim`: EINE knappe, sachliche Aussage (ein Ereignis / eine Tatsache), wie
      sie aus dem Transkript hervorgeht. Keine Erzählstimme, keine Deutung.
    - `character`: die Figur, um die es geht bzw. die handelt — aus dem KONTEXT
      aufgelöst. Der Spielleiter spricht mehrere NPCs; die Figur steht im Text,
      nicht im Sprecher-Feld. Bei Spieler-Figuren der Charaktername. Leer lassen,
      wenn der Fakt keiner Figur zuzuordnen ist.
    - `in_game_date`: das im Transkript genannte In-Game-Datum / der Zeitpunkt —
      sonst null.
    - `source_refs`: die `u…`-Marker (in eckigen Klammern unten), auf denen der
      Fakt fußt. JEDER Fakt MUSS mindestens einen Marker zitieren.

    Überspringe Out-of-Game vollständig (Würfel, Werte, Regelfragen, Pausen, Meta).

    Transkript:
    #{transcript}

    QUELLTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Jeder Fakt MUSS aus dem Transkript belegbar sein (via source_refs). Erfinde
      NICHTS, fülle keine Lücken, dichte keine Wendung dazu.
    - Keine Fakten ohne Beleg. Im Zweifel weglassen.
    - Gib NUR Fakten zurück, die das Transkript wörtlich hergibt.
    """
  end

  defp fact_fidelity_block(source_label) do
    """
    FAKTENTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Verwende NUR Namen, Orte und Ereignisse die explizit im #{source_label} oben stehen.
    - Wenn ein Detail nicht im #{source_label} steht, lass es weg — fülle keine Lücken aus.
    - Wenn das Material nicht für die angefragte Länge reicht, schreibe weniger.
    - Keine inneren Monologe, keine erfundenen Nebenfiguren, keine ausgeschmückten Szenen.
    """
  end

  # Issue #308: Der Epos ist die literarische Ebene — Handlung treu, Erzählweise
  # frei. Bewusst gelockert ggü. fact_fidelity_block/1 (das für Resümee/Chronik
  # gilt): literarische Ausschmückung des WIE ist erwünscht, solange das WAS
  # (Figuren, Ereignisse, Reihenfolge, Ausgang) aus den Resümees stammt.
  defp epos_fidelity_block do
    """
    ERZÄHL-TREUE (Handlung treu, Erzählweise frei — gilt vor allen Stil-Vorgaben):
    - Die Handlung ist bindend: Figuren-Namen, zentrale Ereignisse, deren
      Reihenfolge und Ausgang müssen aus den Session-Resümees oben stammen.
    - Erfinde KEINE neuen Plot-Fakten: keine zusätzlichen benannten Figuren,
      keine Ereignisse oder Wendungen, die nicht in den Resümees vorkommen.
    - Das WIE darfst du literarisch ausmalen: Atmosphäre, Stimmung, Schauplatz-
      Schilderung, Stimmungen und Regungen der Figuren, Übergänge und eine
      durchgängige Erzählstimme sind ausdrücklich erwünscht — solange sie der
      bekannten Handlung nicht widersprechen.
    - Wenn das Material dünn ist, erzähle knapper statt Handlung zu erfinden.
    """
  end

  # Stellt den Stil/Voice der LLM-Antworten als Preamble vorne an. Base
  # (Welt/Setting) und slot-spezifische Voice werden kombiniert. Wenn die
  # Campaign weder Base noch Slot gesetzt hat, kommt nichts — der Prompt
  # bleibt setting-neutral und sachlich.
  defp flavor_preamble(flavors, slot) when is_map(flavors) do
    parts =
      ["base", slot]
      |> Enum.uniq()
      |> Enum.map(&effective_flavor(flavors, &1))
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.trim/1)

    case parts do
      [] ->
        ""

      list ->
        # Issue #389: kompakter Block — Header + Items mit einfachem Newline
        # zwischen den Zeilen, eine Blank-Line zum nachfolgenden Body. So
        # bleiben die Token-Kosten klein und der Prompt rendert in der
        # Live-Vorschau ohne große Whitespace-Inseln.
        "Stil-Vorgabe für diese Kampagne (oberste Priorität — Wortwahl, Ton, Atmosphäre, NICHT Inhalt oder Format):\n" <>
          Enum.join(list, "\n") <> "\n\n"
    end
  end

  defp flavor_preamble(_flavors, _slot), do: ""

  # Issue #313: campaign-gesetzter Ton gewinnt; sonst greift der Default-Ton
  # des Slots. Der #308-Literarik-Ton („atmosphärisch, Spannungsbögen …")
  # lebt jetzt hier als editierbarer Default für „epos" — nicht mehr
  # hartcodiert im gesperrten build_epos_prompt-Block. So bleibt der Output
  # out-of-the-box literarisch, ist aber pro Kampagne überschreibbar.
  @default_epos_flavor "Erzähle die Ereignisse als zusammenhängende, atmosphärische Geschichte: Stimmung, Schauplätze, Spannungsbögen und eine durchgängige Erzählstimme. Gib den Abschnitten erzählerische Titel."

  def effective_flavor(flavors, slot) when is_map(flavors) do
    case Map.get(flavors, slot) do
      s when is_binary(s) ->
        if String.trim(s) == "", do: default_flavor(slot), else: s

      _ ->
        default_flavor(slot)
    end
  end

  def default_flavor("epos"), do: @default_epos_flavor
  def default_flavor(_slot), do: nil

  # Issue #320: Überschrift (vorgaben[stage].name) als Prompt-Direktive. Die
  # Überschrift wird als Textsorte/Gattung verstanden — das LLM gestaltet den
  # Output entsprechend und erzeugt einen ZUM INHALT passenden Titel/Schlagzeile,
  # NICHT das Gattungswort selbst (z.B. „Zeitungsartikel" → echte Schlagzeile,
  # „Novelle" → echter Novellen-Titel). Nur wenn ein Name gesetzt ist — sonst ""
  # (Default-Spalten unverändert). Stage-aware: Chronik ist strikte JSON-Liste,
  # da nur Stil-Rahmung statt freier Überschrift.
  @spec heading_directive(String.t() | nil, String.t()) :: String.t()
  def heading_directive(name, stage) when is_binary(name) do
    case String.trim(name) do
      "" -> ""
      n -> format_directive(stage, n)
    end
  end

  def heading_directive(_, _), do: ""

  defp format_directive("chronik", n),
    do:
      "Formuliere die Chronik-Einträge im Stil der Textsorte «#{n}» " <>
        "(die JSON-Struktur wird durch das Format-Schema fix vorgegeben).\n\n"

  defp format_directive(_stage, n),
    do:
      "Gestalte diesen Abschnitt als «#{n}» (Textsorte/Gattung): folge ihren Konventionen und " <>
        "beginne mit einer zum INHALT passenden Überschrift bzw. Schlagzeile im Stil dieser " <>
        "Textsorte. Verwende NICHT das Wort «#{n}» selbst als Titel.\n\n"

  # Eigener Überschrift-Name dieser Stage aus den Campaign-Vorgaben (nil = default).
  @spec stage_heading(map(), String.t()) :: String.t() | nil
  def stage_heading(campaign, stage) when is_map(campaign) do
    case campaign[:vorgaben] do
      %{^stage => %{name: n}} when is_binary(n) -> n
      _ -> nil
    end
  end

  def stage_heading(_, _), do: nil

  # Sampling-Knöpfe pro Stage (Issue #11). Liefert eine Keyword-Liste mit
  # temperature/top_p/num_predict/repeat_penalty; nil-Werte werden vom
  # Backend ignoriert (Worker.LLM.Local.build_options/1).
  def sampling_opts(stage) when stage in [2, 3, 4] do
    [
      temperature: Worker.Settings.get(:"temperature_stage#{stage}"),
      top_p: Worker.Settings.get(:"top_p_stage#{stage}"),
      num_predict: Worker.Settings.get(:"num_predict_stage#{stage}"),
      repeat_penalty: Worker.Settings.get(:"repeat_penalty_stage#{stage}")
    ]
  end

  def blank?(nil), do: true
  def blank?(s) when is_binary(s), do: String.trim(s) == ""
  def blank?(_), do: true

  # Build discord_id → preferred-display-name STRING map for the campaign:
  # character_name (Issue #2) wins; else users.display_name; else raw id.
  def resolve_speaker_names(campaign_id) do
    char_names = Repo.character_names_for(campaign_id)

    # users_for_campaign returns %{did => %{display_name, avatar_url}} after #6;
    # flatten to a string-map before merging with char_names (also strings).
    user_names =
      Repo.users_for_campaign(campaign_id)
      |> Enum.into(%{}, fn
        {did, %{"display_name" => name}} -> {did, name}
        {did, name} when is_binary(name) -> {did, name}
        {did, _} -> {did, did}
      end)

    Map.merge(user_names, char_names)
  end

  # Public so tests können den Prompt-Build über `apply/3` verifizieren
  # (Issue #226). Marker `@doc false` weil interne API — nicht für externe
  # Aufrufer gedacht.
  @doc false
  def build_epos_prompt(
        existing_md,
        summaries,
        flavors,
        force? \\ false,
        darstellungsform \\ "fliesstext",
        heading \\ ""
      )
      when is_list(summaries) do
    # Issue #114: jede Session-Block trägt jetzt die Liste ihrer Source-
    # Utterance-IDs als annotation. Stage 3 LLM kann daraus pro Absatz oder
    # global eine `source_refs`-Liste zurückgeben (Vereinigung der Quellen
    # die einflossen).
    summaries_block =
      summaries
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} ->
        refs = Map.get(s, :source_refs, [])

        refs_line =
          if refs == [],
            do: "",
            else: "Quell-Utterances: #{Enum.join(refs, ", ")}\n"

        "### Session #{i}\n#{refs_line}#{s.content_md}"
      end)
      |> Enum.join("\n\n")

    # Issue #226: bei manuellem Re-Run (force=true) einen expliziten Hinweis
    # in den Prompt einbauen — sonst produziert das LLM bei nahezu-identischem
    # Input einen bit-identischen Output (temp=0.2 + nur subtil geänderte
    # Summaries → deterministisches Verhalten).
    force_hint =
      if force? do
        """

        HINWEIS: Dies ist ein expliziter Re-Run. Integriere insbesondere die
        jüngsten Session-Inhalte sichtbar in den fortlaufenden Epos. Wiederhole
        NICHT den bisherigen Text wortgleich, sondern erweitere ihn um die
        neuen Plot-Punkte aus den zuletzt hinzugekommenen Resümees.
        """
      else
        ""
      end

    """
    #{heading}#{flavor_preamble(flavors, "epos")}#{epos_structure_block(darstellungsform)}

    Wichtig: das Feld `content_md` ist ein reiner Markdown-String
    (Überschriften, Absätze, evtl. Listen). Verschachtele kein zusätzliches
    JSON-Object darin — der vom Format-Schema vorgegebene äußere Container
    ist das einzige JSON-Object.

    `source_refs` ist die Vereinigung der wichtigsten Quell-Utterance-IDs
    aus den Session-Resümees (siehe Annotationen). Übernehme die utterance_ids
    aus den Resümees, max. 30 Stück (die wichtigsten).

    Bisheriger Text (NUR als Referenz für bereits etablierte Namen und
    Kontinuität — NICHT den Stil übernehmen; folge dem oben gesetzten Stil):
    #{existing_md}

    Session-Resümees (chronologisch):
    #{summaries_block}

    #{epos_fidelity_block()}
    #{force_hint}
    """
  end

  # Issue #313: genre-neutraler Struktur-Block (gesperrt) — nur die FORM,
  # kein Ton. Fließtext (Prosa) vs. Stichpunkte (Liste). Der literarische
  # Ton kommt aus dem editierbaren Flavor (Default = @default_epos_flavor),
  # nicht mehr von hier — so passt der fixe Teil für jedes Genre.
  def epos_structure_block("stichpunkte") do
    String.trim("""
    Fasse die chronologisch aufgelisteten Session-Resümees unten zu einer
    gegliederten Liste auf Deutsch zusammen: ein Stichpunkt pro Ereignis, in
    zeitlicher Reihenfolge. Gruppiere zusammengehörende Ereignisse über
    Session-Grenzen hinweg unter `##`-Abschnitts-Überschriften (nicht pro
    Session). Keine ausschweifende Prosa.
    """)
  end

  def epos_structure_block(_fliesstext) do
    String.trim("""
    Schreibe aus den chronologisch aufgelisteten Session-Resümees unten einen
    zusammenhängenden Fließtext (Prosa) auf Deutsch — KEINE Aufzählung. Gliedere
    nach HANDLUNGSBÖGEN, nicht pro Session: fasse zusammengehörende Ereignisse
    über Session-Grenzen hinweg unter `##`-Überschriften zusammen. Optional ein
    `#`-Titel für das ganze Dokument.
    """)
  end

  # Issue #320: Marker für die im Vorschau-Prompt gekürzten Quelldaten.
  @preview_more "[… weiteres Material hier gekürzt — die LLM bekommt den vollständigen Inhalt …]"

  @doc """
  Issue #313/#320: liefert den Stage-Prompt als Segment-Liste für die Hub-
  Vorschau. **Byte-genau**: ruft denselben echten Builder auf, den die Pipeline
  benutzt (mit gekürzten Beispiel-Quelldaten), und markiert darin nur die
  editierbaren Werte (Ton `base`/Stage + Überschrift `name`) als `:editable` —
  alles andere bleibt `:locked` und ist wortgleich der echte LLM-Input. Die
  Builder selbst bleiben unverändert → kein Drift zwischen Vorschau und Realität.
  """
  @spec preview_prompt(String.t(), map()) :: [tuple()]
  def preview_prompt(stage, campaign)
      when stage in ["summary", "epos", "chronik"] and is_map(campaign) do
    flavors = campaign[:flavors] || %{}

    form =
      case campaign[:vorgaben] do
        %{^stage => %{darstellungsform: f}} when is_binary(f) and f != "" -> f
        _ -> "fliesstext"
      end

    heading = heading_directive(stage_heading(campaign, stage), stage)
    real = preview_real_prompt(stage, campaign, flavors, heading, form)

    # Editierbare Werte (so wie sie im echten Prompt stehen = getrimmt).
    values =
      [
        {"name", stage_heading(campaign, stage)},
        {"base", effective_flavor(flavors, "base")},
        {stage, effective_flavor(flavors, stage)}
      ]
      |> Enum.map(fn {slot, v} -> {slot, String.trim(to_string(v || ""))} end)
      |> Enum.reject(fn {_slot, v} -> v == "" end)

    tokenize_editables(real, values)
  end

  # Ruft den echten Builder mit gekürzten Beispiel-Quelldaten auf.
  defp preview_real_prompt("summary", campaign, flavors, heading, _form),
    do: build_summary_prompt(sample_utterances(campaign), %{}, flavors, heading)

  defp preview_real_prompt("epos", campaign, flavors, heading, form),
    do: build_epos_prompt("", sample_summaries(campaign), flavors, false, form, heading)

  defp preview_real_prompt("chronik", campaign, flavors, heading, _form),
    do:
      build_chronik_prompt(
        sample_epos(campaign),
        :first_try,
        flavors,
        sample_utterances(campaign),
        heading
      )

  defp sample_utterances(campaign) do
    base =
      with cid when is_binary(cid) <- campaign[:id],
           [session | _] <- Repo.list_sessions(cid),
           [_ | _] = utts <- Repo.list_utterances(session.id) do
        utts
        |> Enum.take(3)
        |> Enum.map(fn u ->
          %{discord_id: u.discord_id, text: String.slice(to_string(u.text), 0, 120), id: u.id}
        end)
      else
        _ -> []
      end

    base ++ [%{discord_id: "—", text: @preview_more, id: "preview-marker"}]
  end

  defp sample_summaries(campaign) do
    base =
      with cid when is_binary(cid) <- campaign[:id],
           [_ | _] = sums <- Repo.list_session_summaries(cid) do
        sums
        |> Enum.take(2)
        |> Enum.map(fn s ->
          %{
            content_md: String.slice(to_string(s.content_md), 0, 200),
            source_refs: Map.get(s, :source_refs, [])
          }
        end)
      else
        _ -> []
      end

    base ++ [%{content_md: @preview_more, source_refs: []}]
  end

  defp sample_epos(campaign) do
    case campaign[:id] && Repo.get_epos_entry(campaign[:id]) do
      %{content_md: md} when is_binary(md) and md != "" ->
        String.slice(md, 0, 240) <> "\n\n" <> @preview_more

      _ ->
        @preview_more
    end
  end

  # Zerlegt den echten Prompt-String in `:locked`-Text + `:editable`-Slots, indem
  # die (getrimmten) Eingabewerte an ihrer ersten Fundstelle markiert werden.
  # Links-nach-rechts, ein Wert je Fundstelle (Rest wird im Resttext gesucht →
  # auch gleiche base/stage-Texte werden korrekt getrennt).
  defp tokenize_editables(text, values) do
    matches =
      values
      |> Enum.flat_map(fn {slot, v} ->
        case :binary.match(text, v) do
          {pos, len} -> [{pos, len, slot, v}]
          :nomatch -> []
        end
      end)

    case Enum.min_by(matches, &elem(&1, 0), fn -> nil end) do
      nil ->
        drop_empty([{:locked, text}])

      {pos, len, slot, v} ->
        before = binary_part(text, 0, pos)
        rest = binary_part(text, pos + len, byte_size(text) - pos - len)

        drop_empty([{:locked, before}, {:editable, slot, v}]) ++
          tokenize_editables(rest, List.delete(values, {slot, v}))
    end
  end

  defp drop_empty(segs) do
    Enum.reject(segs, fn
      {:locked, ""} -> true
      _ -> false
    end)
  end

  def build_chronik_prompt(epos_md, attempt, flavors, session_utterances, heading) do
    nudge =
      case attempt do
        :retry ->
          """

          HINWEIS: Im ersten Versuch hast du eine leere Liste geliefert.
          Schaue noch einmal nach klaren Plot-Beats (Ankunft, Begegnung,
          Kampf, Entdeckung). Wenn das Material in einem Kapitel keinen
          klaren Plot-Beat hergibt, lass es weg — eine leere Liste ist
          besser als erfundene Einträge.
          """

        _ ->
          ""
      end

    # Issue #114/#307: verfügbare Kurz-IDs als Whitelist für source_refs.
    # `[uN]` statt voller UUID (Token-Diät, siehe build_summary_prompt). Index
    # 1-basiert, deckungsgleich mit der Auflösung in stage4/3 (Enum.take(60)).
    utterance_ids_block =
      session_utterances
      |> Enum.take(60)
      |> Enum.with_index(1)
      |> Enum.map(fn {u, i} ->
        text_preview = u.text |> to_string() |> String.slice(0, 60)
        "  - u#{i}: #{text_preview}"
      end)
      |> Enum.join("\n")

    """
    #{heading}#{flavor_preamble(flavors, "chronik")}Du extrahierst aus dem folgenden Text eine In-Game-Zeitstrahl-Liste.

    Der Text ist das Resümee EINER einzelnen Spielsitzung. Extrahiere
    ausschließlich Ereignisse, die in DIESER Sitzung passieren — niemals
    Ereignisse aus früheren oder späteren Sitzungen, selbst wenn sie dir
    bekannt vorkommen oder thematisch anknüpfen.

    Regeln:
    - `in_game_date` ist eine chronologische Marke: ein In-Game-Datum
      (z.B. "1625-04-15") oder ein Tag-/Szenen-Zähler (z.B. "Tag 1",
      "Tag 2"), damit die Einträge sortierbar bleiben. Schreibe KEINE
      prosaischen Phrasen wie "Spätabend", "am nächsten Morgen", "kurz
      darauf" oder "Sie standen vor der Tür" in dieses Feld. Steht im Text
      kein explizites Datum, vergib aufsteigende Tag-/Szenen-Zähler in der
      Reihenfolge der Ereignisse.
    - `label` ist eine kurze Überschrift (max 50 Zeichen).
    - `summary` ist ein Satz auf Deutsch.
    - `source_refs` ist die Liste der `u…`-Marker (siehe Whitelist unten)
      die zu diesem Eintrag beigetragen haben — leer wenn keine passt.
    - Antworte NUR mit dem JSON, keine Vorrede.

    ANTI-FABRICATION (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Wenn der Text kein konkretes Datum oder keinen klaren Plot-Beat
      hergibt, lass den Eintrag weg. Eine leere Liste ist eine gültige
      Antwort.
    - Schreibe NIEMALS in `in_game_date` Strings wie "Nicht im Transkript
      erwähnt", "Unbekannt", "Keine Angabe", "N/A" — das sind keine
      gültigen Daten, der Eintrag gehört dann gar nicht in die Liste.
    - Erfinde keine Cliffhanger, keine Atmospheric Filler, keine
      Übergangs-Sätze "Die Gruppe macht sich auf …" wenn dazu nichts
      Konkretes im Transkript steht.
    - source_refs darf nur `u…`-Marker aus der Whitelist unten enthalten —
      keine erfundenen Marker.#{nudge}

    Verfügbare Utterance-Marker der triggernden Session:
    #{utterance_ids_block}

    Text:
    #{epos_md}

    #{fact_fidelity_block("Text")}
    """
  end
end
