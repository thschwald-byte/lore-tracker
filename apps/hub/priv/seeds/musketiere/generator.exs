# Generator für die „Drei-Musketiere"-Demo-Seeds (Issue #423).
#
# Schreibt JSONL-Files in `apps/hub/priv/seeds/musketiere/`:
#   01_setup.jsonl
#   02_session1.jsonl
#   03_session2.jsonl
#   04_session3.jsonl
#   05_session4.jsonl
#
# Aufruf vom Repo-Root:
#   elixir apps/hub/priv/seeds/musketiere/generator.exs
#
# Quelle gemeinfrei: Alexandre Dumas, Les trois mousquetaires (1844). Dumas
# † 1870, global PD seit 1940. Dialoge in den s*_beats.exs sind eigene
# deutschsprachige D&D-Tisch-Kompositionen, lose orientiert an PD-Plot-Beats.
#
# Deterministisch — gleicher Generator-Code → identische JSONLs.

Code.require_file(Path.join(__DIR__, "s1_beats.exs"))
Code.require_file(Path.join(__DIR__, "s2_beats.exs"))
Code.require_file(Path.join(__DIR__, "s3_beats.exs"))
Code.require_file(Path.join(__DIR__, "s4_beats.exs"))

defmodule MusketiereGenerator do
  @out_dir Path.expand(Path.dirname(__ENV__.file))
  @campaign_id "drei-musketiere-demo"
  @sl_did "200000000000000001"

  @players [
    {"200000000000000002", "D'Artagnan-Spieler", "D'Artagnan"},
    {"200000000000000003", "Athos-Spieler", "Athos"},
    {"200000000000000004", "Porthos-Spieler", "Porthos"},
    {"200000000000000005", "Aramis-Spieler", "Aramis"}
  ]

  # Alle 4 PCs sind in allen 4 Sessions aktiv.
  @session_cast %{
    1 => ["D'Artagnan", "Athos", "Porthos", "Aramis"],
    2 => ["D'Artagnan", "Athos", "Porthos", "Aramis"],
    3 => ["D'Artagnan", "Athos", "Porthos", "Aramis"],
    4 => ["D'Artagnan", "Athos", "Porthos", "Aramis"]
  }

  # ─── Banter-Pools pro Charakter ──────────────────────────────────────

  @dartagnan_pool [
    "Gascogne — die Heimat des Stolzes und der dünnen Suppen.",
    "Mein Vater sagte: 'Verteidige deine Ehre, mein Sohn. Mit Worten und mit der Klinge.' Ich glaube, ich nehme die Klinge zuerst.",
    "Ich werfe Geschicklichkeit. Mit Vorteil. Erster Wurf: zwanzig. Zweiter: einundzwanzig. Ich nehme einundzwanzig.",
    "Wenn niemand mit mir reden will, mache ich Bekanntschaften per Degenstoß.",
    "Ich bin neunzehn. Manche sagen, das sei zu jung für die Garde. Ich sage, mein Schwert sei alt genug.",
    "Cardinal-Wachen. Schon wieder. Sie scheinen einen Fanclub auf mich zu betreiben.",
    "Ich liebe Constance. Sage ich das zu oft? Athos sagt, ich sage es zu oft.",
    "Sleight-of-Hand. Mit Vorteil — Gascogne-Erbgut.",
    "Meine Mutter sagte: 'Wenn du in Paris bist, vergiss deine Sporen nicht.' Ich habe sie vergessen.",
    "Macht ist, eine Klinge halten zu können, ohne sich am Heft zu verschneiden.",
    "Ein Pferd, ein Schwert, ein Brief — mehr braucht ein Gascogner nicht.",
    "Mein gelbes Pferd ist gestorben. Es war ein gutes Pferd. Ein sehr gelbes Pferd.",
    "Athos, was meinst du? Soll ich es wagen?",
    "Porthos, dein Wert ist nicht in der Stimme — sondern im Treffer.",
    "Aramis, du redest wie ein Priester. Schlägst aber wie ein Soldat.",
    "Wenn die Königin ruft, gehe ich. Ohne Frage.",
    "Ich gebe nicht auf. Niemals. Nicht für Cardinal, nicht für Tod.",
    "Insight auf den Cardinal. Erste Wurf: dreizehn. Er lügt. Wie immer.",
    "Vier gegen vierzig — das sind die Quoten, die wir mögen.",
    "Ich werfe Performance — Tanz mit einer Hofdame. Vierzehn. Achtbar.",
    "Mein Brief von Vater wurde gestohlen. Ich will den Dieb finden.",
    "Rochefort. Der Mann aus Meung. Ich erkenne ihn überall.",
    "Wenn ich Lieutenant der Musketiere werde, baue ich das Hauptquartier um. Mehr Fenster.",
    "Reisen ist ein Sport für die Jungen. Ich bin ein Sportsmann.",
    "Vor zwei Wochen war ich Bauernbursche. Heute bin ich Held der Königin. Was wird morgen?",
    "Initiative — sechzehn. Ich gehe zuerst.",
    "Beim heiligen Antoine, Aramis, du würdest sogar deine Klinge segnen.",
    "Mein erstes Duell in Paris. Aufregend. Sehr aufregend. Und sehr blutig — meine Seite.",
    "Wenn ich Hugenotten retten muss, rette ich. Wenn ich Katholiken retten muss, rette ich auch."
  ]

  @athos_pool [
    "Wein. Mehr Wein.",
    "Ich werde nicht trinken bis ich vergesse. Ich werde trinken bis ich mich erinnere.",
    "Ich werfe Insight. Mit Vorteil. Dreiundzwanzig. Sie lügt — was nicht überrascht.",
    "Wenn ich erzähle, was ich gesehen habe in meinen jüngeren Jahren, würdet ihr nicht schlafen können.",
    "D'Artagnan, du redest zu viel. Schweige, lerne.",
    "Mein Wappen liegt in einem Truhe in der Provinz Berry. Ich rede nicht darüber.",
    "Macht ist nicht Lärm. Macht ist Schweigen mit einer Klinge in der Hand.",
    "Porthos, deine Eitelkeit wird dich eines Tages töten. Aber elegant.",
    "Aramis, du wirst Bischof. Das prophezeie ich dir. Mit oder ohne deinen Willen.",
    "Persuasion. Achtzehn. Aber ich muss es nicht oft tun. Schweigen überzeugt mehr.",
    "Wenn ich euch sage 'kämpft', kämpft. Wenn ich euch sage 'schweigt', schweigt.",
    "Erinnert mich nicht an meine Vergangenheit. Ich erinnere mich selber, jeden Tag.",
    "Athletik. Sechzehn. Standard.",
    "Meine Vorfahren haben ein Schloss in der Provinz Berry. Niemand erinnert sich daran. Sehr gut so.",
    "Eine Frau? Ich habe einmal eine Frau gehabt. Sie war eine Schlange.",
    "Reckless Attack. Aber nur, wenn ich es nicht anders kann.",
    "Mit dem Schwert: ich gehöre zu den besten Frankreichs. Ohne das Schwert: ich bin nichts.",
    "Wenn ihr eine Probe braucht, frage ich nach Wein zuerst. Inspiration kommt aus der Flasche.",
    "Cardinal Richelieu. Ein Mann, dem ich nie traue, aber dem ich oft begegne.",
    "Vor Tréville verbeuge ich mich. Vor dem Cardinal nicht.",
    "Meine erste Frau war Anne de Bueil. Sie ist tot — oder war es. Genau weiß ich nicht mehr.",
    "Ich nehme die Last. Die anderen kümmern sich um die Action.",
    "Wenn ich vier Worte sage, ist das eine lange Rede. Vier Worte: 'Wir gehen. Wir kämpfen.'",
    "Aramis, dein Schwur als Priester schließt das Trinken nicht aus, oder?",
    "Insight. Wieder. Ich vertraue NIEMANDEM in Paris vollständig.",
    "Die Vergangenheit ist ein Schatten, der mit meinem Schritt fällt.",
    "Meine Reise endet nicht hier. Sie endet auf dem Schlachtfeld oder am Galgen.",
    "Vierzig Hugenotten, vier Musketiere. Vorteil ihnen — sie haben kein Glück.",
    "Wein für die Reise. Wein für die Rast. Wein für die Trauer.",
    "Athos ist nicht mein Geburtsname. Athos ist mein Schweigen."
  ]

  @porthos_pool [
    "Wenn ich aufstehe, hört man's. Wenn ich falle, hört man's noch lauter.",
    "Mein Wams. Hat es gefallen?",
    "Diese Goldspange habe ich aus Picardie. Vom Onkel. Er ist tot. Er war reich.",
    "Athletik. Mit Vorteil — Reckless Attack. Zweiundzwanzig.",
    "Wenn ich die Klinge schwinge, schwingt der Boden mit.",
    "Mein Schwert ist Spanisch. Vom Großvater. Lege es nie nieder.",
    "D'Artagnan, du bist klein, aber schnell. Ich bin groß und langsam. Wir balancieren uns.",
    "Athos, dein Schweigen ist die längste Rede, die ich kenne.",
    "Aramis, dein Latein ist beeindruckend. Mein Schwert ist eindringender.",
    "Eine Lady? Ich habe drei Ladies. Drei verschiedene.",
    "Mein Hut. Habt ihr meinen Hut gesehen? Der mit der Feder?",
    "Wenn die Königin mich erwählt, sterbe ich gerne für sie. Wenn die Königin mich nicht erwählt, sterbe ich immer noch.",
    "Reckless Attack — Vorteil — erster Wurf: dreiundzwanzig. Zweiter: zwanzig. Ich nehme dreiundzwanzig.",
    "Wenn ich kein Frühstück hatte, bin ich gefährlich. Wenn ich Frühstück hatte, bin ich noch gefährlicher.",
    "Mein Lieblingsgetränk: gemischter Wein mit Gewürzen. Aramis, kennst du die Mischung?",
    "Diamant — ein schöner Stein. Ich hätte gerne mehr davon.",
    "Wenn der Cardinal kommt, vergesse ich mein Latein. Dann wechsele ich zu meinem Schwert.",
    "Eine Lady mit einer Brosche an der Schulter — das ist mein Wunschtraum.",
    "Tréville ist ein guter Capitain. Streng aber fair. Wie ein Vater. Aber lauter.",
    "Insight? Was ist Insight? Ich sehe ja, oder ich sehe nicht.",
    "Wein. Brot. Käse. Ein Wams. Ein Schwert. Was braucht ein Mann mehr?",
    "Ich werfe Stärke gegen die Tür. Zweiundzwanzig. Die Tür fällt.",
    "Constanc, die Kuriere-Frau, ist nett. D'Artagnan ist verloren.",
    "Mein Bruder war Soldat. Er ist gefallen. Ich kämpfe für seine Erinnerung.",
    "Wenn ihr einen Wagen umstürzen wollt, fragt mich. Ich kann.",
    "Wenn ihr ein Tor zerstören wollt, fragt mich. Ich kann.",
    "Wenn ihr Diplomatie braucht, fragt Aramis. Ich kann nicht.",
    "Mein Gesicht ist mein Glücksbringer. Ich glaube das wirklich."
  ]

  @aramis_pool [
    "Sicut dixit dominus. Wie der Herr sagte.",
    "Ich werde Bischof. Nächstes Jahr. Übernächstes Jahr. Spätestens.",
    "Ich werfe Religion. Mit Vorteil — Klerikersbildung. Zweiundzwanzig.",
    "Lateinkenntnis: notwendig. Schwertkenntnis: leider auch notwendig.",
    "Mein Mantel ist neu — habt ihr es bemerkt?",
    "Eine Dame namens Marie hat mir das Mantel gegeben. Sie ist… eine Wohltäterin.",
    "D'Artagnan, dein Eifer ist beeindruckend. Aber jugendlich.",
    "Athos, dein Schweigen ist priesterlich. Du hättest mein Lehrer sein können.",
    "Porthos, dein Lärm ist… weltlich. Aber unentbehrlich.",
    "War-Cleric-Aktion: Spiritual Weapon. Schaden 1d8 + Wisdom. Sieben Schaden.",
    "Wenn ich einen Zauber wirken muss, frage ich erst, ob es nötig ist. Meistens ist es.",
    "Mein Glaube ist stark. Meine Klinge ist stärker. Beide sind nötig.",
    "Wenn der Cardinal Bischof ist und Soldat, warum sollte ein Musketier nicht beides sein?",
    "Persuasion mit Vorteil. Einundzwanzig.",
    "Eine Dame brachte mir ein Taschentuch in die Tréville-Kanzlei. Ich war verwirrt.",
    "Macht der Predigt: nicht zu unterschätzen.",
    "Acolyte-Hintergrund. Ich kenne die Liturgien aller großen Klöster Frankreichs.",
    "Wenn ich heirate, wird's eine Witwe. Aus Pragmatismus.",
    "Heilung — Healing Word — vier Hitpoints für D'Artagnan.",
    "Cure Wounds — acht Hitpoints für Porthos.",
    "Ich bete für unsere Sache. Ich bete für unsere Klingen. Ich bete für unsere Pferde.",
    "Wenn die Königin nicht katholisch wäre, wäre ich vielleicht weniger loyal. Aber sie ist es.",
    "Initiative: vierzehn. Standard.",
    "Mein Sermon-Skript für Sonntag liegt im Kloster. Es ist sehr fortgeschritten.",
    "Wenn ihr einen Brief auf Latein verfasst haben wollt, frage ich keine Bezahlung.",
    "Wenn ihr ein Schloss aufschließen wollt, frage Aramis nicht. Sleight-of-Hand: acht.",
    "Mein Vorbild ist nicht ein Heiliger. Mein Vorbild ist Bischof Richelieu — der Soldat und Kleriker zugleich.",
    "Beim heiligen Augustinus, lasst mich überlegen."
  ]

  @dice_fillers [
    "Wahrnehmung. {n}.",
    "Untersuchen. {n}.",
    "Geschichte? {n}.",
    "Akrobatik. {n}.",
    "Heimlichkeit. {n}.",
    "Athletik. {n}.",
    "Persuasion. {n}.",
    "Einschüchtern. {n}.",
    "Insight. {n}.",
    "Natur. {n}.",
    "Religion. {n}.",
    "Initiative — {n}.",
    "Geschicklichkeits-Save. {n}.",
    "Konstitutions-Save. {n}.",
    "Weisheits-Save. {n}.",
    "Charisma-Save. {n}.",
    "Performance — {n}."
  ]

  @ooc_fillers [
    "Moment — kann ich kurz aufs Klo?",
    "Wer hat den Nachschub Cola besorgt?",
    "Habe ich noch Inspiration?",
    "Du hast letzte Woche genau das Gegenteil gesagt.",
    "Kann jemand das Handout nochmal vorlesen?",
    "Bonusaktion oder Aktion?",
    "Reaktion ist noch frei, oder?",
    "Wo ist mein Charakterbogen?",
    "Mein Würfel ist verflucht. Ich brauch einen neuen.",
    "Schreibst du das mit?",
    "Soll ich jetzt aktivieren? Oder warten?",
    "Konzentration halte ich noch?",
    "Bewegung — 30 Fuß, oder?",
    "Vorteil oder Nachteil hier?",
    "Können wir kurz Pause machen?",
    "Hat jemand Chips?",
    "Wer hat die Karte?",
    "Karte bitte!",
    "Ich brauche eine fünfminütige Pause für meine Notizen."
  ]

  defp sl_filler, do: [
    "Ihr hört in der Ferne ein Geräusch — Hufschlag.",
    "Der Wind hat sich gedreht. Aus dem Süden zieht eine Schar Krähen.",
    "Ein Diener verbeugt sich und entzieht sich der Audienz.",
    "Macht eine Wahrnehmungsprobe.",
    "Die Sonne sinkt über die Stadtmauer. Lange Schatten fallen.",
    "Ihr hört Schritte im Korridor — schnell, militärisch.",
    "Auf der Karte: dieser Bereich ist noch unerkundet.",
    "Beschreibt mir, was eure Charaktere tun.",
    "Wirft jemand Insight?",
    "Die Tür ist verschlossen — Eisenkette, gutes Schloss.",
    "Wer geht voran?",
    "Initiative bitte.",
    "Reaktion, jemand?",
    "Habt ihr Vorbereitungen getroffen, oder geht ihr blind rein?",
    "Macht weiter — was wollt ihr tun?",
    "Die Luft wird kälter.",
    "Eine Fackel an der Wand flackert.",
    "Auf dem Boden: Spuren, halb verwischt.",
    "Macht eine Geschichts-Probe. — Nein? Niemand?",
    "Lange Rast oder kurze Rast?",
    "Wer übernimmt die zweite Wache?",
    "Ihr erinnert euch an einen Vers aus einem alten Lied.",
    "Eine Krähe sitzt auf einem Ast und beobachtet euch.",
    "Sturm zieht auf. Wolken verdunkeln den Himmel.",
    "Macht alle eine Konstitutionsprobe.",
    "Es ist nicht klar, ob das, was ihr seht, eine Falle ist.",
    "Eine Stimme — französisch, leise, kühl.",
    "Ein leises Lachen — frauen-stimmig, aus dem Nebenzimmer.",
    "Würfle für mich Schaden — zweimal, mit Vorteil.",
    "Eine Kutsche fährt vorbei — schwarze Pferde, kein Wappen.",
    "Der Wirt schaut weg. Er hat etwas gesehen, das er nicht erwähnen will.",
    "Glocken aus der Notre-Dame schlagen viertel vor zehn.",
    "Auf dem Tisch: ein Briefumschlag, ohne Adresse, mit dem Siegel des Cardinals.",
    "Ein Bediensteter erscheint und nickt euch zu — Constance schickt eine Nachricht.",
    "Die Königin Anne lächelt — knapp, formal — und reicht euch die Hand.",
    "Tréville räuspert sich. Er hat eine Ankündigung.",
    "Rochefort steht vor euch — die Narbe an seiner Schläfe ist nicht zu übersehen."
  ]

  # ─── Setup-File ──────────────────────────────────────────────────────

  def setup_events do
    invites =
      Enum.flat_map(@players, fn {did, display, char} ->
        token = "musk-invite-#{String.slice(did, -3, 3)}"

        [
          %{
            "kind" => "UserUpserted",
            "discord_id" => did,
            "display_name" => display,
            "avatar_url" => nil
          },
          %{
            "kind" => "InviteCreated",
            "campaign_id" => @campaign_id,
            "token" => token,
            "created_by_discord_id" => @sl_did,
            "expires_at" => "2099-12-31T23:59:59Z"
          },
          %{
            "kind" => "InviteRedeemed",
            "token" => token,
            "discord_id" => did,
            "display_name" => display
          },
          %{
            "kind" => "CampaignAliasSet",
            "campaign_id" => @campaign_id,
            "discord_id" => did,
            "character_name" => char
          }
        ]
      end)

    [
      %{
        "kind" => "CampaignCreated",
        "id" => @campaign_id,
        "name" => "Die drei Musketiere",
        "owner_discord_id" => @sl_did,
        "owner_display_name" => "Erzähler",
        "theme_blurb" =>
          "D&D-Tisch-Kampagne lose nach Alexandre Dumas, 'Les trois mousquetaires' (1844, gemeinfrei). 4 PCs: D'Artagnan (Rogue/Swashbuckler), Athos (Fighter/Champion), Porthos (Barbarian/Berserker), Aramis (Cleric/War). Alle NPCs (Tréville, Königin Anne, Cardinal Richelieu, Milady de Winter, Rochefort, Constance, Buckingham etc.) werden vom SL gespielt. Frankreich 1625-1628, Mantel und Degen, Königin-Anhänger-Affäre, La Rochelle, Lys-Finale.",
        "icon_url" =>
          "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Trois_mousquetaires.jpg/640px-Trois_mousquetaires.jpg"
      },
      %{
        "kind" => "UserUpserted",
        "discord_id" => @sl_did,
        "display_name" => "Erzähler",
        "avatar_url" => nil
      },
      %{
        "kind" => "UserRoleSet",
        "discord_id" => @sl_did,
        "role" => "admin",
        "set_by" => "cli:lore.seed.musketiere"
      }
    ] ++
      invites ++
      [
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "summary",
          "voice" =>
            "D&D-Tisch-Session-Protokoll. SL und Spieler getrennt, OOC-Banter gehört zum Protokoll. Pro Session ein Absatz, knapp."
        },
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "epos",
          "voice" =>
            "Heroisch-galant, im Stil eines Schwarz-Weiß-Mantel-und-Degen-Romans. Reim wenn passend."
        },
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "chronik",
          "voice" =>
            "In-Game-Tagebuch im Präsens. Tag-Zähler beginnt mit Tag 1 (Meung-Encounter)."
        }
      ]
  end

  # ─── Session-Beat-Daten ─────────────────────────────────────────────

  def session_beats(1), do: MusketiereGenerator.S1.beats()
  def session_beats(2), do: MusketiereGenerator.S2.beats()
  def session_beats(3), do: MusketiereGenerator.S3.beats()
  def session_beats(4), do: MusketiereGenerator.S4.beats()

  # ─── Generator ──────────────────────────────────────────────────────

  def run do
    File.mkdir_p!(@out_dir)

    write!("01_setup.jsonl", setup_events())

    write_session!(2, 1, ~U[2026-04-12 19:00:00Z], "D'Artagnans Reise + Triple-Duell")
    write_session!(3, 2, ~U[2026-04-19 19:00:00Z], "Anhänger der Königin")
    write_session!(4, 3, ~U[2026-04-26 19:00:00Z], "Milady + La Rochelle")
    write_session!(5, 4, ~U[2026-05-03 19:00:00Z], "Lys-Finale")

    IO.puts("Done.")
  end

  defp write!(filename, events) do
    path = Path.join(@out_dir, filename)

    body =
      events
      |> Enum.map_join("", fn ev -> IO.iodata_to_binary(:json.encode(ev)) <> "\n" end)

    File.write!(path, body)
    word_count = events |> Enum.map(&Map.get(&1, "text", "")) |> Enum.join(" ") |> count_words()

    IO.puts(
      "wrote #{filename}: #{length(events)} events" <>
        if(word_count > 0, do: " (#{word_count} Wörter Text)", else: "")
    )
  end

  defp write_session!(file_n, session_n, started_at, session_name) do
    session_id = "session-musk-#{session_n}"
    cast = @session_cast[session_n]
    beats = session_beats(session_n)

    :rand.seed(:exsss, {session_n, 1844, 1625})

    scheduled =
      %{
        "kind" => "SessionScheduled",
        "id" => session_id,
        "campaign_id" => @campaign_id,
        "name" => "Session #{session_n} — #{session_name}",
        "number" => session_n,
        "scheduled_for" => DateTime.to_iso8601(started_at)
      }

    started =
      %{
        "kind" => "SessionStarted",
        "id" => session_id,
        "started_at" => DateTime.to_iso8601(DateTime.add(started_at, 60, :second)),
        "started_by_discord_id" => @sl_did
      }

    {utterances, _} =
      beats
      |> Enum.with_index()
      |> Enum.flat_map_reduce(0, fn {beat, idx}, counter ->
        beat_lines = expand_beat(beat, cast)
        {tagged, new_counter} = number_lines(beat_lines, counter)
        between = inter_beat_filler(idx, length(beats) - 1, cast)
        {tagged_between, final_counter} = number_lines(between, new_counter)
        {tagged ++ tagged_between, final_counter}
      end)

    ended_at = DateTime.add(started_at, 4 * 3600 + 30 * 60, :second)
    utt_events = utterances_to_events(utterances, session_id, started_at, ended_at)

    ended =
      %{
        "kind" => "SessionEnded",
        "id" => session_id,
        "ended_at" => DateTime.to_iso8601(ended_at),
        "ended_by_discord_id" => @sl_did
      }

    events = [scheduled, started] ++ utt_events ++ [ended]
    write!("0#{file_n}_session#{session_n}.jsonl", events)
  end

  defp number_lines(lines, counter) do
    lines
    |> Enum.with_index(counter + 1)
    |> Enum.map(fn {line, n} -> {n, line} end)
    |> then(fn out -> {out, counter + length(lines)} end)
  end

  defp expand_beat(%{dm: dm, core: core} = beat, cast) do
    head = [{"SL", dm}]
    body = Enum.map(core, fn {actor, text} -> {actor, text} end)
    inner_filler_count = Map.get(beat, :inner_fillers, 32 + :rand.uniform(26))
    inner_filler = generate_filler(inner_filler_count, cast)
    head ++ interleave(body, inner_filler)
  end

  defp inter_beat_filler(_idx, _last_idx, cast) do
    count = 92 + :rand.uniform(58)
    generate_filler(count, cast)
  end

  defp interleave(core, filler) do
    n_core = length(core)

    if n_core == 0 do
      filler
    else
      {_, mixed} =
        Enum.reduce(core, {filler, []}, fn core_line, {remaining_filler, acc} ->
          take_n = min(length(remaining_filler), :rand.uniform(3) - 1)
          {taken, rest} = Enum.split(remaining_filler, take_n)
          {rest, acc ++ taken ++ [core_line]}
        end)

      mixed
    end
  end

  defp generate_filler(count, cast) do
    available = cast -- []
    char_pools = char_pools_for(cast)

    Enum.map(1..count, fn _ ->
      kind = :rand.uniform(100)

      cond do
        kind <= 15 ->
          actor = Enum.random(available)
          line = Enum.random(@ooc_fillers)
          {actor, line}

        kind <= 30 ->
          actor = Enum.random(available)
          line = Enum.random(@dice_fillers)
          line = String.replace(line, "{n}", to_string(:rand.uniform(20) + Enum.random([0, 2, 4])))
          {actor, line}

        kind <= 45 ->
          {"SL", Enum.random(sl_filler())}

        true ->
          actor = Enum.random(available)
          pool = Map.fetch!(char_pools, actor)
          line = Enum.random(pool)
          {actor, line}
      end
    end)
  end

  defp char_pools_for(cast) do
    base = %{
      "D'Artagnan" => @dartagnan_pool,
      "Athos" => @athos_pool,
      "Porthos" => @porthos_pool,
      "Aramis" => @aramis_pool
    }

    Map.take(base, cast)
  end

  defp utterances_to_events(utterances, session_id, started_at, ended_at) do
    total = length(utterances)
    duration_s = DateTime.diff(ended_at, started_at) - 120

    utterances
    |> Enum.map(fn {n, {actor, text}} ->
      did = did_for_actor(actor)
      offset_s = div(duration_s * (n - 1), max(total, 1)) + 60 + :rand.uniform(3)
      ts = DateTime.add(started_at, offset_s, :second)
      conf = sample_confidence()

      %{
        "kind" => "UtteranceAppended",
        "id" => "u-musk-s#{session_index_for(session_id)}-#{pad(n, 4)}",
        "session_id" => session_id,
        "discord_id" => did,
        "timestamp" => DateTime.to_iso8601(ts),
        "text" => text,
        "confidence" => conf,
        "status" => "confirmed"
      }
    end)
  end

  defp sample_confidence do
    if :rand.uniform(100) <= 5 do
      mean = 0.55 + :rand.uniform() * 0.25
      min_p = max(0.2, mean - 0.25)

      %{
        "mean_p" => Float.round(mean, 2),
        "min_p" => Float.round(min_p, 2),
        "low_token_fraction" => Float.round(0.15 + :rand.uniform() * 0.20, 2),
        "token_count" => 12 + :rand.uniform(20)
      }
    else
      mean = 0.85 + :rand.uniform() * 0.14
      min_p = max(0.6, mean - 0.15)

      %{
        "mean_p" => Float.round(mean, 2),
        "min_p" => Float.round(min_p, 2),
        "low_token_fraction" => Float.round(:rand.uniform() * 0.08, 2),
        "token_count" => 8 + :rand.uniform(24)
      }
    end
  end

  defp session_index_for("session-musk-" <> n), do: n
  defp session_index_for(_), do: "0"

  defp pad(n, width) do
    n |> Integer.to_string() |> String.pad_leading(width, "0")
  end

  defp did_for_actor("SL"), do: @sl_did

  defp did_for_actor(char_name) do
    {did, _, _} = Enum.find(@players, fn {_, _, c} -> c == char_name end)
    did
  end

  defp count_words(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp count_words(_), do: 0
end

MusketiereGenerator.run()
