# Generator für die „Ein Skandal in Böhmen"-Fidelity-Testset-Seeds (Issue #644).
#
# Schreibt JSONL-Files in `apps/hub/priv/seeds/skandal-boehmen/`:
#   01_setup.jsonl
#   02_session1.jsonl
#   03_session2.jsonl   (nur falls das Volumen zwei 4-h-Sessions hergibt)
#
# Aufruf vom Repo-Root:
#   elixir apps/hub/priv/seeds/skandal-boehmen/generator.exs
#
# Quelle gemeinfrei: Arthur Conan Doyle, „A Scandal in Bohemia" (1891; Doyle
# † 1930, global PD). Gespielt als Call-of-Cthulhu / BRP / Gaslight, mythos-frei
# (viktorianisches London 1888, kein Übernatürliches).
#
# ─── ZWECK (anders als die Demo-Seeds Romeo/Musketiere) ──────────────────
# Dies ist ein FIDELITY-TESTSET, kein Klick-Demo. Leitprinzipien:
#
#   1. DAS BUCH ABBILDEN, NICHT DAZUDICHTEN. Die Erzählung (SL-Beschreibung,
#      NPC-Dialog, Spieler-Dialog, Ermittlungs-Ausgänge) folgt 1:1 dem Plot.
#      Würfelwürfe sind an den Buch-Ausgang gekoppelt: das Buch sagt, ob die
#      Probe gelingt → der Wurf gelingt/misslingt entsprechend. Jede spätere
#      Resümee-Abweichung vom Buch ist damit ein echter Treuefehler.
#
#   2. CAST = QUELL-CAST. Holmes + Watson sind PCs. Ein SL spricht ALLE anderen
#      Figuren (König von Böhmen / Wilhelm von Ormstein, Irene Adler, Godfrey
#      Norton, Kutscher, Diener) UND beschreibt die Welt. Kein zusätzlicher PC,
#      der nicht-kanonischen Inhalt einbrächte.
#
#   3. FIGUR ≠ SPRECHER. `UtteranceAppended` trägt kein Figur-Feld pro Utterance
#      (nur `discord_id`); der SL ist ein Sprecher. Die Figur, die er gerade
#      spricht, lebt deshalb IM TEXT ("Der König, hinter der Maske: …",
#      "Irene, kühl im Vorbeigehen: …") — genau wie in einer echten Aufnahme.
#      Der spätere Attributions-Test misst, ob Stage 2 daraus korrekt
#      attribuiert. Der SL trägt den Alias „Spielleiter" — ein reines Rollen-
#      Label, KEIN Charakter (König/Irene/… bleiben im Text) —, damit er im
#      Protokoll als „Spielleiter" erscheint statt als rohe discord_id.
#
#   4. REGEL-NOISE ist canon-neutral. Würfel-Deklarationen, OOC-Tischgeplauder
#      und generische SL-Prompts werden eingestreut — sie tragen KEINE
#      Plot-Aussage (dichten also nichts dazu), füllen aber das realistische
#      4-h-Volumen UND sind genau die Noise, die Stage 2 rausfiltern muss.
#      KEINE Charakter-Banter-Pools (die würden Plot/Charakterisierung
#      erfinden, die nicht im Buch steht).
#
# Deterministisch — gleicher Generator-Code → identische JSONLs (der :rand-Seed
# steuert nur die Verteilung/Timestamps der canon-neutralen Noise, nie Inhalt).

Code.require_file(Path.join(__DIR__, "s1_beats.exs"))
Code.require_file(Path.join(__DIR__, "s2_beats.exs"))

defmodule SkandalGenerator do
  @out_dir Path.expand(Path.dirname(__ENV__.file))
  @campaign_id "skandal-boehmen-demo"
  @sl_did "300000000000000001"

  # PCs — Discord-IDs im 3e16-Range (kollisionsfrei: Romeo 1e16, Musk/Ehre 2e16).
  @players [
    {"300000000000000002", "Holmes-Spieler", "Sherlock Holmes"},
    {"300000000000000003", "Watson-Spieler", "Dr. Watson"}
  ]

  # ─── Setup-File ──────────────────────────────────────────────────────
  # NUR Holmes/Watson bekommen einen CampaignAliasSet (Figur-Name). Der SL
  # bekommt KEINEN — er bleibt „Spielleiter", seine NPCs leben im Text.

  def setup_events do
    invites =
      Enum.flat_map(@players, fn {did, display, char} ->
        token = "skandal-invite-#{String.slice(did, -3, 3)}"

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
        "name" => "Ein Skandal in Böhmen",
        "owner_discord_id" => @sl_did,
        "owner_display_name" => "Spielleiter",
        "theme_blurb" =>
          "Fidelity-Testset (Issue #644). Call-of-Cthulhu / BRP / Gaslight, mythos-frei — viktorianisches London 1888. Vorlage: Arthur Conan Doyle, „A Scandal in Bohemia\" (1891, gemeinfrei). PCs: Sherlock Holmes (Beratender Detektiv) + Dr. Watson (Begleiter, Arzt a.D.). Alle NPCs (König von Böhmen / Wilhelm von Ormstein, Irene Adler, Godfrey Norton, Kutscher, Diener) spielt der SL. Das Buch wird abgebildet, NICHT dazugedichtet; Würfelausgänge an den Buch-Plot gekoppelt. Zweck: reproduzierbares Stage-2-Treue-Testset (Regel-Noise-Filterung + Figur-aus-Kontext-Attribution).",
        "icon_url" => nil
      },
      %{
        "kind" => "UserUpserted",
        "discord_id" => @sl_did,
        "display_name" => "Spielleiter",
        "avatar_url" => nil
      },
      %{
        "kind" => "UserRoleSet",
        "discord_id" => @sl_did,
        "role" => "admin",
        "set_by" => "cli:lore.seed.skandal"
      },
      # Den SL explizit als Member + Alias „Spielleiter" eintragen. Ohne das wird
      # er beim --as-admin-Seed (Owner → Caller umgeschrieben) zum Nicht-Member,
      # und die member-scoped Sprecher-Auflösung fällt im Protokoll auf die rohe
      # discord_id zurück statt „Spielleiter". „Spielleiter" ist KEIN Charakter
      # (König/Irene/… bleiben im Text) — der Attributions-Test bleibt intakt.
      %{
        "kind" => "AdminMemberAdded",
        "campaign_id" => @campaign_id,
        "discord_id" => @sl_did,
        "display_name" => "Spielleiter"
      },
      %{
        "kind" => "CampaignAliasSet",
        "campaign_id" => @campaign_id,
        "discord_id" => @sl_did,
        "character_name" => "Spielleiter"
      }
    ] ++
      invites ++
      [
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "summary",
          "voice" =>
            "Sachliches Session-Resümee eines viktorianischen Ermittlungsfalls. Erzählerische Prosa, Vergangenheitsform. Regel-Noise (Würfel, OOC, Probenaufforderungen) gehört NICHT ins Resümee — nur die erzählten Ereignisse. NPCs beim Namen nennen, auch wenn sie vom SL gesprochen werden."
        },
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "epos",
          "voice" =>
            "Im Ton einer viktorianischen Erzählung à la Dr. Watsons Aufzeichnungen. Trocken, beobachtend."
        },
        %{
          "kind" => "CampaignFlavorSet",
          "campaign_id" => @campaign_id,
          "slot" => "chronik",
          "voice" =>
            "In-Game-Zeitstrahl. Datierung nach den Tagen des Falls (Briefdatum 20. März 1888 als Tag 1)."
        }
      ]
  end

  # ─── Session-Beat-Daten ─────────────────────────────────────────────

  def session_beats(1), do: SkandalGenerator.S1.beats()
  def session_beats(2), do: SkandalGenerator.S2.beats()

  # Sessions, die geschrieben werden: {file_n, session_n, started_at}.
  # NUR nummeriert + datiert — eine echte Aufnahme kennt zur Aufnahmezeit KEINEN
  # Titel (der entstünde erst aus dem Resümee). Kein thematischer Name → das
  # Label zeigt nur „Session N". Alles weitere wäre Nachwissen-Leck.
  def sessions do
    [
      {2, 1, ~U[2026-04-12 19:00:00Z]},
      {3, 2, ~U[2026-04-19 19:00:00Z]}
    ]
  end

  # ─── Generator ──────────────────────────────────────────────────────

  def run do
    File.mkdir_p!(@out_dir)
    write!("01_setup.jsonl", setup_events())

    Enum.each(sessions(), fn {file_n, session_n, started_at} ->
      write_session!(file_n, session_n, started_at)
    end)

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

  defp write_session!(file_n, session_n, started_at) do
    session_id = "session-skandal-#{session_n}"
    beats = session_beats(session_n)

    :rand.seed(:exsss, {session_n, 1888, 221})

    scheduled = %{
      "kind" => "SessionScheduled",
      "id" => session_id,
      "campaign_id" => @campaign_id,
      "name" => "",
      "number" => session_n,
      "scheduled_for" => DateTime.to_iso8601(started_at)
    }

    started = %{
      "kind" => "SessionStarted",
      "id" => session_id,
      "started_at" => DateTime.to_iso8601(DateTime.add(started_at, 60, :second)),
      "started_by_discord_id" => @sl_did
    }

    {utterances, _} =
      beats
      |> Enum.flat_map_reduce(0, fn beat, counter ->
        number_lines(expand_beat(beat), counter)
      end)

    ended_at = DateTime.add(started_at, 4 * 3600 + 30 * 60, :second)
    utt_events = utterances_to_events(utterances, session_id, session_n, started_at, ended_at)

    ended = %{
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

  # Ein Beat = %{dm: "<SL-Erzählung/NPC-Stimme>", core: [{actor, text}, ...]}.
  # Alles ist hand-geschrieben & buchtreu — der Generator injiziert KEINE
  # zufällige Noise. Regel-Noise (Proben, Würfe) ist DIEGETISCH: sie steht in
  # `core` genau an den Handlungspunkten, an denen das Buch eine Probe auslöst
  # (Holmes beobachtet → Entdecken dort; Verkleidung → Verkleiden-Probe dort;
  # die Verfolgung → Glück/Fahren dort). So hängt jede Probe an einer Handlung,
  # die das Resümee behalten muss, während die Probe selbst rausgefiltert
  # gehört. Das Volumen kommt aus der Erzählung, nicht aus Füllmaterial.
  defp expand_beat(%{dm: dm, core: core}) do
    head = if dm in [nil, ""], do: [], else: [{"SL", dm}]
    head ++ core
  end

  defp utterances_to_events(utterances, session_id, session_n, started_at, ended_at) do
    total = length(utterances)
    duration_s = DateTime.diff(ended_at, started_at) - 120

    utterances
    |> Enum.map(fn {n, {actor, text}} ->
      did = did_for_actor(actor)
      offset_s = div(duration_s * (n - 1), max(total, 1)) + 60 + :rand.uniform(3)
      ts = DateTime.add(started_at, offset_s, :second)

      %{
        "kind" => "UtteranceAppended",
        "id" => "u-skandal-s#{session_n}-#{pad(n, 4)}",
        "session_id" => session_id,
        "discord_id" => did,
        "timestamp" => DateTime.to_iso8601(ts),
        "text" => text,
        "confidence" => sample_confidence(),
        "status" => "confirmed"
      }
    end)
  end

  defp sample_confidence do
    if :rand.uniform(100) <= 5 do
      mean = 0.55 + :rand.uniform() * 0.25

      %{
        "mean_p" => Float.round(mean, 2),
        "min_p" => Float.round(max(0.2, mean - 0.25), 2),
        "low_token_fraction" => Float.round(0.15 + :rand.uniform() * 0.20, 2),
        "token_count" => 12 + :rand.uniform(20)
      }
    else
      mean = 0.85 + :rand.uniform() * 0.14

      %{
        "mean_p" => Float.round(mean, 2),
        "min_p" => Float.round(max(0.6, mean - 0.15), 2),
        "low_token_fraction" => Float.round(:rand.uniform() * 0.08, 2),
        "token_count" => 8 + :rand.uniform(24)
      }
    end
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  defp did_for_actor("SL"), do: @sl_did

  defp did_for_actor(char_name) do
    {did, _, _} = Enum.find(@players, fn {_, _, c} -> c == char_name end)
    did
  end

  defp count_words(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp count_words(_), do: 0
end

SkandalGenerator.run()
