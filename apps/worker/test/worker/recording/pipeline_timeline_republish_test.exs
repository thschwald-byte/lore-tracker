defmodule Worker.Recording.PipelineTimelineRepublishTest do
  @moduledoc """
  Issue #1211 (J7): der deterministische Zeitstrahl-Republish ist
  **stillgelegt** — und dieser Wächter hält fest, dass das Absicht war.

  Was hier bis #1211 geprüft wurde (#724 Slice F): `republish_timeline_for_session/1`
  baute nach einer Datumskorrektur in der Review-Queue die Chronik einer
  Sitzung neu — datierter Fakt landet im Zeitstrahl, Doppel-Lauf idempotent
  über den #698-Watermark, fehlende Extraktion ohne Wipe, `dismissed`
  ausgeschlossen, Election-Gate.

  **Warum das weg ist.** Die Chronik schreibt seit J7 der Chronik-Jack:
  gebündelte Phasen über Sitzungsgrenzen, Reihenfolge statt gerechneter Tage.
  Einen deterministischen Weg zurück gibt es nicht mehr — und ein Modelllauf
  ist nichts, was man als Nebenwirkung einer Kuration startet (der
  Resümee-Jack brauchte auf der Teststage 10 bis 72 Minuten, und eine
  Kuration ist ein Batch-Vorgang). Die Review-Liste, die diesen Pfad
  auslöste, entfällt mit demselben Ticket.

  **Die ehrliche Folge steht im Code und hier:** Nach einer Lücken-Kuration
  oder einer Neu-Extraktion ziehen die Fakten sofort nach, die Chronik erst
  beim nächsten regulären Pipeline-Lauf. Bis dahin kann sie Fakten zitieren,
  die inzwischen anders lauten.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline

  test "der Republish tut nichts mehr und sagt :ok" do
    # Kein Repo-Zugriff, keine Ereignisse: die Funktion ist ein Stummel, damit
    # ihre drei Aufrufer in `Pipeline.Dirty` nicht ins Leere greifen.
    assert Pipeline.republish_timeline_for_session("beliebige-session") == :ok
  end

  test "der alte Pfad ist aus der Pipeline verschwunden" do
    # Quelltext-Wächter: `Zeit.publiziere/3` rechnete aus jedem verifizierten
    # Fakt einen datierten Eintrag. Käme der Aufruf zurück, entstünde neben
    # der Jack-Chronik eine zweite, nach anderen Regeln gebaute — und die
    # jüngere Generation gewänne, ohne dass etwas rot würde.
    quelle = File.read!("lib/worker/recording/pipeline.ex")

    refute quelle =~ "Zeit.publiziere(",
           "Der deterministische Chronik-Pfad ist zurück — siehe #1211: die Chronik " <>
             "schreibt der Chronik-Jack, sonst entstehen zwei Chroniken nebeneinander."

    assert quelle =~ "chronik_jack(session, campaign, run_id",
           "Der Chronik-Jack wird nicht mehr aufgerufen — dann entsteht gar keine Chronik."
  end
end
