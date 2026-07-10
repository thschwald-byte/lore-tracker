defmodule Worker.Recording.Pipeline.Prompts do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Prompt-Bau-
  Schicht — Fakten-Extraktions-Prompt (#651), Flavor-/Heading-Direktiven,
  Stil-Vorschau. Reine Bau-Funktionen (Strings); ruft nur `Worker.Repo`
  (Vorschau-Sampling) + stdlib. Die Pipeline-Façade importiert dies; Test-
  erreichbare Publics hält die Façade als defdelegate. Die Chain-Prompts
  (Summary/Epos/Chronik + Map-Reduce-Partials/Retry) sind seit #786 entfernt.
  """
  alias Worker.Repo

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
    - `character`: die Figur, die im Fakt handelt oder spricht — aus dem KONTEXT
      aufgelöst, NICHT der Sprecher-Turn. Der Spielleiter spricht mehrere NPCs
      hintereinander; die Figur steht im Text („der König sagt …", „Irene fragt
      …"), nicht im Sprecher-Feld. Bei Spieler-Figuren der Charaktername (Kodex,
      Skrapnik, Holmes). Bei Guise/Verkleidung die im Fakt gemeinte Rolle
      (König, Graf von Kramm — nicht der Klarname, wenn im Text die Rolle
      auftritt). Leerer String `""` NUR bei Weltinfo/Rahmenbedingung, die
      keiner Figur gehört (z.B. „Seattle steht vor der Unabhängigkeitsabstimmung",
      „Die Konzerne regieren die Sechste Welt"). Im Zweifel die Figur eintragen,
      nicht auslassen — Attribution und Timeline hängen an diesem Feld.
    - `narration_time`: WANN passiert das Ereignis relativ zur laufenden Szene?
      `"present"` = jetzt, im aktuellen Spielgeschehen (Default, die klare
      Mehrheit). `"flashback"` = eine Figur erzählt/erinnert etwas VERGANGENES
      („Damals, vor dem Krieg …", „Als ich noch jung war …"). `"future"` =
      Prophezeiung/Plan/Vorhersage („In hundert Jahren wird …", „Wir werden
      morgen …"). Trenne die ERZÄHLZEIT (wann wird es gesagt) von der ERZÄHLTEN
      ZEIT (wann geschah es): ein im Kampf erzählter Rückblick ist `"flashback"`,
      nicht `"present"`.
    - `in_game_date`: das im Transkript wörtlich genannte In-Game-Datum, wenn
      eines fällt (z.B. „20. März 1888", „Abend des Nachmittags"). Leerer String
      `""`, wenn kein Datum genannt oder klar ableitbar ist — NICHT raten,
      NICHT Realdatum, NICHT „irgendwann später".
    - `time_offset` (optional): NUR wenn eine RELATIVE zeitliche Distanz zur
      Gegenwart genannt wird („vor 10 Jahren", „in drei Tagen", „letzten Winter").
      Objekt `{"value": <ganzzahl, vorzeichenbehaftet>, "unit": "day"|"week"|
      "month"|"year"}` — Vergangenheit negativ, Zukunft positiv. „vor 10 Jahren"
      → `{"value":-10,"unit":"year"}`. Weglassen, wenn keine Distanz fällt oder
      schon ein `in_game_date` steht. NICHT rechnen, nur die genannte Distanz.
    - `precision` (optional): Genauigkeit des Zeitpunkts — `"day"|"month"|"year"|
      "decade"`. Weglassen, wenn unklar.
    - `source_refs`: die `u…`-Marker der Turns, deren WORTLAUT den Fakt belegt —
      so WENIGE wie möglich, nur die tatsächlich belegenden (meist 1-3; bei einem
      über mehrere Turns verteilten Ereignis die wenigen beteiligten). NICHT
      vorsichtshalber Nachbar-Turns mitzitieren. Zitiere NIEMALS Würfel-, Wert-,
      Regel-, Pausen- oder Meta-Turns als Beleg — auch dann nicht, wenn sie direkt
      neben der belegenden Stelle stehen. Findet sich kein inhaltlich belegender
      Turn, lass den Fakt WEG (lieber kein Fakt als ein falsch geerdeter).

    Beispiele (illustrieren nur das Feld-Ausfüllen, KEINE Vorlage für Inhalte):
    - `{"claim":"Skrapnik nimmt den Auftrag an","character":"Skrapnik","narration_time":"present","in_game_date":"","source_refs":["u42"]}`
    - `{"claim":"Die Verhandlung findet am 20. März 1888 abends statt","character":"","narration_time":"present","in_game_date":"20. März 1888 abends","precision":"day","source_refs":["u3"]}`
    - Flashback (Figur erzählt Vergangenes): `{"claim":"Kaira verlor ihren Bruder an die Myzel-Blüte","character":"Kaira","narration_time":"flashback","in_game_date":"","time_offset":{"value":-10,"unit":"year"},"precision":"year","source_refs":["u55"]}`
    - Prophezeiung (Zukunft): `{"claim":"Die Seherin sagt den Fall der Stadt voraus","character":"die Seherin","narration_time":"future","in_game_date":"","time_offset":{"value":100,"unit":"year"},"source_refs":["u60"]}`
    - Weltinfo ohne Figur: `{"claim":"Seattle wählt über die Unabhängigkeit ab","character":"","narration_time":"present","in_game_date":"","source_refs":["u1"]}`

    Out-of-Game (Würfel, Werte „X gegen Y", „Geschafft"/„Probe", Regelfragen,
    Pausen, Meta) ist KEIN Inhalt: weder als Fakt extrahieren NOCH als source_ref
    zitieren. Ein Würfelausgang („Idee-Probe geschafft") ist kein Fakt — der
    daraus folgende NARRATIVE Inhalt ist es, und der ist in den Erzähl-Turns
    belegt, nicht im Würfel-Turn.

    Transkript:
    #{transcript}

    QUELLTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Jeder Fakt MUSS aus dem Transkript belegbar sein (via source_refs). Erfinde
      NICHTS, fülle keine Lücken, dichte keine Wendung dazu.
    - Keine Fakten ohne Beleg. Im Zweifel weglassen.
    - Gib NUR Fakten zurück, die das Transkript wörtlich hergibt.
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
  # des Slots. (Der frühere Epos-Default-Flavor ist mit den Chain-Prompts
  # gefallen — #787 webt Flavors in die Render-Prompts ein und bringt einen
  # neuen Default mit.)
  def effective_flavor(flavors, slot) when is_map(flavors) do
    case Map.get(flavors, slot) do
      s when is_binary(s) ->
        if String.trim(s) == "", do: default_flavor(slot), else: s

      _ ->
        default_flavor(slot)
    end
  end

  def default_flavor(_slot), do: nil

  # Issue #320: Überschrift (vorgaben[stage].name) als Prompt-Direktive. Die
  # Überschrift wird als Textsorte/Gattung verstanden — das LLM gestaltet den
  # Output entsprechend und erzeugt einen ZUM INHALT passenden Titel/Schlagzeile,
  # NICHT das Gattungswort selbst (z.B. „Zeitungsartikel" → echte Schlagzeile,
  # „Novelle" → echter Novellen-Titel). Nur wenn ein Name gesetzt ist — sonst ""
  # (Default-Spalten unverändert).
  @spec heading_directive(String.t() | nil, String.t()) :: String.t()
  def heading_directive(name, _stage) when is_binary(name) do
    case String.trim(name) do
      "" ->
        ""

      n ->
        "Gestalte diesen Abschnitt als «#{n}» (Textsorte/Gattung): folge ihren Konventionen und " <>
          "beginne mit einer zum INHALT passenden Überschrift bzw. Schlagzeile im Stil dieser " <>
          "Textsorte. Verwende NICHT das Wort «#{n}» selbst als Titel.\n\n"
    end
  end

  def heading_directive(_, _), do: ""

  # Eigener Überschrift-Name dieser Stage aus den Campaign-Vorgaben (nil = default).
  @spec stage_heading(map(), String.t()) :: String.t() | nil
  def stage_heading(campaign, stage) when is_map(campaign) do
    case campaign[:vorgaben] do
      %{^stage => %{name: n}} when is_binary(n) -> n
      _ -> nil
    end
  end

  def stage_heading(_, _), do: nil

  # Sampling-Knöpfe (Issue #11; seit #786 gibt es nur noch den Stage-2-Slot —
  # Extraktion + Render teilen ihn). Liefert eine Keyword-Liste mit
  # temperature/top_p/repeat_penalty; nil-Werte werden vom Backend ignoriert
  # (Worker.LLM.Local.build_options/1). num_predict setzen die Aufrufer selbst
  # (Extraktion: extract_num_predict_cap #763; Render: bewusst ohne).
  def sampling_opts(2) do
    [
      temperature: Worker.Settings.get(:temperature_stage2),
      top_p: Worker.Settings.get(:top_p_stage2),
      repeat_penalty: Worker.Settings.get(:repeat_penalty_stage2)
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

  # Issue #320: Marker für die im Vorschau-Prompt gekürzten Quelldaten.
  @preview_more "[… weiteres Material hier gekürzt — die LLM bekommt den vollständigen Inhalt …]"

  @doc """
  Issue #313/#320: liefert den Prompt als Segment-Liste für die Hub-Vorschau.
  **Byte-genau**: ruft denselben echten Builder auf, den die Pipeline benutzt
  (mit gekürzten Beispiel-Quelldaten), und markiert darin nur die editierbaren
  Werte (Ton `base`/Slot + Überschrift `name`) als `:editable` — alles andere
  bleibt `:locked` und ist wortgleich der echte LLM-Input. Seit #786 gibt es
  nur noch den `"summary"`-Slot (= Fakten-Extraktions-Prompt, der EINE
  Generativschritt); die Render-Prompt-Vorschau kommt mit #787 zurück.
  """
  @spec preview_prompt(String.t(), map()) :: [tuple()]
  def preview_prompt("summary" = stage, campaign) when is_map(campaign) do
    flavors = campaign[:flavors] || %{}

    heading = heading_directive(stage_heading(campaign, stage), stage)
    real = build_facts_extraction_prompt(sample_utterances(campaign), %{}, flavors, heading)

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
end
