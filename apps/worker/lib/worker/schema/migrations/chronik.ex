defmodule Worker.Schema.Migrations.Chronik do
  @moduledoc """
  Issue #1092 (God-Module-Split aus `Worker.Schema.Migrations`, #544): die
  Spalten-Migrationen der Chronik- und Zeitstrahl-Tabellen — `chronik_entries`
  und `session_anchors`.

  Warum als eigenes Modul: der Zuwachs durch #1092 (`source_pos` an der
  Chronik, `precision` am Session-Anker) hätte die 1000-Zeilen-Grenze des
  Elternmoduls gerissen. Der Schnitt ist inhaltlich und nicht bloß nach
  Zeilenzahl: diese Migrationen bilden die Entwicklung EINER Ansicht ab —
  von der Freitext-Chronik (#650) über den Zeitstrahl (#724) und den
  Clear-Watermark (#698) bis zur Ordnung innerhalb eines Tages (#1092).

  Reihenfolge ist Teil des Vertrags: jede Migration hängt trailing an, also
  muss sie in genau der Folge laufen, in der sie hier steht (`Mnesia.bootstrap!`
  ruft sie so auf). Eine dazwischengeschobene Spalte verschöbe die Indizes
  aller späteren Rows.
  """
  alias Worker.Schema.Mnesia

  @chronik_entries Mnesia.chronik_entries()
  @session_anchors Mnesia.session_anchors()

  def migrate_chronik_entries_add_source_refs! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :source_refs in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid} ->
        {tbl, id, cid, date, label, summary, sid, []}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #385: markdown_body als 9. Spalte am Ende. Verbatim User-Markdown
  # für die Chronik-Anzeige im Hub. Default nil → Lazy-Migration alter
  # Einträge beim ersten Edit. Idempotent.
  def migrate_chronik_entries_add_markdown_body! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :markdown_body in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs} ->
        {tbl, id, cid, date, label, summary, sid, refs, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #724: Zeitstrahl-Spalten `in_game_day` (Integer|nil, kanonischer
  # Tageszähler = Sort-Schlüssel) + `precision` (String|nil, Rendering). Alte
  # Rows → nil (Familie-1-Sort-Fallback in list_chronik_entries, kein Verhaltens-
  # Change). arity 9 → 11.
  def migrate_chronik_entries_add_timeline! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :in_game_day in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body,
        :in_game_day,
        :precision
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs, md} ->
        {tbl, id, cid, date, label, summary, sid, refs, md, nil, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #698 (I7-Bucket-D): trailing `generation` an chronik_entries — der
  # Ordnungsschlüssel für den Clear-Watermark-Vergleich (Row live gdw.
  # generation >= clear_key). Für Pipeline-Runs ist das eine pro Run einmal
  # gemintete UUIDv7 (Clear + alle Entries des Runs teilen sie → within-run
  # zuverlässig, ohne auf UUIDv7-Sub-ms-Monotonie zu bauen). Für solitäre Events
  # (Hub-Manual-Edit, Seeds ohne `generation`) fällt der Materializer auf die
  # Envelope-event_id zurück. Alt-Rows bekommen nil (= „−∞", von jedem Mark
  # unterdrückt, sobald einer existiert; ohne Mark live — heutiges Verhalten).
  def migrate_chronik_entries_add_generation! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :generation in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body,
        :in_game_day,
        :precision,
        :generation
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs, md, day, precision} ->
        {tbl, id, cid, date, label, summary, sid, refs, md, day, precision, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #1092: trailing `source_pos` an chronik_entries — die Position der
  # frühesten Quelle des Eintrags im geglätteten Transkript, als Sekundär-
  # schlüssel INNERHALB eines In-Game-Tages.
  #
  # Ohne ihn hatten alle Einträge desselben Tages denselben Sort-Schlüssel
  # (`{0, day, ""}`); `Enum.sort_by/2` ist stabil, also entschied darunter die
  # Leseordnung einer `:set`-Tabelle, die niemand festgelegt hat. Real gemessen
  # an „Real Free Seattle": 543 von 544 Einträgen auf einem Tag, aufsteigende
  # Nachbarpaare 266/543 = 0,49 — Zufallsniveau.
  #
  # Alt-Rows bekommen `nil`. Der Reader sortiert die ans ENDE ihres Tages
  # (`sort_pos/1`), statt sie über einen `nil < integer`-Vergleich zufällig nach
  # vorn rutschen zu lassen — ein Regenerate mischt befüllte und unbefüllte.
  def migrate_chronik_entries_add_source_pos! do
    current_attrs = :mnesia.table_info(@chronik_entries, :attributes)

    if :source_pos in current_attrs do
      :ok
    else
      target_attrs = [
        :id,
        :campaign_id,
        :in_game_date,
        :label,
        :summary,
        :session_id,
        :source_refs,
        :markdown_body,
        :in_game_day,
        :precision,
        :generation,
        :source_pos
      ]

      transform = fn {tbl, id, cid, date, label, summary, sid, refs, md, day, precision, gen} ->
        {tbl, id, cid, date, label, summary, sid, refs, md, day, precision, gen, nil}
      end

      {:atomic, :ok} = :mnesia.transform_table(@chronik_entries, transform, target_attrs)
      :ok
    end
  end

  # Issue #1092: trailing `precision` an session_anchors — die Genauigkeit der
  # GM-Angabe, abgeleitet aus dem Roh-String (`Resolver.infer_precision/2`).
  #
  # `Calendar.parse/2` macht aus einem blanken Jahr still den 1. Januar; ohne
  # eine mitgeführte Präzision ist danach nicht mehr unterscheidbar, ob der GM
  # „2081" oder „01.01.2081" eingetragen hat. Jeder Fakt, der an diesem Anker
  # hängt, wurde dadurch taggenau angezeigt.
  #
  # Alt-Rows bekommen `nil` = „unbekannt". Der Resolver behandelt das wie
  # bisher (keine Untergrenze) — kein Verhaltens-Change ohne Re-Save des
  # Ankers, und ein Re-Save reicht, um die Präzision nachzuziehen.
  def migrate_session_anchors_add_precision! do
    current_attrs = :mnesia.table_info(@session_anchors, :attributes)

    if :precision in current_attrs do
      :ok
    else
      target_attrs = [:session_id, :campaign_id, :in_game_day, :in_game_date_raw, :precision]

      transform = fn {tbl, sid, cid, day, raw} -> {tbl, sid, cid, day, raw, nil} end

      {:atomic, :ok} = :mnesia.transform_table(@session_anchors, transform, target_attrs)
      :ok
    end
  end
end
