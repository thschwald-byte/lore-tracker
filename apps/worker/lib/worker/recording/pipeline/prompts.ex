defmodule Worker.Recording.Pipeline.Prompts do
  @moduledoc """
  Issue #583 (God-Module-Split aus `Worker.Recording.Pipeline`): die Prompt-Bau-
  Schicht — Fakten-Extraktions-Prompt (#651, stilfrei), Render-Prompts
  (Resümee/Epos aus verifizierten Fakten — hier wirken Flavor-/Heading-
  Direktiven, #787), Stil-Vorschau. Reine Bau-Funktionen (Strings); ruft nur
  `Worker.Repo` (Vorschau-Sampling) + stdlib. Die Pipeline-Façade importiert
  dies; Test-erreichbare Publics hält die Façade als defdelegate. Die
  Chain-Prompts (Summary/Epos/Chronik + Map-Reduce-Partials/Retry) sind seit
  #786 entfernt.
  """
  require Logger

  alias Worker.Recording.Pipeline.Parsing
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
  # #787: bewusst OHNE Stil-Preamble/Heading (Chain-Erbe) — Fakten sind stilfrei;
  # der Erzählstil wirkt im Render-Schritt, HINTER dem Verify-Gate (Stil-
  # Anweisungen können dort keine Fakten mehr einschleusen).
  # Issue #976 (Epic #911 Slice 3): `roster` = bekannter Cast dieser Kampagne
  # (PCs + etablierte NPCs, `Repo.character_roster_for/1`) — fürs neue
  # `cast_match`-Enum-Feld im Schema. Kann leer sein (frische Kampagne).
  def build_facts_extraction_prompt(utterances, speaker_names, roster) do
    transcript = render_transcript(utterances, speaker_names)
    cast_section = cast_roster_section(roster)

    """
    Extrahiere aus dem folgenden Spielsitzungs-Transkript die FAKTEN — atomare,
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
    - `cast_match`: STRUKTURIERTE Bestätigung gegen den bekannten Cast dieser
      Kampagne#{cast_section} — passt eine der gelisteten Figuren exakt auf
      `character`? Dann trage GENAU diesen Namen ein (identische Schreibweise
      wie gelistet). Passt KEINE (neue Figur, oder `character` ist leer),
      trage exakt `"#{Parsing.no_cast_match_sentinel()}"` ein.
    - `narration_time`: WANN passiert das Ereignis relativ zur laufenden Szene?
      `"present"` = jetzt, im aktuellen Spielgeschehen (Default, die klare
      Mehrheit). `"flashback"` = eine Figur erzählt/erinnert etwas VERGANGENES
      („Damals, vor dem Krieg …", „Als ich noch jung war …"). `"future"` =
      Prophezeiung/Plan/Vorhersage („In hundert Jahren wird …", „Wir werden
      morgen …"). Trenne die ERZÄHLZEIT (wann wird es gesagt) von der ERZÄHLTEN
      ZEIT (wann geschah es): ein im Kampf erzählter Rückblick ist `"flashback"`,
      nicht `"present"`.
    - `in_game_date`: **schreibe den Zeitausdruck WÖRTLICH AB**, so wie er im
      Transkript steht — nicht umgerechnet, nicht in ein Datumsformat gebracht.
      „in den frühen 2000ern" bleibt `"in den frühen 2000ern"`, NICHT
      `"1.1.2010"`. „von 2055 bis 2065" bleibt `"von 2055 bis 2065"`. „Mitte
      der 2060er" bleibt so stehen. Das Umrechnen macht ein Programm, das den
      Kalender der Kampagne kennt — es kann aus „frühe 2000er" eine Spanne
      machen, aber nicht aus einem erfundenen Tagesdatum die Unschärfe
      zurückholen. Leerer String `""`, wenn kein Zeitausdruck fällt — NICHT
      raten, NICHT Realdatum, NICHT „irgendwann später".

      **Nur WANN etwas geschieht, nicht WIE LANGE es dauert.** In dieses Feld
      gehört der Zeitpunkt oder Zeitraum, an dem das Ereignis stattfindet
      („2070", „in den frühen 2000ern", „am 24. Dezember 2011"). NICHT hinein
      gehören Laufzeiten und Altersangaben, auch wenn sie im selben Satz
      stehen: „ihr seid für die Woche mein Team" ist die Dauer einer
      Abmachung, „Trolle werden 50 Jahre alt" eine Lebensspanne, „zwei Stunden
      online" eine Gültigkeit. Solche Angaben gehören in den `claim`, nicht ins
      Datumsfeld — dort würden sie als Jahreszahl gelesen. Ebenso wenig hinein
      gehören reine Uhrzeiten ohne Tag („am Abend", „um 20 Uhr") und Bezüge auf
      das Jetzt („gestern", „nächste Woche"); für Letztere gibt es
      `time_offset`.
    - `time_offset` (optional): NUR wenn eine RELATIVE zeitliche Distanz zur
      Gegenwart genannt wird („vor 10 Jahren", „in drei Tagen", „letzten Winter").
      Objekt `{"value": <ganzzahl, vorzeichenbehaftet>, "unit": "day"|"week"|
      "month"|"year"}` — Vergangenheit negativ, Zukunft positiv. „vor 10 Jahren"
      → `{"value":-10,"unit":"year"}`. Weglassen, wenn keine Distanz fällt oder
      schon ein `in_game_date` steht. NICHT rechnen, nur die genannte Distanz.
    - `precision` (optional): Genauigkeit des Zeitpunkts — `"day"|"month"|"year"|
      "decade"`. **Weglassen, wenn sie schon aus dem Wortlaut hervorgeht** —
      bei „2070" oder „Mitte der 2060er" liest das Programm sie selbst ab.
      Nur setzen, wenn du mehr weisst als der Wortlaut verrät.
    - `fact_type`: die Art des Fakts — GENAU eine von: `"ereignis"` (etwas
      geschieht — Default, die klare Mehrheit), `"zustandsänderung"` (ein Zustand
      kippt: Verletzung, Tod, Ortswechsel, Gewinn/Verlust), `"beziehung"` (ein
      Bündnis / eine Feindschaft / eine Bindung entsteht oder ändert sich),
      `"absicht"` (eine Figur fasst einen Plan / ein Ziel / nimmt einen Auftrag
      an), `"enthüllung"` (ein Geheimnis / eine Information wird offenbar),
      `"auflösung"` (ein Handlungsstrang wird abgeschlossen / gelöst). Im Zweifel
      `"ereignis"`.
    - `threads`: eine LISTE der Labels der übergreifenden Erzählstränge, zu denen
      der Fakt gehört — je ein KURZES Nominal-Label (2-4 Wörter), aus dem KONKRETEN
      Inhalt DIESER Sitzung abgeleitet: der Auftrag / der Konflikt / das Rätsel /
      die Reise / die Beziehung / die Ermittlung, um die es im Fakt geht. Vergib
      EIN ODER MEHRERE Labels: die MEISTEN Fakten gehören zu genau einem Strang
      (Liste mit einem Label), aber ein Fakt, der zwei Bögen zugleich vorantreibt
      (oder einen Handlungsbogen UND ein zeitloses Weltwissen-Thema berührt),
      bekommt ALLE zutreffenden Labels. Vergib die Labels großzügig, aber
      KONSISTENT: derselbe Strang trägt über ALLE Fakten und Sessions hinweg EXAKT
      dasselbe Label (gleiche Wörter, gleiche Schreibweise, nicht variieren).
      Leere Liste `[]` NUR für ein wirklich isoliertes Weltdetail, das zu keiner
      fortlaufenden Handlung gehört. WICHTIG: die Beispiel-Labels unten stammen aus
      FREMDEN Spielwelten und illustrieren nur das Format — übernimm sie NIEMALS
      wörtlich; die Labels MÜSSEN aus dem WORTLAUT dieses Transkripts stammen, nie
      aus den Beispielen.
    - `source_refs`: die `u…`-Marker der Turns, deren WORTLAUT den Fakt belegt —
      so WENIGE wie möglich, nur die tatsächlich belegenden (meist 1-3; bei einem
      über mehrere Turns verteilten Ereignis die wenigen beteiligten). NICHT
      vorsichtshalber Nachbar-Turns mitzitieren. Zitiere NIEMALS Würfel-, Wert-,
      Regel-, Pausen- oder Meta-Turns als Beleg — auch dann nicht, wenn sie direkt
      neben der belegenden Stelle stehen. Findet sich kein inhaltlich belegender
      Turn, lass den Fakt WEG (lieber kein Fakt als ein falsch geerdeter).

    Beispiele (illustrieren nur das Feld-Ausfüllen, KEINE Vorlage für Inhalte):
    - Ein Strang: `{"claim":"Skrapnik nimmt den Auftrag an","character":"Skrapnik","cast_match":"Skrapnik","narration_time":"present","in_game_date":"","fact_type":"absicht","threads":["der Schmuggel-Auftrag"],"source_refs":["u42"]}`
    - Zwei Stränge zugleich (die Szene treibt beide voran): `{"claim":"Kaira verrät dem Baron den Standort der Rebellen","character":"Kaira","cast_match":"Kaira","narration_time":"present","in_game_date":"","fact_type":"enthüllung","threads":["der Rebellen-Aufstand","Kairas Doppelspiel"],"source_refs":["u48"]}`
    - Kein Strang (isoliertes Weltdetail): `{"claim":"Die Verhandlung findet am 20. März 1888 abends statt","character":"","cast_match":"#{Parsing.no_cast_match_sentinel()}","narration_time":"present","in_game_date":"am 20. März 1888 abends","fact_type":"ereignis","threads":[],"source_refs":["u3"]}`
    - Flashback (Figur erzählt Vergangenes): `{"claim":"Kaira verlor ihren Bruder an die Myzel-Blüte","character":"Kaira","cast_match":"#{Parsing.no_cast_match_sentinel()}","narration_time":"flashback","in_game_date":"","time_offset":{"value":-10,"unit":"year"},"precision":"year","fact_type":"zustandsänderung","threads":["Kairas Vergangenheit"],"source_refs":["u55"]}`
    - Prophezeiung (Zukunft): `{"claim":"Die Seherin sagt den Fall der Stadt voraus","character":"die Seherin","cast_match":"#{Parsing.no_cast_match_sentinel()}","narration_time":"future","in_game_date":"","time_offset":{"value":100,"unit":"year"},"fact_type":"enthüllung","threads":["die Prophezeiung"],"source_refs":["u60"]}`
    - Weltinfo ohne Figur: `{"claim":"Seattle wählt über die Unabhängigkeit ab","character":"","cast_match":"#{Parsing.no_cast_match_sentinel()}","narration_time":"present","in_game_date":"","fact_type":"ereignis","threads":[],"source_refs":["u1"]}`

    Out-of-Game (Würfel, Werte „X gegen Y", „Geschafft"/„Probe", Regelfragen,
    Pausen, Meta) ist KEIN Inhalt: weder als Fakt extrahieren NOCH als source_ref
    zitieren. Ein Würfelausgang („Idee-Probe geschafft") ist kein Fakt — der
    daraus folgende NARRATIVE Inhalt ist es, und der ist in den Erzähl-Turns
    belegt, nicht im Würfel-Turn.

    Transkript:
    #{transcript}

    QUELLTREUE (oberste Regel):
    - Jeder Fakt MUSS aus dem Transkript belegbar sein (via source_refs). Erfinde
      NICHTS, fülle keine Lücken, dichte keine Wendung dazu.
    - Keine Fakten ohne Beleg. Im Zweifel weglassen.
    - Gib NUR Fakten zurück, die das Transkript wörtlich hergibt.
    """
  end

  # Issue #976: Cast-Liste fürs cast_match-Feld — eingebettet in den
  # cast_match-Bullet-Punkt (": <liste>" oder ein Kurzhinweis bei leerem
  # Roster, statt einer sichtbar leeren Liste).
  defp cast_roster_section([]), do: " (noch kein bekannter Cast — nutze immer den Escape-Wert)"
  defp cast_roster_section(roster), do: ": #{Enum.join(roster, ", ")}"

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

  # #787: die Render-Prompts (Resümee R_n + Epos-Kapitel Ep_n aus den
  # VERIFIZIERTEN Fakten). Stil wirkt HIER — hinter dem Verify-Gate: die
  # Flavor-Preamble (base + Slot) und beim Resümee die Überschrift-Direktive
  # können Wortwahl/Ton prägen, aber keine Fakten mehr einschleusen (das
  # Render-Gating re-verifiziert die Prosa gegen das Fakt-Set).
  # Byte-genau dieselben Builder speisen die Stil-Editor-Vorschau
  # (`preview_prompt/2`) — seit #909 gilt das für Flavor/Heading; die
  # Bogen-Struktur sieht die Vorschau nicht (sample_facts strippt die
  # Annotation → flacher Alt-Pfad, benannte Grenze).
  #
  # #909 (Epic #900 S5): tragen die Fakten die Bogen-Annotation
  # (`bogen_titel`/`bogen_kind` aus `Render.annotate_boegen`), rendert der
  # Prompt ARC-STRUKTURIERT — rauschen fliegt immer raus, context fliegt beim
  # Resümee raus (Free-Seattle-Regelwerk-Ursache) und wird beim Epos zur
  # Hintergrund-Sektion (nur Farbe). Ohne Annotation (Vorschau/Eval/
  # Alt-Pfade): der flache Alt-Prompt, unverändert.
  def build_summary_render_prompt(facts, campaign \\ %{}) do
    heading = heading_directive(stage_heading(campaign, "summary"), "summary")
    flavor = flavor_preamble(campaign[:flavors] || %{}, "summary")
    view = bogen_view(facts)

    cond do
      view != nil and (view.arcs != [] or view.weiteres != []) ->
        sections = view.arcs ++ weiteres_section(view.weiteres)

        """
        #{heading}#{flavor}Verdichte die folgenden GESICHERTEN FAKTEN zu einem Sitzungs-Resümee auf
        Deutsch, gegliedert nach Handlungsbögen.

        FORM: Für jeden Bogen unten ein eigener Abschnitt — erste Zeile GENAU die
        fette Bogen-Überschrift wie angegeben (z.B. **Der Auftrag**), darunter 1-2
        Sätze NUR aus den Fakten dieses Bogens. Mische keine Fakten zwischen den
        Bögen. Keine Einleitung, kein Schlusswort, keine eigenen Überschriften.

        STRENG (context-faithful): Verwende AUSSCHLIESSLICH die Fakten unten. Füge
        KEINEN neuen Claim, keine Figur, kein Ereignis hinzu, das nicht in den Fakten
        steht. Keine Deutung, keine Ausschmückung über die Fakten hinaus. Wenn die
        Fakten eines Bogens dünn sind, schreibe weniger.

        Fakten nach Handlungsbögen:
        #{sectioned_facts(sections)}
        """

      true ->
        flat_facts = fallback_facts(view, facts, "summary")

        """
        #{heading}#{flavor}Verdichte die folgenden GESICHERTEN FAKTEN zu einem zusammenhängenden Resümee
        auf Deutsch (3-6 Sätze).

        STRENG (context-faithful): Verwende AUSSCHLIESSLICH die Fakten unten. Füge
        KEINEN neuen Claim, keine Figur, kein Ereignis hinzu, das nicht in den Fakten
        steht. Keine Deutung, keine Ausschmückung über die Fakten hinaus. Wenn die
        Fakten dünn sind, schreibe weniger.

        Fakten:
        #{numbered_facts(flat_facts)}
        """
    end
  end

  # Epos-Kapitel: Flavor ja, Überschrift-Direktive NEIN — der Kapitel-Kopf ist
  # deterministisch (`Render.chapter_header/2`, #752); eine LLM-Überschrift
  # würde doppeln. #909: arc-gruppiert wie das Resümee, aber der Output bleibt
  # EINE fließende Erzählung (keine Zwischenüberschriften — die Bögen sind
  # rote Fäden, nicht Kapitel); context reist als Hintergrund-Sektion mit.
  def build_epos_render_prompt(facts, campaign \\ %{}) do
    flavor = flavor_preamble(campaign[:flavors] || %{}, "epos")
    view = bogen_view(facts)

    cond do
      view != nil and (view.arcs != [] or view.weiteres != []) ->
        sections = view.arcs ++ weiteres_section(view.weiteres)

        hintergrund =
          case view.context do
            [] ->
              ""

            ctx ->
              "\n\nHintergrund/Weltwissen (nur Farbe — NICHT als Ereignisse dieser Sitzung erzählen):\n" <>
                Enum.map_join(ctx, "\n", fn f -> "- #{f["claim"]}" end)
          end

        """
        #{flavor}Erzähle die folgenden GESICHERTEN FAKTEN als zusammenhängende, atmosphärische
        Geschichte auf Deutsch. Die Fakten sind nach Handlungsbögen gruppiert —
        nutze die Bögen als rote Fäden, aber erzähle EINE fließende Geschichte
        ohne Zwischenüberschriften.

        Handlung treu, Erzählweise frei: Das WIE (Stimmung, Schauplätze, Erzählstimme)
        darfst du ausmalen — das WAS ist bindend. Verwende NUR Figuren, Orte,
        Ereignisse und Ausgänge aus den Fakten unten. Erfinde KEINE neuen Plot-Fakten,
        keine zusätzlichen benannten Figuren, keine Wendungen, die nicht in den Fakten
        stehen.

        Fakten nach Handlungsbögen:
        #{sectioned_facts(sections) <> hintergrund}
        """

      true ->
        flat_facts = fallback_facts(view, facts, "epos")

        """
        #{flavor}Erzähle die folgenden GESICHERTEN FAKTEN als zusammenhängende, atmosphärische
        Geschichte auf Deutsch.

        Handlung treu, Erzählweise frei: Das WIE (Stimmung, Schauplätze, Erzählstimme)
        darfst du ausmalen — das WAS ist bindend. Verwende NUR Figuren, Orte,
        Ereignisse und Ausgänge aus den Fakten unten. Erfinde KEINE neuen Plot-Fakten,
        keine zusätzlichen benannten Figuren, keine Wendungen, die nicht in den Fakten
        stehen.

        Fakten:
        #{numbered_facts(flat_facts)}
        """
    end
  end

  # ─── #838: Prosa-Progression (EIN Eintrag pro Bogen × Session) ──────

  @doc """
  Der Prompt für EINEN (Bogen × Session)-Eintrag. `prior_entry == nil` (Fall
  A): kein vorheriger Eintrag existiert — `new_facts` sind entweder die
  Session-Delta-Fakten (Bogen wirklich neu, `arc.opened_in_session ==
  session.number`) ODER die volle Arc-Fakt-Historie (Backfill-Fall, ein
  Bestandsbogen bekommt seinen ersten Eintrag nach dem Feature-Rollout) —
  DIESER Builder kennt den Unterschied nicht, die Entscheidung trifft
  `Render.render_arc_progression/5` VOR dem Aufruf.

  `prior_entry` (Fall B, Fortsetzung): `%{content_md:, flagged_claims:}` des
  unmittelbar vorherigen Eintrags — NUR dieser eine Eintrag, NICHT die
  aufsummierte Chronik (jeder Eintrag steht für sich, Nachlese zeigt sie
  alle chronologisch). Das Modell liefert NUR den NEUEN Absatz zurück, der
  an den bisherigen Stand anschließt — nicht den bisherigen Stand
  wiederholen (sonst würden aufeinanderfolgende Nachlese-Einträge sich
  inhaltlich duplizieren).

  KEIN Leitfrage-Input: die Leitfrage ist oft eine GM-spekulative
  Zukunftsfrage — ihre Anwesenheit im Kontext würde das Modell dazu
  verleiten, sie im Fortsetzungstext implizit zu "beantworten" (Content-
  Kontaminations-Risiko, s. #838-Plan Design F). Der `canonical`-Titel
  (Daten-Label) bleibt legitim.
  """
  @spec build_arc_progression_prompt(String.t(), map() | nil, [map()], map()) :: String.t()
  def build_arc_progression_prompt(canonical, prior_entry, new_facts, campaign \\ %{})

  def build_arc_progression_prompt(canonical, nil, new_facts, campaign) do
    flavor = flavor_preamble(campaign[:flavors] || %{}, "summary")

    """
    #{flavor}Bogen: #{canonical}

    Schreibe den BEGINN der Verlaufs-Prosa für diesen Handlungsbogen — was ist
    bisher passiert, wo steht er? NUR aus den folgenden GESICHERTEN FAKTEN,
    2-4 Sätze, zusammenhängender Fließtext auf Deutsch.

    STRENG (context-faithful): Verwende AUSSCHLIESSLICH die Fakten unten. Füge
    KEINEN neuen Claim, keine Figur, kein Ereignis hinzu, das nicht in den
    Fakten steht. Keine Spekulation über den weiteren Verlauf.

    Fakten:
    #{numbered_facts(new_facts)}
    """
  end

  def build_arc_progression_prompt(canonical, prior_entry, new_facts, campaign) do
    flavor = flavor_preamble(campaign[:flavors] || %{}, "summary")
    prior_md = mark_flagged(prior_entry.content_md, prior_entry.flagged_claims)

    """
    #{flavor}Bogen: #{canonical}

    Bisheriger Stand dieses Handlungsbogens (letzter Eintrag):
    \"\"\"
    #{prior_md}
    \"\"\"

    Schreibe diesen Stand FORT — führe ihn mit den folgenden NEUEN GESICHERTEN
    FAKTEN dieser Sitzung weiter. Gib NUR den neuen Absatz zurück, der an den
    bisherigen Stand anschließt (2-4 Sätze) — wiederhole NICHT den bisherigen
    Stand, er wird bereits separat angezeigt.

    Widersprich früheren, bereits etablierten Aussagen NICHT — außer die neuen
    Fakten widersprechen ihnen explizit. Mit [unbelegt] markierte Aussagen aus
    dem bisherigen Stand sind nicht belegt — beziehe dich nicht bestätigend
    darauf.

    STRENG (context-faithful): Verwende AUSSCHLIESSLICH die neuen Fakten unten
    (der bisherige Stand ist nur Kontinuitäts-Kontext, keine Fakten-Quelle).
    Füge KEINEN neuen Claim hinzu, der nicht in den Fakten steht. Keine
    Spekulation über den weiteren Verlauf.

    Neue Fakten dieser Sitzung:
    #{numbered_facts(new_facts)}
    """
  end

  defp mark_flagged(content_md, flagged_claims)
       when is_list(flagged_claims) and flagged_claims != [] do
    Enum.reduce(flagged_claims, content_md, fn claim, acc ->
      String.replace(acc, claim, "[unbelegt] " <> claim)
    end)
  end

  defp mark_flagged(content_md, _flagged_claims), do: content_md

  # ─── #909: Bogen-Sicht der annotierten Fakten ────────────────────────

  # nil = keine Annotation (Vorschau/Eval/Alt-Pfade) → flacher Alt-Prompt.
  defp bogen_view(facts) do
    if Enum.any?(facts, &Map.has_key?(&1, "bogen_kind")), do: bogen_groups(facts), else: nil
  end

  # Fallback-Kaskade bei leeren Bogen-Gruppen (kein {:error,…} — der würde in
  # der Pipeline Timeline+Epos mitreißen): reine Welt-Expositions-Session →
  # context-Fakten flach (ehrlich); wirklich alles rauschen → Voll-Liste als
  # letzte Rettung, geloggt (verletzt die Filter-Entscheidung bewusst, statt
  # ein leeres Resümee zu erfinden).
  defp fallback_facts(nil, facts, _stage), do: facts

  defp fallback_facts(view, facts, stage) do
    cond do
      view.context != [] ->
        view.context

      true ->
        Logger.warning(
          "Render[#{stage}]: Session-Fakten sind ausschließlich rauschen — flacher Voll-Fallback"
        )

        facts
    end
  end

  defp weiteres_section([]), do: []
  defp weiteres_section(weiteres), do: [{"Weiteres", weiteres}]

  # Gruppiert annotierte Fakten: arcs = [{titel, [fakten]}] in Erzähl-
  # Chronologie (Position des ersten Bogen-Fakts, Tie-Break Titel — EIN Code
  # für Stage 4+5); Ein-Fakt-„Bögen" wandern unter „Weiteres" (Anti-
  # Fragmentierungs-Deckel: Alt-Kampagnen ohne Registry hätten sonst pro
  # Roh-Label einen Abschnitt — Listen-Karikatur statt Recap).
  defp bogen_groups(facts) do
    indexed = Enum.with_index(facts)

    {rauschen, rest} = Enum.split_with(indexed, fn {f, _} -> f["bogen_kind"] == "rauschen" end)
    {context, rest} = Enum.split_with(rest, fn {f, _} -> f["bogen_kind"] == "context" end)

    {arcish, strandlos} =
      Enum.split_with(rest, fn {f, _} ->
        f["bogen_kind"] == "arc" and is_binary(f["bogen_titel"]) and f["bogen_titel"] != ""
      end)

    groups =
      arcish
      |> Enum.group_by(fn {f, _} -> f["bogen_titel"] end)
      |> Enum.map(fn {titel, fs} -> {titel, Enum.sort_by(fs, &elem(&1, 1))} end)

    {multi, single} = Enum.split_with(groups, fn {_t, fs} -> length(fs) >= 2 end)

    weiteres =
      (strandlos ++ Enum.flat_map(single, fn {_t, fs} -> fs end))
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    arcs =
      multi
      |> Enum.sort_by(fn {titel, fs} -> {fs |> hd() |> elem(1), titel} end)
      |> Enum.map(fn {titel, fs} -> {titel, Enum.map(fs, &elem(&1, 0))} end)

    %{
      arcs: arcs,
      weiteres: weiteres,
      context: context |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)),
      rauschen_count: length(rauschen)
    }
  end

  # Sektionen mit DURCHLAUFENDER Nummerierung (Zeilenformat identisch zur
  # flachen Liste — die Nummern sind prompt-lokal).
  defp sectioned_facts(sections) do
    {blocks, _next} =
      Enum.reduce(sections, {[], 1}, fn {titel, fs}, {acc, i} ->
        lines = fs |> Enum.with_index(i) |> Enum.map_join("\n", fn {f, j} -> fact_line(f, j) end)
        {["**#{titel}**\n" <> lines | acc], i + length(fs)}
      end)

    blocks |> Enum.reverse() |> Enum.join("\n\n")
  end

  defp numbered_facts(facts) do
    facts
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {f, i} -> fact_line(f, i) end)
  end

  defp fact_line(f, i) do
    who =
      case Map.get(f, "character_alias") do
        a when is_binary(a) and a != "" -> "[#{a}] "
        _ -> ""
      end

    "#{i}. #{who}#{f["claim"]}"
  end

  # Issue #313: campaign-gesetzter Ton gewinnt; sonst greift der Default-Ton
  # des Slots. (Kein Slot hat aktuell einen Default — der frühere Epos-
  # Default-Flavor fiel mit den Chain-Prompts, #786; der Epos-Render-Prompt
  # trägt seinen Grundton selbst.)
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

  # Sampling-Knöpfe (Issue #11; seit #783 Phase 2 pro Stage — Extraktion/
  # Verify/Render-Resümee/Render-Epos haben je eigene Werte). Liefert eine
  # Keyword-Liste mit
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

  def sampling_opts(3) do
    [
      temperature: Worker.Settings.get(:temperature_stage3),
      top_p: Worker.Settings.get(:top_p_stage3),
      repeat_penalty: Worker.Settings.get(:repeat_penalty_stage3)
    ]
  end

  def sampling_opts(4) do
    [
      temperature: Worker.Settings.get(:temperature_stage4),
      top_p: Worker.Settings.get(:top_p_stage4),
      repeat_penalty: Worker.Settings.get(:repeat_penalty_stage4)
    ]
  end

  def sampling_opts(5) do
    [
      temperature: Worker.Settings.get(:temperature_stage5),
      top_p: Worker.Settings.get(:top_p_stage5),
      repeat_penalty: Worker.Settings.get(:repeat_penalty_stage5)
    ]
  end

  # #755 Reopen: optionale Output-Notbremse pro Stage (num_predict_stage{n},
  # nil-Default = aus = bisheriges Verhalten „terminiert selbst"). Getrennt
  # von sampling_opts/1, weil ungesetzt KEIN Key erscheinen soll (Aufrufer
  # wie das frühere render_opts assert(et)en die Key-Abwesenheit; Cloud-
  # Backends fallen bei fehlendem Key auf ihren max_tokens-Default). Für
  # Reasoning-Modelle relevant: deren Denk-Tokens zählen mit gegen das
  # Budget — ohne Deckel frisst ein degenerierter Judge-/Render-Call den
  # vollen http_timeout (#763-Klasse). Stage 2 hat seinen eigenen Deckel
  # (extract_num_predict_cap, immer aktiv) — hier nur 3/4/5.
  def num_predict_opt(n) when n in 3..5 do
    case Worker.Settings.get(:"num_predict_stage#{n}") do
      nil -> []
      cap when is_integer(cap) and cap > 0 -> [num_predict: cap]
      _ -> []
    end
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
  bleibt `:locked` und ist wortgleich der echte LLM-Input. Seit #787 zeigen
  die Slots die **Render-Prompts** (Resümee/Epos aus verifizierten Fakten —
  dort wirkt der Stil); die Extraktion ist stilfrei und hat keine Vorschau.
  Beispiel-Fakten kommen aus der ersten Session der Kampagne (verifizierte
  bevorzugt), gekürzt + mit Kürzungs-Marker.
  """
  @spec preview_prompt(String.t(), map()) :: [tuple()]
  def preview_prompt(stage, campaign) when stage in ["summary", "epos"] and is_map(campaign) do
    flavors = campaign[:flavors] || %{}

    real =
      case stage do
        "summary" -> build_summary_render_prompt(sample_facts(campaign), campaign)
        "epos" -> build_epos_render_prompt(sample_facts(campaign), campaign)
      end

    # Editierbare Werte (so wie sie im echten Prompt stehen = getrimmt).
    # `name` nur beim Resümee — der Epos-Prompt trägt keine Überschrift-
    # Direktive (deterministischer Kapitel-Kopf, #752).
    name_values =
      if stage == "summary", do: [{"name", stage_heading(campaign, stage)}], else: []

    values =
      (name_values ++
         [
           {"base", effective_flavor(flavors, "base")},
           {stage, effective_flavor(flavors, stage)}
         ])
      |> Enum.map(fn {slot, v} -> {slot, String.trim(to_string(v || ""))} end)
      |> Enum.reject(fn {_slot, v} -> v == "" end)

    tokenize_editables(real, values)
  end

  # #787: Beispiel-Fakten für die Render-Prompt-Vorschau — analog dem früheren
  # sample_utterances: erste Session, verifizierte Fakten bevorzugt (das ist
  # der echte Render-Input), sonst alle; 3 Stück, Claims gekürzt.
  defp sample_facts(campaign) do
    base =
      with cid when is_binary(cid) <- campaign[:id],
           [session | _] <- Repo.list_sessions(cid),
           %{facts: [_ | _] = facts} <- Repo.get_session_facts(session.id) do
        verified = Enum.filter(facts, &(Map.get(&1, "verified?") == true))

        if(verified == [], do: facts, else: verified)
        |> Enum.take(3)
        |> Enum.map(fn f ->
          %{
            "claim" => String.slice(to_string(f["claim"] || ""), 0, 120),
            "character_alias" => f["character_alias"]
          }
        end)
      else
        _ -> []
      end

    base ++ [%{"claim" => @preview_more, "character_alias" => nil}]
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
