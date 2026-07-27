defmodule Worker.RenderSlotsConvergenceTest do
  @moduledoc """
  Issue #914 (Cut 0): die kuratiert/generiert-Slots durch den echten
  Materializer. Kern ist der **Persistenz-Rundlauf** (Edit → Regenerate →
  Edit überlebt) — der Regressionstest, der mit dem alten ts-LWW ROT wäre.
  Dazu die Review-Matrix: version-gebundene Freigabe, Rebuild macht Freigabe
  stale, Reorder (event_id-LWW, order-insensitiv), Concurrent-Regenerate.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-914"
  @sid "camp-914-s1"
  @eid "camp-914-ep1"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, sessions: [1], apply: true)
    :ok
  end

  defp generated(md, seq) do
    Materializer.apply_event(
      event(
        "SessionSummaryGenerated",
        %{"session_id" => @sid, "campaign_id" => @cid, "content_md" => md, "source" => "llm"},
        seq,
        event_id: eid(seq)
      )
    )
  end

  defp edited(md, seq) do
    Materializer.apply_event(
      event(
        "SessionSummaryEdited",
        %{"session_id" => @sid, "campaign_id" => @cid, "new_md" => md},
        seq,
        event_id: eid(seq)
      )
    )
  end

  defp release(version_id, seq) do
    Materializer.apply_event(
      event(
        "RenderReleaseSet",
        %{"artifact_type" => "summary", "artifact_key" => @sid, "version_id" => version_id},
        seq,
        event_id: eid(seq)
      )
    )
  end

  # event_id monoton in seq (UUIDv7-Surrogat: zero-padded, lexikografisch = seq-Ordnung).
  defp eid(seq), do: "ev-" <> String.pad_leading(Integer.to_string(seq), 4, "0")

  defp display, do: Repo.get_session_summary_display(@sid)
  defp shown, do: Repo.get_session_summary(@sid).content_md

  # ── DER Regressionstest: der Edit überlebt den Regenerate ──
  test "Rundlauf: Edit → Regenerate → der manuelle Edit überlebt (mit ts-LWW wäre das ROT)" do
    generated("G1", 10)
    edited("M1", 11)
    generated("G2", 12)

    assert shown() == "M1"
    d = display()
    assert d.source == :kuratiert
    assert d.rebuild_available?
    assert Repo.get_session_summary(@sid).source == :manual
  end

  test "Freigabe für die aktuelle version_id → generiert angezeigt, kein Prompt" do
    generated("G1", 10)
    edited("M1", 11)
    release(eid(10), 12)

    assert shown() == "G1"
    d = display()
    assert d.source == :generiert
    refute d.rebuild_available?
    assert Repo.get_session_summary(@sid).source == :llm
  end

  test "Freigabe für v1, dann Rebuild v2 → Freigabe stale → kuratiert + Prompt erscheint erneut" do
    generated("G1", 10)
    edited("M1", 11)
    release(eid(10), 12)
    assert shown() == "G1"

    generated("G2", 13)
    assert shown() == "M1"
    assert display().rebuild_available?
  end

  test "Reorder: Events verkehrt herum angewandt → event_id-LWW konvergiert identisch" do
    # Zielzustand: G1(10), M1(11), G2(12) → kuratiert M1. Verkehrt angewandt.
    generated("G2", 12)
    edited("M1", 11)
    generated("G1", 10)

    assert shown() == "M1"
    assert display().source == :kuratiert
  end

  test "Concurrent-Regenerate: höhere event_id gewinnt den generiert-Slot (event_id-LWW)" do
    generated("G_lo", 10)
    generated("G_hi", 12)
    # keine Kuration → generiert angezeigt, die spätere version_id gewinnt.
    assert shown() == "G_hi"
    # niedrigere event_id danach → verworfen (order-insensitiv).
    generated("G_stale", 11)
    assert shown() == "G_hi"
  end

  test "Reorder der Freigabe: Edit e13 nach Freigabe e12 → manuell gewinnt wieder" do
    generated("G1", 10)
    edited("M1", 11)
    release(eid(10), 12)
    assert shown() == "G1"
    # ein neuer Edit NACH der Freigabe holt die manuelle Fassung zurück.
    edited("M2", 13)
    assert shown() == "M2"
    assert display().source == :kuratiert
  end

  # ── Epos: dieselbe Mechanik, source-geroutet über EIN Event ──
  defp epos_ev(md, source, seq) do
    Materializer.apply_event(
      event(
        "EposEntryEdited",
        %{"entry_id" => @eid, "campaign_id" => @cid, "new_md" => md, "source" => source},
        seq,
        event_id: eid(seq)
      )
    )
  end

  test "Epos-Rundlauf: llm-Render → manueller Edit → llm-Render → der Edit überlebt" do
    epos_ev("G1", "llm", 20)
    epos_ev("M1", "manual", 21)
    epos_ev("G2", "llm", 22)

    assert Repo.get_epos_entry(@eid).content_md == "M1"
  end

  test "Epos-Freigabe: RenderReleaseSet(epos) auf die aktuelle version_id → generiert" do
    epos_ev("G1", "llm", 20)
    epos_ev("M1", "manual", 21)

    Materializer.apply_event(
      event(
        "RenderReleaseSet",
        %{"artifact_type" => "epos", "artifact_key" => @eid, "version_id" => eid(20)},
        22,
        event_id: eid(22)
      )
    )

    assert Repo.get_epos_entry(@eid).content_md == "G1"

    # neuer Render → Freigabe stale → manuelle Fassung kehrt zurück.
    epos_ev("G3", "llm", 23)
    assert Repo.get_epos_entry(@eid).content_md == "M1"
  end
end
