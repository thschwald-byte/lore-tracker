defmodule Worker.Recording.Pipeline.Zeit do
  @moduledoc """
  Der Zeit-Anteil der Wahrheitsbild-Pipeline: aus den verifizierten Fakten
  einer Session den Chronik-Zeitstrahl publishen (#724 Slice E), und die
  Quell-Positionen der Blöcke bereitstellen, an denen die Chronik innerhalb
  eines Tages sortiert (#1092).

  Aus `Worker.Recording.Pipeline` herausgelöst, als diese über die
  God-Module-Grenze lief (#544). Der Schnitt ist kohäsiv, nicht willkürlich:
  dieser Teil hängt an nichts aus der Pipeline ausser `Repo`, `Intents` und
  den beiden Render-/Graph-Modulen — er teilt weder `with_status` noch den
  GenServer-State.

  Die zwei Vorfilter vor der Auflösung sind der Grund, warum die Chronik ein
  Zeitstrahl ist und kein Faktendump; ihre Begründung steht an
  `Worker.Timeline.Graph.time_signal?/2`.
  """

  require Logger

  alias Worker.Recording.Pipeline.Render
  alias Worker.Timeline.Graph

  # Issue #724 Slice E: den deterministischen Zeitstrahl aus den verifizierten
  # Fakten in die Chronik publishen. Auflösung: Graph.resolve datiert jeden Fakt
  # (gegen Campaign-Kalender + Session-Anker) → Render.timeline formt Chronik-
  # Einträge. Idempotenz wie Stage 4 (#227): erst ClearForSession, dann pro
  # Eintrag ChronikEntryChanged. Ein leerer Zeitstrahl clärt trotzdem (Re-Run
  # ohne datierbare Fakten hinterlässt keine Alt-Leichen).
  #
  # Issue #911/#958: VOR der Resolver-Auflösung zwei Vorfilter — nur echt
  # datierte (Graph.time_signal?/2, pure) UND nur arc-kind-Fakten
  # (Repo.filter_arc_kind/2, gleiche Zuordnung wie Resümee/Epos seit #909).
  # Ohne diese Filter landete praktisch jeder verifizierte Fakt in der
  # Chronik (Präsens-Fallback pinnt jeden undatierten Fakt aufs Session-
  # Anker-Datum) — die Chronik war ein Dump statt ein kuratierter Zeitstrahl.
  # Reihenfolge: das pure, billige Prädikat zuerst, der Mnesia-Read
  # (campaign_threads/1 unter der Haube) auf der kleineren Restmenge danach.
  def publiziere(session, campaign, verified_facts) do
    calendar = Worker.Repo.get_campaign_calendar(campaign.id)
    anchor = Worker.Repo.get_session_anchor(session.id)
    anchor_day = anchor && anchor.in_game_day
    # Issue #1092: die Genauigkeit der GM-Angabe begrenzt die der Fakten, die
    # an ihr hängen — „2081" darf keine taggenauen Fakten erzeugen.
    anchor_precision = anchor && anchor.precision

    # Issue #1069 (E7): der vom Vorlauf abgeleitete Session-Zeitrahmen. Trägt
    # er (`Graph.rahmen_belegt?/1`), zählt jeder Fakt dieser Session als
    # datierbar — der #958-Vorfilter greift dann nur noch für Sessions ohne
    # belegten Rahmen. Bewusste Produktentscheidung, s. `Graph.time_signal?/2`.
    rahmen = anchor && anchor.rahmen

    timeline_facts =
      verified_facts
      |> Enum.filter(&Graph.time_signal?(&1, rahmen))
      # Issue #1068 (E3): Typ-Filter nach dem Signal-Filter. `time_signal?/1`
      # sieht nur, DASS etwas Zeitliches dasteht — „sechs Jahre lang" passiert
      # ihn genauso wie ein Datum. Erst hier fällt raus, was keine Position auf
      # einem Tageszähler hat (Dauer, Uhrzeit, wiederkehrend, vage).
      |> Enum.filter(&Graph.datierbar?(&1, calendar))
      |> then(&Worker.Repo.filter_arc_kind(campaign.id, &1))

    Logger.info(
      "Pipeline[wahrheitsbild]: Timeline-Vorfilter session=#{session.id} " <>
        "#{length(timeline_facts)}/#{length(verified_facts)} Fakten arc-datiert " <>
        "rahmen=#{if Graph.rahmen_belegt?(rahmen), do: "belegt", else: "-"}"
    )

    entries =
      timeline_facts
      |> Graph.resolve(calendar, anchor_day, anchor_precision)
      |> Render.timeline(block_positions(session.id))

    # Issue #698 (I7): eine Generation pro Run für Clear + alle Entries (s.
    # stage4_publish) — der Clear-Watermark hält den aktuellen Run live und
    # unterdrückt frühere, order-insensitiv.
    generation = UUIDv7.generate()

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.chronik_cleared_for_session(),
        "campaign_id" => campaign.id,
        "session_id" => session.id,
        "cleared_by" => "llm",
        "generation" => generation
      })

    Enum.each(entries, fn e ->
      {:ok, _} =
        Worker.Intents.publish(%{
          "kind" => Shared.Events.chronik_entry_changed(),
          "id" => derive_timeline_id(session.id, e),
          "campaign_id" => campaign.id,
          "in_game_date" => e.in_game_date,
          "label" => e.label,
          "summary" => e.summary,
          "session_id" => session.id,
          "source_refs" => e.source_refs,
          "in_game_day" => e.in_game_day,
          "precision" => e.precision,
          "source_pos" => e.source_pos,
          "generation" => generation
        })
    end)

    # #752: Entries zurückgeben — der Epos-Kapitel-Kopf leitet seine Tag-Range
    # deterministisch daraus ab (best_effort_artifact reicht sie weiter).
    {:ok, entries}
  end

  def block_positions(session_id) do
    case Worker.Repo.get_smoothed_blocks(session_id) do
      %{blocks: blocks} when is_list(blocks) ->
        blocks
        |> Enum.with_index()
        |> Map.new(fn {b, i} -> {b["id"], i} end)

      _ ->
        %{}
    end
  end

  # Stabile ID pro Timeline-Eintrag. Anders als Stages.derive_chronik_id/2
  # (date|label) nimmt sie den Tageszähler UND die summary auf — sonst
  # kollidieren zwei Fakten derselben Figur am selben Tag zu einer Row. Der
  # ClearForSession davor macht Re-Runs ohnehin sauber.
  defp derive_timeline_id(session_id, entry) do
    seed =
      [session_id, to_string(entry.in_game_day || entry.in_game_date), entry.label, entry.summary]
      |> Enum.join("|")

    "chronik-" <> (:crypto.hash(:sha, seed) |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end
end
